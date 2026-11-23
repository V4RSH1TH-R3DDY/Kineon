import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The dashboard calls the FastAPI backend through this proxy, so no CORS setup is needed.
export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/v1': 'http://localhost:8000' } },
  preview: { proxy: { '/v1': 'http://localhost:8000' } },
})
