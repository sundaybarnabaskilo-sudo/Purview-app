import { createClient } from '@supabase/supabase-js';
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';

declare const process: {
  env: {
    EXPO_PUBLIC_SUPABASE_URL?: string;
    EXPO_PUBLIC_SUPABASE_ANON_KEY?: string;
  };
};

// Custom secure storage wrapper to chunk or fallback gracefully if needed
const ExpoSecureStoreAdapter = {
  getItem: (key: string) => {
    return SecureStore.getItemAsync(key);
  },
  setItem: (key: string, value: string) => {
    try {
      return SecureStore.setItemAsync(key, value);
    } catch (e) {
      console.warn('SecureStore setItem error:', e);
    }
  },
  removeItem: (key: string) => {
    return SecureStore.deleteItemAsync(key);
  },
};

const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL || 'https://sesqyncrspefuotjqfri.supabase.co';
const SUPABASE_ANON_KEY = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNlc3F5bmNyc3BlZnVvdGpxZnJpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwMjIzMzYsImV4cCI6MjEwNzU5ODMzNn0.1QEYPD9ixZaLi1oPmNuDsM3OIQJMOnzWbVFNFnebSto';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    storage: Platform.OS !== 'web' ? ExpoSecureStoreAdapter : undefined,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});