import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'node:path'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      xlsx: path.resolve(__dirname, 'node_modules/xlsx/xlsx.js'),
    },
  },
  optimizeDeps: {
    include: ['xlsx'],
  },
  build: {
    sourcemap: false,
    // F12: one 470 kB entry chunk delayed first paint on phones and made every
    // release re-download the whole app. Splitting the stable vendors lets the
    // browser cache them separately from application code.
    rollupOptions: {
      output: {
        manualChunks: {
          'react-vendor': ['react', 'react-dom', 'react-router-dom'],
          supabase: ['@supabase/supabase-js'],
          icons: ['lucide-react'],
        },
      },
    },
  },
})
