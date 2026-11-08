//! A single quick note as an Automerge document.
//!
//! Every note is its own small document, so notes created on different
//! devices while offline never touch each other, and concurrent edits to the
//! same note merge without losing either side.
//!
//! Sync works on raw Automerge changes: a device remembers the `heads` it last
//! exchanged, sends `changes_since(heads)`, and the other side applies them
//! with `apply_changes`. Applying the same changes twice is harmless.
//!
//! Deleting a note is a tombstone (`deleted = true`) rather than removing the
//! document, so a delete made on one device reaches the others instead of the
//! note being resurrected by the next sync.

pub mod sync;

use automerge::{
    ActorId, AutoCommit, ChangeHash, ObjType, ROOT, ReadDoc, ScalarValue, Value,
    transaction::{CommitOptions, Transactable},
};
use std::fmt;
use uuid::Uuid;

const ID: &str = "id";
const CONTENT: &str = "content";
const DELETED: &str = "deleted";

/// Why a note operation failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteError(String);

impl fmt::Display for NoteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NoteError {}

impl From<automerge::AutomergeError> for NoteError {
    fn from(e: automerge::AutomergeError) -> Self {
        NoteError(e.to_string())
    }
}

pub type NoteResult<T> = Result<T, NoteError>;

/// Every `Note` holds a fully committed document. An uncommitted edit would be
/// committed with a fresh timestamp each time heads are read, so the same note
/// would report different heads on every call.
///
/// Each commit carries its time (Unix seconds, Automerge's convention), which
/// is where a note's last-edited time comes from. Merges and applied changes
/// commit nothing new, so they keep the times their changes were made at.
fn sealed(doc: AutoCommit) -> Note {
    sealed_at(doc, now_secs())
}

fn sealed_at(mut doc: AutoCommit, secs: u64) -> Note {
    doc.commit_with(CommitOptions::default().with_time(secs as i64));
    Note { doc }
}

/// The current time in Unix seconds, from the clock UUIDv7 ids already use
/// (in the browser too, through uuid's `js` feature).
fn now_secs() -> u64 {
    uuid::Timestamp::now(uuid::NoContext).to_unix().0
}

#[derive(Debug, Clone)]
pub struct Note {
    doc: AutoCommit,
}

impl Note {
    pub fn new(content: &str) -> Self {
        let mut doc = AutoCommit::new();
        let id = Uuid::now_v7().to_string();
        // Writes to a fresh in-memory document have nothing that can fail.
        doc.put(ROOT, ID, id.as_str())
            .expect("put id on a fresh doc");
        let text = doc
            .put_object(ROOT, CONTENT, ObjType::Text)
            .expect("create text on a fresh doc");
        doc.update_text(&text, content)
            .expect("write text on a fresh doc");
        sealed(doc)
    }

    pub fn id(&self) -> String {
        match self.doc.get(ROOT, ID) {
            Ok(Some((Value::Scalar(v), _))) => match v.as_ref() {
                ScalarValue::Str(id) => id.to_string(),
                _ => String::new(),
            },
            _ => String::new(),
        }
    }

    /// When the note was created, in Unix milliseconds, from its UUIDv7 id.
    /// `None` if the id carries no time.
    pub fn created_at_ms(&self) -> Option<u64> {
        let (secs, nanos) = Uuid::parse_str(&self.id()).ok()?.get_timestamp()?.to_unix();
        Some(secs * 1000 + u64::from(nanos) / 1_000_000)
    }

    /// When the note was last edited, in Unix milliseconds (to the second):
    /// the latest time among its changes, never before it was created. Notes
    /// saved before commits carried a time report their creation time.
    pub fn updated_at_ms(&self) -> u64 {
        // `document()` takes `&mut` to commit pending edits; a `Note` has
        // none, so a clone reads the same history.
        let mut doc = self.doc.clone();
        let latest = doc
            .document()
            .get_changes(&[])
            .iter()
            .map(|c| c.timestamp().max(0) as u64 * 1000)
            .max()
            .unwrap_or(0);
        latest.max(self.created_at_ms().unwrap_or(0))
    }

    pub fn content(&self) -> String {
        match self.doc.get(ROOT, CONTENT) {
            Ok(Some((_, text))) => self.doc.text(text).unwrap_or_default(),
            _ => String::new(),
        }
    }

    pub fn is_deleted(&self) -> bool {
        matches!(
            self.doc.get(ROOT, DELETED),
            Ok(Some((Value::Scalar(v), _))) if matches!(v.as_ref(), ScalarValue::Boolean(true))
        )
    }

    pub fn update(&self, new_content: &str) -> NoteResult<Note> {
        self.update_at(new_content, now_secs())
    }

    fn update_at(&self, new_content: &str, secs: u64) -> NoteResult<Note> {
        let mut doc = self.branch();
        let text = match doc.get(ROOT, CONTENT)? {
            Some((_, text)) => text,
            None => return Err(NoteError("note has no content".into())),
        };
        doc.update_text(&text, new_content)?;
        Ok(sealed_at(doc, secs))
    }

