import { describe, expect, test } from "vitest";
import { Note } from "../src/core/qot_wasm";
import { age, capture, deleteNote, liveNotes, parseNotes } from "../src/notes";

describe("notes", () => {
  test("live notes hide tombstones, newest first", () => {
    const a = new Note("first");
    const b = new Note("second");
    const c = new Note("gone").delete();
    expect(liveNotes([a, b, c]).map((n) => n.content)).toEqual(["second", "first"]);
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

  test("deleting makes a tombstone of the right note", () => {
    const a = new Note("a");
    const deleted = deleteNote([a, new Note("b")], a.id);
    expect(deleted.ok && deleted.value.isDeleted && deleted.value.id === a.id).toBe(true);
    expect(deleteNote([a], "nope").ok).toBe(false);
  });

  test("age reads naturally", () => {
    const now = Date.UTC(2026, 10, 6, 12);
    expect(age(now - 5_000, now)).toBe("just now");
    expect(age(now - 5 * 60_000, now)).toBe("5 min ago");
    expect(age(now - 3 * 3_600_000, now)).toBe("3 h ago");
    expect(age(now - 3 * 86_400_000, now)).toMatch(/Nov/);
  });
});
