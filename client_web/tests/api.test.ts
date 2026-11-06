import { describe, expect, test } from "vitest";
import { Api, parsePage } from "../src/api";

const reply = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  (async () => new Response(JSON.stringify(body), { status, headers })) as typeof fetch;

describe("api", () => {
  test("a pull page decodes base64 changes", () => {
    const page = parsePage({ changes: [{ seq: 1, note_id: "n", data: "AQID" }], cursor: 1, more: false });
    expect(page.ok && Array.from(page.value.changes[0]!.data)).toEqual([1, 2, 3]);
  });

  test("a malformed page is an error, never a partial page", () => {
    expect(parsePage({ changes: [{ seq: 1, note_id: "n", data: "!!" }], cursor: 1, more: false }).ok).toBe(false);
    expect(parsePage({ changes: [{ seq: 1 }], cursor: 1, more: false }).ok).toBe(false);
    expect(parsePage({ cursor: 1 }).ok).toBe(false);
  });

  test("approving maps the server's answers", async () => {
    const signedIn = await new Api("https://api.example", reply(200, {
      access_token: "a", refresh_token: "r", user: { id: "u", email: "me@example.com" },
    })).approve("t", "BBBB-BBBB", true);
    expect(signedIn.ok && signedIn.value.status).toBe("signed_in");

    const approved = await new Api("https://api.example", reply(200, { approved: true })).approve("t", "c", false);
    expect(approved.ok && approved.value).toEqual({ status: "approved" });

    const mismatch = await new Api("https://api.example", reply(422, { error: "mismatch" })).approve("t", "c", true);
    expect(mismatch.ok && mismatch.value).toEqual({ status: "mismatch" });

    const used = await new Api("https://api.example", reply(410, { error: "denied" })).approve("t", "c", true);
    expect(used.ok && used.value).toEqual({ status: "unusable", reason: "denied" });
  });

  test("rate limits and offline are their own errors", async () => {
    const limited = await new Api("https://api.example", reply(429, { error: "rate_limited" }, { "retry-after": "120" })).startDeviceLogin("me@example.com");
    expect(!limited.ok && limited.error).toEqual({ kind: "rate_limited", retryAfter: 120 });

    const offline = await new Api("https://api.example", (async () => {
      throw new TypeError("Failed to fetch");
    }) as typeof fetch).startDeviceLogin("me@example.com");
    expect(!offline.ok && offline.error.kind).toBe("offline");
  });

  test("deleting the account sends the typed email and maps the answers", async () => {
    let sent: { method?: string; auth?: string | null; body?: unknown } = {};
    const capture = (async (_url: RequestInfo | URL, init?: RequestInit) => {
      sent = {
        method: init?.method,
        auth: new Headers(init?.headers).get("authorization"),
        body: JSON.parse(String(init?.body)),
      };
      return new Response(JSON.stringify({ deleted: true }), { status: 200 });
    }) as typeof fetch;
    const deleted = await new Api("https://api.example", capture).deleteAccount("tok", "me@example.com");
    expect(deleted.ok).toBe(true);
    expect(sent).toEqual({ method: "DELETE", auth: "Bearer tok", body: { confirm: "me@example.com" } });

    const mismatch = await new Api("https://api.example", reply(400, { error: "confirmation_mismatch" })).deleteAccount("t", "x");
    expect(!mismatch.ok && mismatch.error).toEqual({ kind: "failed", status: 400, error: "confirmation_mismatch" });
  });

  test("the socket lives next to the API", () => {
    expect(new Api("https://api.example/").socketUrl()).toBe("wss://api.example/socket");
    expect(new Api("http://localhost:4000").socketUrl()).toBe("ws://localhost:4000/socket");
  });
});
