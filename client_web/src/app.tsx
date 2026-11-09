import { useCallback, useEffect, useRef, useState } from "preact/hooks";
import { type Api, type ApiError, describe, type DeviceStart } from "./api";
import { appleAvailable, appleErrorText, appleSignIn, prepareApple, type PreparedApple } from "./apple";
import type { Note } from "./core/qot_wasm";
import { connectLive } from "./live";
import { deleteLocal, discardIfEmpty, saveEdit, saveNew } from "./local";
import { age, type Edit, filterNotes, liveNotes, parseNotes } from "./notes";
import type { Result } from "./result";
import { adoptTokens, browserChoice, confirmsAccount, deleteAccount, signOut } from "./session";
import type { Credentials, Store } from "./store";
import { sync, syncErrorText, type SyncError } from "./sync";

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

  const go = (to: string, state: unknown = null) => {
    history.pushState(state, "", to);
    setPath(location.pathname);
  };

  // A note is open at /notes/<id>, one history entry above the list: opened
  // from the list it pushes one (switching notes side by side replaces it),
  // so "back" pops to the list; opened from a link or a reload, back
  // replaces the entry with the list instead.
  const openId = path.startsWith("/notes/") ? decodeURIComponent(path.slice("/notes/".length)) : null;
  const openNote = (id: string) => {
    const to = `/notes/${encodeURIComponent(id)}`;
    if (openId) {
      history.replaceState(history.state, "", to);
      setPath(location.pathname);
    } else go(to, { fromList: true });
  };
  const closeNote = () => {
    if ((history.state as { fromList?: boolean } | null)?.fromList) history.back();
    else {
      history.replaceState(null, "", "/");
      setPath("/");
    }
  };

  // Local changes save first, then tell other tabs and sync in the background.
  const afterChange = () => {
    changed();
    runSync();
  };

  const onCapture = async (text: string) => {
    const saved = await saveNew(store, text);
    if (!saved.ok) return setLoadError(`not saved: ${saved.error}`);
    if (saved.value) afterChange();
  };

  const onDelete = async (id: string) => {
    if (id === openId) closeNote();
    const result = await deleteLocal(store, id);
    if (!result.ok) setLoadError(`not deleted: ${result.error}`);
    afterChange();
  };

  const onSaveEdit = async (base: Note, text: string) => {
    const result = await saveEdit(store, base, text);
    if (result.ok && result.value) afterChange();
    return result;
  };

  const onLeaveNote = async (id: string) => {
    const discarded = await discardIfEmpty(store, id);
    if (discarded.ok && discarded.value) afterChange();
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

  const onAccountDeleted = async () => {
    setStatus({ kind: "idle" });
    setBanner("Account deleted. Your notes stay in this browser.");
    await changed();
    go("/");
  };

  if (path === "/auth/device") {
    const token = new URLSearchParams(location.search).get("token") ?? "";
    return (
      <Shell onNavigate={go}>
        <DeviceApproval token={token} api={api} store={store} current={creds} onSignedIn={onSignedIn} onHome={() => go("/")} />
      </Shell>
    );
  }

  const header = (
    <HeaderAccount creds={creds} status={status} onSignOut={onSignOut} onNavigate={go} />
  );
  const notices = (
    <>
      {banner && (
        <p class="banner" role="status">
          {banner}
          <button class="link" onClick={() => setBanner(null)} aria-label="Dismiss">
            ×
          </button>
        </p>
      )}
      {loadError && <p class="error">{loadError}</p>}
    </>
  );

  if (path === "/sign-in") {
    return (
      <Shell onNavigate={go}>
        {creds ? (
          <section class="page">
            <p>You're signed in as {creds.email}.</p>
            <Link to="/" onNavigate={go}>‹ Notes</Link>
          </section>
        ) : (
          <SignIn api={api} store={store} onSignedIn={onSignedIn} onNavigate={go} />
        )}
      </Shell>
    );
  }

  if (path === "/settings") {
    return (
      <Shell right={header} onNavigate={go}>
        {notices}
        <Settings
          creds={creds}
          status={status}
          onSync={() => runSync()}
          onSignOut={onSignOut}
          deleting={(typed) => deleteAccount(store, api, typed)}
          onDeleted={onAccountDeleted}
          onNavigate={go}
        />
      </Shell>
    );
  }

  const open = openId && notes ? notes.find((n) => n.id === openId) : undefined;

  return (
    <Shell wide right={header} onNavigate={go}>
      {notices}
      <div class={`panes${openId ? " editing" : ""}`}>
        <div class="list-pane">
          <Capture onCapture={onCapture} />
          {notes === null ? null : <NoteList notes={notes} openId={openId} onOpen={openNote} onDelete={onDelete} />}
        </div>
        <section class="editor-pane" aria-label="Note">
          {!openId ? (
            <p class="muted placeholder">Choose a note to read or edit it.</p>
          ) : notes === null ? null : open && !open.isDeleted ? (
            <Editor
              key={openId}
              note={open}
              save={onSaveEdit}
              onLeave={() => onLeaveNote(openId)}
              onBack={closeNote}
              onDelete={() => onDelete(openId)}
            />
          ) : (
            <div class="gone">
              <BackButton onBack={closeNote} />
              <p class="muted">This note was deleted.</p>
            </div>
          )}
        </section>
      </div>
    </Shell>
  );
}

