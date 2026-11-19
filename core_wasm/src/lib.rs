//! `qot_core` for the browser, through wasm-bindgen.
//!
//! A thin shell, like `qot_ffi`: every rule lives in `qot_core`, and this
//! crate only adapts types to what JavaScript can carry. Notes stay immutable
//! values (each edit returns a new `Note`), and failures are thrown errors,
//! never empty notes.
//!
//! Sync state crosses as the same JSON the CLI writes to `sync.json`, so the
//! PWA can store it as a string. Seqs and cursors are JS numbers: integers
//! below 2^53, which a per-user change log never reaches.
//!
//! The functions that take `Note[]` take ownership of the objects passed in
//! (a wasm-bindgen rule), so callers pass copies (`note.copy()`).

use qot_core::sync as core_sync;
use std::collections::BTreeMap;
use wasm_bindgen::prelude::*;

/// Errors cross as plain messages; the wasm-facing functions turn them into
/// thrown `Error`s. Kept as `String` so the logic is testable off wasm.
type Res<T> = Result<T, String>;

fn throw<T>(r: Res<T>) -> Result<T, JsError> {
    r.map_err(|m| JsError::new(&m))
}

/// Media on a note. The bytes are a blob with the same id, never in the note.
#[wasm_bindgen]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment(qot_core::Attachment);

#[wasm_bindgen]
impl Attachment {
    /// `text` is `none`, `pending` or `done`: whether the attachment's text
    /// (a recording's transcript) is expected, and in the note yet. Throws
    /// on anything else, or a size or duration that isn't a whole number.
    #[wasm_bindgen(constructor)]
    pub fn new(
        id: String,
        kind: String,
        media_type: String,
        size: f64,
        duration_ms: Option<f64>,
        text: &str,
    ) -> Result<Attachment, JsError> {
        throw(Self::make(id, kind, media_type, size, duration_ms, text))
    }

    fn make(
        id: String,
        kind: String,
        media_type: String,
        size: f64,
        duration_ms: Option<f64>,
        text: &str,
    ) -> Res<Attachment> {
        let whole = |n: f64, what: &str| to_seq(n).map_err(|_| format!("bad {what}: {n}"));
        Ok(Attachment(qot_core::Attachment {
            id,
            kind,
            media_type,
            size: whole(size, "size")?,
            duration_ms: duration_ms.map(|d| whole(d, "duration")).transpose()?,
            text: match text {
                "none" => qot_core::AttachmentText::None,
                "pending" => qot_core::AttachmentText::Pending,
                "done" => qot_core::AttachmentText::Done,
                other => return Err(format!("bad attachment text state: {other}")),
            },
        }))
    }

    /// An id for a new attachment (a UUIDv7).
    #[wasm_bindgen(js_name = newId)]
    pub fn new_id() -> String {
        qot_core::Attachment::new_id()
    }

    #[wasm_bindgen(getter)]
    pub fn id(&self) -> String {
        self.0.id.clone()
    }

    /// `audio`; a kind this build doesn't know is still listed and kept.
    #[wasm_bindgen(getter)]
    pub fn kind(&self) -> String {
        self.0.kind.clone()
    }

    #[wasm_bindgen(getter, js_name = mediaType)]
    pub fn media_type(&self) -> String {
        self.0.media_type.clone()
    }

    #[wasm_bindgen(getter)]
    pub fn size(&self) -> f64 {
        self.0.size as f64
    }

    #[wasm_bindgen(getter, js_name = durationMs)]
    pub fn duration_ms(&self) -> Option<f64> {
        self.0.duration_ms.map(|d| d as f64)
    }

    /// `none`, `pending` or `done`.
    #[wasm_bindgen(getter)]
    pub fn text(&self) -> String {
        match self.0.text {
            qot_core::AttachmentText::None => "none",
            qot_core::AttachmentText::Pending => "pending",
            qot_core::AttachmentText::Done => "done",
        }
        .into()
    }

    /// What to show where the attachment can't be: `audio 0:42`.
    #[wasm_bindgen(getter)]
    pub fn label(&self) -> String {
        self.0.label()
    }
}

