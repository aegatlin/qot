// Errors are values: every fallible step returns one of these, so a failure
// can't silently become an empty list or a default note.
export type Result<T, E = string> = { ok: true; value: T } | { ok: false; error: E };

export const ok = <T>(value: T): Result<T, never> => ({ ok: true, value });
export const err = <E>(error: E): Result<never, E> => ({ ok: false, error });

/** Runs `f`, turning a throw (e.g. from the wasm core) into an error value. */
export function attempt<T>(f: () => T): Result<T> {
  try {
    return ok(f());
  } catch (e) {
    return err(e instanceof Error ? e.message : String(e));
  }
}
