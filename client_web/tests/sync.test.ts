import { beforeEach, describe, expect, test } from "vitest";
import { Api } from "../src/api";
import { Note, syncCursor } from "../src/core/qot_wasm";
import { saveEdit } from "../src/local";
import { liveNotes, parseNotes } from "../src/notes";
import { openStore, type Store } from "../src/store";
import { sync } from "../src/sync";
import { FakeServer } from "./fake-server";

const API = "https://api.example";
let n = 0;

async function device(signedIn = true): Promise<Store> {
  const store = await openStore(`device-${n++}`);
  if (signedIn)
    await store.putCredentials({
      server: API,
      email: "me@example.com",
      userId: "u",
      accessToken: "access-1",
      refreshToken: "refresh-1",
    });
  return store;
}

async function contents(store: Store): Promise<string[]> {
  const notes = parseNotes(await store.allNotes());
  if (!notes.ok) throw new Error(notes.error);
  return liveNotes(notes.value).map((x) => x.content);
}

async function add(store: Store, content: string): Promise<Note> {
  const note = new Note(content);
  await store.putNotes([{ id: note.id, bytes: note.toBytes() }]);
  return note;
}

describe("sync", () => {
  let server: FakeServer;
  let api: Api;
  beforeEach(() => {
    server = new FakeServer();
    api = new Api(API, server.fetch);
  });

  test("a note captured on one device reaches the other", async () => {
    const [laptop, phone] = [await device(), await device()];
    await add(laptop, "get milk");

    expect(await sync(laptop, api)).toEqual({ ok: true, value: { pushed: 1, pulled: 1 } });
    expect(await sync(phone, api)).toEqual({ ok: true, value: { pushed: 0, pulled: 1 } });
    expect(await contents(phone)).toEqual(["get milk"]);
  });

  test("a delete syncs as a tombstone", async () => {
    const [laptop, phone] = [await device(), await device()];
    const note = await add(laptop, "get milk");
    await sync(laptop, api);
    await sync(phone, api);

    const deleted = note.delete();
    await laptop.putNotes([{ id: deleted.id, bytes: deleted.toBytes() }]);
    await sync(laptop, api);
    await sync(phone, api);
    expect(await contents(phone)).toEqual([]);
  });

  test("an edit syncs, and edits made on two devices at once both survive", async () => {
    const [laptop, phone] = [await device(), await device()];
    const note = await add(laptop, "get milk");
    await sync(laptop, api);
    await sync(phone, api);

    const onPhone = Note.fromBytes((await phone.note(note.id))!);
    expect((await saveEdit(phone, onPhone, "get oat milk")).ok).toBe(true);
    expect((await saveEdit(laptop, note, "get milk\nand eggs")).ok).toBe(true);
    await sync(phone, api);
    await sync(laptop, api);
    await sync(phone, api);
    expect(await contents(laptop)).toEqual(["get oat milk\nand eggs"]);
    expect(await contents(phone)).toEqual(["get oat milk\nand eggs"]);
  });

  test("a second sync with nothing new sends nothing", async () => {
    const laptop = await device();
    await add(laptop, "x");
    await sync(laptop, api);
    expect(await sync(laptop, api)).toEqual({ ok: true, value: { pushed: 0, pulled: 0 } });
    expect(server.log).toHaveLength(1);
  });

  test("pulls page by page until caught up", async () => {
    server.pageSize = 2;
    const laptop = await device();
    for (const c of ["a", "b", "c", "d", "e"]) await add(laptop, c);
    await sync(laptop, api);
    const phone = await device();
    expect(await sync(phone, api)).toEqual({ ok: true, value: { pushed: 0, pulled: 5 } });
    expect(await contents(phone)).toHaveLength(5);
    expect(syncCursor((await phone.syncState())!)).toBe(5);
  });

  test("an expired access token is refreshed once and saved", async () => {
    const laptop = await device();
    await add(laptop, "x");
    server.expireAccessTokens();
    expect((await sync(laptop, api)).ok).toBe(true);
    expect(server.refreshes).toBe(1);
    expect((await laptop.credentials())!.accessToken).toBe("access-2");
  });

  test("a refused refresh token means signed out", async () => {
    const laptop = await device();
    server.expireAccessTokens();
    server.validRefresh.clear();
    expect(await sync(laptop, api)).toEqual({ ok: false, error: { kind: "signed_out" } });
  });

  test("offline keeps the note and says so; the next sync sends it", async () => {
    const laptop = await device();
    await add(laptop, "on the train");
    server.offline = true;
    expect(await sync(laptop, api)).toEqual({ ok: false, error: { kind: "offline" } });
    expect(await contents(laptop)).toEqual(["on the train"]);
    server.offline = false;
    expect(await sync(laptop, api)).toMatchObject({ ok: true, value: { pushed: 1 } });
  });

  test("a bad change from the server leaves the cursor put", async () => {
    const phone = await device();
    server.log.push({ seq: 1, note_id: "x", data: "AQID" });
    const result = await sync(phone, api);
    expect(result.ok).toBe(false);
    expect(await phone.syncState()).toBeUndefined();
  });

  test("signed out, nothing is sent", async () => {
    const laptop = await device(false);
    await add(laptop, "x");
    expect(await sync(laptop, api)).toEqual({ ok: false, error: { kind: "signed_out" } });
    expect(server.log).toHaveLength(0);
  });

  test("concurrent syncs run one at a time and agree", async () => {
    const laptop = await device();
    await add(laptop, "x");
    const results = await Promise.all([sync(laptop, api), sync(laptop, api)]);
    expect(results.every((r) => r.ok)).toBe(true);
    expect(server.log).toHaveLength(1);
  });
});

describe("store", () => {
  test("signing out forgets credentials and sync state; notes stay", async () => {
    const store = await device();
    await add(store, "keep me");
    await store.putSyncState('{"cursor":3,"pushed":{}}');
    await store.forgetSession();
    expect(await store.credentials()).toBeUndefined();
    expect(await store.syncState()).toBeUndefined();
    expect(await contents(store)).toEqual(["keep me"]);
  });
});
