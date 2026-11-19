//! Shared sync test vectors (`vectors/sync.json`): language-neutral cases
//! that the Rust core and every binding (Swift through `qot_ffi`, the
//! browser through `qot_wasm`) replay, so a wrapper can't drift from the
//! core. Each case is one device: its notes, sync state and blob files, what
//! it should push, what to do with the blobs, what applying one pulled page
//! gives, and what it should push and do with the blobs after.
//!
//! The vectors are generated from real notes, then committed:
//! `cargo test -p qot_core --test sync_vectors -- --ignored regenerate`.
//! Regenerate only when the sync rules change on purpose; a diff in the
//! vectors is a change in behaviour every client sees.

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use qot_core::sync::{
    BlobPlan, Incoming, Outgoing, SyncState, apply_pulled, mark_pushed, mark_uploaded, plan_blobs,
    plan_push,
};
use qot_core::{AUDIO, Attachment, AttachmentText, Note};
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
    /// The blob files on the device, by attachment id.
    local_blobs: Vec<String>,
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
    /// `plan_blobs(notes, state, local_blobs)`.
    blobs: Blobs,
    /// `apply_pulled(notes, state, incoming)`; absent when it must fail.
    pulled: Option<Pulled>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Push {
    note_id: String,
    data: String,
    heads: Vec<String>,
    deleted_blobs: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Blobs {
    upload: Vec<Upload>,
    discard: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Upload {
    id: String,
    note_id: String,
}

impl From<BlobPlan> for Blobs {
    fn from(plan: BlobPlan) -> Self {
        Blobs {
            upload: plan
                .upload
                .into_iter()
                .map(|u| Upload {
                    id: u.id,
                    note_id: u.note_id,
                })
                .collect(),
            discard: plan.discard,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Pulled {
    state: SyncState,
    /// The changed notes, by id.
    changed: Vec<NoteView>,
    /// Note ids `plan_push` returns after saving the changed notes and state:
    /// local edits that were waiting must still go up.
    push_after: Vec<String>,
    /// `plan_blobs` after saving them: a pulled delete leaves its recording
    /// to be discarded.
    blobs_after: Blobs,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct NoteView {
    id: String,
    content: String,
    deleted: bool,
    heads: Vec<String>,
    attachments: Vec<AttachmentView>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct AttachmentView {
    id: String,
    kind: String,
    media_type: String,
    size: u64,
    duration_ms: Option<u64>,
    /// `none`, `pending` or `done`.
    text: String,
    label: String,
}

fn view(a: Attachment) -> AttachmentView {
    AttachmentView {
        label: a.label(),
        id: a.id,
        kind: a.kind,
        media_type: a.media_type,
        size: a.size,
        duration_ms: a.duration_ms,
        text: match a.text {
            AttachmentText::None => "none",
            AttachmentText::Pending => "pending",
            AttachmentText::Done => "done",
        }
        .into(),
    }
}

/// What the core does with a case's inputs.
fn run(notes: &[String], state: &SyncState, local_blobs: &[String], incoming: &[Change]) -> Expect {
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
            deleted_blobs: o.deleted_blobs,
        })
        .collect();
    let blobs = plan_blobs(&notes, state, local_blobs).into();
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
                blobs_after: plan_blobs(&saved, &next, local_blobs).into(),
                state: next,
                changed: changed
                    .values()
                    .map(|n| NoteView {
                        id: n.id(),
                        content: n.content(),
                        deleted: n.is_deleted(),
                        heads: n.heads(),
                        attachments: n.attachments().into_iter().map(view).collect(),
                    })
                    .collect(),
            }
        });
    Expect {
        push,
        blobs,
        pulled,
    }
}

#[test]
fn the_core_matches_the_vectors() {
    let vectors: Vectors = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
    assert!(vectors.cases.len() >= 20);
    for case in &vectors.cases {
        assert_eq!(
            run(&case.notes, &case.state, &case.local_blobs, &case.incoming),
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

    // Blobs.
    let waits = get("a new voice memo is pushed whole and its recording waits");
    assert_eq!(waits.expect.push.len(), 1);
    assert!(waits.expect.blobs.upload.is_empty());
    assert!(waits.expect.blobs.discard.is_empty());
    let up = get("a pushed voice memo's recording is uploaded");
    assert_eq!(up.expect.blobs.upload.len(), 1);
    assert_eq!(up.expect.blobs.upload[0].id, up.local_blobs[0]);
    assert!(
        get("a recording already on the server is not uploaded again")
            .expect
            .blobs
            .upload
            .is_empty()
    );
    for name in [
        "removing the recording deletes its blob with the push",
        "deleting a voice memo deletes its blob with the push",
    ] {
        let case = get(name);
        assert_eq!(
            case.expect.push[0].deleted_blobs, case.local_blobs,
            "{name}"
        );
        assert_eq!(case.expect.blobs.discard, case.local_blobs, "{name}");
    }
    assert!(
        get("an edit that keeps the recording deletes nothing")
            .expect
            .push[0]
            .deleted_blobs
            .is_empty()
    );
    let gone = get("a pulled delete leaves the recording to be discarded");
    assert!(gone.expect.blobs.discard.is_empty());
    assert_eq!(pulled(&gone.name).blobs_after.discard, gone.local_blobs);
    assert!(pulled(&gone.name).push_after.is_empty());
    let memo = &pulled("a pulled voice memo lists its recording").changed[0];
    assert_eq!(memo.attachments.len(), 1);
    assert_eq!(memo.attachments[0].label, "audio 0:42");
    assert_eq!(memo.attachments[0].text, "pending");
    let unknown = &pulled("an attachment of an unknown kind is listed, not dropped").changed[0];
    assert_eq!(unknown.attachments[0].kind, "hologram");
    assert_eq!(unknown.attachments[0].label, "hologram, 2 MB");
    assert_eq!(
        get("a file no note refers to is discarded")
            .expect
            .blobs
            .discard,
        get("a file no note refers to is discarded").local_blobs
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
    blob_case(name, notes, state, &[], incoming)
}

/// A case for a device that holds blob files.
fn blob_case(
    name: &str,
    notes: &[&Note],
    state: SyncState,
    local_blobs: &[&String],
    incoming: Vec<Change>,
) -> Case {
    let notes: Vec<String> = notes.iter().map(|n| b64(n)).collect();
    let local_blobs: Vec<String> = local_blobs.iter().map(|s| (*s).clone()).collect();
    let expect = run(&notes, &state, &local_blobs, &incoming);
    Case {
        name: name.into(),
        notes,
        state,
        local_blobs,
        incoming,
        expect,
    }
}

fn attachment(kind: &str, duration_ms: Option<u64>, text: AttachmentText) -> Attachment {
    Attachment {
        id: Attachment::new_id(),
        kind: kind.into(),
        media_type: if kind == AUDIO {
            "audio/mp4".into()
        } else {
            "model/x-holo".into()
        },
        size: if kind == AUDIO { 340_000 } else { 2_400_000 },
        duration_ms,
        text,
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

    // A voice memo, on the phone that recorded it and on a laptop.
    let audio = attachment(AUDIO, Some(42_000), AttachmentText::Done);
    let memo = Note::with_attachment("call the plumber", &audio).unwrap();
    let uploaded = mark_uploaded(&pushed(&[&memo]), std::slice::from_ref(&audio.id));
    let memo_edited = memo.update("call the plumber today").unwrap();
    let memo_text_only = memo.detach(&audio.id).unwrap();
    let memo_deleted = memo.delete().unwrap();
    let pending = attachment(AUDIO, Some(42_000), AttachmentText::Pending);
    let untranscribed = Note::with_attachment("", &pending).unwrap();
    let hologram = Note::new("holiday")
        .attach(&attachment("hologram", None, AttachmentText::None))
        .unwrap();
    let stray = Attachment::new_id();

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
        blob_case(
            "a new voice memo is pushed whole and its recording waits",
            &[&memo],
            SyncState::default(),
            &[&audio.id],
            vec![],
        ),
        blob_case(
            "a pushed voice memo's recording is uploaded",
            &[&memo],
            pushed(&[&memo]),
            &[&audio.id],
            vec![],
        ),
        blob_case(
            "a recording already on the server is not uploaded again",
            &[&memo],
            uploaded.clone(),
            &[&audio.id],
            vec![],
        ),
        blob_case(
            "an edit that keeps the recording deletes nothing",
            &[&memo_edited],
            uploaded.clone(),
            &[&audio.id],
            vec![],
        ),
        blob_case(
            "removing the recording deletes its blob with the push",
            &[&memo_text_only],
            uploaded.clone(),
            &[&audio.id],
            vec![],
        ),
        blob_case(
            "deleting a voice memo deletes its blob with the push",
            &[&memo_deleted],
            uploaded.clone(),
            &[&audio.id],
            vec![],
        ),
        blob_case(
            "a pulled delete leaves the recording to be discarded",
            &[&memo],
            uploaded.clone(),
            &[&audio.id],
            vec![change(
                4,
                &memo,
                memo_deleted.changes_since(memo.heads()).unwrap(),
            )],
        ),
        blob_case(
            "a file no note refers to is discarded",
            &[&milk],
            pushed(&[&milk]),
            &[&stray],
            vec![],
        ),
        case(
            "a pulled voice memo lists its recording",
            &[],
            SyncState::default(),
            vec![change(1, &untranscribed, whole(&untranscribed))],
        ),
        case(
            "an attachment of an unknown kind is listed, not dropped",
            &[],
            SyncState::default(),
            vec![change(1, &hologram, whole(&hologram))],
        ),
    ];
    let vectors = Vectors {
        about: "Shared sync test vectors; see core/tests/sync_vectors.rs. Generated, do not edit."
            .into(),
        cases,
    };
    std::fs::write(PATH, serde_json::to_string_pretty(&vectors).unwrap() + "\n").unwrap();
}
