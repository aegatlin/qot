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

use crate::{Note, NoteResult};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// What a client persists between syncs.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    /// The last server `seq` this client has applied.
    pub cursor: u64,
    /// Per note id, the heads this client last pushed (or pulled while it had
    /// nothing unpushed).
    pub pushed: BTreeMap<String, Vec<String>>,
}

/// One note's changes to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub note_id: String,
    pub data: Vec<u8>,
    /// The note's heads when planned; recorded once the push succeeds.
    pub heads: Vec<String>,
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
            let data = note
                .changes_since(since)
                .unwrap_or_else(|_| note.to_bytes());
            Some(Outgoing {
                note_id: id,
                data,
                heads,
            })
        })
        .collect()
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
