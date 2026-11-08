// The device's storage, in IndexedDB: the CLI's layout in browser form.
//   notes: note id -> Automerge bytes (notes/<id>.note)
//   meta:  "sync" -> SyncState JSON (sync.json),
//          "credentials" -> Credentials (credentials.json)
// Every tab of the app shares it. Methods reject on I/O failure; callers turn
// that into an error value.

export interface Credentials {
  server: string;
  email: string;
  userId: string;
  accessToken: string;
  refreshToken: string;
}

export interface Store {
  allNotes(): Promise<Map<string, Uint8Array>>;
  note(id: string): Promise<Uint8Array | undefined>;
  putNotes(notes: { id: string; bytes: Uint8Array }[]): Promise<void>;
  syncState(): Promise<string | undefined>;
  putSyncState(json: string): Promise<void>;
  credentials(): Promise<Credentials | undefined>;
  putCredentials(c: Credentials): Promise<void>;
  /** Signs out: forgets credentials and sync state. Notes stay, like `qot logout`. */
  forgetSession(): Promise<void>;
}

const NOTES = "notes";
const META = "meta";

function done(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error ?? new Error("transaction aborted"));
  });
}

function request<T>(r: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

export async function openStore(name = "qot", idb: IDBFactory = indexedDB): Promise<Store> {
  const open = idb.open(name, 1);
  open.onupgradeneeded = () => {
    const db = open.result;
    if (!db.objectStoreNames.contains(NOTES)) db.createObjectStore(NOTES);
    if (!db.objectStoreNames.contains(META)) db.createObjectStore(META);
  };
  const db = await request(open);

  const getMeta = async <T>(key: string): Promise<T | undefined> => {
    const tx = db.transaction(META, "readonly");
    return (await request(tx.objectStore(META).get(key))) as T | undefined;
  };
  const putMeta = async (key: string, value: unknown) => {
    const tx = db.transaction(META, "readwrite");
    tx.objectStore(META).put(value, key);
    await done(tx);
  };

  return {
    async allNotes() {
      const tx = db.transaction(NOTES, "readonly");
      const store = tx.objectStore(NOTES);
      const [keys, values] = await Promise.all([request(store.getAllKeys()), request(store.getAll())]);
      const notes = new Map<string, Uint8Array>();
      keys.forEach((k, i) => notes.set(String(k), new Uint8Array(values[i] as ArrayBuffer | Uint8Array)));
      return notes;
    },
    async note(id) {
      const tx = db.transaction(NOTES, "readonly");
      const value = (await request(tx.objectStore(NOTES).get(id))) as ArrayBuffer | Uint8Array | undefined;
      return value === undefined ? undefined : new Uint8Array(value);
    },
    async putNotes(notes) {
      if (notes.length === 0) return;
      const tx = db.transaction(NOTES, "readwrite");
      for (const n of notes) tx.objectStore(NOTES).put(n.bytes, n.id);
      await done(tx);
    },
    syncState: () => getMeta<string>("sync"),
    putSyncState: (json) => putMeta("sync", json),
    credentials: () => getMeta<Credentials>("credentials"),
    putCredentials: (c) => putMeta("credentials", c),
    async forgetSession() {
      const tx = db.transaction(META, "readwrite");
      tx.objectStore(META).delete("credentials");
      tx.objectStore(META).delete("sync");
      await done(tx);
    },
  };
}
