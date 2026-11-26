import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Forward only the API used by the doctor dashboard. The phone uses the backend directly.
const proxy = { '^/v1/(doctor|links|verify)(/|$)': 'http://localhost:8000' }

export default defineConfig({
  plugins: [react()],
  server: { proxy },
  preview: { proxy },
})
