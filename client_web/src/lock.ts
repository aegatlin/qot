// Mutual exclusion across every tab of the app (Web Locks), so two tabs never
// interleave a read-modify-write of the same note, and only one syncs at a
// time. Falls back to an in-tab queue where Web Locks are missing (tests).

const queues = new Map<string, Promise<unknown>>();

export function withLock<T>(name: string, f: () => Promise<T>): Promise<T> {
  const locks = (globalThis.navigator as Navigator | undefined)?.locks;
  if (locks) return locks.request(name, f) as Promise<T>;
  const prev = queues.get(name) ?? Promise.resolve();
  const next = prev.then(f, f);
  queues.set(name, next.catch(() => undefined));
  return next;
}
