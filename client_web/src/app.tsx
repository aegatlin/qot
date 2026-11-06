import { useCallback, useEffect, useRef, useState } from "preact/hooks";
import { type Api, describe, type DeviceStart } from "./api";
import type { Note } from "./core/qot_wasm";
import { connectLive } from "./live";
import { withLock } from "./lock";
import { age, capture, deleteNote, liveNotes, parseNotes } from "./notes";
import { adoptTokens, browserChoice, signOut } from "./session";
import type { Credentials, Store } from "./store";
import { STORE_LOCK, sync, syncErrorText, type SyncError } from "./sync";

type SyncStatus = { kind: "idle" } | { kind: "syncing" } | { kind: "synced" } | { kind: "error"; error: SyncError };

/** Tells the app's other tabs that the store changed. */
const channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel("qot");

export function App({ api, store }: { api: Api; store: Store }) {
  const [notes, setNotes] = useState<Note[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [creds, setCreds] = useState<Credentials | undefined>(undefined);
  const [status, setStatus] = useState<SyncStatus>({ kind: "idle" });
  const [banner, setBanner] = useState<string | null>(null);
  const [path, setPath] = useState(location.pathname);

  const reload = useCallback(async () => {
    try {
      const parsed = parseNotes(await store.allNotes());
      if (parsed.ok) {
        setNotes(parsed.value);
        setLoadError(null);
      } else setLoadError(parsed.error);
      setCreds(await store.credentials());
    } catch (e) {
      setLoadError(`couldn't read this browser's storage: ${e instanceof Error ? e.message : e}`);
    }
  }, [store]);

  const changed = useCallback(async () => {
    await reload();
    channel?.postMessage("changed");
  }, [reload]);

  // One sync at a time per tab; a request while one runs queues one more.
  const syncing = useRef<Promise<void> | null>(null);
  const again = useRef(false);
  const runSync = useCallback(async (): Promise<void> => {
    if (syncing.current) {
      again.current = true;
      return syncing.current;
    }
    syncing.current = (async () => {
      do {
        again.current = false;
        if (!(await store.credentials())) break;
        setStatus({ kind: "syncing" });
        const result = await sync(store, api);
        if (result.ok) {
          setStatus({ kind: "synced" });
          if (result.value.pulled > 0 || result.value.pushed > 0) await changed();
        } else {
          setStatus({ kind: "error", error: result.error });
          // The refresh token was refused: this browser's session is over.
          // Forget it (notes stay) so the page offers to sign in again.
          if (result.error.kind === "signed_out") {
            await store.forgetSession();
            await changed();
          }
        }
      } while (again.current);
    })().finally(() => {
      syncing.current = null;
    });
    return syncing.current;
  }, [api, store, changed]);

  useEffect(() => {
    reload();
    const onMessage = () => reload();
    channel?.addEventListener("message", onMessage);
    const onPop = () => setPath(location.pathname);
    addEventListener("popstate", onPop);
    return () => {
      channel?.removeEventListener("message", onMessage);
      removeEventListener("popstate", onPop);
    };
  }, [reload]);

  // While signed in: sync now, when back online or shown, and on every nudge.
  const userId = creds?.userId;
  useEffect(() => {
    if (!userId) return;
    runSync();
    const onOnline = () => runSync();
    const onVisible = () => document.visibilityState === "visible" && runSync();
    addEventListener("online", onOnline);
    document.addEventListener("visibilitychange", onVisible);
    let lastErrorSync = 0;
    const live = connectLive({
      socketUrl: api.socketUrl(),
      userId,
      token: () => credsRef.current?.accessToken ?? "",
      onChanged: () => runSync(),
      // A refused socket is usually an expired access token: a sync
      // refreshes it, then the socket's next retry gets in.
      onTrouble: () => {
        if (Date.now() - lastErrorSync > 10_000) {
          lastErrorSync = Date.now();
          runSync();
        }
      },
    });
    return () => {
      live.close();
      removeEventListener("online", onOnline);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [userId, api, runSync]);

  const credsRef = useRef(creds);
  credsRef.current = creds;

  const go = (to: string) => {
    history.pushState(null, "", to);
    setPath(location.pathname);
  };

  const onCapture = async (text: string) => {
    const note = capture(text);
    if (!note) return;
    try {
      await withLock(STORE_LOCK, () => store.putNotes([{ id: note.id, bytes: note.toBytes() }]));
    } catch (e) {
      setLoadError(`not saved: ${e instanceof Error ? e.message : e}`);
      return;
    }
    await changed();
    runSync();
  };

  const onDelete = async (id: string) => {
    const result = await withLock(STORE_LOCK, async () => {
      const current = parseNotes(await store.allNotes());
      if (!current.ok) return current;
      const deleted = deleteNote(current.value, id);
      if (deleted.ok) await store.putNotes([{ id, bytes: deleted.value.toBytes() }]);
      return deleted;
    }).catch((e: unknown) => ({ ok: false as const, error: e instanceof Error ? e.message : String(e) }));
    if (!result.ok) setLoadError(`not deleted: ${result.error}`);
    await changed();
    runSync();
  };

  const onSignedIn = async (message: string) => {
    setBanner(message);
    await changed();
    go("/");
  };

  const onSignOut = async () => {
    await signOut(store, api);
    setStatus({ kind: "idle" });
    await changed();
  };

  if (path === "/auth/device") {
    const token = new URLSearchParams(location.search).get("token") ?? "";
    return (
      <Shell>
        <DeviceApproval token={token} api={api} store={store} current={creds} onSignedIn={onSignedIn} onHome={() => go("/")} />
      </Shell>
    );
  }

  return (
    <Shell
      right={creds ? <Account creds={creds} status={status} onSignOut={onSignOut} /> : null}
    >
      {banner && (
        <p class="banner" role="status">
          {banner}
          <button class="link" onClick={() => setBanner(null)} aria-label="Dismiss">
            ×
          </button>
        </p>
      )}
      {loadError && <p class="error">{loadError}</p>}
      <Capture onCapture={onCapture} />
      {notes === null ? null : <NoteList notes={notes} onDelete={onDelete} />}
      {!creds && <SignIn api={api} store={store} onSignedIn={onSignedIn} />}
    </Shell>
  );
}

function Shell({ children, right }: { children: preact.ComponentChildren; right?: preact.ComponentChildren }) {
  return (
    <main>
      <header>
        <a class="brand" href="/">
          <img src="/icon.svg" alt="" width="28" height="28" />
          <span>Quantum of Thought</span>
        </a>
        {right}
      </header>
      {children}
    </main>
  );
}

function Account({ creds, status, onSignOut }: { creds: Credentials; status: SyncStatus; onSignOut: () => void }) {
  const [label, title] =
    status.kind === "syncing"
      ? ["Syncing…", ""]
      : status.kind === "error"
        ? [status.error.kind === "offline" ? "Offline" : "Not synced", syncErrorText(status.error)]
        : status.kind === "synced"
          ? ["Synced", ""]
          : ["", ""];
  return (
    <div class="account">
      <span class={`sync sync-${status.kind}`} title={title} data-testid="sync-status">
        {label}
      </span>
      <details>
        <summary aria-label="Account">{creds.email}</summary>
        <div class="menu">
          {status.kind === "error" && <p class="muted">{syncErrorText(status.error)}</p>}
          <button onClick={onSignOut}>Sign out of this browser</button>
          <p class="muted">Notes stay on this device.</p>
        </div>
      </details>
    </div>
  );
}

function Capture({ onCapture }: { onCapture: (text: string) => void }) {
  const [text, setText] = useState("");
  const submit = (e: Event) => {
    e.preventDefault();
    onCapture(text);
    setText("");
  };
  return (
    <form class="capture" onSubmit={submit}>
      <textarea
        aria-label="New note"
        placeholder="get milk"
        value={text}
        rows={2}
        autofocus
        onInput={(e) => setText((e.target as HTMLTextAreaElement).value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey && !e.isComposing) submit(e);
        }}
      />
      <button type="submit" disabled={!text.trim()}>
        Save
      </button>
    </form>
  );
}

function NoteList({ notes, onDelete }: { notes: Note[]; onDelete: (id: string) => void }) {
  const live = liveNotes(notes);
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);
  if (live.length === 0) return <p class="muted empty">No notes yet. Type one above, or run <code>qot get milk</code>.</p>;
  return (
    <ul class="notes" aria-label="Notes">
      {live.map((n) => (
        <li key={n.id}>
          <p class="content">{n.content}</p>
          <span class="muted when">{age(n.createdAtMs, now)}</span>
          <button class="delete" aria-label={`Delete “${n.content}”`} onClick={() => onDelete(n.id)}>
            ×
          </button>
        </li>
      ))}
    </ul>
  );
}

/** Sign in from the browser itself: the same device sign-in as the CLI. */
function SignIn({ api, store, onSignedIn }: { api: Api; store: Store; onSignedIn: (message: string) => void }) {
  const [email, setEmail] = useState("");
  const [started, setStarted] = useState<DeviceStart | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!started) return;
    let stop = false;
    const deadline = Date.now() + started.expiresIn * 1000;
    (async () => {
      while (!stop) {
        await new Promise((r) => setTimeout(r, Math.max(1, started.interval) * 1000));
        if (stop) return;
        // Approved in another tab of this browser: that tab signed us in.
        if (await store.credentials()) return onSignedIn("You're signed in.");
        const poll = await api.pollDeviceLogin(started.deviceCode);
        if (!poll.ok) continue; // offline for a moment: keep trying
        if (poll.value.status === "done") {
          await adoptTokens(store, api, poll.value.tokens);
          return onSignedIn("You're signed in. Notes you take anywhere show up here.");
        }
        if (poll.value.status === "failed" || Date.now() > deadline) {
          setStarted(null);
          return setError(poll.value.status === "failed" ? `Sign-in failed: ${poll.value.reason}` : "The sign-in expired. Try again.");
        }
      }
    })();
    return () => {
      stop = true;
    };
  }, [started, api, store, onSignedIn]);

  if (started) {
    return (
      <section class="card">
        <h2>Check your email</h2>
        <p>We sent a link to {email}. Open it and enter this code:</p>
        <p class="code" data-testid="user-code">{started.userCode}</p>
        <p class="muted">Waiting for you to confirm…</p>
      </section>
    );
  }

  return (
    <section class="card">
      <h2>Sync your notes</h2>
      <p class="muted">Notes are saved in this browser. Sign in to have them on your other devices too.</p>
      <form
        class="row"
        onSubmit={async (e) => {
          e.preventDefault();
          setError(null);
          const r = await api.startDeviceLogin(email.trim());
          if (r.ok) setStarted(r.value);
          else setError(describe(r.error));
        }}
      >
        <input
          type="email"
          required
          aria-label="Email"
          placeholder="you@example.com"
          autocomplete="email"
          value={email}
          onInput={(e) => setEmail((e.target as HTMLInputElement).value)}
        />
        <button type="submit">Sign in</button>
      </form>
      {error && <p class="error">{error}</p>}
    </section>
  );
}