/** An in-app link: a real link (new tab works), routed without a reload. */
function Link({
  to,
  onNavigate,
  class: className,
  children,
}: {
  to: string;
  onNavigate: (to: string) => void;
  class?: string;
  children: preact.ComponentChildren;
}) {
  return (
    <a
      class={className}
      href={to}
      onClick={(e) => {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
        e.preventDefault();
        onNavigate(to);
      }}
    >
      {children}
    </a>
  );
}

function Shell({
  children,
  right,
  wide,
  onNavigate,
}: {
  children: preact.ComponentChildren;
  right?: preact.ComponentChildren;
  wide?: boolean;
  onNavigate: (to: string) => void;
}) {
  return (
    <>
      <header class="topbar">
        <div class={`topbar-inner${wide ? " wide" : ""}`}>
          <Link class="brand" to="/" onNavigate={onNavigate}>
            <img src="/icon.svg" alt="" width="28" height="28" />
            <span>Quantum of Thought</span>
          </Link>
          {right}
        </div>
      </header>
      <main class={wide ? "wide" : undefined}>{children}</main>
    </>
  );
}

function syncLabel(status: SyncStatus): [label: string, detail: string] {
  switch (status.kind) {
    case "syncing":
      return ["Syncing…", ""];
    case "error":
      return [status.error.kind === "offline" ? "Offline" : "Not synced", syncErrorText(status.error)];
    case "synced":
      return ["Synced", ""];
    case "idle":
      return ["", ""];
  }
}

/**
 * The header's right side: "Sign in" when signed out; when signed in, the
 * sync status and a menu under the account's initial.
 */
function HeaderAccount({
  creds,
  status,
  onSignOut,
  onNavigate,
}: {
  creds: Credentials | undefined;
  status: SyncStatus;
  onSignOut: () => void;
  onNavigate: (to: string) => void;
}) {
  const menu = useRef<HTMLDetailsElement>(null);
  const close = () => menu.current?.removeAttribute("open");
  // Clicking anywhere else closes the menu.
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      if (menu.current && !menu.current.contains(e.target as Node)) close();
    };
    document.addEventListener("click", onClick);
    return () => document.removeEventListener("click", onClick);
  }, []);

  if (!creds)
    return (
      <Link class="button primary" to="/sign-in" onNavigate={onNavigate}>
        Sign in
      </Link>
    );
  const [label, detail] = syncLabel(status);
  return (
    <div class="account">
      <span class={`sync sync-${status.kind}`} title={detail} data-testid="sync-status">
        {label}
      </span>
      <details ref={menu}>
        <summary aria-label="Account" class="avatar">
          {(creds.email.trim()[0] ?? "?").toUpperCase()}
        </summary>
        <div class="menu" role="menu">
          <p class="menu-email">{creds.email}</p>
          {detail && <p class="muted">{detail}</p>}
          <Link
            class="menu-item"
            to="/settings"
            onNavigate={(to) => {
              close();
              onNavigate(to);
            }}
          >
            Settings
          </Link>
          <button
            class="menu-item"
            onClick={() => {
              close();
              onSignOut();
            }}
          >
            Sign out
          </button>
        </div>
      </details>
    </div>
  );
}

