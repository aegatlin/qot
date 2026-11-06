//! Shared sync test vectors (`vectors/sync.json`): language-neutral cases
//! that the Rust core and every binding (Swift through `qot_ffi`, the
//! browser through `qot_wasm`) replay, so a wrapper can't drift from the
//! core. Each case is one device: its notes and sync state, what it should
//! push, what applying one pulled page gives, and what it should push after.
//!
//! The vectors are generated from real notes, then committed:
//! `cargo test -p qot_core --test sync_vectors -- --ignored regenerate`.
//! Regenerate only when the sync rules change on purpose; a diff in the
//! vectors is a change in behaviour every client sees.

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use qot_core::Note;
use qot_core::sync::{Incoming, Outgoing, SyncState, apply_pulled, mark_pushed, plan_push};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors/sync.json");

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Vectors {
    about: String,
    cases: Vec<Case>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Case {
    name: String,
    /// The device's notes, Automerge bytes, base64.
    notes: Vec<String>,
    /// The device's `SyncState`, as the CLI's `sync.json` holds it.
    state: SyncState,
    /// One pulled page, in order.
    incoming: Vec<Change>,
    expect: Expect,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Change {
    seq: u64,
    note_id: String,
    data: String,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Expect {
    /// `plan_push(notes, state)`, in note order.
    push: Vec<Push>,
    /// `apply_pulled(notes, state, incoming)`; absent when it must fail.
    pulled: Option<Pulled>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Push {
    note_id: String,
    data: String,
    heads: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Pulled {
    state: SyncState,
    /// The changed notes, by id.
    changed: Vec<NoteView>,
    /// Note ids `plan_push` returns after saving the changed notes and state:
    /// local edits that were waiting must still go up.
    push_after: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct NoteView {
    id: String,
    content: String,
    deleted: bool,
    heads: Vec<String>,
}

/// What the core does with a case's inputs.
fn run(notes: &[String], state: &SyncState, incoming: &[Change]) -> Expect {
    let notes: Vec<Note> = notes
        .iter()
        .map(|b| Note::from_bytes(&B64.decode(b).unwrap()).unwrap())
        .collect();
    let push = plan_push(&notes, state)
        .into_iter()
        .map(|o| Push {
            note_id: o.note_id,
            data: B64.encode(&o.data),
            heads: o.heads,
        })
        .collect();
    let incoming: Vec<Incoming> = incoming
        .iter()
        .map(|c| Incoming {
            seq: c.seq,
            note_id: c.note_id.clone(),
            data: B64.decode(&c.data).unwrap(),
        })
        .collect();
    let by_id: BTreeMap<String, Note> = notes.iter().map(|n| (n.id(), n.clone())).collect();
    let pulled = apply_pulled(&by_id, state, &incoming)
        .ok()
        .map(|(changed, next)| {
            let mut saved = by_id.clone();
            saved.extend(changed.clone());
            let saved: Vec<Note> = saved.into_values().collect();
            Pulled {
                push_after: plan_push(&saved, &next)
                    .into_iter()
                    .map(|o| o.note_id)
                    .collect(),
                state: next,
                changed: changed
                    .values()
                    .map(|n| NoteView {
                        id: n.id(),
                        content: n.content(),
                        deleted: n.is_deleted(),
                        heads: n.heads(),
                    })
                    .collect(),
            }
        });
    Expect { push, pulled }
}

#[test]
fn the_core_matches_the_vectors() {
    let vectors: Vectors = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
    assert!(vectors.cases.len() >= 10);
    for case in &vectors.cases {
        assert_eq!(
            run(&case.notes, &case.state, &case.incoming),
            case.expect,
            "case {}",
            case.name
        );
    }
}

/// The vectors are generated from the core, so they also have to say what
/// the rules mean, not just what the code did.
#[test]
fn the_vectors_say_what_the_rules_mean() {
    let vectors: Vectors = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
    let get = |name: &str| {
        vectors
            .cases
            .iter()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("no case {name}"))
    };
    let pulled = |name: &str| get(name).expect.pulled.as_ref().unwrap();

    assert!(
        get("a pushed note with nothing new is not pushed")
            .expect
            .push
            .is_empty()
    );
    let waiting = "a pulled edit while a local edit waits keeps it waiting to go up";
    assert_eq!(pulled(waiting).push_after.len(), 1);
    assert_eq!(pulled(waiting).state.pushed, get(waiting).state.pushed);
    assert!(pulled(waiting).changed[0].content.contains("oat"));
    assert!(pulled(waiting).changed[0].content.contains("eggs"));
    assert!(pulled("a pulled delete makes a tombstone").changed[0].deleted);
    assert!(
        pulled("a pulled new note is saved and counts as pushed")
            .push_after
            .is_empty()
    );
    assert_eq!(pulled("the cursor is the last seq applied").state.cursor, 9);
    let own = get("a device's own push pulled back changes nothing but the cursor");
    assert_eq!(
        own.expect.pulled.as_ref().unwrap().state.pushed,
        own.state.pushed
    );
    assert!(
        get("a change that isn't Automerge fails the whole page")
            .expect
            .pulled
            .is_none()
    );
}

// MARK: - Generating

fn b64(note: &Note) -> String {
    B64.encode(note.to_bytes())
}

fn change(seq: u64, note: &Note, data: Vec<u8>) -> Change {
    Change {
        seq,
        note_id: note.id(),
        data: B64.encode(data),
    }
}

/// The whole note as one pushed change.
fn whole(note: &Note) -> Vec<u8> {
    note.changes_since(vec![]).unwrap()
}

fn pushed(notes: &[&Note]) -> SyncState {
    let out: Vec<Outgoing> = plan_push(
        &notes.iter().map(|n| (*n).clone()).collect::<Vec<_>>(),
        &SyncState::default(),
    );
    mark_pushed(&SyncState::default(), &out)
}

fn case(name: &str, notes: &[&Note], state: SyncState, incoming: Vec<Change>) -> Case {
    let notes: Vec<String> = notes.iter().map(|n| b64(n)).collect();
    let expect = run(&notes, &state, &incoming);
    Case {
        name: name.into(),
        notes,
        state,
        incoming,
        expect,
    }
}

#[test]
#[ignore = "writes vectors/sync.json; run only when the rules change on purpose"]
fn regenerate() {
    let milk = Note::new("get milk");
    let mom = Note::new("call mom");
    let milk_oat = milk.update("get oat milk").unwrap();
    // Another device's copy of `milk`, edited there.
    let laptop = Note::from_bytes(&milk.to_bytes()).unwrap();
    let laptop_edit = laptop.update("get milk and eggs").unwrap();
    let laptop_delete = laptop.delete().unwrap();
    let remote = Note::new("from the laptop");
    let mut state_with_cursor = pushed(&[&milk]);
    state_with_cursor.cursor = 7;
    let mut unknown = SyncState::default();
    unknown.pushed.insert(milk.id(), vec!["00".repeat(32)]);

    let cases = vec![
        case(
            "a new note is pushed whole",
            &[&milk],
            SyncState::default(),
            vec![],
        ),
        case(
            "a pushed note with nothing new is not pushed",
            &[&milk],
            pushed(&[&milk]),
            vec![],
        ),
        case(
            "an edit since the push sends only what's new",
            &[&milk_oat],
            pushed(&[&milk]),
            vec![],
        ),
        case(
            "heads the note doesn't know mean send it all",
            &[&milk],
            unknown,
            vec![],
        ),
        case(
            "only notes that moved are pushed",
            &[&milk, &mom],
            pushed(&[&milk]),
            vec![],
        ),
        case(
            "a pulled new note is saved and counts as pushed",
            &[],
            SyncState::default(),
            vec![change(1, &remote, whole(&remote))],
        ),
        case(
            "a pulled edit to a note with nothing waiting moves its pushed heads",
            &[&milk],
            pushed(&[&milk]),
            vec![change(
                2,
                &milk,
                laptop_edit.changes_since(milk.heads()).unwrap(),
            )],
        ),
        case(
            "a pulled edit while a local edit waits keeps it waiting to go up",
            &[&milk_oat],
            pushed(&[&milk]),
            vec![change(
                2,
                &milk,
                laptop_edit.changes_since(milk.heads()).unwrap(),
            )],
        ),
        case(
            "a pulled delete makes a tombstone",
            &[&milk],
            pushed(&[&milk]),
            vec![change(
                3,
                &milk,
                laptop_delete.changes_since(milk.heads()).unwrap(),
            )],
        ),
        case(
            "a device's own push pulled back changes nothing but the cursor",
            &[&milk],
            pushed(&[&milk]),
            vec![change(1, &milk, whole(&milk))],
        ),
        case(
            "the cursor is the last seq applied",
            &[&milk],
            state_with_cursor,
            vec![
                change(8, &remote, whole(&remote)),
                change(9, &mom, whole(&mom)),
            ],
        ),
        case(
            "a change that isn't Automerge fails the whole page",
            &[&milk],
            pushed(&[&milk]),
            vec![
                change(1, &remote, whole(&remote)),
                Change {
                    seq: 2,
                    note_id: "0199e2c0-0000-7000-8000-000000000000".into(),
                    data: B64.encode(b"not automerge"),
                },
            ],
        ),
    ];
    let vectors = Vectors {
        about: "Shared sync test vectors; see core/tests/sync_vectors.rs. Generated, do not edit."
            .into(),
        cases,
    };
    std::fs::write(PATH, serde_json::to_string_pretty(&vectors).unwrap() + "\n").unwrap();
}
