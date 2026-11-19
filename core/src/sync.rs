//! Client-side sync planning: pure functions over notes and a small saved
//! state, shared by every client. The caller does the I/O: it sends what
//! `plan_push` returns, records success with `mark_pushed`, and feeds pulled
//! changes to `apply_pulled`.
//!
//! The server is a per-user, append-only log of opaque change blobs with a
//! gap-free `seq`. A client remembers the last `seq` it pulled (`cursor`)
//! and, per note, the heads it last pushed, so a push sends only what is new.
//! Re-sending or re-applying a change is harmless, so every failure mode
//! resolves by simply syncing again.
//!
//! Attachments' bytes (blobs) move beside the log, never in it: a blob is
//! uploaded once the change that added its attachment has been pushed
//! (`plan_blobs`), and a push names the blobs whose attachment is gone, for
//! the server to delete with it (`Outgoing::deleted_blobs`).

use crate::{Note, NoteResult};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// What a client persists between syncs.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    /// The last server `seq` this client has applied.
    pub cursor: u64,
    /// Per note id, the heads this client last pushed (or pulled while it had
    /// nothing unpushed).
    pub pushed: BTreeMap<String, Vec<String>>,
    /// The blobs (by attachment id) known to be on the server: uploaded from
    /// this device, or downloaded to it.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub uploaded: BTreeSet<String>,
}

/// One note's changes to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub note_id: String,
    pub data: Vec<u8>,
    /// The note's heads when planned; recorded once the push succeeds.
    pub heads: Vec<String>,
    /// Blobs to delete on the server with this push: attachments the note
    /// had when last pushed and has no more (removed, or the note deleted).
    pub deleted_blobs: Vec<String>,
}

/// A blob to upload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobUpload {
    /// The attachment's id.
    pub id: String,
    pub note_id: String,
}

/// What to do with the blob files on this device.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BlobPlan {
    /// Upload these, then `mark_uploaded`.
    pub upload: Vec<BlobUpload>,
    /// Delete these files, then `forget_blobs`: no live note refers to them.
    pub discard: Vec<String>,
}

/// One change from the server log.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Incoming {
    pub seq: u64,
    pub note_id: String,
    pub data: Vec<u8>,
}

/// The changes to push: for every note whose heads moved since it was last
/// pushed, what is new since then (the whole note if it was never pushed).
pub fn plan_push(notes: &[Note], state: &SyncState) -> Vec<Outgoing> {
    notes
        .iter()
        .filter_map(|note| {
            let id = note.id();
            let heads = note.heads();
            let since = state.pushed.get(&id).cloned().unwrap_or_default();
            if since == heads {
                return None;
            }
            // Heads we can't find (state from a lost store) mean "send it all".
            let deleted_blobs = dropped_attachments(note, &since);
            let data = note
                .changes_since(since)
                .unwrap_or_else(|_| note.to_bytes());
            Some(Outgoing {
                deleted_blobs,
                note_id: id,
                data,
                heads,
            })
        })
        .collect()
}

/// The attachments `note` had at `since` (its heads when last pushed) and
/// has no more. A deleted note has none. Nothing when it was never pushed,
/// or the heads are unknown: there is then no record of what the server has.
fn dropped_attachments(note: &Note, since: &[String]) -> Vec<String> {
    if since.is_empty() {
        return vec![];
    }
    let before = note.attachment_ids_at(since).unwrap_or_default();
    let now = live_attachment_ids(note);
    before.into_iter().filter(|id| !now.contains(id)).collect()
}

fn live_attachment_ids(note: &Note) -> BTreeSet<String> {
    if note.is_deleted() {
        return BTreeSet::new();
    }
    note.attachments().into_iter().map(|a| a.id).collect()
}

