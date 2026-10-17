import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Modal,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { useAuth } from '../context/AuthContext';
import { supabase } from '../services/supabase';

interface MemberProfile {
  full_name: string;
  savings_balance: number;
  share_capital: number;
  active_loan: number;
}

interface TransactionRecord {
  id: string;
  title: string;
  amount: number;
  type: 'credit' | 'debit';
  created_at?: string;
}

type LoanType = 'short_term' | 'mid_term' | 'long_term';

export default function MemberDashboardScreen() {
  const { session, signOut } = useAuth();
  const [profile, setProfile] = useState<MemberProfile | null>(null);
  const [loadingProfile, setLoadingProfile] = useState(true);

  // Navigation & View States
  const [activeTab, setActiveTab] = useState<'Home' | 'Savings' | 'Loans' | 'Profile'>('Home');
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [amountInput, setAmountInput] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [depositVisible, setDepositVisible] = useState(false);
  const [loanApplyVisible, setLoanApplyVisible] = useState(false);
  const [loanRepayVisible, setLoanRepayVisible] = useState(false);
  const [selectedLoanType, setSelectedLoanType] = useState<LoanType>('short_term');
  const [activities, setActivities] = useState<TransactionRecord[]>([]);

  const fetchMemberData = async () => {
    if (!session?.user.id) {
      setProfile(null);
      setActivities([]);
      setLoadingProfile(false);
      return;
    }

    setLoadingProfile(true);
    try {
      const { data: profileData, error: profileError } = await supabase
        .from('profiles')
        .select('full_name, savings_balance, share_capital, active_loan')
        .eq('id', session.user.id)
        .single();
      if (profileError) throw profileError;
      setProfile(profileData);

      const { data: transactionData, error: transactionError } = await supabase
        .from('transactions')
        .select('id, title, amount, type, created_at')
        .eq('user_id', session.user.id)
        .order('created_at', { ascending: false })
        .limit(10);
      if (transactionError) throw transactionError;
      setActivities(transactionData ?? []);
    } catch (err) {
      console.error('Data fetch error:', err);
    } finally {
      setLoadingProfile(false);
    }
  };

  useEffect(() => {
    fetchMemberData();
  }, [session]);

  const formatCurrency = (minorUnits: number) => {
    const val = (minorUnits || 0) / 100;
    return '₦' + val.toLocaleString('en-NG', { minimumFractionDigits: 0, maximumFractionDigits: 0 });
  };

  const getTimeGreeting = () => {
    const hour = new Date().getHours();
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  };

  const getInitials = (name: string) => {
    if (!name) return 'MB';
    const parts = name.trim().split(' ');
    if (parts.length >= 2 && parts[0] && parts[1]) {
      return `${parts[0][0]}${parts[1][0]}`.toUpperCase();
    }
    return name.substring(0, 2).toUpperCase();
  };

  const getLoanConfig = (type: LoanType) => {
    switch (type) {
      case 'short_term':
        return { label: 'Short-Term', months: 3, rate: 0.05, percent: '5%' };
      case 'mid_term':
        return { label: 'Mid-Term', months: 6, rate: 0.07, percent: '7%' };
      case 'long_term':
        return { label: 'Long-Term', months: 12, rate: 0.10, percent: '10%' };
    }
  };

  const currentConfig = getLoanConfig(selectedLoanType);
  const principalNaira = parseFloat(amountInput) || 0;
  const interestNaira = principalNaira * currentConfig.rate;
  const totalRepaymentNaira = principalNaira + interestNaira;

  const netPosition =
    (profile?.savings_balance || 0) +
    (profile?.share_capital || 0) -
    (profile?.active_loan || 0);

  // Deposit Handler
  const handleDeposit = async () => {
    const amountNaira = parseFloat(amountInput);
    if (isNaN(amountNaira) || amountNaira <= 0) {
      Alert.alert('Invalid Amount', 'Please enter a valid amount in Naira.');
      return;
    }

    const minorUnits = Math.round(amountNaira * 100);
    setSubmitting(true);

    try {
      const newSavings = (profile?.savings_balance || 0) + minorUnits;

      // Update Profile Balance
      await supabase
        .from('profiles')
        .update({ savings_balance: newSavings })
        .eq('id', session?.user.id);

      // Log Transaction
      await supabase.from('transactions').insert([
        {
          user_id: session?.user.id,
          title: 'Savings deposit',
          amount: minorUnits,
          type: 'credit',
        },
      ]);

      Alert.alert('Success', `Successfully deposited ${formatCurrency(minorUnits)} into savings!`);
      setAmountInput('');
      setDepositVisible(false);
      fetchMemberData();
    } catch (err: any) {
      Alert.alert('Deposit Failed', err.message);
    } finally {
      setSubmitting(false);
    }
  };

  // Apply Loan Handler
  const handleApplyLoan = async () => {
    if (principalNaira <= 0) {
      Alert.alert('Invalid Amount', 'Please enter a valid principal loan amount.');
      return;
    }

    const principalKobo = Math.round(principalNaira * 100);
    const totalRepaymentKobo = Math.round(totalRepaymentNaira * 100);

    setSubmitting(true);

    try {
      await supabase.from('loan_applications').insert([
        {
          user_id: session?.user.id,
          loan_type: selectedLoanType,
          principal_amount: principalKobo,
          interest_rate: currentConfig.rate * 100,
          total_repayment: totalRepaymentKobo,
          duration_months: currentConfig.months,
          status: 'active',
        },
      ]);

      const newActiveLoan = (profile?.active_loan || 0) + totalRepaymentKobo;
      await supabase
        .from('profiles')
        .update({ active_loan: newActiveLoan })
        .eq('id', session?.user.id);

      await supabase.from('transactions').insert([
        {
          user_id: session?.user.id,
          title: `${currentConfig.label} Loan Approved`,
          amount: principalKobo,
          type: 'credit',
        },
      ]);

      Alert.alert(
        'Loan Approved',
        `${currentConfig.label} loan for ${formatCurrency(principalKobo)} applied successfully!`
      );

      setAmountInput('');
      setLoanApplyVisible(false);
      fetchMemberData();
    } catch (err: any) {
      Alert.alert('Application Error', err.message);
    } finally {
      setSubmitting(false);
    }
  };

  // Repay Loan Handler
  const handleRepayLoan = async () => {
    const amountNaira = parseFloat(amountInput);
    if (isNaN(amountNaira) || amountNaira <= 0) {
      Alert.alert('Invalid Amount', 'Please enter a valid repayment amount.');
      return;
    }

    const minorUnits = Math.round(amountNaira * 100);
    setSubmitting(true);

    try {
      const activeLoan = profile?.active_loan || 0;
      const newActiveLoan = Math.max(0, activeLoan - minorUnits);

      await supabase
        .from('profiles')
        .update({ active_loan: newActiveLoan })
        .eq('id', session?.user.id);

      await supabase.from('transactions').insert([
        {
          user_id: session?.user.id,
          title: 'Loan repayment',
          amount: minorUnits,
          type: 'debit',
        },
      ]);

      Alert.alert('Success', `Repaid ${formatCurrency(minorUnits)} towards active loan balance.`);
      setAmountInput('');
      setLoanRepayVisible(false);
      fetchMemberData();
    } catch (err: any) {
      Alert.alert('Repayment Error', err.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar backgroundColor="#121315" barStyle="light-content" />

      {/* Top Bar Navigation */}
      <View style={styles.topBar}>
        <TouchableOpacity onPress={() => setDrawerOpen(true)} style={styles.iconButton}>
          <Text style={styles.topIconText}>Menu</Text>
        </TouchableOpacity>
        <View style={styles.topRightContainer}>
          <TouchableOpacity onPress={() => setDrawerOpen(true)} style={styles.iconButton}>
            <Text style={styles.topIconText}>Account</Text>
          </TouchableOpacity>
        </View>
      </View>

      <ScrollView contentContainerStyle={styles.scrollContent} showsVerticalScrollIndicator={false}>
        
        {/* Member Greeting Header */}
        <View style={styles.greetingHeader}>
          <View>
            <Text style={styles.greetingSubtitle}>{getTimeGreeting()}</Text>
            {loadingProfile ? (
              <ActivityIndicator size="small" color="#3B82F6" style={{ alignSelf: 'flex-start', marginTop: 4 }} />
            ) : (
              <Text style={styles.memberName}>{profile?.full_name || 'Member'}</Text>
            )}
          </View>
          <TouchableOpacity onPress={() => setDrawerOpen(true)} style={styles.avatarBadge}>
            <Text style={styles.avatarText}>
              {profile ? getInitials(profile.full_name) : 'MB'}
            </Text>
          </TouchableOpacity>
        </View>

        {/* Dynamic Tab Screen Switcher */}
        {activeTab === 'Home' && (
          <>
            {/* Net Position Card */}
            <View style={styles.netPositionCard}>
              <Text style={styles.netPositionLabel}>Net Position</Text>
              <Text style={styles.netPositionValue}>{formatCurrency(netPosition)}</Text>
            </View>

            {/* Dual Financial Cards */}
            <View style={styles.dualCardsRow}>
              <View style={[styles.summaryCard, styles.halfCard]}>
                <Text style={styles.summaryCardLabel}>Savings Balance</Text>
                <Text style={styles.summaryCardValue}>
                  {formatCurrency(profile?.savings_balance ?? 0)}
                </Text>
              </View>

              <View style={[styles.summaryCard, styles.halfCard]}>
                <Text style={styles.summaryCardLabel}>Share Capital</Text>
                <Text style={styles.summaryCardValue}>
                  {formatCurrency(profile?.share_capital ?? 0)}
                </Text>
              </View>
            </View>

            {/* Active Loan Card */}
            <View style={styles.loanCard}>
              <View style={styles.loanHeaderRow}>
                <Text style={styles.loanTitle}>Active Loan Facility</Text>
                <View style={styles.activeTag}>
                  <Text style={styles.activeTagText}>Active</Text>
                </View>
              </View>
              <Text style={styles.loanAmountText}>
                {formatCurrency(profile?.active_loan ?? 0)}{' '}
                <Text style={styles.loanOutstandingLabel}>outstanding</Text>
              </Text>

              <View style={styles.loanActionRow}>
                <TouchableOpacity onPress={() => {
                    setAmountInput('');
                    setLoanApplyVisible(true);
                  }} style={styles.loanInlineBtn}>
                  <Text style={styles.loanInlineBtnText}>+ Apply Loan</Text>
                </TouchableOpacity>

                <TouchableOpacity
                  onPress={() => {
                    setAmountInput('');
                    setLoanRepayVisible(true);
                  }}
                  style={[styles.loanInlineBtn, styles.loanRepayBtn]}
                >
                  <Text style={styles.loanInlineBtnText}>Repay Loan</Text>
                </TouchableOpacity>
              </View>
            </View>

            {/* Live Recent Activity */}
            <Text style={styles.sectionTitle}>Recent Activity</Text>
            <View style={styles.activityList}>
              {activities.map((item) => (
                <View key={item.id} style={styles.activityRow}>
                  <View style={styles.activityLeft}>
                    <View
                      style={[
                        styles.activityIconBadge,
                        item.type === 'credit' ? styles.creditBadge : styles.debitBadge,
                      ]}
                    >
                      <Text
                        style={[
                          styles.activityIconText,
                          item.type === 'credit' ? styles.creditIconText : styles.debitIconText,
                        ]}
                      >
                        {item.type === 'credit' ? '+' : '-'}
                      </Text>
                    </View>
                    <Text style={styles.activityTitle}>{item.title}</Text>
                  </View>
                  <Text
                    style={[
                      styles.activityAmount,
                      item.type === 'credit' ? styles.creditAmount : styles.debitAmount,
                    ]}
                  >
                    {item.type === 'credit' ? '+' : '-'}{formatCurrency(item.amount)}
                  </Text>
                </View>
              ))}
            </View>
          </>
        )}

        {/* Dedicated Savings View */}
        {activeTab === 'Savings' && (
          <View>
            <View style={styles.tabHeaderCard}>
              <Text style={styles.tabHeaderTitle}>Savings Ledger Breakdown</Text>
              <Text style={styles.tabHeaderAmount}>{formatCurrency(profile?.savings_balance ?? 0)}</Text>
            </View>

            <TouchableOpacity
              onPress={() => {
                setAmountInput('');
                setDepositVisible(true);
              }}
              style={styles.fullWidthBtn}
            >
              <Text style={styles.fullWidthBtnText}>+ Deposit Into Savings Ledger</Text>
            </TouchableOpacity>

            <Text style={styles.sectionTitle}>Savings History</Text>
            <View style={styles.activityList}>
              {activities
                .filter((a) => a.title.toLowerCase().includes('savings') || a.type === 'credit')
                .map((item) => (
                  <View key={item.id} style={styles.activityRow}>
                    <Text style={styles.activityTitle}>{item.title}</Text>
                    <Text style={styles.creditAmount}>+{formatCurrency(item.amount)}</Text>
                  </View>
                ))}
            </View>
          </View>
        )}

        {/* Dedicated Loans View */}
        {activeTab === 'Loans' && (
          <View>
            <View style={[styles.tabHeaderCard, { backgroundColor: '#381E0B', borderColor: '#542D11' }]}>
              <Text style={[styles.tabHeaderTitle, { color: '#F97316' }]}>Active Outstanding Loan</Text>
              <Text style={styles.tabHeaderAmount}>{formatCurrency(profile?.active_loan ?? 0)}</Text>
            </View>

            <View style={styles.dualBtnRow}>
              <TouchableOpacity onPress={() => {
                  setAmountInput('');
                  setLoanApplyVisible(true);
                }} style={[styles.halfWidthBtn, { backgroundColor: '#2563EB' }]}>
                <Text style={styles.fullWidthBtnText}>Apply Loan</Text>
              </TouchableOpacity>

              <TouchableOpacity onPress={() => {
                  setAmountInput('');
                  setLoanRepayVisible(true);
                }} style={[styles.halfWidthBtn, { backgroundColor: '#2A2D34' }]}>
                <Text style={styles.fullWidthBtnText}>Repay Loan</Text>
              </TouchableOpacity>
            </View>

            <Text style={styles.sectionTitle}>Loan Policy Parameters</Text>
            <View style={styles.policyCard}>
              <Text style={styles.policyRow}>• Short-Term: 3 Months @ 5% Interest</Text>
              <Text style={styles.policyRow}>• Mid-Term: 6 Months @ 7% Interest</Text>
              <Text style={styles.policyRow}>• Long-Term: 12 Months @ 10% Interest</Text>
            </View>
          </View>
        )}

      </ScrollView>

      {/* Text-Based Bottom Navigation Bar */}
      <View style={styles.bottomTabBar}>
        <TouchableOpacity onPress={() => setActiveTab('Home')} style={styles.tabItem}>
          <Text style={[styles.tabText, activeTab === 'Home' && styles.activeTabText]}>Home</Text>
        </TouchableOpacity>

        <TouchableOpacity onPress={() => setActiveTab('Savings')} style={styles.tabItem}>
          <Text style={[styles.tabText, activeTab === 'Savings' && styles.activeTabText]}>Savings</Text>
        </TouchableOpacity>

        <TouchableOpacity onPress={() => {
            setAmountInput('');
            setDepositVisible(true);
          }} style={styles.depositFabButton}>
          <Text style={styles.fabButtonText}>+ Deposit</Text>
        </TouchableOpacity>

        <TouchableOpacity onPress={() => setActiveTab('Loans')} style={styles.tabItem}>
          <Text style={[styles.tabText, activeTab === 'Loans' && styles.activeTabText]}>Loans</Text>
        </TouchableOpacity>

        <TouchableOpacity onPress={() => setDrawerOpen(true)} style={styles.tabItem}>
          <Text style={[styles.tabText, activeTab === 'Profile' && styles.activeTabText]}>Profile</Text>
        </TouchableOpacity>
      </View>

      {/* Sidebar Drawer */}
      <Modal animationType="fade" transparent visible={drawerOpen}>
        <View style={styles.drawerOverlay}>
          <TouchableOpacity onPress={() => setDrawerOpen(false)} style={styles.drawerDismissArea} />
          <View style={styles.drawerContent}>
            <View style={styles.drawerHeader}>
              <View style={styles.drawerAvatar}>
                <Text style={styles.drawerAvatarText}>{profile ? getInitials(profile.full_name) : 'MB'}</Text>
              </View>
              <Text style={styles.drawerMemberName}>{profile?.full_name}</Text>
              <Text style={styles.drawerEmail}>{session?.user.email}</Text>
            </View>

            <View style={styles.drawerMenu}>
              <TouchableOpacity onPress={() => setDrawerOpen(false)} style={styles.drawerItem}>
                <Text style={styles.drawerItemText}>Profile Information</Text>
              </TouchableOpacity>
              <TouchableOpacity onPress={() => setDrawerOpen(false)} style={styles.drawerItem}>
                <Text style={styles.drawerItemText}>Cooperative Account Ledger</Text>
              </TouchableOpacity>
              <TouchableOpacity onPress={() => setDrawerOpen(false)} style={styles.drawerItem}>
                <Text style={styles.drawerItemText}>Security & Settings</Text>
              </TouchableOpacity>
            </View>

            <TouchableOpacity onPress={() => { setDrawerOpen(false); signOut(); }} style={styles.drawerSignOutButton}>
              <Text style={styles.drawerSignOutText}>Sign Out</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>

      {/* Deposit Modal */}
      <Modal animationType="slide" transparent visible={depositVisible}>
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>Deposit Savings</Text>
            <Text style={styles.modalSubtitle}>Enter deposit amount in Naira (NGN)</Text>
            <TextInput keyboardType="numeric" onChangeText={setAmountInput} placeholder="e.g. 20000" placeholderTextColor="#6B7280" style={styles.modalInput} value={amountInput} />
            <View style={styles.modalActions}>
              <TouchableOpacity onPress={() => setDepositVisible(false)} style={[styles.modalButton, styles.cancelButton]}>
                <Text style={styles.cancelButtonText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity disabled={submitting} onPress={handleDeposit} style={styles.modalButton}>
                {submitting ? <ActivityIndicator color="#FFFFFF" /> : <Text style={styles.modalButtonText}>Confirm Deposit</Text>}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>

      {/* Apply Loan Modal */}
      <Modal animationType="slide" transparent visible={loanApplyVisible}>
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>Apply for Loan Facility</Text>
            <Text style={styles.modalSubtitle}>Select duration and policy terms</Text>

            <View style={styles.loanTypeSelector}>
              <TouchableOpacity
                onPress={() => setSelectedLoanType('short_term')}
                style={[styles.typeOption, selectedLoanType === 'short_term' && styles.typeOptionActive]}
              >
                <Text style={[styles.typeOptionText, selectedLoanType === 'short_term' && styles.typeOptionTextActive]}>3 Mo (5%)</Text>
              </TouchableOpacity>

              <TouchableOpacity
                onPress={() => setSelectedLoanType('mid_term')}
                style={[styles.typeOption, selectedLoanType === 'mid_term' && styles.typeOptionActive]}
              >
                <Text style={[styles.typeOptionText, selectedLoanType === 'mid_term' && styles.typeOptionTextActive]}>6 Mo (7%)</Text>
              </TouchableOpacity>

              <TouchableOpacity
                onPress={() => setSelectedLoanType('long_term')}
                style={[styles.typeOption, selectedLoanType === 'long_term' && styles.typeOptionActive]}
              >
                <Text style={[styles.typeOptionText, selectedLoanType === 'long_term' && styles.typeOptionTextActive]}>12 Mo (10%)</Text>
              </TouchableOpacity>
            </View>

            <TextInput keyboardType="numeric" onChangeText={setAmountInput} placeholder="Requested Amount in Naira (e.g. 100000)" placeholderTextColor="#6B7280" style={styles.modalInput} value={amountInput} />

            <View style={styles.calcPreviewCard}>
              <View style={styles.calcRow}>
                <Text style={styles.calcLabel}>Principal Amount:</Text>
                <Text style={styles.calcValue}>₦{principalNaira.toLocaleString()}</Text>
              </View>
              <View style={styles.calcRow}>
                <Text style={styles.calcLabel}>Interest ({currentConfig.percent}):</Text>
                <Text style={styles.calcValue}>₦{interestNaira.toLocaleString()}</Text>
              </View>
              <View style={[styles.calcRow, styles.calcRowTotal]}>
                <Text style={styles.calcTotalLabel}>Total Repayment:</Text>
                <Text style={styles.calcTotalValue}>₦{totalRepaymentNaira.toLocaleString()}</Text>
              </View>
            </View>

            <View style={styles.modalActions}>
              <TouchableOpacity onPress={() => setLoanApplyVisible(false)} style={[styles.modalButton, styles.cancelButton]}>
                <Text style={styles.cancelButtonText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity disabled={submitting} onPress={handleApplyLoan} style={styles.modalButton}>
                {submitting ? <ActivityIndicator color="#FFFFFF" /> : <Text style={styles.modalButtonText}>Submit Application</Text>}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>

      {/* Repay Loan Modal */}
      <Modal animationType="slide" transparent visible={loanRepayVisible}>
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>Repay Active Loan</Text>
            <Text style={styles.modalSubtitle}>Enter loan repayment amount in Naira (NGN)</Text>
            <TextInput keyboardType="numeric" onChangeText={setAmountInput} placeholder="e.g. 15000" placeholderTextColor="#6B7280" style={styles.modalInput} value={amountInput} />
            <View style={styles.modalActions}>
              <TouchableOpacity onPress={() => setLoanRepayVisible(false)} style={[styles.modalButton, styles.cancelButton]}>
                <Text style={styles.cancelButtonText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity disabled={submitting} onPress={handleRepayLoan} style={styles.modalButton}>
                {submitting ? <ActivityIndicator color="#FFFFFF" /> : <Text style={styles.modalButtonText}>Confirm Repayment</Text>}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>

    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#121315' },
  topBar: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingHorizontal: 20, paddingTop: 12, paddingBottom: 8 },
  topRightContainer: { flexDirection: 'row', alignItems: 'center' },
  iconButton: { paddingVertical: 6, paddingHorizontal: 12, backgroundColor: '#1E2024', borderRadius: 6, borderWidth: 1, borderColor: '#2A2D34' },
  topIconText: { color: '#9CA3AF', fontSize: 12, fontWeight: '600' },
  scrollContent: { paddingHorizontal: 20, paddingBottom: 110 },
  greetingHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginTop: 8, marginBottom: 20 },
  greetingSubtitle: { color: '#9CA3AF', fontSize: 13, fontWeight: '500' },
  memberName: { color: '#FFFFFF', fontSize: 22, fontWeight: 'bold', marginTop: 2 },
  avatarBadge: { width: 42, height: 42, borderRadius: 21, backgroundColor: '#1E3A8A', justifyContent: 'center', alignItems: 'center' },
  avatarText: { color: '#60A5FA', fontWeight: 'bold', fontSize: 15 },
  netPositionCard: { backgroundColor: '#1C1D21', borderRadius: 14, padding: 20, marginBottom: 16, borderWidth: 1, borderColor: '#2A2D34' },
  netPositionLabel: { color: '#9CA3AF', fontSize: 13, marginBottom: 6, fontWeight: '500' },
  netPositionValue: { color: '#FFFFFF', fontSize: 30, fontWeight: 'bold' },
  dualCardsRow: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 16 },
  summaryCard: { backgroundColor: '#1C1D21', borderRadius: 14, padding: 16, borderWidth: 1, borderColor: '#2A2D34' },
  halfCard: { width: '48%' },
  summaryCardLabel: { color: '#9CA3AF', fontSize: 12, marginBottom: 6, fontWeight: '500' },
  summaryCardValue: { color: '#FFFFFF', fontSize: 17, fontWeight: 'bold' },
  loanCard: { backgroundColor: '#381E0B', borderRadius: 14, padding: 20, marginBottom: 24, borderWidth: 1, borderColor: '#542D11' },
  loanHeaderRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 },
  loanTitle: { color: '#F97316', fontSize: 13, fontWeight: '600' },
  activeTag: { backgroundColor: '#271508', paddingHorizontal: 8, paddingVertical: 2, borderRadius: 10 },
  activeTagText: { color: '#F97316', fontSize: 11, fontWeight: '600' },
  loanAmountText: { color: '#FFFFFF', fontSize: 20, fontWeight: 'bold', marginBottom: 12 },
  loanOutstandingLabel: { color: '#FFFFFF', fontSize: 16, fontWeight: '400' },
  loanActionRow: { flexDirection: 'row', justifyContent: 'space-between' },
  loanInlineBtn: { backgroundColor: '#2563EB', paddingVertical: 8, paddingHorizontal: 12, borderRadius: 8, flex: 0.48, alignItems: 'center' },
  loanRepayBtn: { backgroundColor: '#2A2D34' },
  loanInlineBtnText: { color: '#FFFFFF', fontSize: 12, fontWeight: 'bold' },
  sectionTitle: { color: '#FFFFFF', fontSize: 15, fontWeight: '600', marginBottom: 12 },
  activityList: { backgroundColor: '#1C1D21', borderRadius: 14, paddingHorizontal: 16, borderWidth: 1, borderColor: '#2A2D34' },
  activityRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingVertical: 14, borderBottomWidth: 1, borderBottomColor: '#2A2D34' },
  activityLeft: { flexDirection: 'row', alignItems: 'center' },
  activityIconBadge: { width: 28, height: 28, borderRadius: 14, justifyContent: 'center', alignItems: 'center', marginRight: 12 },
  creditBadge: { backgroundColor: 'rgba(16, 185, 129, 0.15)' },
  debitBadge: { backgroundColor: 'rgba(239, 68, 68, 0.15)' },
  activityIconText: { fontSize: 14, fontWeight: 'bold' },
  creditIconText: { color: '#10B981' },
  debitIconText: { color: '#EF4444' },
  activityTitle: { color: '#FFFFFF', fontSize: 13, fontWeight: '500' },
  activityAmount: { fontSize: 13, fontWeight: '600' },
  creditAmount: { color: '#10B981' },
  debitAmount: { color: '#EF4444' },
  tabHeaderCard: { backgroundColor: '#1C1D21', borderRadius: 14, padding: 20, marginBottom: 16, borderWidth: 1, borderColor: '#2A2D34', alignItems: 'center' },
  tabHeaderTitle: { color: '#9CA3AF', fontSize: 13, fontWeight: '500', marginBottom: 4 },
  tabHeaderAmount: { color: '#FFFFFF', fontSize: 28, fontWeight: 'bold' },
  fullWidthBtn: { backgroundColor: '#2563EB', paddingVertical: 14, borderRadius: 10, alignItems: 'center', marginBottom: 20 },
  fullWidthBtnText: { color: '#FFFFFF', fontSize: 14, fontWeight: 'bold' },
  dualBtnRow: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 20 },
  halfWidthBtn: { flex: 0.48, paddingVertical: 14, borderRadius: 10, alignItems: 'center' },
  policyCard: { backgroundColor: '#1C1D21', borderRadius: 14, padding: 16, borderWidth: 1, borderColor: '#2A2D34' },
  policyRow: { color: '#9CA3AF', fontSize: 13, marginBottom: 8 },
  bottomTabBar: { position: 'absolute', bottom: 16, left: 20, right: 20, height: 64, backgroundColor: '#1C1D21', borderRadius: 16, flexDirection: 'row', justifyContent: 'space-around', alignItems: 'center', borderWidth: 1, borderColor: '#2A2D34', paddingHorizontal: 8, elevation: 10 },
  tabItem: { paddingVertical: 10, paddingHorizontal: 8 },
  tabText: { color: '#6B7280', fontSize: 12, fontWeight: '600' },
  activeTabText: { color: '#FFFFFF', fontWeight: 'bold' },
  depositFabButton: { backgroundColor: '#2563EB', paddingVertical: 8, paddingHorizontal: 14, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  fabButtonText: { color: '#FFFFFF', fontSize: 12, fontWeight: 'bold' },
  drawerOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.75)', flexDirection: 'row' },
  drawerDismissArea: { flex: 0.3 },
  drawerContent: { flex: 0.7, backgroundColor: '#1E2024', padding: 24, justifyContent: 'space-between' },
  drawerHeader: { alignItems: 'center', borderBottomWidth: 1, borderBottomColor: '#2A2D34', paddingBottom: 20, marginTop: 40 },
  drawerAvatar: { width: 56, height: 56, borderRadius: 28, backgroundColor: '#1E3A8A', justifyContent: 'center', alignItems: 'center', marginBottom: 10 },
  drawerAvatarText: { color: '#60A5FA', fontSize: 20, fontWeight: 'bold' },
  drawerMemberName: { color: '#FFFFFF', fontSize: 17, fontWeight: 'bold', textAlign: 'center' },
  drawerEmail: { color: '#9CA3AF', fontSize: 12, marginTop: 2 },
  drawerMenu: { marginTop: 20, flex: 1 },
  drawerItem: { paddingVertical: 14, borderBottomWidth: 1, borderBottomColor: '#2A2D34' },
  drawerItemText: { color: '#FFFFFF', fontSize: 14, fontWeight: '500' },
  drawerSignOutButton: { backgroundColor: '#EF4444', paddingVertical: 14, borderRadius: 10, alignItems: 'center', marginBottom: 20 },
  drawerSignOutText: { color: '#FFFFFF', fontSize: 14, fontWeight: 'bold' },
  modalOverlay: { flex: 1, backgroundColor: 'rgba(0, 0, 0, 0.75)', justifyContent: 'center', paddingHorizontal: 20 },
  modalContent: { backgroundColor: '#1E2024', padding: 24, borderRadius: 16, borderWidth: 1, borderColor: '#2A2D34' },
  modalTitle: { color: '#FFFFFF', fontSize: 18, fontWeight: 'bold', marginBottom: 4 },
  modalSubtitle: { color: '#9CA3AF', fontSize: 12, marginBottom: 16 },
  modalInput: { backgroundColor: '#121315', color: '#FFFFFF', borderRadius: 8, paddingHorizontal: 14, paddingVertical: 12, fontSize: 15, borderWidth: 1, borderColor: '#2A2D34', marginBottom: 16 },
  loanTypeSelector: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 16 },
  typeOption: { flex: 0.31, backgroundColor: '#121315', paddingVertical: 10, borderRadius: 8, alignItems: 'center', borderWidth: 1, borderColor: '#2A2D34' },
  typeOptionActive: { backgroundColor: '#2563EB', borderColor: '#3B82F6' },
  typeOptionText: { color: '#9CA3AF', fontSize: 12, fontWeight: '600' },
  typeOptionTextActive: { color: '#FFFFFF' },
  calcPreviewCard: { backgroundColor: '#121315', padding: 14, borderRadius: 8, borderWidth: 1, borderColor: '#2A2D34', marginBottom: 20 },
  calcRow: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 6 },
  calcRowTotal: { borderTopWidth: 1, borderTopColor: '#2A2D34', paddingTop: 6, marginTop: 4 },
  calcLabel: { color: '#9CA3AF', fontSize: 12 },
  calcValue: { color: '#FFFFFF', fontSize: 12, fontWeight: '600' },
  calcTotalLabel: { color: '#FFFFFF', fontSize: 13, fontWeight: 'bold' },
  calcTotalValue: { color: '#10B981', fontSize: 14, fontWeight: 'bold' },
  modalActions: { flexDirection: 'row', justifyContent: 'space-between' },
  modalButton: { backgroundColor: '#2563EB', paddingVertical: 12, borderRadius: 8, alignItems: 'center', flex: 0.48 },
  cancelButton: { backgroundColor: '#2A2D34' },
  modalButtonText: { color: '#FFFFFF', fontWeight: '600', fontSize: 13 },
  cancelButtonText: { color: '#9CA3AF', fontWeight: '600', fontSize: 13 },
});