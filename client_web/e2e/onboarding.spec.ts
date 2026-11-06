import { expect, test } from "@playwright/test";
import { Cli, Server } from "./harness";

// The onboarding moment (docs/records/2026-11-06-sign-in-through-the-pwa.md):
// sign in once from the CLI, land on the PWA signed in, and watch notes move
// between the two live.

const server = new Server();
test.beforeAll(async () => server.start());
test.afterAll(() => server.stop());

test("sign in from the CLI, and the browser that approves is signed in too", async ({ page }) => {
  const email = `e2e-${Date.now()}@example.com`;
  const cli = new Cli();
  const login = cli.login(email);
  const code = await login.code;

  await page.goto(await server.signInLink(email));
  await expect(page.getByText(`sign in as ${email}`)).toBeVisible();
  await expect(page.getByLabel("Also sign in this browser")).toBeChecked();
  await page.getByLabel("Code").fill(code.toLowerCase());
  await page.getByRole("button", { name: "Sign in" }).click();

  await expect(page.getByText("Return to your terminal; this browser is signed in too")).toBeVisible();
  await expect(page).toHaveURL("/");
  await expect(page.getByTestId("sync-status")).toHaveText("Synced");

  const done = await login.exited;
  expect(done.code, done.out).toBe(0);
  expect(done.out).toContain(`Signed in as ${email}`);
  expect(done.out).toContain("Your notes are on the web too: http://localhost:4173");

  // Terminal to browser, live: no reload.
  expect(cli.run("get", "milk").status).toBe(0);
  await expect(page.getByRole("list", { name: "Notes" })).toContainText("get milk", { timeout: 10_000 });

  // Browser to terminal.
  await page.getByLabel("New note").fill("call the dentist");
  await page.keyboard.press("Enter");
  await expect(page.getByTestId("sync-status")).toHaveText("Synced");
  await expect.poll(() => cli.run("list").stdout, { timeout: 10_000 }).toContain("call the dentist");

  // A delete in the browser reaches the terminal.
  await page.getByRole("button", { name: "Delete “get milk”" }).click();
  await expect.poll(() => cli.run("list").stdout, { timeout: 10_000 }).not.toContain("get milk");
});

test("the app opens and captures offline, then syncs when back", async ({ page, context }) => {
  const email = `e2e-off-${Date.now()}@example.com`;
  const cli = new Cli();
  const login = cli.login(email);
  const code = await login.code;
  await page.goto(await server.signInLink(email));
  await page.getByLabel("Code").fill(code);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByTestId("sync-status")).toHaveText("Synced");
  await login.exited;

  // Wait for the service worker to take over, so a reload works offline.
  await page.evaluate(() => navigator.serviceWorker.ready);
  await context.setOffline(true);
  await page.reload();
  await page.getByLabel("New note").fill("written on the train");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("list", { name: "Notes" })).toContainText("written on the train");
  await expect(page.getByTestId("sync-status")).toHaveText("Offline");

  await context.setOffline(false);
  await expect(page.getByTestId("sync-status")).toHaveText("Synced", { timeout: 15_000 });
  await expect.poll(() => cli.run("list").stdout, { timeout: 10_000 }).toContain("written on the train");
});

test("a wrong code says so and signs nothing in", async ({ page }) => {
  const email = `e2e-bad-${Date.now()}@example.com`;
  const login = new Cli().login(email);
  await login.code;
  await page.goto(await server.signInLink(email));
  await page.getByLabel("Code").fill("ZZZZ-ZZZZ");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByText("That code doesn't match")).toBeVisible();
});

test("deleting the account from the browser signs everything out; notes stay", async ({ page }) => {
  const email = `e2e-delete-${Date.now()}@example.com`;
  const cli = new Cli();
  const login = cli.login(email);
  const code = await login.code;
  await page.goto(await server.signInLink(email));
  await page.getByLabel("Code").fill(code);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByTestId("sync-status")).toHaveText("Synced");
  await login.exited;

  await page.getByLabel("New note").fill("keep this one");
  await page.keyboard.press("Enter");
  await expect(page.getByTestId("sync-status")).toHaveText("Synced");

  await page.getByLabel("Account").click();
  await page.getByRole("button", { name: "Delete account…" }).click();
  const confirm = page.getByRole("button", { name: "Delete account", exact: true });
  await page.getByLabel(`Type ${email} to confirm`).fill("someone@example.com");
  await expect(confirm).toBeDisabled();
  await page.getByLabel(`Type ${email} to confirm`).fill(email.toUpperCase());
  await confirm.click();

  await expect(page.getByText("Account deleted. Your notes stay in this browser.")).toBeVisible();
  await expect(page.getByLabel("Account")).toHaveCount(0);
  await expect(page.getByRole("list", { name: "Notes" })).toContainText("keep this one");

  // Still signed out after a reload: the session is gone, not just hidden.
  await page.reload();
  await expect(page.getByRole("list", { name: "Notes" })).toContainText("keep this one");
  await expect(page.getByLabel("Account")).toHaveCount(0);
});
