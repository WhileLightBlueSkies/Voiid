import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './e2e', outputDir: './test-results/runs', timeout: 45000, workers: 1,
  use: { baseURL: 'http://localhost:4173', viewport: { width: 1440, height: 1000 }, colorScheme: 'light' },
  webServer: { command: 'node server.mjs', url: 'http://localhost:4173', reuseExistingServer: true },
});