/** The account: sync, sign out, delete. Signed out, a way to sign in. */
function Settings({
  creds,
  status,
  onSync,
  onSignOut,
  deleting,
  onDeleted,
  onNavigate,
}: {
  creds: Credentials | undefined;
  status: SyncStatus;
  onSync: () => void;
  onSignOut: () => void;
  deleting: (typed: string) => Promise<{ ok: true } | { ok: false; error: ApiError }>;
  onDeleted: () => void;
  onNavigate: (to: string) => void;
}) {
  const [confirming, setConfirming] = useState(false);
  const [label, detail] = syncLabel(status);
  return (
    <section class="page">
      <Link class="back" to="/" onNavigate={onNavigate}>
        ‹ Notes
      </Link>
      <h1>Settings</h1>
      <h2>Account</h2>
      {!creds ? (
        <>
          <p class="muted">Notes are saved in this browser. Sign in to sync them.</p>
          <Link class="button primary" to="/sign-in" onNavigate={onNavigate}>
            Sign in
          </Link>
        </>
      ) : (
        <>
          <p>{creds.email}</p>
          <p class="muted">
            {detail || label || "Not synced yet"}
          </p>
          <div class="actions">
            <button onClick={onSync} disabled={status.kind === "syncing"}>
              Sync now
            </button>
            <button onClick={onSignOut}>Sign out of this browser</button>
          </div>
          <p class="muted">Signing out keeps your notes in this browser.</p>
          <h2>Delete account</h2>
          {confirming ? (
            <DeleteAccount email={creds.email} deleting={deleting} onDeleted={onDeleted} onCancel={() => setConfirming(false)} />
          ) : (
            <button class="danger" onClick={() => setConfirming(true)}>
              Delete account…
            </button>
          )}
        </>
      )}
    </section>
  );
}

/** Like `qot delete-account`: the email typed again confirms it. */
function DeleteAccount({
  email,
  deleting,
  onDeleted,
  onCancel,
}: {
  email: string;
  deleting: (typed: string) => Promise<{ ok: true } | { ok: false; error: ApiError }>;
  onDeleted: () => void;
  onCancel: () => void;
}) {
  const [typed, setTyped] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async (e: Event) => {
    e.preventDefault();
    if (!confirmsAccount(typed, email)) return;
    setBusy(true);
    setError(null);
    const result = await deleting(typed);
    setBusy(false);
    if (result.ok) onDeleted();
    else setError(deleteErrorText(result.error));
  };
  return (
    <form class="delete-account" onSubmit={submit}>
      <p>
        This deletes the account and every note synced to it from the server. Everywhere else you're signed in is
        signed out within the hour. Notes in this browser stay.
      </p>
      <label>
        Type {email} to confirm
        <input type="email" value={typed} autocomplete="off" onInput={(e) => setTyped((e.target as HTMLInputElement).value)} />
      </label>
      {error && <p class="error">{error}</p>}
      <div class="actions">
        <button type="submit" class="danger" disabled={busy || !confirmsAccount(typed, email)}>
          {busy ? "Deleting…" : "Delete account"}
        </button>
        <button type="button" class="link" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}

function deleteErrorText(e: ApiError): string {
  if (e.kind === "offline") return "Not deleted: you're offline.";
  if (e.kind === "unauthorized") return "Not deleted: this browser is signed out. Sign in again first.";
  if (e.kind === "failed" && e.error === "confirmation_mismatch") return "Not deleted: that isn't this account's email.";
  return `Not deleted: ${describe(e)}.`;
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
        placeholder="New note (Enter saves)"
        value={text}
        rows={1}
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

/** The time now, refreshed every 30 s, for "5 min ago". */
function useNow(): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);
  return now;
}

function NoteList({
  notes,
  openId,
  onOpen,
  onDelete,
}: {
  notes: Note[];
  openId: string | null;
  onOpen: (id: string) => void;
  onDelete: (id: string) => void;
}) {
  const live = liveNotes(notes);
  const [query, setQuery] = useState("");
  const now = useNow();
  if (live.length === 0) return <p class="muted empty">No notes yet. Type one above.</p>;
  const shown = filterNotes(live, query);
  return (
    <>
      <input
        class="search"
        type="search"
        aria-label="Search notes"
        placeholder="Search"
        value={query}
        onInput={(e) => setQuery((e.target as HTMLInputElement).value)}
      />
      {shown.length === 0 && <p class="muted empty">No notes match “{query.trim()}”.</p>}
      <ul class="notes" aria-label="Notes">
        {shown.map((n) => (
          <li key={n.id}>
            <a
              class="open"
              href={`/notes/${encodeURIComponent(n.id)}`}
              aria-current={n.id === openId ? "true" : undefined}
              onClick={(e) => {
                // Let modified clicks open a new tab as links do.
                if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
                e.preventDefault();
                onOpen(n.id);
              }}
            >
              <span class="title">{n.title}</span>
              <span class="sub">
                <span class="when">{age(n.updatedAtMs, now)}</span>
                {n.preview && <span class="preview">{n.preview}</span>}
              </span>
            </a>
            <button class="delete" aria-label={`Delete “${n.title}”`} onClick={() => onDelete(n.id)}>
              ×
            </button>
          </li>
        ))}
      </ul>
    </>
  );
}

