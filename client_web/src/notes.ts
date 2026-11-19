// Pure rules for showing and changing notes, over the core's immutable Note.

import { type Attachment, Note } from "./core/qot_wasm";
import { attempt, err, ok, type Result } from "./result";

/** Media on a note, as the UI needs it. The bytes are a blob with this id. */
export interface AttachmentView {
  id: string;
  /** `audio`; anything else is a kind this build can't show. */
  kind: string;
  mediaType: string;
  size: number;
  durationMs: number | undefined;
  /** The core's short description: `audio 0:42`, `image, 2 MB`. */
  label: string;
  /** What to call it where a title is needed: `Voice memo 0:42`. */
  title: string;
}

export interface NoteView {
  id: string;
  content: string;
  attachments: AttachmentView[];
  createdAtMs: number;
  /** The last edit, to the second. */
  updatedAtMs: number;
  title: string;
  preview: string;
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

/** Live notes for the list, most recently edited first. */
export function liveNotes(notes: Note[]): NoteView[] {
  return sortByEdit(
    notes
      .filter((n) => !n.isDeleted)
      .map((n) => {
        const content = n.content;
        const attachments = attachmentViews(n);
        return {
          id: n.id,
          content,
          attachments,
          createdAtMs: n.createdAtMs,
          updatedAtMs: n.updatedAtMs,
          ...summary(content, attachments),
        };
      }),
  );
}

/** Newest edit first; edits in the same second by creation, newest first
 *  (UUIDv7 ids sort by creation time). */
export function sortByEdit(views: NoteView[]): NoteView[] {
  return [...views].sort((a, b) => b.updatedAtMs - a.updatedAtMs || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
}

/** A note's attachments, oldest first. */
export function attachmentViews(note: Note): AttachmentView[] {
  return note.attachments().map((a) => ({
    id: a.id,
    kind: a.kind,
    mediaType: a.mediaType,
    size: a.size,
    durationMs: a.durationMs,
    label: a.label,
    title: attachmentTitle(a),
  }));
}

/** A recording is a "Voice memo 0:42"; a kind this build doesn't know is
 *  named by the core's label, so it is never shown as nothing. */
export function attachmentTitle(a: Pick<Attachment, "kind" | "label">): string {
  if (a.kind === "audio") return a.label.replace(/^audio/, "Voice memo");
  return `Attachment (${a.label})`;
}

/** A list row's text, like Apple Notes: the first non-empty line is the
 *  title, the rest (joined onto one line) the preview. A note with no text
 *  is titled by its first attachment. */
export function summary(content: string, attachments: AttachmentView[] = []): { title: string; preview: string } {
  const lines = content
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  return {
    title: lines[0] ?? attachments[0]?.title ?? "New note",
    preview: lines.slice(1).join(" ").slice(0, 200),
  };
}

/** Notes containing every word of the query, ignoring case. */
export function filterNotes(views: NoteView[], query: string): NoteView[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return views;
  return views.filter((v) => {
    // The title too: a recording with no text is found as a "voice memo".
    const text = `${v.title}\n${v.content}`.toLowerCase();
    return words.every((w) => text.includes(w));
  });
}

/** A new note from typed text, or null if there's nothing to keep. */
export function capture(text: string): Note | null {
  const content = text.trim();
  return content ? new Note(content) : null;
}

export interface Edit {
  /** What to store: the edit merged into the stored note. */
  saved: Note;
  /** The editor's text as a note: the version its next edit is typed over. */
  base: Note;
}

/**
 * An editor's text, saved. `base` is the version the text was typed over, so
 * the edit is that version's diff to `text`, merged into `stored`: changes
 * that arrived meanwhile (a sync, another tab) are kept rather than undone by
 * diffing from a copy that lacks them. Text unchanged from its base is
 * nothing to save (null).
 */
export function applyEdit(stored: Note, base: Note, text: string): Result<Edit | null> {
  if (stored.id !== base.id) return err(`an edit to note ${base.id} can't go into note ${stored.id}`);
  if (base.content === text) return ok(null);
  return attempt(() => {
    const edited = base.update(text);
    return { saved: stored.merge(edited), base: edited };
  });
}

/** Leaving a note with nothing in it deletes it, the way Apple Notes discards
 *  empty notes: no text and no attachments (a recording with no text stays).
 *  Only a live note: a tombstone stays as it is. */
export function shouldDiscard(note: Note): boolean {
  return !note.isDeleted && note.isEmpty;
}

/** "just now", "5 min ago", "3 h ago", then the date. */
export function age(atMs: number, nowMs: number): string {
  const secs = Math.max(0, Math.round((nowMs - atMs) / 1000));
  if (secs < 60) return "just now";
  if (secs < 3600) return `${Math.floor(secs / 60)} min ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)} h ago`;
  const d = new Date(atMs);
  const sameYear = d.getFullYear() === new Date(nowMs).getFullYear();
  return d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    ...(sameYear ? {} : { year: "numeric" }),
  });
}
