import { describe, expect, test } from "vitest";
import { Api } from "../src/api";
import { APPLE_CLIENT_ID, appleAvailable, appleErrorText, appleRedirectURI, readAppleResponse, sha256Hex } from "../src/apple";

describe("Sign in with Apple on the web", () => {
  test("the nonce Apple sees is the SHA-256 hex of the one the server gets, as on iOS", async () => {
    expect(await sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });

  test("the return URL is this app's /auth/apple, registered on the Services ID", () => {
    expect(APPLE_CLIENT_ID).toBe("llc.abstractsyntax.qot.web");
    expect(appleRedirectURI("https://app.quantumofthought.com")).toBe("https://app.quantumofthought.com/auth/apple");
  });

  test("it's offered only where Apple can return: the registered https origins", () => {
    expect(appleAvailable("https://app.quantumofthought.com")).toBe(true);
    expect(appleAvailable("https://staging-app.quantumofthought.com")).toBe(true);
    expect(appleAvailable("http://localhost:5173")).toBe(false);
    expect(appleAvailable("https://example.com")).toBe(false);
  });

  test("Apple's answer gives the identity token and the authorization code", () => {
    const r = readAppleResponse({ authorization: { id_token: "jwt", code: "c1", state: "s" } });
    expect(r).toEqual({ ok: true, value: { identityToken: "jwt", authorizationCode: "c1" } });

    const noCode = readAppleResponse({ authorization: { id_token: "jwt" } });
    expect(noCode).toEqual({ ok: true, value: { identityToken: "jwt", authorizationCode: null } });
  });

  test("closing Apple's window is a cancel, not an error to show", () => {
    expect(readAppleResponse({ error: "popup_closed_by_user" })).toEqual({ ok: false, error: "cancelled" });
    expect(readAppleResponse({ error: "user_cancelled_authorize" })).toEqual({ ok: false, error: "cancelled" });
    expect(readAppleResponse({ error: "popup_blocked_by_browser" })).toEqual({ ok: false, error: "popup_blocked_by_browser" });
    expect(readAppleResponse(undefined)).toEqual({ ok: false, error: "no answer from Apple" });
    expect(readAppleResponse({ authorization: {} })).toEqual({ ok: false, error: "no answer from Apple" });
  });

  test("the server's refusals read as what to do next", () => {
    expect(appleErrorText({ kind: "failed", status: 409, error: "email_in_use" })).toMatch(/already has an account/);
    expect(appleErrorText({ kind: "failed", status: 422, error: "email_required" })).toMatch(/email/);
    expect(appleErrorText({ kind: "unauthorized" })).toMatch(/couldn't be checked/);
    expect(appleErrorText({ kind: "offline", message: "x" })).toBe("offline");
  });

  test("the API posts the token, the raw nonce and the code, and returns tokens", async () => {
    let sent: { url?: string; body?: unknown } = {};
    const capture = (async (url: RequestInfo | URL, init?: RequestInit) => {
      sent = { url: String(url), body: JSON.parse(String(init?.body)) };
      return new Response(
        JSON.stringify({ access_token: "a", refresh_token: "r", user: { id: "u", email: "x@privaterelay.appleid.com" } }),
        { status: 200 },
      );
    }) as typeof fetch;
    const r = await new Api("https://api.example", capture).signInWithApple("jwt", "raw", "c1");
    expect(sent).toEqual({
      url: "https://api.example/api/auth/apple",
      body: { identity_token: "jwt", nonce: "raw", authorization_code: "c1" },
    });
    expect(r.ok && r.value.user.email).toBe("x@privaterelay.appleid.com");

    const conflict = (async () => new Response(JSON.stringify({ error: "email_in_use" }), { status: 409 })) as typeof fetch;
    const refused = await new Api("https://api.example", conflict).signInWithApple("jwt", "raw", null);
    expect(!refused.ok && refused.error).toEqual({ kind: "failed", status: 409, error: "email_in_use" });
  });
});
