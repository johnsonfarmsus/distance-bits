/// <reference types="vitest/config" />
import { defineConfig } from 'vitest/config';
import basicSsl from '@vitejs/plugin-basic-ssl';

// Camera access needs a secure context, so the dev server runs over HTTPS with a
// self-signed cert. On the phone, accept the certificate warning once.
// BASE_PATH is set by the GitHub Pages workflow (e.g. /distance-bits/).
const base = (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env.BASE_PATH ?? '/';

export default defineConfig({
  base,
  define: { __BUILD_TIME__: JSON.stringify(new Date().toISOString()) },
  plugins: [basicSsl()],
  server: { host: true, port: 5173 },
  build: { target: 'es2022', sourcemap: true },
  test: { include: ['src/**/*.test.ts'] },
});
