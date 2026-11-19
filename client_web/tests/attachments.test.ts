import { beforeEach, describe, expect, test } from "vitest";
import { Api } from "../src/api";
import { loadBlob } from "../src/blobs";
import { Attachment, Note } from "../src/core/qot_wasm";
import { deleteLocal, discardIfEmpty, removeAttachment, saveEdit } from "../src/local";
import { attachmentTitle, filterNotes, liveNotes, parseNotes, shouldDiscard } from "../src/notes";
import { openStore, type Store } from "../src/store";
import { sync } from "../src/sync";
import { FakeServer } from "./fake-server";
import { memo } from "./memo";

const API = "https://api.example";
let n = 0;

async function device(signedIn = true): Promise<Store> {
  const store = await openStore(`memo-device-${n++}`);
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

const put = (store: Store, note: Note) => store.putNotes([{ id: note.id, bytes: note.toBytes() }]);

async function stored(store: Store, id: string): Promise<Note> {
  const bytes = await store.note(id);
  if (!bytes) throw new Error(`no note ${id}`);
  return Note.fromBytes(bytes);
}

async function views(store: Store) {
  const notes = parseNotes(await store.allNotes());
  if (!notes.ok) throw new Error(notes.error);
  return liveNotes(notes.value);
}

describe("showing notes with attachments", () => {
  test("a voice memo lists its recording; its title is its text", () => {
    const { note, audio } = memo("call the plumber\nabout the sink");
    const [view] = liveNotes([note]);
    expect(view!.title).toBe("call the plumber");
    expect(view!.preview).toBe("about the sink");
    expect(view!.attachments).toEqual([
      { id: audio.id, kind: "audio", mediaType: "audio/mp4", size: 340_000, durationMs: 42_000, label: "audio 0:42", title: "Voice memo 0:42" },
    ]);
  });

  test("a recording with no text is titled as a voice memo", () => {
    const [view] = liveNotes([memo("").note]);
    expect(view!.title).toBe("Voice memo 0:42");
    expect(view!.preview).toBe("");
  });

  test("an attachment of a kind this app doesn't know is still named", () => {
    const hologram = new Attachment(Attachment.newId(), "hologram", "model/x-holo", 2_400_000, undefined, "none");
    expect(attachmentTitle(hologram)).toBe("Attachment (hologram, 2 MB)");
    const [view] = liveNotes([Note.withAttachment("", hologram)]);
    expect(view!.title).toBe("Attachment (hologram, 2 MB)");
  });

  test("search finds a memo by its text, and one without text by its title", () => {
    const all = liveNotes([memo("call the plumber").note, memo("").note, new Note("get milk")]);
    expect(filterNotes(all, "plumber").map((v) => v.title)).toEqual(["call the plumber"]);
    expect(filterNotes(all, "voice memo").map((v) => v.title)).toEqual(["Voice memo 0:42"]);
  });

  test("a recording with no text is not an empty note to discard", () => {
    expect(shouldDiscard(memo("").note)).toBe(false);
    expect(shouldDiscard(new Note("x").update(""))).toBe(true);
  });
});

describe("the blob store", () => {
  test("keeps bytes by id and lists them", async () => {
    const store = await device(false);
    expect(await store.blob("a")).toBeUndefined();
    await store.putBlob("a", new Uint8Array([1, 2, 3]));
    await store.putBlob("b", new Uint8Array([4]));
    expect(await store.blob("a")).toEqual(new Uint8Array([1, 2, 3]));
    expect((await store.blobIds()).sort()).toEqual(["a", "b"]);
    await store.deleteBlobs(["a", "missing"]);
    expect(await store.blobIds()).toEqual(["b"]);
  });

  test("a store from before blobs gains them and keeps its notes", async () => {
    const name = `memo-old-${n++}`;
    const note = new Note("get milk");
    await new Promise<void>((resolve, reject) => {
      const open = indexedDB.open(name, 1);
      open.onupgradeneeded = () => {
        open.result.createObjectStore("notes");
        open.result.createObjectStore("meta");
      };
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const tx = open.result.transaction("notes", "readwrite");
        tx.objectStore("notes").put(note.toBytes(), note.id);
        tx.oncomplete = () => {
          open.result.close();
          resolve();
        };
      };
    });
    const store = await openStore(name);
    expect((await views(store)).map((v) => v.content)).toEqual(["get milk"]);
    await store.putBlob("a", new Uint8Array([1]));
    expect(await store.blobIds()).toEqual(["a"]);
  });
});