/// What to do with the blob files a device holds (`local`, attachment ids).
///
/// A blob is uploaded when a live note has its attachment, the change that
/// added the attachment has been pushed (so the note reaches other devices
/// first, and the server never holds bytes no note points to), and it isn't
/// known to be on the server. A blob no live note refers to is discarded:
/// that is how a delete made on another device removes the file here.
///
/// A recording still being made must not be in `local`: keep it elsewhere
/// until the step that saves its note.
pub fn plan_blobs(notes: &[Note], state: &SyncState, local: &[String]) -> BlobPlan {
    let mut live: BTreeMap<String, &Note> = BTreeMap::new();
    for note in notes {
        for id in live_attachment_ids(note) {
            live.insert(id, note);
        }
    }
    let mut plan = BlobPlan::default();
    for id in local {
        let Some(note) = live.get(id) else {
            plan.discard.push(id.clone());
            continue;
        };
        if state.uploaded.contains(id) {
            continue;
        }
        let note_id = note.id();
        let pushed = state
            .pushed
            .get(&note_id)
            .filter(|heads| !heads.is_empty())
            .and_then(|heads| note.attachment_ids_at(heads).ok())
            .is_some_and(|ids| ids.contains(id));
        if pushed {
            plan.upload.push(BlobUpload {
                id: id.clone(),
                note_id,
            });
        }
    }
    plan
}

/// The state after these blobs reached the server, or were fetched from it.
pub fn mark_uploaded(state: &SyncState, ids: &[String]) -> SyncState {
    let mut next = state.clone();
    next.uploaded.extend(ids.iter().cloned());
    next
}

/// The state after these blob files were discarded.
pub fn forget_blobs(state: &SyncState, ids: &[String]) -> SyncState {
    let mut next = state.clone();
    for id in ids {
        next.uploaded.remove(id);
    }
    next
}

/// The state after `sent` was accepted by the server.
pub fn mark_pushed(state: &SyncState, sent: &[Outgoing]) -> SyncState {
    let mut next = state.clone();
    for out in sent {
        next.pushed.insert(out.note_id.clone(), out.heads.clone());
    }
    next
}

