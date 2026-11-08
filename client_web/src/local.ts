// Changes made on this device: every read-modify-write of a note, under the
// store's Web Lock, so it can't interleave with another tab's change or a
// sync applying pulled changes (sync.ts takes the same lock). The rules are
// in notes.ts; this only loads and saves. The caller then tells other tabs
// and syncs.

import { Note } from "./core/qot_wasm";
import { withLock } from "./lock";
import { applyEdit, capture, type Edit, shouldDiscard } from "./notes";
import { attempt, err, ok, type Result } from "./result";
import type { Store } from "./store";
import { STORE_LOCK } from "./sync";

function locked<T>(f: () => Promise<Result<T>>): Promise<Result<T>> {
  return withLock(STORE_LOCK, f).catch((e: unknown) => err(e instanceof Error ? e.message : String(e)));
}

async function load(store: Store, id: string): Promise<Result<Note>> {
  const bytes = await store.note(id);
  if (!bytes) return err(`no note ${id}`);
  const note = attempt(() => Note.fromBytes(bytes));
  return note.ok ? note : err(`note ${id} is unreadable: ${note.error}`);
}

const put = (store: Store, note: Note) => store.putNotes([{ id: note.id, bytes: note.toBytes() }]);

/** Captures typed text as a new note; null if it was blank. */
export function saveNew(store: Store, text: string): Promise<Result<Note | null>> {
  const note = capture(text);
  if (!note) return Promise.resolve(ok(null));
  return locked(async () => {
    await put(store, note);
    return ok(note);
  });
}

/** Saves an editor's text, typed over `base` (see `applyEdit`). Null when
 *  there was nothing to save. */
export function saveEdit(store: Store, base: Note, text: string): Promise<Result<Edit | null>> {
  return locked(async () => {
    const stored = await load(store, base.id);
    if (!stored.ok) return stored;
    const edit = applyEdit(stored.value, base, text);
    if (edit.ok && edit.value) await put(store, edit.value.saved);
    return edit;
  });
}

/** On leaving a note: deletes it if it has no text. True if it did. */
export function discardIfEmpty(store: Store, id: string): Promise<Result<boolean>> {
  return locked(async () => {
    const stored = await load(store, id);
    if (!stored.ok) return stored;
    if (!shouldDiscard(stored.value)) return ok(false);
    const deleted = attempt(() => stored.value.delete());
    if (!deleted.ok) return deleted;
    await put(store, deleted.value);
    return ok(true);
  });
}

/** Deletes a note: a tombstone, so the delete syncs. */
export function deleteLocal(store: Store, id: string): Promise<Result<Note>> {
  return locked(async () => {
    const stored = await load(store, id);
    if (!stored.ok) return stored;
    const deleted = attempt(() => stored.value.delete());
    if (deleted.ok) await put(store, deleted.value);
    return deleted;
  });
}
