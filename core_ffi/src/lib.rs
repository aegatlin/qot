//! `qot_core` for Swift and Kotlin, through UniFFI.
//!
//! A thin shell: every rule lives in `qot_core`, and this crate only adapts
//! its types to what UniFFI can carry. Notes stay immutable values (each
//! operation returns a new `Note`), and failures are errors, never empty
//! notes.

uniffi::setup_scaffolding!();

use qot_core::sync as core_sync;
use std::collections::BTreeMap;
use std::sync::Arc;

/// Why an operation failed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum QotError {
    /// Bytes that aren't a note, a change that doesn't apply, or saved sync
    /// state that doesn't parse.
    Invalid { message: String },
}

impl std::fmt::Display for QotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            QotError::Invalid { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for QotError {}

impl From<qot_core::NoteError> for QotError {
    fn from(e: qot_core::NoteError) -> Self {
        QotError::Invalid {
            message: e.to_string(),
        }
    }
}

type QotResult<T> = Result<T, QotError>;

/// One note. Immutable: every edit returns a new `Note`.
#[derive(Debug, Clone, uniffi::Object)]
pub struct Note(qot_core::Note);

fn wrap(note: qot_core::Note) -> Arc<Note> {
    Arc::new(Note(note))
}

#[uniffi::export]
impl Note {
    #[uniffi::constructor]
    pub fn new(content: String) -> Arc<Self> {
        wrap(qot_core::Note::new(&content))
    }

    /// A note saved with `to_bytes`. Bytes that aren't a note are an error.
    #[uniffi::constructor]
    pub fn from_bytes(bytes: Vec<u8>) -> QotResult<Arc<Self>> {
        Ok(wrap(qot_core::Note::from_bytes(&bytes)?))
    }

    pub fn id(&self) -> String {
        self.0.id()
    }

    pub fn content(&self) -> String {
        self.0.content()
    }

    pub fn is_deleted(&self) -> bool {
        self.0.is_deleted()
    }

    /// When the note was created, in Unix milliseconds, read from its
    /// UUIDv7 id (0 if the id carries no time).
    pub fn created_at_ms(&self) -> u64 {
        self.0.created_at_ms().unwrap_or(0)
    }

    /// When the note was last edited, in Unix milliseconds (to the second).
    pub fn updated_at_ms(&self) -> u64 {
        self.0.updated_at_ms()
    }

    pub fn update(&self, content: String) -> QotResult<Arc<Note>> {
        Ok(wrap(self.0.update(&content)?))
    }

    /// Marks the note deleted (a tombstone, so the delete syncs).
    pub fn delete(&self) -> QotResult<Arc<Note>> {
        Ok(wrap(self.0.delete()?))
    }

    pub fn merge(&self, other: Arc<Note>) -> QotResult<Arc<Note>> {
        Ok(wrap(self.0.merge(&other.0)?))
    }

    /// The whole note as Automerge bytes, for storage.
    pub fn to_bytes(&self) -> Vec<u8> {
        self.0.to_bytes()
    }

    pub fn heads(&self) -> Vec<String> {
        self.0.heads()
    }
}

/// What a device persists between syncs. Stored as JSON, the same format the
/// CLI writes to `sync.json`.
#[derive(Debug, Clone, uniffi::Object)]
pub struct SyncState(core_sync::SyncState);

#[uniffi::export]
impl SyncState {
    #[uniffi::constructor]
    pub fn empty() -> Arc<Self> {
        Arc::new(SyncState(core_sync::SyncState::default()))
    }

    #[uniffi::constructor]
    pub fn from_json(json: String) -> QotResult<Arc<Self>> {
        serde_json::from_str(&json)
            .map(|s| Arc::new(SyncState(s)))
            .map_err(|e| QotError::Invalid {
                message: format!("bad sync state: {e}"),
            })
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(&self.0).expect("sync state always serializes")
    }

    /// The last server seq applied; pull from here.
    pub fn cursor(&self) -> u64 {
        self.0.cursor
    }
}

/// One note's changes to push.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Outgoing {
    pub note_id: String,
    pub data: Vec<u8>,
    pub heads: Vec<String>,
}

/// One change pulled from the server log.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Incoming {
    pub seq: u64,
    pub note_id: String,
    pub data: Vec<u8>,
}

/// What a pull changed: the notes to save, and the state to save after them.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Pulled {
    pub changed: Vec<Arc<Note>>,
    pub state: Arc<SyncState>,
}