function BackButton({ onBack }: { onBack: () => void }) {
  return (
    <button class="link back" onClick={onBack}>
      ‹ Notes
    </button>
  );
}

const SAVE_DELAY_MS = 500;

/**
 * One note, edited in place. Typing saves after a pause (and on blur, on
 * leaving, and when the page is hidden) through `save`, which merges the edit
 * into the stored note, so nothing waits on a button.
 *
 * `note` is the stored note, new on every reload (a sync, another tab, our
 * own save). The text typed here is always relative to `base`, the version it
 * was typed over. When the text has no unsaved typing (no save pending or
 * running and it equals `base`), the editor shows the stored note; while
 * there is, it keeps the typing, and the next save merges the two (see
 * `applyEdit`), after which it catches up. So a change from elsewhere never
 * clobbers typing, and typing never undoes it.
 *
 * Leaving the note (back, opening another, closing it) saves, then deletes
 * it if it has no text, the way Apple Notes discards empty notes
 * (`discardIfEmpty`). Closing the page only saves: a reload reopens the note.
 */
function Editor({
  note,
  save,
  onLeave,
  onBack,
  onDelete,
}: {
  note: Note;
  save: (base: Note, text: string) => Promise<Result<Edit | null>>;
  onLeave: () => void;
  onBack: () => void;
  onDelete: () => void;
}) {
  const [text, setText] = useState(note.content);
  const [error, setError] = useState<string | null>(null);
  const textRef = useRef(note.content);
  const base = useRef(note);
  const latest = useRef(note);
  latest.current = note;
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const saves = useRef<Promise<void>>(Promise.resolve());
  const running = useRef(0);
  const area = useRef<HTMLTextAreaElement>(null);
  const now = useNow();

  const catchUp = () => {
    if (timer.current !== null || running.current > 0 || textRef.current !== base.current.content) return;
    base.current = latest.current;
    if (latest.current.content !== textRef.current) {
      textRef.current = latest.current.content;
      setText(textRef.current);
    }
  };

  // Saves run one after another, each over the base the last one returned.
  const flush = () => {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
    running.current++;
    saves.current = saves.current
      .then(async () => {
        const result = await save(base.current, textRef.current);
        if (!result.ok) return setError(`Not saved: ${result.error}`);
        if (result.value) base.current = result.value.base;
        setError(null);
      })
      .finally(() => {
        running.current--;
        catchUp();
      });
    return saves.current;
  };

  useEffect(catchUp, [note]);

  useEffect(() => {
    // Typing straight away with a keyboard; on touch screens the keyboard
    // would cover the note, so it waits for a tap.
    const el = area.current;
    if (el && matchMedia("(pointer: fine)").matches) {
      el.focus();
      el.setSelectionRange(el.value.length, el.value.length);
    }
    const onHide = () => {
      if (timer.current !== null || textRef.current !== base.current.content) flush();
    };
    const onVisibility = () => document.visibilityState === "hidden" && onHide();
    addEventListener("pagehide", onHide);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      removeEventListener("pagehide", onHide);
      document.removeEventListener("visibilitychange", onVisibility);
      flush().then(onLeave);
    };
  }, []);

  return (
    <div class="editor-view">
      <div class="editor-bar">
        <BackButton onBack={onBack} />
        <span class="muted when">Edited {age(note.updatedAtMs, now)}</span>
        <button class="link danger" onClick={onDelete}>
          Delete
        </button>
      </div>
      {error && <p class="error">{error}</p>}
      <textarea
        ref={area}
        class="editor"
        aria-label="Edit note"
        value={text}
        onInput={(e) => {
          textRef.current = (e.target as HTMLTextAreaElement).value;
          setText(textRef.current);
          if (timer.current !== null) clearTimeout(timer.current);
          timer.current = setTimeout(flush, SAVE_DELAY_MS);
        }}
        onBlur={() => timer.current !== null && flush()}
        onKeyDown={(e) => {
          if (e.key === "Escape") onBack();
        }}
      />
    </div>
  );
}