type LinkState = { kind: "loading" } | { kind: "ready"; email: string } | { kind: "unusable"; reason: string } | { kind: "error"; message: string };

/**
 * The page an emailed sign-in link opens. Typing the code the device shows
 * approves that device and (unless unticked) signs this browser in too
 * (docs/records/2026-11-06-sign-in-through-the-pwa.md). Opening the page
 * approves nothing.
 */
function DeviceApproval({
  token,
  api,
  store,
  current,
  onSignedIn,
  onHome,
}: {
  token: string;
  api: Api;
  store: Store;
  current: Credentials | undefined;
  onSignedIn: (message: string) => void;
  onHome: () => void;
}) {
  const [link, setLink] = useState<LinkState>({ kind: "loading" });
  const [code, setCode] = useState("");
  const [signInHere, setSignInHere] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [approvedOnly, setApprovedOnly] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!token) return setLink({ kind: "unusable", reason: "expired" });
    api.deviceLink(token).then((r) => {
      if (!r.ok) setLink({ kind: "error", message: describe(r.error) });
      else if ("email" in r.value) setLink({ kind: "ready", email: r.value.email });
      else setLink({ kind: "unusable", reason: r.value.unusable });
    });
  }, [api, token]);

  if (approvedOnly) {
    return (
      <section class="card">
        <h1>Approved</h1>
        <p>Return to your terminal (or the device you're signing in); it's signed in now.</p>
        <button class="link" onClick={onHome}>
          Open qot in this browser
        </button>
      </section>
    );
  }
  if (link.kind === "loading") return <p class="muted">Checking your link…</p>;
  if (link.kind === "error") return <p class="error">Couldn't check the link: {link.message}</p>;
  if (link.kind === "unusable") {
    return (
      <section class="card">
        <h1>{link.reason === "approved" || link.reason === "consumed" ? "This link was already used" : "This link has expired"}</h1>
        <p>Sign-in links work once and for 15 minutes. Start again from your device.</p>
      </section>
    );
  }

  const choice = browserChoice(current, link.email, api.base);
  const checked = signInHere ?? choice.checked;

  const submit = async (e: Event) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const r = await api.approve(token, code, checked);
    setBusy(false);
    if (!r.ok) return setError(describe(r.error));
    const a = r.value;
    if (a.status === "mismatch") return setError("That code doesn't match. Check your terminal and try again.");
    if (a.status === "unusable") return setLink({ kind: "unusable", reason: a.reason });
    if (a.status === "approved") {
      if (choice.kind === "already") return onSignedIn("Approved. Return to your terminal; this browser was already signed in.");
      return setApprovedOnly(true);
    }
    await adoptTokens(store, api, a.tokens);
    onSignedIn("You're signed in. Return to your terminal; this browser is signed in too.");
  };

  return (
    <section class="card">
      <h1>Sign in to Quantum of Thought</h1>
      <p>
        Enter the code shown in your terminal (or on the device you are signing in) to sign in as{" "}
        <strong>{link.email}</strong>.
      </p>
      <form onSubmit={submit}>
        <input
          class="code-input"
          aria-label="Code"
          placeholder="XXXX-XXXX"
          autocomplete="one-time-code"
          autocapitalize="characters"
          spellcheck={false}
          autofocus
          required
          value={code}
          onInput={(e) => setCode((e.target as HTMLInputElement).value)}
        />
        {choice.kind === "already" ? (
          <p class="muted">This browser is already signed in as {link.email}.</p>
        ) : (
          <label class="check">
            <input type="checkbox" checked={checked} onChange={(e) => setSignInHere((e.target as HTMLInputElement).checked)} />
            {choice.kind === "switch"
              ? ` Also switch this browser from ${choice.from} to ${link.email}`
              : " Also sign in this browser"}
          </label>
        )}
        {error && <p class="error">{error}</p>}
        <button type="submit" disabled={busy}>
          Sign in
        </button>
      </form>
      <p class="muted">If you didn't just try to sign in, close this page.</p>
    </section>
  );
}