/// One note. Immutable: every edit returns a new `Note`.
#[wasm_bindgen]
#[derive(Debug, Clone)]
pub struct Note(qot_core::Note);

#[wasm_bindgen]
impl Note {
    #[wasm_bindgen(constructor)]
    pub fn new(content: &str) -> Note {
        Note(qot_core::Note::new(content))
    }

    /// A note saved with `toBytes`. Bytes that aren't a note throw.
    #[wasm_bindgen(js_name = fromBytes)]
    pub fn from_bytes(bytes: &[u8]) -> Result<Note, JsError> {
        throw(Self::parse(bytes))
    }

    fn parse(bytes: &[u8]) -> Res<Note> {
        qot_core::Note::from_bytes(bytes)
            .map(Note)
            .map_err(|e| e.to_string())
    }

    #[wasm_bindgen(getter)]
    pub fn id(&self) -> String {
        self.0.id()
    }

    #[wasm_bindgen(getter)]
    pub fn content(&self) -> String {
        self.0.content()
    }

    #[wasm_bindgen(getter, js_name = isDeleted)]
    pub fn is_deleted(&self) -> bool {
        self.0.is_deleted()
    }

    /// When the note was created, in Unix milliseconds, read from its
    /// UUIDv7 id (0 if the id carries no time).
    #[wasm_bindgen(getter, js_name = createdAtMs)]
    pub fn created_at_ms(&self) -> f64 {
        self.0.created_at_ms().unwrap_or(0) as f64
    }

    /// When the note was last edited, in Unix milliseconds (to the second).
    #[wasm_bindgen(getter, js_name = updatedAtMs)]
    pub fn updated_at_ms(&self) -> f64 {
        self.0.updated_at_ms() as f64
    }

    pub fn update(&self, content: &str) -> Result<Note, JsError> {
        throw(self.0.update(content).map(Note).map_err(|e| e.to_string()))
    }

    /// Marks the note deleted (a tombstone, so the delete syncs).
    pub fn delete(&self) -> Result<Note, JsError> {
        throw(self.0.delete().map(Note).map_err(|e| e.to_string()))
    }

    pub fn merge(&self, other: &Note) -> Result<Note, JsError> {
        throw(self.0.merge(&other.0).map(Note).map_err(|e| e.to_string()))
    }

    /// The whole note as Automerge bytes, for storage.
    #[wasm_bindgen(js_name = toBytes)]
    pub fn to_bytes(&self) -> Vec<u8> {
        self.0.to_bytes()
    }

    pub fn heads(&self) -> Vec<String> {
        self.0.heads()
    }

    /// A second handle to the same note, for passing to functions that take
    /// ownership of their arguments.
    pub fn copy(&self) -> Note {
        self.clone()
    }

    /// A new note that starts with an attachment: a voice memo, whose
    /// content is its transcript (empty if there is none yet).
    #[wasm_bindgen(js_name = withAttachment)]
    pub fn with_attachment(content: &str, attachment: &Attachment) -> Result<Note, JsError> {
        throw(
            qot_core::Note::with_attachment(content, &attachment.0)
                .map(Note)
                .map_err(|e| e.to_string()),
        )
    }

    /// The note's attachments, oldest first.
    pub fn attachments(&self) -> Vec<Attachment> {
        self.0.attachments().into_iter().map(Attachment).collect()
    }

    /// No text and no attachments: nothing to keep.
    #[wasm_bindgen(getter, js_name = isEmpty)]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn attach(&self, attachment: &Attachment) -> Result<Note, JsError> {
        throw(
            self.0
                .attach(&attachment.0)
                .map(Note)
                .map_err(|e| e.to_string()),
        )
    }

    /// Removes an attachment and keeps the text. Sync deletes the blob.
    pub fn detach(&self, id: &str) -> Result<Note, JsError> {
        throw(self.0.detach(id).map(Note).map_err(|e| e.to_string()))
    }

    /// Writes a pending attachment's text into the note and marks it done;
    /// unchanged if it wasn't pending.
    #[wasm_bindgen(js_name = fillText)]
    pub fn fill_text(&self, id: &str, text: &str) -> Result<Note, JsError> {
        throw(
            self.0
                .fill_text(id, text)
                .map(Note)
                .map_err(|e| e.to_string()),
        )
    }
}

