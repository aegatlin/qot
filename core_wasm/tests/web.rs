//! The exported API as JavaScript sees it, run in Node by
//! wasm-bindgen-test (`mise run test:wasm`).
#![cfg(target_arch = "wasm32")]

use qot_wasm::*;
use wasm_bindgen_test::*;

#[wasm_bindgen_test]
fn notes_are_created_edited_and_deleted() {
    let note = Note::new("get milk");
    let edited = note.update("get oat milk").unwrap();
    let deleted = edited.delete().unwrap();
    assert_eq!(note.content(), "get milk");
    assert_eq!(edited.content(), "get oat milk");
    assert!(deleted.is_deleted());
    assert!(note.created_at_ms() > 1_700_000_000_000.0);
}

#[wasm_bindgen_test]
fn ids_are_random_in_the_browser() {
    // Exercises getrandom's wasm_js backend.
    assert_ne!(Note::new("a").id(), Note::new("a").id());
}

#[wasm_bindgen_test]
fn bad_input_throws() {
    assert!(Note::from_bytes(b"nope").is_err());
    assert!(Incoming::new(-1.0, "x".into(), vec![]).is_err());
    assert!(sync_cursor("nope").is_err());
}

#[wasm_bindgen_test]
fn a_note_syncs_from_one_device_to_another() {
    let note = Note::new("get milk");
    let out = plan_push(vec![note.copy()], &empty_sync_state()).unwrap();
    let log: Vec<Incoming> = out
        .iter()
        .map(|o| Incoming::new(1.0, o.note_id(), o.data()).unwrap())
        .collect();
    let state = mark_pushed(&empty_sync_state(), out).unwrap();
    assert!(plan_push(vec![note.copy()], &state).unwrap().is_empty());

    let pulled = apply_pulled(vec![], &empty_sync_state(), log).unwrap();
    assert_eq!(sync_cursor(&pulled.state()).unwrap(), 1.0);
    assert_eq!(pulled.changed()[0].content(), "get milk");
}
