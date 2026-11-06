import { describe, expect, test } from "vitest";
import { Api } from "../src/api";
import { Note } from "../src/core/qot_wasm";
import { adoption, browserChoice, confirmsAccount, deleteAccount } from "../src/session";
import { openStore, type Credentials } from "../src/store";
import { FakeServer } from "./fake-server";

const creds = (email: string, userId = email, server = "https://api.example"): Credentials => ({
  server,
  email,
  userId,
  accessToken: "a",
  refreshToken: "r",
});

describe("the sign-in page's browser box", () => {
  test("a browser that isn't signed in is offered sign-in, ticked", () => {
    expect(browserChoice(undefined, "me@example.com", "https://api.example")).toEqual({
      kind: "sign_in",
      checked: true,
    });
  });

  test("already signed in as that account: nothing to tick", () => {
    expect(browserChoice(creds("Me@Example.com"), "me@example.com", "https://api.example").kind).toBe("already");
  });

  test("another account: switching is offered, never ticked by default", () => {
    expect(browserChoice(creds("other@example.com"), "me@example.com", "https://api.example")).toEqual({
      kind: "switch",
      from: "other@example.com",
      checked: false,
    });
  });

  test("credentials for another server don't count", () => {
    expect(browserChoice(creds("me@example.com", "u", "http://localhost:4000"), "me@example.com", "https://api.example").kind).toBe("sign_in");
  });
});

describe("adopting tokens", () => {
  test("keeps an existing session for the same user, switches for another", () => {
    expect(adoption(undefined, creds("a"))).toBe("save");
    expect(adoption(creds("a", "u1"), creds("a", "u1"))).toBe("keep");
    expect(adoption(creds("a", "u1"), creds("b", "u2"))).toBe("switch");
  });
});

describe("deleting the account", () => {
  test("the typed email must be the account's, ignoring case and spaces", () => {
    expect(confirmsAccount(" Me@Example.com ", "me@example.com")).toBe(true);
    expect(confirmsAccount("me@example.co", "me@example.com")).toBe(false);
    expect(confirmsAccount("", "me@example.com")).toBe(false);
  });

  async function signedIn(name: string) {
    const store = await openStore(name);
    await store.putCredentials({ ...creds("me@example.com", "u"), accessToken: "access-1", refreshToken: "refresh-1" });
    await store.putSyncState('{"cursor":3}');
    const note = new Note("get milk");
    await store.putNotes([{ id: note.id, bytes: note.toBytes() }]);
    return store;
  }

  test("deletes it on the server and signs this browser out; notes stay", async () => {
    const server = new FakeServer();
    const store = await signedIn("delete-ok");
    const result = await deleteAccount(store, new Api("https://api.example", server.fetch), "me@example.com");
    expect(result.ok).toBe(true);
    expect(server.deleted).toBe(true);
    expect(await store.credentials()).toBeUndefined();
    expect(await store.syncState()).toBeUndefined();
    expect(await store.allNotes()).toHaveLength(1);
  });

  test("refreshes an expired access token first", async () => {
    const server = new FakeServer();
    server.expireAccessTokens();
    const store = await signedIn("delete-refresh");
    const result = await deleteAccount(store, new Api("https://api.example", server.fetch), "me@example.com");
    expect(result.ok).toBe(true);
    expect(server.refreshes).toBe(1);
  });

  test("a refusal or no connection leaves the session as it was", async () => {
    const server = new FakeServer();
    const store = await signedIn("delete-refused");
    const api = new Api("https://api.example", server.fetch);
    const wrong = await deleteAccount(store, api, "other@example.com");
    expect(!wrong.ok && wrong.error.kind).toBe("failed");

    server.offline = true;
    const offline = await deleteAccount(store, api, "me@example.com");
    expect(!offline.ok && offline.error.kind).toBe("offline");

    expect(server.deleted).toBe(false);
    expect((await store.credentials())?.email).toBe("me@example.com");
    expect(await store.syncState()).toBe('{"cursor":3}');
  });
});