/// One note's changes to push. `data` is what goes to the server; hand the
/// whole object back to `markPushed` once the push succeeds.
#[wasm_bindgen]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing(core_sync::Outgoing);

#[wasm_bindgen]
impl Outgoing {
    #[wasm_bindgen(getter, js_name = noteId)]
    pub fn note_id(&self) -> String {
        self.0.note_id.clone()
    }

    #[wasm_bindgen(getter)]
    pub fn data(&self) -> Vec<u8> {
        self.0.data.clone()
    }

    #[wasm_bindgen(getter)]
    pub fn heads(&self) -> Vec<String> {
        self.0.heads.clone()
    }

    /// Blobs for the server to delete with this push.
    #[wasm_bindgen(getter, js_name = deletedBlobs)]
    pub fn deleted_blobs(&self) -> Vec<String> {
        self.0.deleted_blobs.clone()
    }
}

/// A blob to upload.
#[wasm_bindgen]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobUpload(core_sync::BlobUpload);

#[wasm_bindgen]
impl BlobUpload {
    #[wasm_bindgen(getter)]
    pub fn id(&self) -> String {
        self.0.id.clone()
    }

    #[wasm_bindgen(getter, js_name = noteId)]
    pub fn note_id(&self) -> String {
        self.0.note_id.clone()
    }
}

/// What to do with the blobs this device holds.
#[wasm_bindgen]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobPlan(core_sync::BlobPlan);

#[wasm_bindgen]
impl BlobPlan {
    /// Upload these, then `markUploaded`.
    #[wasm_bindgen(getter)]
    pub fn upload(&self) -> Vec<BlobUpload> {
        self.0.upload.iter().cloned().map(BlobUpload).collect()
    }

    /// Delete these, then `forgetBlobs`: no live note refers to them.
    #[wasm_bindgen(getter)]
    pub fn discard(&self) -> Vec<String> {
        self.0.discard.clone()
    }
}

/// One change pulled from the server log.
#[wasm_bindgen]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Incoming(core_sync::Incoming);

#[wasm_bindgen]
impl Incoming {
    /// Throws if `seq` is not a non-negative integer.
    #[wasm_bindgen(constructor)]
    pub fn new(seq: f64, note_id: String, data: Vec<u8>) -> Result<Incoming, JsError> {
        throw(Self::make(seq, note_id, data))
    }

    fn make(seq: f64, note_id: String, data: Vec<u8>) -> Res<Incoming> {
        Ok(Incoming(core_sync::Incoming {
            seq: to_seq(seq)?,
            note_id,
            data,
        }))
    }
}

/// What a pull changed: the notes to save, then the state to save after them.
#[wasm_bindgen]
pub struct Pulled {
    changed: Vec<Note>,
    state: String,
}

#[wasm_bindgen]
impl Pulled {
    #[wasm_bindgen(getter)]
    pub fn changed(&self) -> Vec<Note> {
        self.changed.clone()
    }

    #[wasm_bindgen(getter)]
    pub fn state(&self) -> String {
        self.state.clone()
    }
}

/// A JS number as a seq: a non-negative integer no larger than 2^53.
fn to_seq(n: f64) -> Res<u64> {
    const MAX_SAFE: f64 = 9_007_199_254_740_991.0;
    if n.is_finite() && n >= 0.0 && n.fract() == 0.0 && n <= MAX_SAFE {
        Ok(n as u64)
    } else {
        Err(format!("bad seq: {n}"))
    }
}

fn parse_state(json: &str) -> Res<core_sync::SyncState> {
    serde_json::from_str(json).map_err(|e| format!("bad sync state: {e}"))
}

fn state_json(state: &core_sync::SyncState) -> String {
    serde_json::to_string(state).expect("sync state always serializes")
}

/// The sync state of a device that has never synced.
#[wasm_bindgen(js_name = emptySyncState)]
pub fn empty_sync_state() -> String {
    state_json(&core_sync::SyncState::default())
}