/**
 * The sign-in page: Sign in with Apple where Apple allows it, else (or
 * also) the same emailed device sign-in as the CLI.
 */
function SignIn({
  api,
  store,
  onSignedIn,
  onNavigate,
}: {
  api: Api;
  store: Store;
  onSignedIn: (message: string) => void;
  onNavigate: (to: string) => void;
}) {
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
          return onSignedIn("You're signed in.");
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
      <section class="card narrow">
        <h1>Check your email</h1>
        <p>We sent a link to {email}. Open it and enter this code:</p>
        <p class="code" data-testid="user-code">{started.userCode}</p>
        <p class="muted">Waiting for you to confirm…</p>
      </section>
    );
  }

  return (
    <section class="card narrow">
      <h1>Sign in</h1>
      <p class="muted">Sign in to sync your notes. Notes already in this browser stay.</p>
      {appleAvailable(location.origin) && (
        <>
          <AppleButton api={api} store={store} onSignedIn={onSignedIn} onError={setError} />
          <p class="or">or</p>
        </>
      )}
      <form
        class="stack"
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
        <button type="submit">Email me a sign-in link</button>
      </form>
      {error && <p class="error">{error}</p>}
      <p>
        <Link class="back" to="/" onNavigate={onNavigate}>
          ‹ Back to notes
        </Link>
      </p>
    </section>
  );
}

/**
 * Sign in with Apple (#87). Apple's SDK is loaded and given a nonce before
 * the click, so the click opens Apple's window with nothing awaited first.
 */
function AppleButton({
  api,
  store,
  onSignedIn,
  onError,
}: {
  api: Api;
  store: Store;
  onSignedIn: (message: string) => void;
  onError: (message: string | null) => void;
}) {
  const [prepared, setPrepared] = useState<PreparedApple | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let live = true;
    setPrepared(null);
    prepareApple(location.origin).then(
      (p) => live && setPrepared(p),
      () => live && onError("Sign in with Apple couldn't load. Sign in with your email instead."),
    );
    return () => {
      live = false;
    };
  }, [attempt, onError]);

  return (
    <button
      type="button"
      class="apple"
      disabled={!prepared || busy}
      onClick={async () => {
        if (!prepared) return;
        onError(null);
        setBusy(true);
        try {
          const credential = await appleSignIn(prepared);
          if (!credential.ok) {
            if (credential.error !== "cancelled") onError(`Sign in with Apple failed: ${credential.error}`);
            return;
          }
          const { identityToken, nonce, authorizationCode } = credential.value;
          const tokens = await api.signInWithApple(identityToken, nonce, authorizationCode);
          if (!tokens.ok) return onError(appleErrorText(tokens.error));
          await adoptTokens(store, api, tokens.value);
          onSignedIn("You're signed in.");
        } finally {
          setBusy(false);
          setAttempt((n) => n + 1); // a nonce is used once
        }
      }}
    >
      <svg aria-hidden="true" viewBox="0 0 814 1000" width="14" height="17">
        <path
          fill="currentColor"
          d="M788 341c-6 4-108 62-108 190 0 149 131 201 135 203-1 3-21 72-69 142-43 62-88 124-156 124s-86-40-164-40c-77 0-104 41-166 41s-106-57-156-127C46 792 0 667 0 548c0-191 124-292 247-292 65 0 119 43 160 43 39 0 100-45 174-45 28 0 129 2 196 87zM554 159c31-37 53-88 53-139 0-7-1-14-2-20-50 2-110 34-146 76-28 32-55 83-55 135 0 8 1 16 2 18 3 1 9 2 14 2 45 0 102-30 134-72z"
        />
      </svg>
      Sign in with Apple
    </button>
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
        <p>The device you're signing in is signed in now. You can close this page.</p>
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
    if (a.status === "mismatch") return setError("That code doesn't match. Check the code on the device you're signing in and try again.");
    if (a.status === "unusable") return setLink({ kind: "unusable", reason: a.reason });
    if (a.status === "approved") {
      if (choice.kind === "already") return onSignedIn("Approved. The device you're signing in is signed in now; this browser already was.");
      return setApprovedOnly(true);
    }
    await adoptTokens(store, api, a.tokens);
    onSignedIn("Approved. The device you're signing in is signed in now, and so is this browser.");
  };

  return (
    <section class="card">
      <h1>Sign in to Quantum of Thought</h1>
      <p>
        Enter the code shown on the device you're signing in to sign in as{" "}
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
