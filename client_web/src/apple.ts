// Sign in with Apple in the browser (#87): Apple's JS SDK opens Apple's
// window, and its identity token goes to the same `/api/auth/apple` the iOS
// app uses. The rules are pure; `appleSignIn` is the shell. The SDK is
// Apple's only script here, loaded from Apple only when the sign-in card
// shows (the CSP allows its origin and nothing else).

import type { ApiError } from "./api";
import { describe } from "./api";
import { err, ok, type Result } from "./result";

/** The Services ID registered for the web, with the return URLs below. */
export const APPLE_CLIENT_ID = "llc.abstractsyntax.qot.web";

const SDK_URL = "https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js";

/** The origins registered on the Services ID; Apple refuses any other. */
const REGISTERED = new Set(["https://app.quantumofthought.com", "https://staging-app.quantumofthought.com"]);

export function appleAvailable(origin: string): boolean {
  return REGISTERED.has(origin);
}

export function appleRedirectURI(origin: string): string {
  return `${origin}/auth/apple`;
}

/** Hex SHA-256: Apple gets the hash of the nonce, the server the nonce itself. */
export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

export interface AppleCredential {
  identityToken: string;
  authorizationCode: string | null;
}

const CANCELS = new Set(["popup_closed_by_user", "user_cancelled_authorize"]);

/** What `AppleID.auth.signIn()` resolved or rejected with. */
export function readAppleResponse(answer: unknown): Result<AppleCredential, string> {
  const a = (answer ?? {}) as { error?: unknown; authorization?: { id_token?: unknown; code?: unknown } };
  if (typeof a.error === "string") return err(CANCELS.has(a.error) ? "cancelled" : a.error);
  const token = a.authorization?.id_token;
  if (typeof token !== "string" || token === "") return err("no answer from Apple");
  const code = a.authorization?.code;
  return ok({ identityToken: token, authorizationCode: typeof code === "string" && code !== "" ? code : null });
}

/** The server's answer to an Apple sign-in, as something to tell the person. */
export function appleErrorText(e: ApiError): string {
  if (e.kind === "unauthorized") return "Apple's sign-in couldn't be checked. Try again.";
  if (e.kind === "failed" && e.error === "email_in_use")
    return "That email already has an account that isn't linked to this Apple ID. Sign in with the email instead.";
  if (e.kind === "failed" && e.error === "email_required")
    return "qot needs an email from Apple. Try again and share your email (or Hide My Email).";
  if (e.kind === "failed" && e.error === "apple_unavailable") return "Apple can't be reached right now. Try again soon.";
  return describe(e);
}

// The shell: Apple's SDK.

interface AppleSDK {
  auth: {
    init(options: Record<string, unknown>): void;
    signIn(): Promise<unknown>;
  };
}

let sdk: Promise<AppleSDK> | null = null;

/** Loads Apple's SDK once; a failed load can be retried. */
export function loadAppleSDK(): Promise<AppleSDK> {
  sdk ??= new Promise<AppleSDK>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = SDK_URL;
    script.async = true;
    script.onload = () => {
      const found = (window as unknown as { AppleID?: AppleSDK }).AppleID;
      if (found) resolve(found);
      else reject(new Error("Apple's sign-in didn't load"));
    };
    script.onerror = () => reject(new Error("Apple's sign-in didn't load"));
    document.head.appendChild(script);
  }).catch((e) => {
    sdk = null;
    throw e;
  });
  return sdk;
}

export interface PreparedApple {
  apple: AppleSDK;
  nonce: string;
}

/**
 * Loads the SDK and sets it up with a fresh nonce, before the click: the
 * click must open Apple's window with nothing awaited first, or Safari
 * blocks it. Prepare again after every attempt (a nonce is used once).
 */
export async function prepareApple(origin: string): Promise<PreparedApple> {
  const apple = await loadAppleSDK();
  const nonce = crypto.randomUUID();
  apple.auth.init({
    clientId: APPLE_CLIENT_ID,
    scope: "email",
    redirectURI: appleRedirectURI(origin),
    nonce: await sha256Hex(nonce),
    usePopup: true,
  });
  return { apple, nonce };
}

/** Opens Apple's window; call it straight from the click. */
export async function appleSignIn({ apple, nonce }: PreparedApple): Promise<Result<AppleCredential & { nonce: string }, string>> {
  let answer: unknown;
  try {
    answer = await apple.auth.signIn();
  } catch (e) {
    answer = e;
  }
  const credential = readAppleResponse(answer);
  return credential.ok ? ok({ ...credential.value, nonce }) : credential;
}
