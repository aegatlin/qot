// The sync shell: push, then pull (CLAUDE.md "Client sync"). The rules are
// the core's (planPush, markPushed, applyPulled); this only moves bytes and
// saves state after every step, so an interrupted sync resumes and anything
// repeated is harmless.

import { type Api, type ApiError, type ApiResult, describe } from "./api";
import { applyPulled, emptySyncState, Incoming, markPushed, type Note, planPush, syncCursor } from "./core/qot_wasm";
import { withLock } from "./lock";
import { parseNotes } from "./notes";
import { attempt, err, ok, type Result } from "./result";
import type { Credentials, Store } from "./store";

/** The server takes at most 500 changes per push (Qot.Sync.Batch). */
const PUSH_CHUNK = 500;

export const STORE_LOCK = "qot-store";
const SYNC_LOCK = "qot-sync";

export interface SyncReport {
  pushed: number;
  pulled: number;
}

export type SyncError =
  | { kind: "signed_out" }
  | { kind: "offline" }
  | { kind: "failed"; message: string };

export function syncErrorText(e: SyncError): string {
  switch (e.kind) {
    case "signed_out":
      return "Signed out: sign in again to sync.";
    case "offline":
      return "Offline. Notes are saved here and sync when you're back.";
    case "failed":
      return `Not synced: ${e.message}`;
  }
}

function fromApi(e: ApiError): SyncError {
  if (e.kind === "unauthorized") return { kind: "signed_out" };
  if (e.kind === "offline") return { kind: "offline" };
  return { kind: "failed", message: describe(e) };
}

const failed = (message: string): Result<never, SyncError> => err({ kind: "failed", message });

/** Runs `call` with the access token, refreshing it once if it was refused. */
export async function authed<T>(
  api: Api,
  store: Store,
  creds: Credentials,
  call: (token: string) => ApiResult<T>,
): ApiResult<T> {
  const first = await call(creds.accessToken);
  if (first.ok || first.error.kind !== "unauthorized") return first;
  const fresh = await api.refresh(creds.refreshToken);
  if (!fresh.ok) return fresh;
  creds.accessToken = fresh.value;
  await store.putCredentials(creds);
  return call(creds.accessToken);
}

async function loadNotes(store: Store): Promise<Result<Note[], SyncError>> {
  const notes = parseNotes(await store.allNotes());
  return notes.ok ? notes : failed(notes.error);
}

/** One sync, run by one tab at a time. */
export function sync(store: Store, api: Api): Promise<Result<SyncReport, SyncError>> {
  return withLock(SYNC_LOCK, () => syncOnce(store, api)).catch((e: unknown) =>
    failed(e instanceof Error ? e.message : String(e)),
  );
}

async function syncOnce(store: Store, api: Api): Promise<Result<SyncReport, SyncError>> {
  const creds = await store.credentials();
  if (!creds) return err({ kind: "signed_out" });
  const report: SyncReport = { pushed: 0, pulled: 0 };
  let state = (await store.syncState()) ?? emptySyncState();

  const notes = await loadNotes(store);
  if (!notes.ok) return notes;
  const planned = attempt(() => planPush(notes.value.map((n) => n.copy()), state));
  if (!planned.ok) return failed(planned.error);

  for (let i = 0; i < planned.value.length; i += PUSH_CHUNK) {
    const chunk = planned.value.slice(i, i + PUSH_CHUNK);
    const sent = await authed(api, store, creds, (t) =>
      api.push(
        t,
        chunk.map((o) => ({ noteId: o.noteId, data: o.data })),
      ),
    );
    if (!sent.ok) return err(fromApi(sent.error));
    const next = attempt(() => markPushed(state, chunk));
    if (!next.ok) return failed(next.error);
    state = next.value;
    await store.putSyncState(state);
    report.pushed += chunk.length;
  }

  for (;;) {
    const cursor = attempt(() => syncCursor(state));
    if (!cursor.ok) return failed(cursor.error);
    const page = await authed(api, store, creds, (t) => api.pull(t, cursor.value));
    if (!page.ok) return err(fromApi(page.error));

    // Load, apply and save under the store lock, so a delete made in another
    // tab meanwhile isn't overwritten by a copy from before it.
    const applied = await withLock(STORE_LOCK, async (): Promise<Result<string, SyncError>> => {
      const current = await loadNotes(store);
      if (!current.ok) return current;
      const pulled = attempt(() => {
        const incoming = page.value.changes.map((c) => new Incoming(c.seq, c.noteId, c.data));
        return applyPulled(
          current.value.map((n) => n.copy()),
          state,
          incoming,
        );
      });
      if (!pulled.ok) return failed(pulled.error);
      await store.putNotes(pulled.value.changed.map((n) => ({ id: n.id, bytes: n.toBytes() })));
      await store.putSyncState(pulled.value.state);
      return ok(pulled.value.state);
    });
    if (!applied.ok) return applied;
    state = applied.value;
    report.pulled += page.value.changes.length;
    if (!page.value.more) break;
  }

  return ok(report);
}
