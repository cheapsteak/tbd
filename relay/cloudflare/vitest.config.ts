import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
    }),
  ],
  // Longer than the helpers' 5 s message wait, so a missing message fails with
  // the helper's error rather than a bare test timeout.
  test: { testTimeout: 15_000 },
});
