# Attachments in notes, and voice memos first

Status: decided
Date: 2026-11-19
Question: How do notes hold media (audio first, then images and video): where
the bytes live, how they sync and get deleted, where speech is turned into
text, and what end-to-end encryption has to allow?

## Answer

**qot does not launch without voice memos that sync.** The scenario that has
to work: out on a walk, one gesture in Control Center records a memo; the
phone goes back in the pocket and the app is never opened; at home the PWA
shows the note with both the recording and its text; deleting it there removes
both from the phone.

1. **One note, with attachments.** A voice memo is one note: the transcript is
   the note's `content`, the recording is an attachment. Not two linked notes.
2. **Bytes live outside the note**, as opaque blobs the server stores per
   user. The note holds only a reference.
3. **Blobs are in Postgres for now**, reached only through the server's own
   API, so moving them to a bucket later is a server-side change. Video is
   the trigger to move.
4. **Blob deletion rides on the sync push**, in the same transaction as the
   change that removed the attachment or deleted the note.
5. **Speech becomes text on the device that recorded it** (iPhone first). The
   server never hears a memo recorded there.
6. **The plumbing is for every kind of attachment; only audio ships now.** A
   client that meets a kind it doesn't know shows a placeholder and leaves it
   intact.
7. **End-to-end encryption (#72) comes after this, and must be built on a
   keypair per account**, so that parties that can't read an account (a
   capture-only device, an opt-in server pipeline) can still write to it.

Follow-ups are issues: #78 tracks audio and lists the build steps; #79
(images) and #80 (video) reuse this base; #72 is encryption.

## The note model

A note gains `attachments`: an Automerge map keyed by attachment id, so two
devices adding attachments merge, and removing one is deleting its key.

| Field | What |
|---|---|
| key | The attachment's id, a UUIDv7 made by the capturing client. Also the blob's id on the server. |
| `kind` | `audio` now; `image`, `video` later. |
| `media_type` | e.g. `audio/mp4`. |
| `size` | Bytes. |
| `duration_ms` | Audio and video. |
| `text` | `pending` while the attachment's text (a transcript) hasn't been written into the note, else `done`. Absent when no text is expected. |

Rules, all in `qot_core` so every client inherits them:

- **An attachment belongs to exactly one note**, and a blob to one
  attachment. No content addressing and no sharing, so there is no reference
  counting: when the attachment goes, the blob goes.