    /// Marks the note deleted. The document is kept so the delete can sync.
    pub fn delete(&self) -> NoteResult<Note> {
        let mut doc = self.branch();
        doc.put(ROOT, DELETED, true)?;
        Ok(sealed(doc))
    }

    /// A copy to make an edit on, with a fresh actor: two edits made from
    /// the same `Note` value would otherwise both be (actor, seq n+1), and
    /// merging them fails ("duplicate seq").
    fn branch(&self) -> AutoCommit {
        let mut doc = self.doc.clone();
        doc.set_actor(ActorId::random());
        doc
    }

    pub fn merge(&self, other: &Note) -> NoteResult<Note> {
        if self.id() != other.id() {
            return Err(NoteError("cannot merge two different notes".into()));
        }
        let mut doc = self.doc.clone();
        let mut other_doc = other.doc.clone();
        doc.merge(&mut other_doc)?;
        Ok(sealed(doc))
    }

    /// The whole note as Automerge bytes, for storage.
    pub fn to_bytes(&self) -> Vec<u8> {
        self.doc.clone().save()
    }

    pub fn from_bytes(bytes: &[u8]) -> NoteResult<Note> {
        let doc = AutoCommit::load(bytes)?;
        let note = Note { doc };
        if note.id().is_empty() {
            return Err(NoteError("document is not a note: it has no id".into()));
        }
        Ok(note)
    }

    /// The note's current heads as hex hashes. A sync peer stores these to
    /// ask for only what is new next time.
    pub fn heads(&self) -> Vec<String> {
        self.doc
            .clone()
            .get_heads()
            .iter()
            .map(|h| h.to_string())
            .collect()
    }

    /// Changes made after `heads`, encoded for `apply_changes`. Empty heads
    /// means everything. Unknown heads are an error, not "send everything",
    /// so a peer with corrupt state finds out.
    pub fn changes_since(&self, heads: Vec<String>) -> NoteResult<Vec<u8>> {
        let hashes = heads
            .iter()
            .map(|h| {
                h.parse::<ChangeHash>()
                    .map_err(|e| NoteError(format!("bad head {h}: {e}")))
            })
            .collect::<NoteResult<Vec<_>>>()?;
        let mut doc = self.doc.clone();
        for hash in &hashes {
            if doc.get_change_by_hash(hash).is_none() {
                return Err(NoteError(format!("unknown head {hash}")));
            }
        }
        Ok(doc.save_after(&hashes))
    }

    /// Applies changes from `changes_since` (or a whole saved note).
    /// Re-applying changes already present is a no-op.
    pub fn apply_changes(&self, changes: &[u8]) -> NoteResult<Note> {
        let mut doc = self.doc.clone();
        doc.load_incremental(changes)?;
        Ok(sealed(doc))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_note_has_uuid_v7_id_and_content() {
        let note = Note::new("expected content!");
        let id = Uuid::try_parse(&note.id()).unwrap();
        assert_eq!(id.get_version_num(), 7);
        assert_eq!(note.content(), "expected content!");
        assert!(!note.is_deleted());
    }

    #[test]
    fn created_at_is_read_from_the_v7_id() {
        let before = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let at = Note::new("x").created_at_ms().unwrap();
        assert!(at >= before && at < before + 5_000);
    }

    fn now_ms() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
    }

    #[test]
    fn a_new_note_was_last_edited_when_it_was_made() {
        let before = now_ms() / 1000 * 1000;
        let at = Note::new("x").updated_at_ms();
        assert!(at >= before && at < before + 5_000, "{at} vs {before}");
    }

    #[test]
    fn an_edit_moves_the_last_edited_time() {
        let note = Note::new("x");
        let later = note.created_at_ms().unwrap() / 1000 + 60;
        let edited = note.update_at("y", later).unwrap();
        assert_eq!(edited.updated_at_ms(), later * 1000);
        assert!(note.updated_at_ms() < edited.updated_at_ms());
    }

    #[test]
    fn a_merge_keeps_the_latest_edit_time() {
        let note = Note::new("x");
        let later = note.created_at_ms().unwrap() / 1000 + 60;
        let edited = note.update_at("y", later).unwrap();
        assert_eq!(note.merge(&edited).unwrap().updated_at_ms(), later * 1000);
    }

    #[test]
    fn a_note_with_untimed_changes_was_last_edited_when_it_was_made() {
        // Notes saved before commits carried a time have only time-0 changes.
        let mut doc = AutoCommit::new();
        let id = Uuid::now_v7().to_string();
        doc.put(ROOT, ID, id.as_str()).unwrap();
        doc.put_object(ROOT, CONTENT, ObjType::Text).unwrap();
        doc.commit();
        let note = Note::from_bytes(&doc.save()).unwrap();
        assert_eq!(note.updated_at_ms(), note.created_at_ms().unwrap());
    }

