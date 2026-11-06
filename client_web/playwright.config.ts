import { defineConfig } from "@playwright/test";

// End to end: the built PWA (vite preview), the Phoenix server and the real
// CLI, in headless Chromium. `mise run e2e:web`; needs Postgres running.
// The spec starts the server itself, because it reads sign-in emails from
// the server's log (dev logs every email).
export default defineConfig({
  testDir: "e2e",
  timeout: 90_000,
  workers: 1,
  use: { baseURL: "http://localhost:4173", trace: "off" },
  webServer: {
    command: "npm run build && npm run preview",
    url: "http://localhost:4173",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
  },
});