/// The changes to push for every note whose heads moved since last pushed.
#[uniffi::export]
pub fn plan_push(notes: Vec<Arc<Note>>, state: Arc<SyncState>) -> Vec<Outgoing> {
    let notes: Vec<qot_core::Note> = notes.iter().map(|n| n.0.clone()).collect();
    core_sync::plan_push(&notes, &state.0)
        .into_iter()
        .map(|o| Outgoing {
            note_id: o.note_id,
            data: o.data,
            heads: o.heads,
        })
        .collect()
}

/// The state after the server accepted `sent`.
#[uniffi::export]
pub fn mark_pushed(state: Arc<SyncState>, sent: Vec<Outgoing>) -> Arc<SyncState> {
    let sent: Vec<core_sync::Outgoing> = sent
        .into_iter()
        .map(|o| core_sync::Outgoing {
            note_id: o.note_id,
            data: o.data,
            heads: o.heads,
        })
        .collect();
    Arc::new(SyncState(core_sync::mark_pushed(&state.0, &sent)))
}

/// Applies pulled changes in order. On error, save nothing: the cursor stays
/// put and the next sync retries.
#[uniffi::export]
pub fn apply_pulled(
    notes: Vec<Arc<Note>>,
    state: Arc<SyncState>,
    incoming: Vec<Incoming>,
) -> QotResult<Pulled> {
    let notes: BTreeMap<String, qot_core::Note> =
        notes.iter().map(|n| (n.0.id(), n.0.clone())).collect();
    let incoming: Vec<core_sync::Incoming> = incoming
        .into_iter()
        .map(|c| core_sync::Incoming {
            seq: c.seq,
            note_id: c.note_id,
            data: c.data,
        })
        .collect();
    let (changed, next) = core_sync::apply_pulled(&notes, &state.0, &incoming)?;
    Ok(Pulled {
        changed: changed.into_values().map(wrap).collect(),
        state: Arc::new(SyncState(next)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_note_round_trips_through_bytes() {
        let note = Note::new("get milk".into());
        let copy = Note::from_bytes(note.to_bytes()).unwrap();
        assert_eq!(copy.id(), note.id());
        assert_eq!(copy.content(), "get milk");
        assert!(!copy.is_deleted());
    }

    #[test]
    fn garbage_bytes_are_an_error() {
        assert!(Note::from_bytes(b"nope".to_vec()).is_err());
    }

    #[test]
    fn edits_return_new_notes() {
        let note = Note::new("get milk".into());
        let edited = note.update("get oat milk".into()).unwrap();
        let deleted = edited.delete().unwrap();
        assert_eq!(note.content(), "get milk");
        assert_eq!(edited.content(), "get oat milk");
        assert!(deleted.is_deleted());
        assert!(!edited.is_deleted());
    }

    #[test]
    fn created_at_comes_from_the_id() {
        let note = Note::new("x".into());
        assert!(note.created_at_ms() > 1_700_000_000_000);
    }

    #[test]
    fn updated_at_is_the_last_edit() {
        let note = Note::new("x".into());
        assert!(note.updated_at_ms() >= note.created_at_ms() / 1000 * 1000);
    }

    #[test]
    fn sync_state_round_trips_through_json() {
        let state = SyncState::empty();
        assert_eq!(state.cursor(), 0);
        let copy = SyncState::from_json(state.to_json()).unwrap();
        assert_eq!(copy.cursor(), 0);
        assert!(SyncState::from_json("{".into()).is_err());
    }

    #[test]
    fn two_devices_sync_through_a_log() {
        // The phone pushes a note; the laptop pulls it.
        let phone_note = Note::new("get milk".into());
        let phone_state = SyncState::empty();
        let out = plan_push(vec![phone_note.clone()], phone_state.clone());
        assert_eq!(out.len(), 1);
        let phone_state = mark_pushed(phone_state, out.clone());
        assert!(plan_push(vec![phone_note.clone()], phone_state).is_empty());

        let log: Vec<Incoming> = out
            .into_iter()
            .enumerate()
            .map(|(i, o)| Incoming {
                seq: i as u64 + 1,
                note_id: o.note_id,
                data: o.data,
            })
            .collect();
        let pulled = apply_pulled(vec![], SyncState::empty(), log).unwrap();
        assert_eq!(pulled.state.cursor(), 1);
        assert_eq!(pulled.changed.len(), 1);
        assert_eq!(pulled.changed[0].content(), "get milk");
        assert_eq!(pulled.changed[0].id(), phone_note.id());
    }

    #[test]
    fn a_bad_pulled_change_is_an_error() {
        let bad = Incoming {
            seq: 1,
            note_id: "x".into(),
            data: b"nope".to_vec(),
        };
        assert!(apply_pulled(vec![], SyncState::empty(), vec![bad]).is_err());
    }
}