/// Applies pulled changes in order. Returns the notes that changed (to be
/// saved) and the new state. On error nothing should be saved and the cursor
/// stays put, so the next sync retries the same changes.
pub fn apply_pulled(
    notes: &BTreeMap<String, Note>,
    state: &SyncState,
    incoming: &[Incoming],
) -> NoteResult<(BTreeMap<String, Note>, SyncState)> {
    let mut changed: BTreeMap<String, Note> = BTreeMap::new();
    let mut next = state.clone();

    for change in incoming {
        let current = changed.get(&change.note_id).or(notes.get(&change.note_id));
        let updated = match current {
            Some(note) => {
                let before = note.heads();
                let updated = note.apply_changes(&change.data)?;
                // Only move "pushed" when nothing local was waiting to go up;
                // otherwise the next push must still send the local edits.
                if next.pushed.get(&change.note_id) == Some(&before) {
                    next.pushed.insert(change.note_id.clone(), updated.heads());
                }
                updated
            }
            None => {
                let note = Note::from_bytes(&change.data)?;
                next.pushed.insert(change.note_id.clone(), note.heads());
                note
            }
        };
        changed.insert(change.note_id.clone(), updated);
        next.cursor = change.seq;
    }

    Ok((changed, next))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A device: its notes and its sync state.
    #[derive(Default)]
    struct Device {
        notes: BTreeMap<String, Note>,
        state: SyncState,
    }

    impl Device {
        fn add(&mut self, content: &str) -> String {
            let note = Note::new(content);
            let id = note.id();
            self.notes.insert(id.clone(), note);
            id
        }

        fn edit(&mut self, id: &str, f: impl Fn(&Note) -> Note) {
            let note = f(&self.notes[id]);
            self.notes.insert(id.to_string(), note);
        }

        fn content(&self, id: &str) -> String {
            self.notes[id].content()
        }

        /// Push then pull, the order every client uses.
        fn sync(&mut self, server: &mut Vec<Incoming>) {
            let all: Vec<Note> = self.notes.values().cloned().collect();
            let out = plan_push(&all, &self.state);
            for o in &out {
                let seq = server.len() as u64 + 1;
                server.push(Incoming {
                    seq,
                    note_id: o.note_id.clone(),
                    data: o.data.clone(),
                });
            }
            self.state = mark_pushed(&self.state, &out);

            let new: Vec<Incoming> = server
                .iter()
                .filter(|c| c.seq > self.state.cursor)
                .cloned()
                .collect();
            let (changed, state) = apply_pulled(&self.notes, &self.state, &new).unwrap();
            self.notes.extend(changed);
            self.state = state;
        }
    }

    #[test]
    fn notes_taken_offline_arrive_on_the_other_device() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());

        let milk = phone.add("get milk");
        let eggs = phone.add("get eggs");
        phone.sync(&mut server);
        laptop.sync(&mut server);

        assert_eq!(laptop.content(&milk), "get milk");
        assert_eq!(laptop.content(&eggs), "get eggs");
    }

    #[test]
    fn concurrent_offline_edits_converge_on_both_devices() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());
        let id = phone.add("one two three");
        phone.sync(&mut server);
        laptop.sync(&mut server);

        phone.edit(&id, |n| n.update("cool one two three").unwrap());
        laptop.edit(&id, |n| n.update("one two three wow").unwrap());
        phone.sync(&mut server);
        laptop.sync(&mut server);
        phone.sync(&mut server);

        assert_eq!(phone.content(&id), "cool one two three wow");
        assert_eq!(laptop.content(&id), "cool one two three wow");
    }

    #[test]
    fn a_delete_reaches_the_other_device() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());
        let id = phone.add("buy milk");
        phone.sync(&mut server);
        laptop.sync(&mut server);

        laptop.edit(&id, |n| n.delete().unwrap());
        laptop.sync(&mut server);
        phone.sync(&mut server);

        assert!(phone.notes[&id].is_deleted());
    }

    #[test]
    fn a_synced_device_has_nothing_to_push() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());
        phone.add("a");
        phone.sync(&mut server);
        laptop.sync(&mut server);

        let all: Vec<Note> = laptop.notes.values().cloned().collect();
        assert!(plan_push(&all, &laptop.state).is_empty());
        let all: Vec<Note> = phone.notes.values().cloned().collect();
        assert!(plan_push(&all, &phone.state).is_empty());
    }

    #[test]
    fn only_new_changes_are_pushed_after_the_first_sync() {
        let mut server = vec![];
        let mut phone = Device::default();
        let id = phone.add("hello");
        phone.sync(&mut server);
        let first = server[0].data.len();

        phone.edit(&id, |n| n.update("hello world").unwrap());
        phone.sync(&mut server);

        assert_eq!(server.len(), 2);
        assert!(server[1].data.len() < first + 1);
    }

    #[test]
    fn local_edits_made_before_a_pull_are_still_pushed() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());
        let id = phone.add("base");
        phone.sync(&mut server);
        laptop.sync(&mut server);

        // Laptop edits, then pulls the phone's edit *without* pushing first.
        laptop.edit(&id, |n| n.update("base laptop").unwrap());
        phone.edit(&id, |n| n.update("phone base").unwrap());
        phone.sync(&mut server);
        let pending: Vec<Incoming> = server
            .iter()
            .filter(|c| c.seq > laptop.state.cursor)
            .cloned()
            .collect();
        let (changed, state) = apply_pulled(&laptop.notes, &laptop.state, &pending).unwrap();
        laptop.notes.extend(changed);
        laptop.state = state;

        // Its own edit must still be planned for push.
        let all: Vec<Note> = laptop.notes.values().cloned().collect();
        assert_eq!(plan_push(&all, &laptop.state).len(), 1);
        laptop.sync(&mut server);
        phone.sync(&mut server);
        assert_eq!(phone.content(&id), "phone base laptop");
    }

    #[test]
    fn a_lost_sync_state_recovers_by_resending_everything() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());
        let id = phone.add("hello");
        phone.sync(&mut server);
        phone.state = SyncState::default();
        phone.sync(&mut server);
        laptop.sync(&mut server);
        assert_eq!(laptop.content(&id), "hello");
    }

    #[test]
    fn a_change_for_an_unknown_note_that_is_not_whole_is_an_error() {
        let note = Note::new("hello");
        let delta = note
            .update("hello world")
            .unwrap()
            .changes_since(note.heads())
            .unwrap();
        let incoming = [Incoming {
            seq: 1,
            note_id: note.id(),
            data: delta,
        }];
        assert!(apply_pulled(&BTreeMap::new(), &SyncState::default(), &incoming).is_err());
    }

    // MARK: blobs

    use crate::{AUDIO, Attachment, AttachmentText};

    fn memo() -> Attachment {
        Attachment {
            id: Attachment::new_id(),
            kind: AUDIO.into(),
            media_type: "audio/mp4".into(),
            size: 340_000,
            duration_ms: Some(42_000),
            text: AttachmentText::Done,
        }
    }

    impl Device {
        fn record(&mut self, text: &str) -> (String, String) {
            let audio = memo();
            let note = Note::with_attachment(text, &audio).unwrap();
            let id = note.id();
            self.notes.insert(id.clone(), note);
            (id, audio.id)
        }

        fn all(&self) -> Vec<Note> {
            self.notes.values().cloned().collect()
        }

        fn blobs(&self, local: &[&String]) -> BlobPlan {
            let local: Vec<String> = local.iter().map(|s| (*s).clone()).collect();
            plan_blobs(&self.all(), &self.state, &local)
        }
    }

    #[test]
    fn a_recording_is_uploaded_only_after_its_note_is_pushed() {
        let mut server = vec![];
        let mut phone = Device::default();
        let (note, blob) = phone.record("call the plumber");

        assert_eq!(phone.blobs(&[&blob]), BlobPlan::default());

        phone.sync(&mut server);
        assert_eq!(
            phone.blobs(&[&blob]).upload,
            vec![BlobUpload {
                id: blob.clone(),
                note_id: note
            }]
        );

        phone.state = mark_uploaded(&phone.state, std::slice::from_ref(&blob));
        assert_eq!(phone.blobs(&[&blob]), BlobPlan::default());
    }

    #[test]
    fn an_attachment_added_since_the_push_waits_for_the_next_push() {
        let mut server = vec![];
        let mut phone = Device::default();
        let id = phone.add("trip");
        phone.sync(&mut server);
        let audio = memo();
        phone.edit(&id, |n| n.attach(&audio).unwrap());

        assert!(phone.blobs(&[&audio.id]).upload.is_empty());
        phone.sync(&mut server);
        assert_eq!(phone.blobs(&[&audio.id]).upload.len(), 1);
    }

    #[test]
    fn deleting_a_note_elsewhere_removes_the_recording_everywhere() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());
        let (note, blob) = phone.record("call the plumber");
        phone.sync(&mut server);
        phone.state = mark_uploaded(&phone.state, std::slice::from_ref(&blob));
        laptop.sync(&mut server);

        // The laptop fetched the recording to play it, then deleted the note.
        laptop.state = mark_uploaded(&laptop.state, std::slice::from_ref(&blob));
        laptop.edit(&note, |n| n.delete().unwrap());
        let out = plan_push(&laptop.all(), &laptop.state);
        assert_eq!(out[0].deleted_blobs, vec![blob.clone()]);
        laptop.sync(&mut server);
        assert_eq!(laptop.blobs(&[&blob]).discard, vec![blob.clone()]);

        // The phone is told nothing; it finds the file unreferenced.
        phone.sync(&mut server);
        let plan = phone.blobs(&[&blob]);
        assert_eq!(plan.discard, vec![blob.clone()]);
        assert!(plan.upload.is_empty());
        let state = forget_blobs(&phone.state, &plan.discard);
        assert!(state.uploaded.is_empty());
        // And it has nothing more to tell the server.
        assert!(plan_push(&phone.all(), &phone.state).is_empty());
    }

    #[test]
    fn removing_the_recording_keeps_the_note_and_deletes_the_blob() {
        let mut server = vec![];
        let mut phone = Device::default();
        let (note, blob) = phone.record("call the plumber");
        phone.sync(&mut server);

        phone.edit(&note, |n| n.detach(&blob).unwrap());
        let out = plan_push(&phone.all(), &phone.state);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].deleted_blobs, vec![blob.clone()]);
        assert_eq!(phone.blobs(&[&blob]).discard, vec![blob]);
        assert_eq!(phone.content(&note), "call the plumber");
    }

    #[test]
    fn a_failed_push_names_the_blobs_again() {
        let mut server = vec![];
        let mut phone = Device::default();
        let (note, blob) = phone.record("x");
        phone.sync(&mut server);
        phone.edit(&note, |n| n.delete().unwrap());

        // The push fails: nothing is marked, so the next plan is the same.
        let first = plan_push(&phone.all(), &phone.state);
        let second = plan_push(&phone.all(), &phone.state);
        assert_eq!(first, second);
        assert_eq!(second[0].deleted_blobs, vec![blob]);
    }

    #[test]
    fn an_edit_that_keeps_the_recording_deletes_nothing() {
        let mut server = vec![];
        let mut phone = Device::default();
        let (note, _) = phone.record("call the plumber");
        phone.sync(&mut server);
        phone.edit(&note, |n| n.update("call the plumber today").unwrap());
        assert!(
            plan_push(&phone.all(), &phone.state)[0]
                .deleted_blobs
                .is_empty()
        );
    }

    #[test]
    fn a_recording_deleted_before_it_was_ever_pushed_is_only_discarded() {
        let mut phone = Device::default();
        let (note, blob) = phone.record("x");
        phone.edit(&note, |n| n.delete().unwrap());
        let out = plan_push(&phone.all(), &phone.state);
        assert!(out[0].deleted_blobs.is_empty());
        let plan = phone.blobs(&[&blob]);
        assert_eq!(plan.discard, vec![blob]);
        assert!(plan.upload.is_empty());
    }

    #[test]
    fn a_recording_deleted_elsewhere_before_its_upload_is_never_uploaded() {
        let mut server = vec![];
        let (mut phone, mut laptop) = (Device::default(), Device::default());
        let (note, blob) = phone.record("x");
        phone.sync(&mut server);
        laptop.sync(&mut server);
        laptop.edit(&note, |n| n.delete().unwrap());
        // The laptop still tells the server, which then refuses a late upload.
        assert_eq!(
            plan_push(&laptop.all(), &laptop.state)[0].deleted_blobs,
            vec![blob.clone()]
        );
        laptop.sync(&mut server);
        phone.sync(&mut server);
        let plan = phone.blobs(&[&blob]);
        assert!(plan.upload.is_empty());
        assert_eq!(plan.discard, vec![blob]);
    }

    #[test]
    fn a_file_no_note_knows_is_discarded() {
        let phone = Device::default();
        let stray = Attachment::new_id();
        assert_eq!(phone.blobs(&[&stray]).discard, vec![stray]);
    }

    #[test]
    fn sync_state_written_before_blobs_still_loads() {
        let old: SyncState = serde_json::from_str(r#"{"cursor":3,"pushed":{}}"#).unwrap();
        assert!(old.uploaded.is_empty());
        assert_eq!(
            serde_json::to_string(&SyncState::default()).unwrap(),
            r#"{"cursor":0,"pushed":{}}"#
        );
        let state = mark_uploaded(&old, &["a".into()]);
        let json = serde_json::to_string(&state).unwrap();
        assert_eq!(serde_json::from_str::<SyncState>(&json).unwrap(), state);
    }

    #[test]
    fn the_cursor_follows_the_last_applied_seq() {
        let note = Note::new("x");
        let incoming = [Incoming {
            seq: 7,
            note_id: note.id(),
            data: note.to_bytes(),
        }];
        let (_, state) = apply_pulled(&BTreeMap::new(), &SyncState::default(), &incoming).unwrap();
        assert_eq!(state.cursor, 7);
    }
}