    #[test]
    fn two_edits_from_the_same_note_merge() {
        // Each edit gets its own actor, so edits branching from one value
        // never share a seq (Automerge's "duplicate seq" on merge).
        let note = Note::new("milk");
        let a = note.update("oat milk").unwrap();
        let b = note.update("milk and eggs").unwrap();
        let merged = a.merge(&b).unwrap();
        assert!(merged.content().contains("oat"), "{}", merged.content());
        assert!(merged.content().contains("eggs"), "{}", merged.content());
    }

    #[test]
    fn an_edit_and_a_delete_from_the_same_note_merge() {
        let note = Note::new("milk");
        let edited = note.update("oat milk").unwrap();
        let deleted = note.delete().unwrap();
        let merged = edited.merge(&deleted).unwrap();
        assert!(merged.is_deleted());
        assert_eq!(merged.content(), "oat milk");
    }

    #[test]
    fn round_trips_through_bytes() {
        let note1 = Note::new("expected content!");
        let note2 = Note::from_bytes(&note1.to_bytes()).unwrap();
        assert_eq!(note2.id(), note1.id());
        assert_eq!(note2.content(), "expected content!");
    }

    #[test]
    fn from_garbage_is_an_error_not_an_empty_note() {
        assert!(Note::from_bytes(b"not automerge").is_err());
    }

    #[test]
    fn from_a_doc_without_an_id_is_an_error() {
        let bytes = AutoCommit::new().save();
        assert!(Note::from_bytes(&bytes).is_err());
    }

    #[test]
    fn concurrent_edits_merge() {
        let bytes = Note::new("one two three").to_bytes();
        let a = Note::from_bytes(&bytes).unwrap();
        let b = Note::from_bytes(&bytes).unwrap();
        let a = a.update(&format!("cool {}", a.content())).unwrap();
        let b = b.update(&format!("{} wow", b.content())).unwrap();

        let merged = a.merge(&b).unwrap();
        assert_eq!(merged.id(), a.id());
        assert_eq!(merged.content(), "cool one two three wow");
    }

    #[test]
    fn merging_two_different_notes_is_an_error() {
        assert!(Note::new("a").merge(&Note::new("b")).is_err());
    }

    #[test]
    fn delete_is_a_tombstone_that_keeps_id_and_content() {
        let note = Note::new("buy milk").delete().unwrap();
        assert!(note.is_deleted());
        assert_eq!(note.content(), "buy milk");
        assert!(!note.id().is_empty());
    }

    #[test]
    fn a_delete_on_one_device_survives_an_edit_on_another() {
        let bytes = Note::new("buy milk").to_bytes();
        let deleted = Note::from_bytes(&bytes).unwrap().delete().unwrap();
        let edited = Note::from_bytes(&bytes)
            .unwrap()
            .update("buy oat milk")
            .unwrap();

        let merged = edited.merge(&deleted).unwrap();
        assert!(merged.is_deleted());
        assert_eq!(merged.content(), "buy oat milk");
    }

    #[test]
    fn changes_since_empty_heads_recreates_the_note() {
        let note = Note::new("hello");
        let changes = note.changes_since(vec![]).unwrap();
        let copy = Note::from_bytes(&changes).unwrap();
        assert_eq!(copy.id(), note.id());
        assert_eq!(copy.content(), "hello");
    }

    #[test]
    fn incremental_sync_sends_only_new_changes() {
        let phone = Note::new("hello");
        let laptop = Note::from_bytes(&phone.to_bytes()).unwrap();
        let synced_heads = phone.heads();

        let phone = phone.update("hello world").unwrap();
        let delta = phone.changes_since(synced_heads).unwrap();
        assert!(delta.len() < phone.to_bytes().len());

        let laptop = laptop.apply_changes(&delta).unwrap();
        assert_eq!(laptop.content(), "hello world");
        assert_eq!(laptop.heads(), phone.heads());
    }

    #[test]
    fn applying_the_same_changes_twice_is_harmless() {
        let phone = Note::new("hello").update("hello world").unwrap();
        let all = phone.changes_since(vec![]).unwrap();
        let laptop = Note::from_bytes(&all).unwrap().apply_changes(&all).unwrap();
        assert_eq!(laptop.content(), "hello world");
        assert_eq!(laptop.heads(), phone.heads());
    }

    #[test]
    fn nothing_new_means_empty_changes() {
        let note = Note::new("hello");
        assert!(note.changes_since(note.heads()).unwrap().is_empty());
    }

    #[test]
    fn unknown_or_malformed_heads_are_errors() {
        let other = Note::new("other");
        assert!(Note::new("x").changes_since(other.heads()).is_err());
        assert!(Note::new("x").changes_since(vec!["zz".into()]).is_err());
    }
}
