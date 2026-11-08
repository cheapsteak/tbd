// The phone app's end-to-end suite: every spec runs in WebKit as an iPhone and in Chromium as
// an Android phone, against server.js (the staged loader, and the test host that runs the
// committed bundle in the loader's real app frame beside a fake laptop on 127.0.0.1). Run it
// with `npm run test:app:e2e` in phone/.

import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.js',
  forbidOnly: true,
  retries: 0,
  workers: 2,
  timeout: 30_000,
  outputDir: 'test-results',
  reporter: [['list'], ['html', { outputFolder: 'report', open: 'never' }]],
  use: { trace: 'retain-on-failure' },
  projects: [
    {
      name: 'webkit-iphone',
      use: { ...devices['iPhone 15'] },
    },
    {
      name: 'chromium-pixel',
      use: { ...devices['Pixel 7'] },
    },
  ],
});
