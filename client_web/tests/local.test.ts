import { describe, expect, test } from "vitest";
import { Note } from "../src/core/qot_wasm";
import { deleteLocal, discardIfEmpty, saveEdit, saveNew } from "../src/local";
import { liveNotes, parseNotes } from "../src/notes";
import { openStore, type Store } from "../src/store";

let n = 0;
const fresh = () => openStore(`local-${n++}`);

async function stored(store: Store, id: string): Promise<Note> {
  const bytes = await store.note(id);
  if (!bytes) throw new Error(`no note ${id}`);
  return Note.fromBytes(bytes);
}

async function saved(store: Store, text: string): Promise<Note> {
  const note = await saveNew(store, text);
  if (!note.ok || !note.value) throw new Error("not saved");
  return note.value;
}

describe("local changes", () => {
  test("a new note is saved at once; blank text saves nothing", async () => {
    const store = await fresh();
    const note = await saveNew(store, " get milk ");
    expect(note.ok && note.value?.content).toBe("get milk");
    expect(await saveNew(store, "  ")).toEqual({ ok: true, value: null });
    const notes = parseNotes(await store.allNotes());
    expect(notes.ok && liveNotes(notes.value).map((v) => v.content)).toEqual(["get milk"]);
  });

  test("an edit is saved and returns the new base", async () => {
    const store = await fresh();
    const note = await saved(store, "get milk");
    const edit = await saveEdit(store, note, "get oat milk");
    expect(edit.ok && edit.value?.base.content).toBe("get oat milk");
    expect((await stored(store, note.id)).content).toBe("get oat milk");

    // Typing on: each save goes over the base the last one returned.
    if (!edit.ok || !edit.value) throw new Error("no edit");
    const next = await saveEdit(store, edit.value.base, "get oat milk\nand eggs");
    expect(next.ok).toBe(true);
    expect((await stored(store, note.id)).content).toBe("get oat milk\nand eggs");
  });

  test("edits from two tabs over the same version both survive", async () => {
    const store = await fresh();
    const base = await saved(store, "milk");
    // Each tab loaded its own copy of the note.
    const [tab1, tab2] = [Note.fromBytes(base.toBytes()), Note.fromBytes(base.toBytes())];
    const [a, b] = await Promise.all([saveEdit(store, tab1, "oat milk"), saveEdit(store, tab2, "milk\neggs")]);
    expect(a.ok && b.ok).toBe(true);
    expect((await stored(store, base.id)).content).toBe("oat milk\neggs");
  });

  test("editing a note that isn't stored is an error, and saves nothing", async () => {
    const store = await fresh();
    const result = await saveEdit(store, new Note("never saved"), "edited");
    expect(result.ok).toBe(false);
    expect((await store.allNotes()).size).toBe(0);
  });

  test("leaving an emptied note deletes it; a note with text stays", async () => {
    const store = await fresh();
    const empty = await saved(store, "soon empty");
    const kept = await saved(store, "keep");
    await saveEdit(store, empty, "");
    expect(await discardIfEmpty(store, empty.id)).toEqual({ ok: true, value: true });
    expect(await discardIfEmpty(store, kept.id)).toEqual({ ok: true, value: false });
    expect((await stored(store, empty.id)).isDeleted).toBe(true);
    expect((await stored(store, kept.id)).isDeleted).toBe(false);
  });

  test("delete leaves a tombstone", async () => {
    const store = await fresh();
    const note = await saved(store, "x");
    expect((await deleteLocal(store, note.id)).ok).toBe(true);
    expect((await stored(store, note.id)).isDeleted).toBe(true);
    expect((await deleteLocal(store, "nope")).ok).toBe(false);
  });
});
