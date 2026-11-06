// Signing this browser in and out. The rules are pure; `adoptTokens` and
// `signOut` are the shell.

import type { Api, ApiResult, Tokens } from "./api";
import { err } from "./result";
import type { Credentials, Store } from "./store";
import { withLock } from "./lock";
import { authed, SYNC_LOCK } from "./sync";

const sameEmail = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

/** What the "also sign in this browser" box means on the sign-in page. */
export type BrowserChoice =
  | { kind: "sign_in"; checked: true }
  | { kind: "already"; checked: false }
  | { kind: "switch"; from: string; checked: false };

export function browserChoice(current: Credentials | undefined, linkEmail: string, server: string): BrowserChoice {
  if (!current || current.server !== server) return { kind: "sign_in", checked: true };
  if (sameEmail(current.email, linkEmail)) return { kind: "already", checked: false };
  // Switching accounts is never the default: it changes whose notes sync here.
  return { kind: "switch", from: current.email, checked: false };
}

export function credentialsFrom(tokens: Tokens, server: string): Credentials {
  return {
    server,
    email: tokens.user.email,
    userId: tokens.user.id,
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
  };
}

/** What to do with tokens a sign-in just returned, given what's stored. */
export function adoption(current: Credentials | undefined, next: Credentials): "save" | "switch" | "keep" {
  if (!current || current.server !== next.server) return current ? "switch" : "save";
  if (current.userId === next.userId) return "keep";
  return "switch";
}

/**
 * Stores tokens from a sign-in. Already signed in as the same account (the
 * link was approved in another tab, say): keep the session there is and
 * revoke the new one. Another account: forget the old sync position first,
 * like `qot login`, so the new account doesn't inherit it. Notes stay.
 */
export async function adoptTokens(store: Store, api: Api, tokens: Tokens): Promise<Credentials> {
  const next = credentialsFrom(tokens, api.base);
  const current = await store.credentials();
  switch (adoption(current, next)) {
    case "keep":
      await api.logout(next.refreshToken);
      return current!;
    case "switch":
      await store.forgetSession();
      break;
    case "save":
      break;
  }
  await store.putCredentials(next);
  // Ask the browser not to evict notes that haven't synced yet.
  await navigator.storage?.persist?.().catch(() => false);
  return next;
}

/** Like `qot logout`: revoke, forget credentials and sync state; notes stay. */
export async function signOut(store: Store, api: Api): Promise<void> {
  const current = await store.credentials();
  if (current) await api.logout(current.refreshToken);
  await store.forgetSession();
}

/** Whether the typed email confirms deleting `email`'s account (the server's rule too). */
export function confirmsAccount(typed: string, email: string): boolean {
  return typed.trim() !== "" && sameEmail(typed, email);
}

/**
 * Like `qot delete-account`: deletes the account on the server, then forgets
 * this browser's session and sync position. Notes in this browser stay. On
 * any failure nothing local changes. Holds the sync lock, so no tab's sync
 * writes a sync position back after it's forgotten.
 */
export function deleteAccount(store: Store, api: Api, typed: string): ApiResult<void> {
  return withLock(SYNC_LOCK, async () => {
    const current = await store.credentials();
    if (!current) return err({ kind: "unauthorized" as const });
    const result = await authed(api, store, current, (token) => api.deleteAccount(token, typed));
    if (result.ok) await store.forgetSession();
    return result;
  });
}