- **A note may have attachments and no text.** The "an empty note is
  discarded" rules (iOS editor, PWA editor, `qot edit`) become "a note with no
  text and no attachments". Its title is then the attachment's, e.g. `Voice
  memo 0:42`.
- **Unknown kinds are kept.** A client lists them as a placeholder
  (`[image, 2 MB]`) and never drops them when it edits the note. Older builds
  will still be installed when images ship, so this rule has to be in the
  first release that knows about attachments.
- **Deleting each modality on its own** needs no splitting into two notes:
  removing the audio is an edit that removes the attachment (the note is then
  an ordinary text note); removing the text is clearing `content`; deleting
  the note is the existing tombstone and takes both.

Clearing text hides it, but Automerge keeps earlier text in the note's
history, which the server holds. That is already true of every text edit, and
encryption is what closes it. Deleted blob bytes are really gone.

### Where the transcript goes

Into `content`, as ordinary text: it is searchable, editable and shown by
every client, including ones that can't play audio. The recording device
writes the transcript in the same commit that creates the note when it has it
by then, else marks the attachment `text: pending` and fills it in later (a
failed or interrupted transcription retries from the local file).

Filling in is "if `text` is `pending`: insert the transcript and set `done`,
in one commit". Two parties filling the same attachment at the same moment
would both insert, and the note would show the text twice. In this design
only the recording device fills in, so it can't happen yet. It becomes
possible when a second transcriber exists (a server pipeline, or another
device transcribing a PWA recording); that work decides who is allowed to
fill, and is where to solve it.

## The server

A `Qot.Blobs` context and a `blobs` table: `id`, `user_id` (deleted with the
user), `note_id`, `byte_size`, `data` (`bytea`), `deleted_at`. The server
never inspects the bytes and stores no media type: what a blob is lives in
the note, which the server doesn't read.

- `PUT /api/blobs/:id?note_id=…`, body the raw bytes. Idempotent: the same id
  again changes nothing. 413 over the size limit, 403 `quota_exceeded`, 410
  for an id that was deleted.
- `GET /api/blobs/:id` returns the bytes as `application/octet-stream`; 404
  when it isn't there (not uploaded yet, or another account's).
- `POST /api/sync/push` gains an optional `deleted_blobs: [id]`. The server
  appends the changes and deletes those blobs in one transaction. Deleting
  twice, or deleting an id never uploaded, is fine.
- **A deleted blob leaves its row** (bytes removed, `deleted_at` set), so an
  upload that arrives late, from a phone that was offline when another device
  deleted the note, is refused instead of storing bytes nothing points to.
- Deleting the account deletes its blobs with it.
- **Limits**: 25 MB per blob and 1 GB per account while dogfooding. Both are
  configuration, and both are checked on upload. A recorder stops at 30
  minutes (about 14 MB of speech at 64 kbps).

### Why Postgres, for now

A voice memo is about half a megabyte a minute; images are a few megabytes.
Postgres holds those without trouble, and for one developer it is the least
to maintain:

- nothing new to host, no credentials, no S3 client;
- a blob is deleted in the same transaction as the change that drops it, and
  with its account, so nothing is orphaned and no sweeper is needed;
- tests use the existing database sandbox.

What it is bad at is large files: a `bytea` is read whole into memory, there
are no range requests, and the database and its backups grow. That is video.
Clients only ever use `/api/blobs`, so moving the bytes to a bucket (Railway
has S3-compatible ones) is a server change plus a one-time copy. Do it when
video (#80) starts or the table passes a few gigabytes, whichever is first.

Railway's buckets were not tried for this record; the choice is about the
number of parts on the path a launch depends on, not a finding against them.

## Client sync

`qot_core::sync` stays the one place for the rules, with new cases in the
shared test vectors. Bytes on a device live beside the notes
(`blobs/<attachment id>`).

- **The note goes up first, the bytes after.** Text reaches other devices
  quickly; a blob is uploaded only once the change that added its attachment
  has been pushed. `SyncState` records which blobs were uploaded.
- **Before uploading, check the note**: if it is deleted or no longer has
  that attachment, drop the local file instead.
- **`plan_push` also returns the blobs to delete**: attachments the note had
  at the heads last pushed and doesn't have now (removed, or the note is a
  tombstone). They go in the same push, so a failed push retries them with
  it.
- **Other devices are told nothing.** After any pull, a client removes local
  blob files that no live note refers to. A recording in progress is written
  elsewhere and moved into `blobs/` in the same locked step that saves its
  note, so it is never swept.
- **Downloads are lazy.** A client fetches a blob when the note is opened or
  played, not during sync. If the bytes aren't on the server yet it says so
  ("audio on its way") and tries again next time. No new nudge is needed.

## Each client

| Client | Records | Plays | Otherwise |
|---|---|---|---|
| iPhone | Yes: Control Center, the Action button, Siri, in the app | Yes | Transcribes on the device |
| PWA | Later | Yes | Remove audio, delete |
| CLI | No | No | Lists `[audio 0:42]` with the text; `qot export` writes the files |
| Watch | Later (hands off to the phone, as text does) | No | |

Format: AAC in an `.m4a` (`audio/mp4`), mono, about 64 kbps. Every browser
and Apple device plays it.

On the iPhone, the memo is a different gesture from dictation and makes a
different promise. In-app dictation (`Dictation.swift`) still keeps no audio.
A voice memo keeps the recording and syncs it; choosing that control is the
person's choice to keep audio, and the privacy policy, the website's iPhone
page and support say so when it ships.

Not verified, and the first thing to prototype on a real phone: that a
Control Center control can start recording without opening the app
(`AudioRecordingIntent`, which the docs show needs a Live Activity while it
records), and that a background `URLSession` upload finishes after the app is
suspended. On-device transcription of live audio and of files
(`SpeechAnalyzer`, `SpeechTranscriber`, iOS 26) is in Apple's documentation;
the app already targets iOS 26.

## Encryption

Features come before end-to-end encryption, but nothing here may make it
harder:

- **The server treats blobs as opaque**, as it does change blobs. Encryption
  is then the client encrypting before upload and decrypting after download,
  with no server change.
- **Until #72 ships the server could read stored audio**, as it could note
  text. The privacy policy has to say so when audio ships.
- **Server-side transcription is not ruled out by encryption.** A client that
  can't transcribe (the PWA, or a future push-to-talk device with one button)
  may send a recording to the server to be transcribed. The server hears that
  memo once, encrypts the audio and the transcript to the account, and keeps
  nothing readable. This is the explicit opt-in CLAUDE.md already requires of
  anything where the server reads content; the default, a device that
  transcribes for itself, is untouched.
- **So #72 needs a keypair per account, not only a shared secret.** With a
  public key, a party can write to an account without being able to read it:
  the server's pipeline, and a capture-only device that holds nothing worth
  stealing. A symmetric-only design would put the key to everything on every
  device.

## Options considered

- **Transcribe on the server for everyone.** Simple for clients, but the
  server hears every memo, which ends the "server never reads content"
  default. Kept only as the opt-in above.
- **A third-party speech API called from the phone.** The audio goes to
  another company, costs per minute, and needs a key shipped in a client.
- **Transcript only, audio thrown away.** Needs no attachments at all, and
  was the first proposal. Rejected: seeing and hearing the original on
  another device is the feature.
- **Audio and text as two linked notes.** Twice the ids and deletes, and
  links that can drift. One note with an optional attachment gives the same
  independent deletion.
- **Content-addressed blobs** (by hash, as #77 first suggested). Saves
  storing the same bytes twice, which voice memos never are, and costs
  reference counting on delete.
- **The bytes inside the Automerge document.** Everything in a note is kept
  in its history forever and is sent to every device on sync.
- **A bucket from the start.** Right for video; for audio it adds a service,
  credentials, a fake for tests and deletes that aren't transactional.
- **Images and video in the same piece of work.** The plumbing is shared and
  is built for all of them; capture and display are not (camera and picker, a
  share extension, thumbnails, browser formats, streaming, resumable uploads),
  and each is its own issue.

## Sources

- Apple, Speech framework (`SpeechAnalyzer`, `SpeechTranscriber`,
  `AssetInputSequenceProvider`; iOS 26), read in Xcode's documentation on
  2026-11-17.
- Apple, App Intents (`AudioRecordingIntent`), same. Its background behaviour
  was not tested.
- Blob sizes are arithmetic from the bitrate, not measurements.
