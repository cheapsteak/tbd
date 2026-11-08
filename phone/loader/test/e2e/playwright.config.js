// The phone loader's end-to-end suite: every spec runs in WebKit as an iPhone and in Chromium
// as an Android phone, against fake-laptop.js (a staged loader, a fake relay and scripted
// laptops on 127.0.0.1). Run it with `npm run test:e2e` in phone/.

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
      use: {
        ...devices['Pixel 7'],
        launchOptions: { args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] },
      },
    },
  ],
});