/// The last server seq applied; pull from here. Throws on bad state.
#[wasm_bindgen(js_name = syncCursor)]
pub fn sync_cursor(state: &str) -> Result<f64, JsError> {
    throw(parse_state(state).map(|s| s.cursor as f64))
}

/// The changes to push for every note whose heads moved since last pushed.
#[wasm_bindgen(js_name = planPush)]
pub fn plan_push(notes: Vec<Note>, state: &str) -> Result<Vec<Outgoing>, JsError> {
    throw(plan(&notes, state))
}

fn plan(notes: &[Note], state: &str) -> Res<Vec<Outgoing>> {
    let state = parse_state(state)?;
    let notes: Vec<qot_core::Note> = notes.iter().map(|n| n.0.clone()).collect();
    Ok(core_sync::plan_push(&notes, &state)
        .into_iter()
        .map(Outgoing)
        .collect())
}

/// What to do with the blobs this device holds (`local`, by attachment id):
/// upload the ones whose note has been pushed, discard the ones no live note
/// refers to. A recording still being made must not be in `local`.
#[wasm_bindgen(js_name = planBlobs)]
pub fn plan_blobs(notes: Vec<Note>, state: &str, local: Vec<String>) -> Result<BlobPlan, JsError> {
    throw(blobs(&notes, state, &local))
}

fn blobs(notes: &[Note], state: &str, local: &[String]) -> Res<BlobPlan> {
    let state = parse_state(state)?;
    let notes: Vec<qot_core::Note> = notes.iter().map(|n| n.0.clone()).collect();
    Ok(BlobPlan(core_sync::plan_blobs(&notes, &state, local)))
}

/// The state after these blobs reached the server, or were fetched from it.
#[wasm_bindgen(js_name = markUploaded)]
pub fn mark_uploaded(state: &str, ids: Vec<String>) -> Result<String, JsError> {
    throw(parse_state(state).map(|s| state_json(&core_sync::mark_uploaded(&s, &ids))))
}

/// The state after these blobs were discarded.
#[wasm_bindgen(js_name = forgetBlobs)]
pub fn forget_blobs(state: &str, ids: Vec<String>) -> Result<String, JsError> {
    throw(parse_state(state).map(|s| state_json(&core_sync::forget_blobs(&s, &ids))))
}

/// The state after the server accepted `sent`.
#[wasm_bindgen(js_name = markPushed)]
pub fn mark_pushed(state: &str, sent: Vec<Outgoing>) -> Result<String, JsError> {
    throw(mark(state, &sent))
}

fn mark(state: &str, sent: &[Outgoing]) -> Res<String> {
    let state = parse_state(state)?;
    let sent: Vec<core_sync::Outgoing> = sent.iter().map(|o| o.0.clone()).collect();
    Ok(state_json(&core_sync::mark_pushed(&state, &sent)))
}

/// Applies pulled changes in order. On a throw, save nothing: the cursor
/// stays put and the next sync retries.
#[wasm_bindgen(js_name = applyPulled)]
pub fn apply_pulled(
    notes: Vec<Note>,
    state: &str,
    incoming: Vec<Incoming>,
) -> Result<Pulled, JsError> {
    throw(apply(&notes, state, &incoming))
}

fn apply(notes: &[Note], state: &str, incoming: &[Incoming]) -> Res<Pulled> {
    let state = parse_state(state)?;
    let notes: BTreeMap<String, qot_core::Note> =
        notes.iter().map(|n| (n.0.id(), n.0.clone())).collect();
    let incoming: Vec<core_sync::Incoming> = incoming.iter().map(|c| c.0.clone()).collect();
    let (changed, next) =
        core_sync::apply_pulled(&notes, &state, &incoming).map_err(|e| e.to_string())?;
    Ok(Pulled {
        changed: changed.into_values().map(Note).collect(),
        state: state_json(&next),
    })
}

