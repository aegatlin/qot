//! Notes with attachments in the CLI, which can't record or play them: it
//! lists a marker, exports the files, and tells the server when a recording
//! is gone. The notes are made the way an iPhone would make them (through
//! `qot_core`) and put straight into the store.

use assert_cmd::Command;
use httpmock::prelude::*;
use predicates::prelude::*;
use qot_core::sync::{SyncState, mark_pushed, plan_push};
use qot_core::{AUDIO, Attachment, AttachmentText, Note};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use tempfile::TempDir;

struct Qot {
    dir: TempDir,
}

impl Qot {
    fn new() -> Self {
        let dir = TempDir::new().unwrap();
        std::fs::create_dir_all(dir.path().join("data/notes")).unwrap();
        Qot { dir }
    }

    fn data(&self) -> PathBuf {
        self.dir.path().join("data")
    }

    fn cmd(&self) -> Command {
        let mut cmd = Command::cargo_bin("qot").unwrap();
        cmd.env("QOT_DATA_DIR", self.data())
            .env_remove("VISUAL")
            .env_remove("EDITOR")
            .env_remove("QOT_SERVER");
        cmd
    }

    fn save(&self, note: &Note) {
        let path = self.data().join(format!("notes/{}.note", note.id()));
        std::fs::write(path, note.to_bytes()).unwrap();
    }

    /// As if these notes had already been synced from this device.
    fn mark_synced(&self, notes: &[&Note]) {
        let notes: Vec<Note> = notes.iter().map(|n| (*n).clone()).collect();
        let empty = SyncState::default();
        let state = mark_pushed(&empty, &plan_push(&notes, &empty));
        std::fs::write(
            self.data().join("sync.json"),
            serde_json::to_vec(&state).unwrap(),
        )
        .unwrap();
    }

    fn sign_in(&self, server: &MockServer) {
        std::fs::write(
            self.data().join("credentials.json"),
            json!({
                "server": server.base_url(),
                "email": "me@example.com",
                "access_token": "good",
                "refresh_token": "refresh"
            })
            .to_string(),
        )
        .unwrap();
    }