describe("a note's recording", () => {
  let server: FakeServer;
  let api: Api;
  beforeEach(() => {
    server = new FakeServer();
    api = new Api(API, server.fetch);
  });

  /** A phone that recorded a memo, synced it and uploaded the recording. */
  async function recorded(text = "call the plumber") {
    const phone = await device();
    const m = memo(text);
    await put(phone, m.note);
    await sync(phone, api);
    server.blobs.set(m.audio.id, m.bytes);
    return { phone, ...m };
  }

  test("is fetched when asked for, then kept", async () => {
    const { note, audio, bytes } = await recorded();
    const laptop = await device();
    await sync(laptop, api);
    expect(await laptop.blobIds()).toEqual([]);

    expect(await loadBlob(laptop, api, audio.id)).toEqual({ ok: true, value: bytes });
    expect(await laptop.blob(audio.id)).toEqual(bytes);
    expect((await stored(laptop, note.id)).attachments()[0]!.id).toBe(audio.id);

    // The second time it comes from this device, even offline.
    server.offline = true;
    expect(await loadBlob(laptop, api, audio.id)).toEqual({ ok: true, value: bytes });
  });

  test("that the server doesn't have yet is 'on its way', and nothing is kept", async () => {
    const { audio } = await recorded();
    server.blobs.clear();
    const laptop = await device();
    await sync(laptop, api);
    expect(await loadBlob(laptop, api, audio.id)).toEqual({ ok: false, error: { kind: "not_yet" } });
    expect(await laptop.blobIds()).toEqual([]);
  });

  test("can't be fetched offline or signed out, and says which", async () => {
    const { note, audio } = await recorded();
    const laptop = await device();
    await sync(laptop, api);
    server.offline = true;
    expect(await loadBlob(laptop, api, audio.id)).toEqual({ ok: false, error: { kind: "offline" } });

    const guest = await device(false);
    await put(guest, note);
    expect(await loadBlob(guest, api, audio.id)).toEqual({ ok: false, error: { kind: "signed_out" } });
  });

  test("survives a refreshed token", async () => {
    const { audio, bytes } = await recorded();
    const laptop = await device();
    await sync(laptop, api);
    server.expireAccessTokens();
    expect(await loadBlob(laptop, api, audio.id)).toEqual({ ok: true, value: bytes });
  });

  test("deleting the note here deletes the recording here, on the server and on the phone", async () => {
    const { phone, note, audio, bytes } = await recorded();
    await phone.putBlob(audio.id, bytes);
    const laptop = await device();
    await sync(laptop, api);
    await loadBlob(laptop, api, audio.id);

    await deleteLocal(laptop, note.id);
    expect(await laptop.blobIds()).toEqual([]);
    await sync(laptop, api);
    expect(server.blobs.has(audio.id)).toBe(false);
    expect(server.deletedBlobs).toEqual([audio.id]);

    await sync(phone, api);
    expect(await views(phone)).toEqual([]);
    expect(await phone.blobIds()).toEqual([]);
  });

  test("removing the recording keeps the text", async () => {
    const { note, audio } = await recorded();
    const laptop = await device();
    await sync(laptop, api);
    await loadBlob(laptop, api, audio.id);

    const removed = await removeAttachment(laptop, note.id, audio.id);
    expect(removed.ok).toBe(true);
    const [view] = await views(laptop);
    expect(view!.content).toBe("call the plumber");
    expect(view!.attachments).toEqual([]);
    expect(await laptop.blobIds()).toEqual([]);

    await sync(laptop, api);
    expect(server.blobs.has(audio.id)).toBe(false);
  });

  test("clearing the text keeps the recording, and leaving the note doesn't discard it", async () => {
    const { note, audio } = await recorded();
    const laptop = await device();
    await sync(laptop, api);

    const edit = await saveEdit(laptop, await stored(laptop, note.id), "");
    expect(edit.ok).toBe(true);
    expect(await discardIfEmpty(laptop, note.id)).toEqual({ ok: true, value: false });
    const [view] = await views(laptop);
    expect(view!.title).toBe("Voice memo 0:42");
    expect(view!.attachments.map((a) => a.id)).toEqual([audio.id]);
  });

  test("an ordinary push names no blobs", async () => {
    const laptop = await device();
    await put(laptop, new Note("get milk"));
    await sync(laptop, api);
    expect(server.pushes.at(-1)).not.toHaveProperty("deleted_blobs");
  });
});
