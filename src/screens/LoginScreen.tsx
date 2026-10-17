import React, { useState } from 'react';
import {
    ActivityIndicator,
    Alert,
    KeyboardAvoidingView,
    Platform,
    ScrollView,
    StyleSheet,
    Text,
    TextInput,
    TouchableOpacity,
    View,
} from 'react-native';
import { supabase } from '../services/supabase';

type AuthMode = 'signin' | 'signup' | 'forgot';

export default function LoginScreen() {
  const [mode, setMode] = useState<AuthMode>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [fullName, setFullName] = useState('');
  const [loading, setLoading] = useState(false);
  const handleSubmit = async () => {
    if (!email) {
      Alert.alert('Error', 'Please enter your email address.');
      return;
    }

    if (mode !== 'forgot' && !password) {
      Alert.alert('Error', 'Please enter your password.');
      return;
    }

    setLoading(true);
    try {
      if (mode === 'signin') {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        if (error) Alert.alert('Sign In Failed', error.message);
      } else if (mode === 'signup') {
        const { error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: {
            data: { full_name: fullName || 'Cooperative Member' },
          },
        });

        if (error) {
          Alert.alert('Registration Failed', error.message);
        } else {
          Alert.alert('Success', 'Account created! You can now sign in.');
          setMode('signin');
        }
      } else if (mode === 'forgot') {
        const { error } = await supabase.auth.resetPasswordForEmail(email.trim());
        if (error) {
          Alert.alert('Reset Failed', error.message);
        } else {
          Alert.alert('Email Sent', 'Instructions sent to your inbox.');
          setMode('signin');
        }
      }
    } catch (err: any) {
      Alert.alert('Error', err.message || 'An error occurred.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <ScrollView contentContainerStyle={styles.scrollContainer} keyboardShouldPersistTaps="handled">
        <View style={styles.card}>
          <Text style={styles.branding}>Purview</Text>
          <Text style={styles.tagline}>INNOVATED BY MEZZIMAH</Text>

          <Text style={styles.title}>
            {mode === 'signin' && 'Member Sign In'}
            {mode === 'signup' && 'Create Member Account'}
            {mode === 'forgot' && 'Reset Password'}
          </Text>

          {mode === 'signup' && (
            <TextInput
              style={styles.input}
              placeholder="Full Name"
              placeholderTextColor="#6B7280"
              value={fullName}
              onChangeText={setFullName}
            />
          )}

          <TextInput
            style={styles.input}
            placeholder="Member Email"
            placeholderTextColor="#6B7280"
            value={email}
            onChangeText={setEmail}
            autoCapitalize="none"
            keyboardType="email-address"
          />

          {mode !== 'forgot' && (
            <TextInput
              style={styles.input}
              placeholder="Password"
              placeholderTextColor="#6B7280"
              value={password}
              onChangeText={setPassword}
              secureTextEntry
            />
          )}

          <TouchableOpacity
            style={[styles.button, loading && styles.buttonDisabled]}
            onPress={handleSubmit}
            disabled={loading}
          >
            {loading ? (
              <ActivityIndicator color="#FFFFFF" />
            ) : (
              <Text style={styles.buttonText}>
                {mode === 'signin' && 'Sign In'}
                {mode === 'signup' && 'Register Account'}
                {mode === 'forgot' && 'Send Reset Link'}
              </Text>
            )}
          </TouchableOpacity>

          <View style={styles.switchContainer}>
            {mode === 'signin' && (
              <>
                <TouchableOpacity onPress={() => setMode('signup')}>
                  <Text style={styles.switchText}>Create Account</Text>
                </TouchableOpacity>
                <Text style={styles.dot}>•</Text>
                <TouchableOpacity onPress={() => setMode('forgot')}>
                  <Text style={styles.switchText}>Forgot Password?</Text>
                </TouchableOpacity>
              </>
            )}

            {mode === 'signup' && (
              <TouchableOpacity onPress={() => setMode('signin')}>
                <Text style={styles.switchText}>Already registered? Sign In</Text>
              </TouchableOpacity>
            )}

            {mode === 'forgot' && (
              <TouchableOpacity onPress={() => setMode('signin')}>
                <Text style={styles.switchText}>Back to Sign In</Text>
              </TouchableOpacity>
            )}
          </View>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#121315' },
  scrollContainer: { flexGrow: 1, justifyContent: 'center', paddingHorizontal: 24 },
  card: {
    backgroundColor: '#1E2024',
    padding: 24,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#2A2D34',
  },
  branding: { color: '#3B82F6', fontSize: 28, fontWeight: 'bold', textAlign: 'center' },
  tagline: {
    color: '#9CA3AF',
    fontSize: 10,
    textAlign: 'center',
    marginBottom: 24,
    letterSpacing: 1.2,
    fontWeight: '600',
  },
  title: { color: '#FFFFFF', fontSize: 18, fontWeight: '600', marginBottom: 16 },
  input: {
    backgroundColor: '#121315',
    color: '#FFFFFF',
    borderRadius: 8,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 14,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: '#2A2D34',
  },
  button: { backgroundColor: '#2563EB', paddingVertical: 14, borderRadius: 8, alignItems: 'center', marginTop: 8 },
  buttonDisabled: { opacity: 0.6 },
  buttonText: { color: '#FFFFFF', fontSize: 16, fontWeight: '600' },
  switchContainer: { flexDirection: 'row', justifyContent: 'center', alignItems: 'center', marginTop: 20 },
  switchText: { color: '#3B82F6', fontSize: 13, fontWeight: '500' },
  dot: { color: '#6B7280', marginHorizontal: 8 },
});