    fn editor(&self, body: &str) -> PathBuf {
        let path = self.dir.path().join("ed.sh");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn stored(&self, id: &str) -> Note {
        let bytes = std::fs::read(self.data().join(format!("notes/{id}.note"))).unwrap();
        Note::from_bytes(&bytes).unwrap()
    }
}

fn audio() -> Attachment {
    Attachment {
        id: Attachment::new_id(),
        kind: AUDIO.into(),
        media_type: "audio/mp4".into(),
        size: 340_000,
        duration_ms: Some(42_000),
        text: AttachmentText::Done,
    }
}

fn memo(text: &str) -> (Note, Attachment) {
    let audio = audio();
    (Note::with_attachment(text, &audio).unwrap(), audio)
}

fn empty_pull(server: &MockServer) {
    server.mock(|when, then| {
        when.method(GET).path("/api/sync/pull");
        then.status(200)
            .json_body(json!({ "changes": [], "cursor": 0, "more": false }));
    });
}

#[test]
fn list_marks_a_recording_beside_its_text() {
    let qot = Qot::new();
    qot.save(&memo("call the plumber").0);
    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout("1. [audio 0:42] call the plumber\n");
}

#[test]
fn list_shows_a_recording_with_no_text() {
    let qot = Qot::new();
    qot.save(&memo("").0);
    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout("1. [audio 0:42]\n");
}

#[test]
fn list_shows_a_kind_it_does_not_know() {
    let qot = Qot::new();
    let mut hologram = audio();
    hologram.kind = "hologram".into();
    hologram.duration_ms = None;
    hologram.size = 2_400_000;
    qot.save(&Note::new("holiday").attach(&hologram).unwrap());
    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout("1. [hologram, 2 MB] holiday\n");
}

#[test]
fn export_describes_attachments() {
    let qot = Qot::new();
    let (note, audio) = memo("call the plumber");
    qot.save(&note);
    qot.cmd().args(["get", "milk"]).assert().success();

    let out = qot.cmd().arg("export").assert().success();
    let notes: serde_json::Value = serde_json::from_slice(&out.get_output().stdout).unwrap();
    assert_eq!(notes[0]["content"], "call the plumber");
    assert_eq!(
        notes[0]["attachments"],
        json!([{
            "id": audio.id, "kind": "audio", "media_type": "audio/mp4",
            "size": 340_000, "duration_ms": 42_000
        }])
    );
    // A text note's export is what it always was.
    assert!(notes[1].get("attachments").is_none());
}

#[test]
fn export_to_a_directory_writes_the_notes_and_the_recordings() {
    let server = MockServer::start();
    empty_pull(&server);
    let qot = Qot::new();
    let (note, audio) = memo("call the plumber");
    qot.save(&note);
    qot.mark_synced(&[&note]);
    qot.sign_in(&server);
    let blob = server.mock(|when, then| {
        when.method(GET)
            .path(format!("/api/blobs/{}", audio.id))
            .header("authorization", "Bearer good");
        then.status(200)
            .header("content-type", "application/octet-stream")
            .body(b"\x00\x01recording\xff");
    });

    let out = qot.dir.path().join("backup");
    qot.cmd()
        .args(["export", "--dir"])
        .arg(&out)
        .assert()
        .success()
        .stdout(predicate::str::contains("1 note"))
        .stdout(predicate::str::contains("1 attachment"));

    blob.assert();
    let file = format!("attachments/{}.m4a", audio.id);
    assert_eq!(
        std::fs::read(out.join(&file)).unwrap(),
        b"\x00\x01recording\xff"
    );
    let notes: serde_json::Value =
        serde_json::from_slice(&std::fs::read(out.join("notes.json")).unwrap()).unwrap();
    assert_eq!(notes[0]["attachments"][0]["file"], file);
    // The export doesn't keep recordings in the CLI's own store.
    assert!(!qot.data().join("blobs").exists());
}

#[test]
fn export_to_a_directory_says_which_recordings_it_could_not_get() {
    let server = MockServer::start();
    empty_pull(&server);
    let qot = Qot::new();
    let (note, audio) = memo("call the plumber");
    qot.save(&note);
    qot.mark_synced(&[&note]);
    qot.sign_in(&server);
    server.mock(|when, then| {
        when.method(GET).path(format!("/api/blobs/{}", audio.id));
        then.status(404).json_body(json!({ "error": "Not found" }));
    });

    let out = qot.dir.path().join("backup");
    qot.cmd()
        .args(["export", "--dir"])
        .arg(&out)
        .assert()
        .failure()
        .stderr(predicate::str::contains(&audio.id))
        .stderr(predicate::str::contains("isn't on the server"));

    // The text is exported all the same, and doesn't claim a file.
    let notes: serde_json::Value =
        serde_json::from_slice(&std::fs::read(out.join("notes.json")).unwrap()).unwrap();
    assert_eq!(notes[0]["content"], "call the plumber");
    assert!(notes[0]["attachments"][0].get("file").is_none());
}

#[test]
fn export_to_a_directory_needs_a_sign_in_only_for_recordings() {
    let qot = Qot::new();
    qot.cmd().args(["get", "milk"]).assert().success();
    let out = qot.dir.path().join("backup");
    qot.cmd()
        .args(["export", "--dir"])
        .arg(&out)
        .assert()
        .success();
    assert!(out.join("notes.json").exists());

    qot.save(&memo("call the plumber").0);
    qot.cmd()
        .args(["export", "--dir"])
        .arg(&out)
        .assert()
        .failure()
        .stderr(predicate::str::contains("qot login"));
}

#[test]
fn deleting_a_voice_memo_tells_the_server_to_delete_its_recording() {
    let server = MockServer::start();
    empty_pull(&server);
    let qot = Qot::new();
    let (note, audio) = memo("call the plumber");
    qot.save(&note);
    qot.mark_synced(&[&note]);
    qot.sign_in(&server);
    let push = server.mock(|when, then| {
        when.method(POST)
            .path("/api/sync/push")
            .body_includes("\"deleted_blobs\"")
            .body_includes(&audio.id);
        then.status(200).json_body(json!({ "cursor": 2 }));
    });

    qot.cmd()
        .args(["delete", "1"])
        .assert()
        .success()
        .stdout("Deleted: [audio 0:42] call the plumber\n");
    push.assert();
}

#[test]
fn a_push_that_deletes_no_recording_does_not_mention_blobs() {
    let server = MockServer::start();
    empty_pull(&server);
    let with_blobs = server.mock(|when, then| {
        when.method(POST)
            .path("/api/sync/push")
            .body_includes("deleted_blobs");
        then.status(200).json_body(json!({ "cursor": 1 }));
    });
    let plain = server.mock(|when, then| {
        when.method(POST).path("/api/sync/push");
        then.status(200).json_body(json!({ "cursor": 1 }));
    });
    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd().args(["get", "milk"]).assert().success();
    plain.assert();
    with_blobs.assert_calls(0);
}

#[test]
fn editing_a_voice_memo_keeps_its_recording() {
    let qot = Qot::new();
    let (note, audio) = memo("call the plumber");
    qot.save(&note);
    let editor = qot.editor(r#"printf 'call the plumber today\n' > "$1""#);
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", &editor)
        .assert()
        .success()
        .stdout("Edited: [audio 0:42] call the plumber today\n");
    assert_eq!(qot.stored(&note.id()).attachments(), vec![audio]);
}

#[test]
fn a_voice_memo_may_be_edited_down_to_just_its_recording() {
    let qot = Qot::new();
    let (note, audio) = memo("call the plumber");
    qot.save(&note);
    let editor = qot.editor(r#": > "$1""#);
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", &editor)
        .assert()
        .success()
        .stdout("Edited: [audio 0:42]\n");
    let saved = qot.stored(&note.id());
    assert_eq!(saved.content(), "");
    assert_eq!(saved.attachments(), vec![audio]);
    assert!(!saved.is_deleted());
}

#[test]
fn status_counts_a_recording_with_no_text_as_a_note() {
    let qot = Qot::new();
    qot.save(&memo("").0);
    qot.cmd()
        .arg("status")
        .assert()
        .success()
        .stdout(predicate::str::contains("1"));
}
