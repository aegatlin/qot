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
fn edits_carry_the_browser_clock() {
    // A commit's time comes from the clock in the browser too, not 0.
    let note = Note::new("x");
    assert!(note.updated_at_ms() >= (note.created_at_ms() / 1000.0).floor() * 1000.0);
    assert!(note.updated_at_ms() > 1_700_000_000_000.0);
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

/// The shared sync vectors (`core/tests/vectors/sync.json`, see
/// `core/tests/sync_vectors.rs`) through the JS API, so `qot_wasm` can't
/// drift from the core.
#[wasm_bindgen_test]
fn the_binding_matches_the_shared_vectors() {
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    use serde_json::{Value, json};

    let vectors: Value =
        serde_json::from_str(include_str!("../../core/tests/vectors/sync.json")).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 10);
    let decode = |v: &Value| B64.decode(v.as_str().unwrap()).unwrap();

    for case in cases {
        let name = case["name"].as_str().unwrap();
        let notes: Vec<Note> = case["notes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| Note::from_bytes(&decode(b)).unwrap())
            .collect();
        let state = case["state"].to_string();
        let expect = &case["expect"];

        let push: Vec<Value> = plan_push(notes.iter().map(Note::copy).collect(), &state)
            .unwrap()
            .iter()
            .map(|o| json!({"note_id": o.note_id(), "data": B64.encode(o.data()), "heads": o.heads()}))
            .collect();
        assert_eq!(Value::from(push), expect["push"], "{name}: push");

        let incoming: Vec<Incoming> = case["incoming"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                Incoming::new(
                    c["seq"].as_f64().unwrap(),
                    c["note_id"].as_str().unwrap().into(),
                    decode(&c["data"]),
                )
                .unwrap()
            })
            .collect();
        let result = apply_pulled(notes.iter().map(Note::copy).collect(), &state, incoming);
        let want = &expect["pulled"];
        if want.is_null() {
            assert!(result.is_err(), "{name}: must fail");
            continue;
        }
        let pulled = result.unwrap();
        let got_state: Value = serde_json::from_str(&pulled.state()).unwrap();
        assert_eq!(got_state, want["state"], "{name}: state");

        let mut changed = pulled.changed();
        changed.sort_by_key(|n| n.id());
        let views: Vec<Value> = changed
            .iter()
            .map(|n| json!({"id": n.id(), "content": n.content(), "deleted": n.is_deleted(), "heads": n.heads()}))
            .collect();
        assert_eq!(Value::from(views), want["changed"], "{name}: changed");

        let mut saved: std::collections::BTreeMap<String, Note> =
            notes.iter().map(|n| (n.id(), n.copy())).collect();
        for n in &changed {
            saved.insert(n.id(), n.copy());
        }
        let after: Vec<String> = plan_push(saved.into_values().collect(), &pulled.state())
            .unwrap()
            .iter()
            .map(|o| o.note_id())
            .collect();
        assert_eq!(Value::from(after), want["push_after"], "{name}: push after");
    }
}
