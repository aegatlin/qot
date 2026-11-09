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

  await expect(page.getByText("The device you're signing in is signed in now, and so is this browser")).toBeVisible();
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

test("edit a note in the browser, see it in the terminal and on another device", async ({ page, browser }) => {
  const email = `e2e-edit-${Date.now()}@example.com`;
  const cli = new Cli();
  const login = cli.login(email);
  const code = await login.code;
  await page.goto(await server.signInLink(email));
  await page.getByLabel("Code").fill(code);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByTestId("sync-status")).toHaveText("Synced");
  await login.exited;

  // Wide screen: the list and the open note side by side.
  expect(cli.run("get", "milk").status).toBe(0);
  const list = page.getByRole("list", { name: "Notes" });
  await list.getByRole("link", { name: /get milk/ }).click({ timeout: 10_000 });
  await expect(page).toHaveURL(/\/notes\//);
  const editor = page.getByLabel("Edit note");
  await expect(editor).toHaveValue("get milk");
  await expect(editor).toBeFocused();
  await editor.fill("get oat milk\nand eggs");
  // Saved as you type: the list shows the title and preview, the CLI the text.
  await expect(list.getByRole("link", { name: /get oat milk.*and eggs/ })).toBeVisible();
  await expect.poll(() => cli.run("list").stdout, { timeout: 10_000 }).toContain("get oat milk\nand eggs");

  // A second device, phone-sized: signs in from the PWA itself.
  const phoneContext = await browser.newContext({ viewport: { width: 390, height: 800 } });
  const phone = await phoneContext.newPage();
  await phone.goto("/");
  await phone.getByRole("link", { name: "Sign in" }).click();
  await expect(phone).toHaveURL("/sign-in");
  await phone.getByLabel("Email").fill(email);
  await phone.getByRole("button", { name: "Email me a sign-in link" }).click();
  const phoneCode = await phone.getByTestId("user-code").textContent();
  const approve = await phoneContext.newPage();
  await approve.goto(await server.signInLink(email));
  await approve.getByLabel("Code").fill(phoneCode!);
  await approve.getByRole("button", { name: "Sign in" }).click();
  await approve.close();
  await expect(phone.getByTestId("sync-status")).toHaveText("Synced", { timeout: 15_000 });

  // Narrow: the note replaces the list, and back returns to it.
  const phoneList = phone.getByRole("list", { name: "Notes" });
  await phoneList.getByRole("link", { name: /get oat milk/ }).click();
  await expect(phoneList).toBeHidden();
  const phoneEditor = phone.getByLabel("Edit note");
  await expect(phoneEditor).toHaveValue("get oat milk\nand eggs");
  await phoneEditor.press("End");
  await phoneEditor.pressSequentially("\nand bread");

  // The open note on the first device catches up live, since nothing is
  // being typed there.
  await expect(editor).toHaveValue("get oat milk\nand eggs\nand bread", { timeout: 15_000 });
  await phone.getByRole("button", { name: "‹ Notes" }).click();
  await expect(phoneList).toBeVisible();
  await expect.poll(() => cli.run("list").stdout, { timeout: 10_000 }).toContain("and bread");

  // Search filters the list.
  expect(cli.run("get", "call", "mom").status).toBe(0);
  await expect(list).toContainText("call mom", { timeout: 10_000 });
  await page.getByLabel("Search notes").fill("bread");
  await expect(list.getByRole("link")).toHaveCount(1);
  await page.getByLabel("Search notes").fill("");

  // Delete from the editor.
  await list.getByRole("link", { name: /call mom/ }).click();
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  await expect(list).not.toContainText("call mom");
  await expect.poll(() => cli.run("list").stdout, { timeout: 10_000 }).not.toContain("call mom");

  // Emptying a note and leaving it discards it.
  await list.getByRole("link", { name: /get oat milk/ }).click();
  await editor.fill("");
  await page.getByRole("button", { name: "‹ Notes" }).click();
  await expect(page.getByText("No notes yet")).toBeVisible();
  await expect.poll(() => cli.run("list").stdout, { timeout: 10_000 }).toContain("No notes yet");
  await expect(phone.getByText("No notes yet")).toBeVisible({ timeout: 15_000 });
  await phoneContext.close();
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
  await page.getByRole("link", { name: "Settings" }).click();
  await expect(page).toHaveURL("/settings");
  await page.getByRole("button", { name: "Delete account…" }).click();
  const confirm = page.getByRole("button", { name: "Delete account", exact: true });
  await page.getByLabel(`Type ${email} to confirm`).fill("someone@example.com");
  await expect(confirm).toBeDisabled();
  await page.getByLabel(`Type ${email} to confirm`).fill(email.toUpperCase());
  await confirm.click();

  await expect(page.getByText("Account deleted. Your notes stay in this browser.")).toBeVisible();
  await expect(page).toHaveURL("/");
  await expect(page.getByLabel("Account")).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Sign in" })).toBeVisible();
  await expect(page.getByRole("list", { name: "Notes" })).toContainText("keep this one");

  // Still signed out after a reload: the session is gone, not just hidden.
  await page.reload();
  await expect(page.getByRole("list", { name: "Notes" })).toContainText("keep this one");
  await expect(page.getByLabel("Account")).toHaveCount(0);
  // The terminal signed in to the same account: its access token is still
  // within its hour, but the server refuses it, so it is told it is signed out.
  const sync = cli.run("sync");
  expect(sync.status).not.toBe(0);
  expect(sync.stderr).toContain("not signed in");
});
