//! `qot record`: a voice memo made in the terminal. The recorder is the
//! machine's own (`$QOT_RECORDER` here: a script that writes a file and
//! waits to be told to stop), so no test needs a microphone.

use assert_cmd::Command;
use httpmock::prelude::*;
use predicates::prelude::*;
use qot_core::sync::SyncState;
use qot_core::{AUDIO, AttachmentText, Note};
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
            .env("QOT_RECORDER", self.recorder(RECORDS))
            .env_remove("QOT_PLAYER")
            .env_remove("QOT_SERVER");
        cmd
    }

    fn script(&self, name: &str, body: &str) -> PathBuf {
        let path = self.dir.path().join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn recorder(&self, body: &str) -> PathBuf {
        self.script("rec.sh", body)
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

    fn notes(&self) -> Vec<Note> {
        let mut paths: Vec<PathBuf> = std::fs::read_dir(self.data().join("notes"))
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect();
        paths.sort();
        paths
            .iter()
            .map(|p| Note::from_bytes(&std::fs::read(p).unwrap()).unwrap())
            .collect()
    }

    fn blob(&self, id: &str) -> PathBuf {
        self.data().join("blobs").join(id)
    }

    fn state(&self) -> SyncState {
        serde_json::from_slice(&std::fs::read(self.data().join("sync.json")).unwrap()).unwrap()
    }
}

/// Records "fake audio", then waits to be told to stop, as ffmpeg does.
const RECORDS: &str = r#"printf 'fake audio' > "$1"
read line"#;

fn pull_and_push(server: &MockServer) {
    server.mock(|when, then| {
        when.method(GET).path("/api/sync/pull");
        then.status(200)
            .json_body(json!({ "changes": [], "cursor": 0, "more": false }));
    });
    server.mock(|when, then| {
        when.method(POST).path("/api/sync/push");
        then.status(200).json_body(json!({ "cursor": 1 }));
    });
}

#[test]
fn record_saves_a_note_with_the_recording() {
    let qot = Qot::new();
    qot.cmd()
        .arg("record")
        .write_stdin("\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("Enter to stop"))
        .stdout(predicate::str::contains("Recorded: [audio 0:0"));

    let notes = qot.notes();
    assert_eq!(notes.len(), 1);
    assert_eq!(notes[0].content(), "");
    let attachments = notes[0].attachments();
    assert_eq!(attachments.len(), 1);
    let audio = &attachments[0];
    assert_eq!(audio.kind, AUDIO);
    assert_eq!(audio.media_type, "audio/mp4");
    assert_eq!(audio.size, 10);
    assert!(audio.duration_ms.is_some());
    // Nothing here will transcribe it.
    assert_eq!(audio.text, AttachmentText::None);
    assert_eq!(std::fs::read(qot.blob(&audio.id)).unwrap(), b"fake audio");
    // Nothing is left where recordings are made.
    let making = qot.data().join("recordings");
    assert!(!making.exists() || std::fs::read_dir(making).unwrap().next().is_none());

    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::starts_with("1. [audio 0:0"));
}

#[test]
fn words_after_record_are_the_notes_text() {
    let qot = Qot::new();
    qot.cmd()
        .args(["record", "call", "the", "plumber"])
        .write_stdin("\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("call the plumber"));
    assert_eq!(qot.notes()[0].content(), "call the plumber");
}

#[test]
fn the_recorder_is_given_a_file_named_m4a() {
    let qot = Qot::new();
    let name = qot.dir.path().join("name");
    let recorder = qot.script(
        "named.sh",
        &format!("echo \"$1\" > {}\n{RECORDS}", name.display()),
    );
    qot.cmd()
        .env("QOT_RECORDER", recorder)
        .arg("record")
        .write_stdin("\n")
        .assert()
        .success();
    assert!(
        std::fs::read_to_string(name)
            .unwrap()
            .trim()
            .ends_with(".m4a")
    );
}

#[test]
fn a_recorder_that_fails_saves_nothing() {
    let qot = Qot::new();
    let recorder = qot.script("broken.sh", "echo 'no microphone' >&2\nexit 1");
    qot.cmd()
        .env("QOT_RECORDER", recorder)
        .arg("record")
        .assert()
        .failure()
        .stderr(predicate::str::contains("recorder"));
    assert!(qot.notes().is_empty());
}

#[test]
fn a_recording_with_nothing_in_it_saves_nothing() {
    let qot = Qot::new();
    let recorder = qot.script("silent.sh", ": > \"$1\"\nread line");
    qot.cmd()
        .env("QOT_RECORDER", recorder)
        .arg("record")
        .write_stdin("\n")
        .assert()
        .failure()
        .stderr(predicate::str::contains("empty"));
    assert!(qot.notes().is_empty());
}

#[test]
fn without_a_recorder_it_says_what_to_install() {
    let qot = Qot::new();
    qot.cmd()
        .env_remove("QOT_RECORDER")
        .env("PATH", qot.dir.path())
        .arg("record")
        .assert()
        .failure()
        .stderr(predicate::str::contains("ffmpeg"))
        .stderr(predicate::str::contains("QOT_RECORDER"));
    assert!(qot.notes().is_empty());
}

#[test]
fn signed_in_the_note_goes_up_and_then_the_recording() {
    let server = MockServer::start();
    pull_and_push(&server);
    let upload = server.mock(|when, then| {
        when.method(PUT)
            .path_includes("/api/blobs/")
            .query_param_exists("note_id")
            .header("authorization", "Bearer good")
            .body("fake audio");
        then.status(204);
    });
    let qot = Qot::new();
    qot.sign_in(&server);

    qot.cmd()
        .arg("record")
        .write_stdin("\n")
        .assert()
        .success()
        .stderr("");

    upload.assert();
    let audio = &qot.notes()[0].attachments()[0];
    assert!(qot.state().uploaded.contains(&audio.id));
    // Kept: `qot play` uses it, and a later sign-in elsewhere needs it.
    assert!(qot.blob(&audio.id).exists());

    // Nothing more to send.
    qot.cmd().arg("sync").assert().success();
    upload.assert_calls(1);
}

#[test]
fn a_recording_made_signed_out_goes_up_at_the_next_sync() {
    let server = MockServer::start();
    pull_and_push(&server);
    let upload = server.mock(|when, then| {
        when.method(PUT).path_includes("/api/blobs/");
        then.status(204);
    });
    let qot = Qot::new();
    qot.cmd().arg("record").write_stdin("\n").assert().success();
    upload.assert_calls(0);

    qot.sign_in(&server);
    qot.cmd().arg("sync").assert().success();
    upload.assert_calls(1);
}

#[test]
fn an_upload_the_server_says_was_deleted_is_dropped() {
    let server = MockServer::start();
    pull_and_push(&server);
    server.mock(|when, then| {
        when.method(PUT).path_includes("/api/blobs/");
        then.status(410).json_body(json!({ "error": "deleted" }));
    });
    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd().arg("record").write_stdin("\n").assert().success();
    let audio = &qot.notes()[0].attachments()[0];
    assert!(!qot.blob(&audio.id).exists());
}

#[test]
fn an_upload_over_the_quota_is_reported_and_the_file_kept() {
    let server = MockServer::start();
    pull_and_push(&server);
    server.mock(|when, then| {
        when.method(PUT).path_includes("/api/blobs/");
        then.status(403)
            .json_body(json!({ "error": "quota_exceeded" }));
    });
    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd()
        .arg("record")
        .write_stdin("\n")
        .assert()
        .success()
        .stderr(predicate::str::contains("not synced"));
    let audio = &qot.notes()[0].attachments()[0];
    assert!(qot.blob(&audio.id).exists());
}

#[test]
fn play_uses_the_recording_on_this_device() {
    let qot = Qot::new();
    qot.cmd().arg("record").write_stdin("\n").assert().success();
    let heard = qot.dir.path().join("heard");
    let player = qot.script("play.sh", &format!("cp \"$1\" {}", heard.display()));

    // Signed out, and no server asked.
    qot.cmd()
        .env("QOT_PLAYER", player)
        .args(["play", "1"])
        .assert()
        .success();
    assert_eq!(std::fs::read(heard).unwrap(), b"fake audio");
}

#[test]
fn deleting_the_note_removes_the_recording_from_this_device() {
    let qot = Qot::new();
    qot.cmd().arg("record").write_stdin("\n").assert().success();
    let audio = qot.notes()[0].attachments()[0].clone();
    assert!(qot.blob(&audio.id).exists());

    qot.cmd().args(["delete", "1"]).assert().success();
    assert!(!qot.blob(&audio.id).exists());
}
