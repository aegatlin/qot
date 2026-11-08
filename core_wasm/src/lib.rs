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
