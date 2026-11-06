// Pure rules for showing and changing notes, over the core's immutable Note.

import { Note } from "./core/qot_wasm";
import { attempt, err, ok, type Result } from "./result";

export interface NoteView {
  id: string;
  content: string;
  createdAtMs: number;
}

/** Every stored note, tombstones included. One unreadable note is an error:
 *  hiding it would look like data loss and let the next save drop it. */
export function parseNotes(stored: Map<string, Uint8Array>): Result<Note[]> {
  const notes: Note[] = [];
  for (const [id, bytes] of stored) {
    const note = attempt(() => Note.fromBytes(bytes));
    if (!note.ok) return err(`note ${id} is unreadable: ${note.error}`);
    notes.push(note.value);
  }
  return ok(notes);
}

/** Live notes, newest first (UUIDv7 ids sort by creation time). */
export function liveNotes(notes: Note[]): NoteView[] {
  return notes
    .filter((n) => !n.isDeleted)
    .map((n) => ({ id: n.id, content: n.content, createdAtMs: n.createdAtMs }))
    .sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
}

/** A new note from typed text, or null if there's nothing to keep. */
export function capture(text: string): Note | null {
  const content = text.trim();
  return content ? new Note(content) : null;
}

export function deleteNote(notes: Note[], id: string): Result<Note> {
  const note = notes.find((n) => n.id === id);
  if (!note) return err(`no note ${id}`);
  return attempt(() => note.delete());
}

/** "just now", "5 min ago", "3 h ago", then the date. */
export function age(createdAtMs: number, nowMs: number): string {
  const secs = Math.max(0, Math.round((nowMs - createdAtMs) / 1000));
  if (secs < 60) return "just now";
  if (secs < 3600) return `${Math.floor(secs / 60)} min ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)} h ago`;
  const d = new Date(createdAtMs);
  const sameYear = d.getFullYear() === new Date(nowMs).getFullYear();
  return d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    ...(sameYear ? {} : { year: "numeric" }),
  });
}
