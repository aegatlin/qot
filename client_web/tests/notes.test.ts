import { describe, expect, test } from "vitest";
import { Note } from "../src/core/qot_wasm";
import {
  age,
  applyEdit,
  capture,
  filterNotes,
  liveNotes,
  type NoteView,
  parseNotes,
  shouldDiscard,
  sortByEdit,
  summary,
} from "../src/notes";

const view = (id: string, updatedAtMs: number, content = id): NoteView => ({
  id,
  content,
  createdAtMs: 0,
  updatedAtMs,
  ...summary(content),
});

describe("notes", () => {
  test("live notes hide tombstones, newest first", () => {
    const a = new Note("first");
    const b = new Note("second");
    const c = new Note("gone").delete();
    expect(liveNotes([a, b, c]).map((n) => n.content)).toEqual(["second", "first"]);
  });

  test("a live note carries its title, preview and last edit", () => {
    const note = new Note("Groceries\neggs");
    const [v] = liveNotes([note]);
    expect(v).toMatchObject({ id: note.id, title: "Groceries", preview: "eggs", updatedAtMs: note.updatedAtMs });
  });

  test("the title is the first non-empty line, the preview the text after it", () => {
    expect(summary("get milk")).toEqual({ title: "get milk", preview: "" });
    expect(summary("\n  Groceries  \n\n eggs \n bread\n")).toEqual({ title: "Groceries", preview: "eggs bread" });
    expect(summary(" \n\t")).toEqual({ title: "New note", preview: "" });
  });

  test("sorted by last edit, newest first; ties by creation, newest first", () => {
    const sorted = sortByEdit([view("a", 1000), view("c", 1000), view("b", 3000)]);
    expect(sorted.map((v) => v.id)).toEqual(["b", "c", "a"]);
  });

  test("filtering keeps notes containing every word, ignoring case", () => {
    const views = [view("1", 0, "Get MILK"), view("2", 0, "milk tea\nwith boba"), view("3", 0, "call mom")];
    expect(filterNotes(views, "milk").map((v) => v.id)).toEqual(["1", "2"]);
    expect(filterNotes(views, " BOBA  milk ").map((v) => v.id)).toEqual(["2"]);
    expect(filterNotes(views, "   ")).toEqual(views);
  });

  test("capture trims, and keeps nothing for blank text", () => {
    expect(capture("  get milk \n")?.content).toBe("get milk");
    expect(capture("   ")).toBeNull();
  });

  test("an unreadable stored note is an error, not a shorter list", () => {
    const good = new Note("ok");
    const stored = new Map([
      [good.id, good.toBytes()],
      ["bad", new Uint8Array([1, 2, 3])],
    ]);
    const parsed = parseNotes(stored);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error).toMatch(/note bad is unreadable/);
  });

  test("age reads naturally", () => {
    const now = Date.UTC(2026, 10, 6, 12);
    expect(age(now - 5_000, now)).toBe("just now");
    expect(age(now - 5 * 60_000, now)).toBe("5 min ago");
    expect(age(now - 3 * 3_600_000, now)).toBe("3 h ago");
    expect(age(now - 3 * 86_400_000, now)).toMatch(/Nov/);
  });
});

describe("editing", () => {
  test("an edit is applied to the version it was typed over", () => {
    const note = new Note("get milk");
    const edit = applyEdit(note, note, "get oat milk");
    if (!edit.ok || !edit.value) throw new Error("no edit");
    expect(edit.value.saved.content).toBe("get oat milk");
    expect(edit.value.base.content).toBe("get oat milk");
  });

  test("text unchanged from its base is nothing to save", () => {
    const note = new Note("get milk");
    expect(applyEdit(note, note, "get milk")).toEqual({ ok: true, value: null });
  });

  test("an edit typed over an older version keeps changes made meanwhile", () => {
    const original = new Note("get milk");
    // Another device (its own copy, so its own Automerge actor) appended a
    // line, and it has synced into the store.
    const elsewhere = Note.fromBytes(original.toBytes()).update("get milk\nand eggs");
    const stored = original.merge(elsewhere);
    // The editor still shows the original and the person types over it.
    const edit = applyEdit(stored, original, "get oat milk");
    if (!edit.ok || !edit.value) throw new Error("no edit");
    expect(edit.value.saved.content).toBe("get oat milk\nand eggs");
    // The new base is what the editor shows, so the next edit diffs from it.
    expect(edit.value.base.content).toBe("get oat milk");
  });

  test("an edit to a different note is an error", () => {
    expect(applyEdit(new Note("a"), new Note("b"), "c").ok).toBe(false);
  });

  test("an empty live note is discarded on leaving; anything else stays", () => {
    expect(shouldDiscard(new Note("x").update(" \n "))).toBe(true);
    expect(shouldDiscard(new Note("x"))).toBe(false);
    expect(shouldDiscard(new Note("x").update("").delete())).toBe(false);
  });
});
