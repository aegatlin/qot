# Pipelines first: the server may read and edit notes; end-to-end encryption comes second

Status: direction decided (the owner, 2026-11-20); how to build it is proposed and waits for the owner
Date: 2026-11-20
Question: May the server read and change notes, and what does that do to
end-to-end encryption?

## Answer

**Yes. The server becomes a peer that edits notes, and that vision ranks
above end-to-end encryption.** The owner, 2026-11-20: "this dream is
primary and e2e encryption is secondary"; having both is "the best
possible world".

The dream: a person sets up **triggers** that send notes to programs and
paid services, which **add to the note**. A note beginning `#appidea a
game that teaches you plant names` is picked up on the server, sent to a
service that builds it, and gets a link appended when the build is done.
Meanwhile the person (later, a team sharing a space) keeps editing on any
client. Every party edits the same CRDT, so all of it converges. Cloud
transcription of a voice memo is the first and simplest such pipeline.

What this changes:

- "The server never reads note content" (CLAUDE.md, and #72's wording)
  stops being the rule everything else bends to. Until encryption exists
  the server can read everything anyway; what changes is that **something
  we run will now read notes**, which the privacy policy today says
  nothing does. The policy changes before any pipeline runs in production.
- End-to-end encryption is still wanted, as a mode that must be designed
  **around** pipelines, not the other way round (below).
- A pipeline still runs only because the person set it up: nothing reads
  a note on the server unless a trigger of theirs matched it, or their
  plan includes a pipeline they turned on (transcription).

## Proposed shape (for the owner to confirm)

1. **The server runs `qot_core`.** Editing a note means making an
   Automerge change with the same rules every client uses, so the rules
   stay in one place. Two ways:
   - **A Rustler NIF, `core_nif/`** (recommended): a fourth thin binding
     beside `core_ffi/` and `core_wasm/` ("adapts types only; no rules"),
     called from Phoenix, which already holds the change log, the blobs,
     the plan and the nudge channel. Costs: a Rust stage in the server's
     Dockerfile, NIF calls on dirty schedulers. The previous qot had this
     setup.
   - *A separate Rust worker* that signs in like a device and syncs
     through the public API. Cleaner isolation, but a second service to
     deploy, and it needs its own way to see plans, triggers and blobs.
2. **The server writes like any device**: it builds the note from the
   account's change log, applies its edit, and appends the change to the
   same log, with the same per-user seqs and the same nudge. Clients need
   no new code to receive it. The shared sync test vectors gain a replay
   in Elixir.
3. **A pipeline run's state lives in the note**, the way an attachment's
   `text: pending | done` does: a small map at the note's root per run
   (`pipeline:<id>`: which pipeline, `pending | done | failed`). Clients
   can show "working…", a run is done at most once however many servers
   or retries there are, and a pipeline's own output can't trigger it
   again. A database row claims the job so two workers don't both call
   the paid service.
4. **Transcription moves onto this**: the server sees a note with an
   audio attachment whose text is `pending` and whose blob has arrived,
   transcribes it and writes the text in (`fill_text`). Then it works for
   every client with no client code, and with the phone back in the
   pocket. What was built on 2026-11-20 (the provider, the plan gate, the
   allowance) is reused; `POST /api/transcriptions`, where the client
   sends the audio and writes the text itself, stays as the path that
   needs no server reading of stored data.
5. **Triggers** come after: a per-account list of (match, pipeline),
   matched in `qot_core` so every party agrees on what matches; the
   first match is a leading `#tag`. Pipelines that cost money are part
   of the paid plan (#112).

## End-to-end encryption, second

Options for later, none designed (#72):

- **Encryption as a per-account mode that limits pipelines.** An
  encrypted account's server can't read the log, so only client-started
  pipelines work: the capturing client sees the trigger match and sends
  that one note to the pipeline (it is online, it just captured), and
  the server writes its result back encrypted to the account's public
  key, which #72 already asks for ("a party that can't read an account
  can still write to it").
- **The server holds a key the person granted it**, for the notes or
  spaces they chose. Honest name: not end-to-end for those.
- **No end-to-end encryption**, only encryption at rest.

The first keeps both promises where they can both hold and is the one to
aim at, but it is not decided, and it must not slow pipelines down.

## What this supersedes

- CLAUDE.md, "Sync and end-to-end encryption": the default that the
  server never reads note content, and that anything reading notes "must
  not weaken this default".
- `2026-11-20-paid-transcription.md`, answer 1 ("the server doesn't read
  stored blobs"; "the server still never writes notes"): kept as one
  path, no longer the design's centre.
- `2026-11-08-why-not-automerge-swift.md` and the rule that Automerge
  comes through `qot_core` are **unchanged**, and are why the server
  should use the core too.
