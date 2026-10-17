import React, { useEffect } from 'react';
import { ActivityIndicator, StatusBar, StyleSheet, Text, View } from 'react-native';

interface Props {
  onFinish: () => void;
}

export default function SplashScreen({ onFinish }: Props) {
  useEffect(() => {
    const timer = setTimeout(() => {
      onFinish();
    }, 2500); // Displays for 2.5 seconds
    return () => clearTimeout(timer);
  }, []);

  return (
    <View style={styles.container}>
      <StatusBar barStyle="light-content" backgroundColor="#121315" />
      <View style={styles.logoContainer}>
        {/* Logo Badge */}
        <View style={styles.logoBadge}>
          <Text style={styles.logoBadgeText}>P</Text>
        </View>
        <Text style={styles.brandTitle}>Purview</Text>
        <Text style={styles.brandTagline}>INNOVATED BY MEZZIMAH</Text>
      </View>
      <ActivityIndicator size="small" color="#2563EB" style={styles.loader} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#121315',
    justifyContent: 'center',
    alignItems: 'center',
  },
  logoContainer: {
    alignItems: 'center',
  },
  logoBadge: {
    width: 80,
    height: 80,
    borderRadius: 24,
    backgroundColor: '#2563EB',
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 20,
    shadowColor: '#2563EB',
    shadowOpacity: 0.5,
    shadowRadius: 10,
    elevation: 8,
  },
  logoBadgeText: {
    color: '#FFFFFF',
    fontSize: 42,
    fontWeight: 'bold',
  },
  brandTitle: {
    color: '#FFFFFF',
    fontSize: 32,
    fontWeight: 'bold',
    letterSpacing: 0.5,
  },
  brandTagline: {
    color: '#3B82F6',
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 2,
    marginTop: 6,
  },
  loader: {
    position: 'absolute',
    bottom: 60,
  },
});