// Off wasm the `Res` layer is tested directly (a `JsError` can only be made
// inside a JS host); `tests/web.rs` runs the exported API in Node.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_note_round_trips_through_bytes() {
        let note = Note::new("get milk");
        let copy = Note::parse(&note.to_bytes()).unwrap();
        assert_eq!(copy.id(), note.id());
        assert_eq!(copy.content(), "get milk");
        assert!(!copy.is_deleted());
    }

    #[test]
    fn garbage_bytes_are_an_error() {
        assert!(Note::parse(b"nope").is_err());
    }

    #[test]
    fn seqs_must_be_whole_non_negative_numbers() {
        assert_eq!(to_seq(7.0), Ok(7));
        assert!(to_seq(-1.0).is_err());
        assert!(to_seq(1.5).is_err());
        assert!(to_seq(f64::NAN).is_err());
        assert!(to_seq(1e300).is_err());
    }

    #[test]
    fn sync_state_is_the_cli_json() {
        let empty = empty_sync_state();
        assert_eq!(empty, r#"{"cursor":0,"pushed":{}}"#);
        assert!(parse_state("{").is_err());
    }

    #[test]
    fn two_devices_sync_through_a_log() {
        let phone_note = Note::new("get milk");
        let out = plan(&[phone_note.copy()], &empty_sync_state()).unwrap();
        assert_eq!(out.len(), 1);
        let phone_state = mark(&empty_sync_state(), &out).unwrap();
        assert!(plan(&[phone_note.copy()], &phone_state).unwrap().is_empty());

        let log: Vec<Incoming> = out
            .iter()
            .enumerate()
            .map(|(i, o)| Incoming::make(i as f64 + 1.0, o.note_id(), o.data()).unwrap())
            .collect();
        let pulled = apply(&[], &empty_sync_state(), &log).unwrap();
        assert_eq!(parse_state(&pulled.state()).unwrap().cursor, 1);
        assert_eq!(pulled.changed().len(), 1);
        assert_eq!(pulled.changed()[0].content(), "get milk");
        assert_eq!(pulled.changed()[0].id(), phone_note.id());
    }

    #[test]
    fn a_voice_memo_and_its_blob() {
        let audio = Attachment::make(
            qot_core::Attachment::new_id(),
            "audio".into(),
            "audio/mp4".into(),
            340_000.0,
            Some(42_000.0),
            "pending",
        )
        .unwrap();
        assert_eq!(audio.label(), "audio 0:42");
        assert_eq!(audio.text(), "pending");
        let memo = Note(qot_core::Note::with_attachment("", &audio.0).unwrap());
        assert!(!memo.is_empty());
        assert_eq!(memo.attachments(), vec![audio.clone()]);

        let local = vec![audio.id()];
        let empty = empty_sync_state();
        assert!(
            blobs(&[memo.copy()], &empty, &local)
                .unwrap()
                .upload()
                .is_empty()
        );
        let out = plan(&[memo.copy()], &empty).unwrap();
        assert!(out[0].deleted_blobs().is_empty());
        let state = mark(&empty, &out).unwrap();
        let plan = blobs(&[memo.copy()], &state, &local).unwrap();
        assert_eq!(plan.upload()[0].id(), audio.id());
        assert_eq!(plan.upload()[0].note_id(), memo.id());
    }

    #[test]
    fn a_bad_attachment_is_an_error() {
        let make = |size: f64, text: &str| {
            Attachment::make(
                "x".into(),
                "audio".into(),
                "audio/mp4".into(),
                size,
                None,
                text,
            )
        };
        assert!(make(1.5, "none").is_err());
        assert!(make(-1.0, "none").is_err());
        assert!(make(1.0, "maybe").is_err());
        assert!(make(1.0, "none").is_ok());
        assert!(blobs(&[], "nope", &[]).is_err());
    }

    #[test]
    fn a_bad_pulled_change_is_an_error() {
        let bad = Incoming::make(1.0, "x".into(), b"nope".to_vec()).unwrap();
        assert!(apply(&[], &empty_sync_state(), &[bad]).is_err());
    }

    #[test]
    fn bad_state_is_an_error_not_a_fresh_start() {
        assert!(plan(&[Note::new("x")], "nope").is_err());
        assert!(mark("nope", &[]).is_err());
        assert!(apply(&[], "nope", &[]).is_err());
    }
}
