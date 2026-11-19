// Attachments' bytes on this device. A blob is fetched the first time its
// note is shown, not during sync, then kept in the store; `planBlobs` (run
// by a sync and by local deletes) removes it once no live note refers to it.

import type { Api, ApiError } from "./api";
import { emptySyncState, markUploaded } from "./core/qot_wasm";
import { withLock } from "./lock";
import { attempt, err, ok, type Result } from "./result";
import type { Store } from "./store";
import { authed, SYNC_LOCK } from "./sync";

export type BlobError =
  /** The server doesn't have it: the device that recorded it hasn't sent it
   *  yet (or it was deleted, and the note will follow). */
  | { kind: "not_yet" }
  | { kind: "signed_out" }
  | { kind: "offline" }
  | { kind: "failed"; message: string };

export function blobErrorText(e: BlobError): string {
  switch (e.kind) {
    case "not_yet":
      return "Audio on its way. It plays here once the device that recorded it has sent it.";
    case "signed_out":
      return "Sign in to load this recording.";
    case "offline":
      return "Offline. The recording loads when you're back.";
    case "failed":
      return `The recording couldn't be loaded: ${e.message}`;
  }
}

function fromApi(e: ApiError): BlobError {
  if (e.kind === "unauthorized") return { kind: "signed_out" };
  if (e.kind === "offline") return { kind: "offline" };
  if (e.kind === "rate_limited") return { kind: "failed", message: "too many requests" };
  return { kind: "failed", message: e.error };
}

/** An attachment's bytes: from this device if it has them, else the server. */
export async function loadBlob(store: Store, api: Api, id: string): Promise<Result<Uint8Array, BlobError>> {
  try {
    const kept = await store.blob(id);
    if (kept) return ok(kept);
    const creds = await store.credentials();
    if (!creds) return err({ kind: "signed_out" });
    const fetched = await authed(api, store, creds, (token) => api.getBlob(token, id));
    if (!fetched.ok) return err(fromApi(fetched.error));
    const bytes = fetched.value;
    if (!bytes) return err({ kind: "not_yet" });

    // Keep it, and record that the server has it. The sync state is a sync's
    // to write, so this waits for one that is running.
    const kept2 = await withLock(SYNC_LOCK, async (): Promise<Result<null>> => {
      await store.putBlob(id, bytes);
      const state = (await store.syncState()) ?? emptySyncState();
      const next = attempt(() => markUploaded(state, [id]));
      if (!next.ok) return next;
      await store.putSyncState(next.value);
      return ok(null);
    });
    if (!kept2.ok) return err({ kind: "failed", message: kept2.error });
    return ok(bytes);
  } catch (e) {
    return err({ kind: "failed", message: e instanceof Error ? e.message : String(e) });
  }
}
