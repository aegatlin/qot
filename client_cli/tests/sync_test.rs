//! `qot` against a mock server: the HTTP shape of login and sync. The sync
//! rules themselves are tested in `qot_core::sync`.

use assert_cmd::Command;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use httpmock::prelude::*;
use predicates::prelude::*;
use serde_json::json;
use tempfile::TempDir;

struct Qot {
    dir: TempDir,
}

impl Qot {
    fn new() -> Self {
        Qot {
            dir: TempDir::new().unwrap(),
        }
    }

    fn cmd(&self) -> Command {
        let mut cmd = Command::cargo_bin("qot").unwrap();
        cmd.env("QOT_DATA_DIR", self.dir.path())
            .env_remove("QOT_SERVER");
        cmd
    }

    fn sign_in(&self, server: &MockServer) {
        std::fs::write(
            self.dir.path().join("credentials.json"),
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
}

fn empty_pull(server: &MockServer) -> httpmock::Mock<'_> {
    server.mock(|when, then| {
        when.method(GET).path("/api/sync/pull");
        then.status(200)
            .json_body(json!({ "changes": [], "cursor": 0, "more": false }));
    })
}

#[test]
fn login_shows_the_code_and_saves_credentials() {
    let server = MockServer::start();
    let start = server.mock(|when, then| {
        when.method(POST)
            .path("/api/auth/device")
            .json_body(json!({ "email": "me@example.com" }));
        then.status(200).json_body(json!({
            "device_code": "dev", "user_code": "BCDF-GHJK", "interval": 0, "expires_in": 60
        }));
    });
    let token = server.mock(|when, then| {
        when.method(POST)
            .path("/api/auth/device/token")
            .json_body(json!({ "device_code": "dev" }));
        then.status(200).json_body(json!({
            "access_token": "jwt", "refresh_token": "ref",
            "user": { "id": "u", "email": "me@example.com" }
        }));
    });
    empty_pull(&server);

    let qot = Qot::new();
    qot.cmd()
        .args(["login", "me@example.com", "--server", &server.base_url()])
        .assert()
        .success()
        .stdout(predicate::str::contains("BCDF-GHJK"))
        .stdout(predicate::str::contains("Signed in as me@example.com"));

    start.assert();
    token.assert();
    let saved = std::fs::read_to_string(qot.dir.path().join("credentials.json")).unwrap();
    assert!(saved.contains("\"access_token\": \"jwt\""));
}

#[test]
fn a_denied_login_fails_without_saving_anything() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/api/auth/device");
        then.status(200).json_body(json!({
            "device_code": "dev", "user_code": "BCDF-GHJK", "interval": 0, "expires_in": 60
        }));
    });
    server.mock(|when, then| {
        when.method(POST).path("/api/auth/device/token");
        then.status(400)
            .json_body(json!({ "error": "access_denied" }));
    });

    let qot = Qot::new();
    qot.cmd()
        .args(["login", "me@example.com", "--server", &server.base_url()])
        .assert()
        .failure()
        .stderr(predicate::str::contains("access_denied"));
    assert!(!qot.dir.path().join("credentials.json").exists());
}

#[test]
fn a_new_note_is_pushed_when_signed_in() {
    let server = MockServer::start();
    let push = server.mock(|when, then| {
        when.method(POST)
            .path("/api/sync/push")
            .header("authorization", "Bearer good")
            .body_includes("\"note_id\"");
        then.status(200).json_body(json!({ "cursor": 1 }));
    });
    empty_pull(&server);

    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd().args(["get", "milk"]).assert().success();
    push.assert();

    // Nothing new, so the next sync sends nothing.
    qot.cmd()
        .arg("sync")
        .assert()
        .success()
        .stdout("Synced: 0 sent, 0 received\n");
}

#[test]
fn a_note_from_another_device_shows_up_in_list() {
    let other = qot_core::Note::new("from the phone");
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(GET)
            .path("/api/sync/pull")
            .query_param("since", "0");
        then.status(200).json_body(json!({
            "changes": [{ "seq": 1, "note_id": other.id(), "data": B64.encode(other.to_bytes()) }],
            "cursor": 1, "more": false
        }));
    });
    server.mock(|when, then| {
        when.method(GET)
            .path("/api/sync/pull")
            .query_param("since", "1");
        then.status(200)
            .json_body(json!({ "changes": [], "cursor": 1, "more": false }));
    });

    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout("1. from the phone\n");
    qot.cmd()
        .arg("sync")
        .assert()
        .success()
        .stdout("Synced: 0 sent, 0 received\n");
}

#[test]
fn an_expired_access_token_is_refreshed_once() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(GET)
            .path("/api/sync/pull")
            .header("authorization", "Bearer good");
        then.status(401).json_body(json!({ "error": "expired" }));
    });
    let refresh = server.mock(|when, then| {
        when.method(POST)
            .path("/api/auth/refresh")
            .json_body(json!({ "refresh_token": "refresh" }));
        then.status(200)
            .json_body(json!({ "access_token": "fresh" }));
    });
    server.mock(|when, then| {
        when.method(GET)
            .path("/api/sync/pull")
            .header("authorization", "Bearer fresh");
        then.status(200)
            .json_body(json!({ "changes": [], "cursor": 0, "more": false }));
    });

    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd().arg("sync").assert().success();
    refresh.assert();
    let saved = std::fs::read_to_string(qot.dir.path().join("credentials.json")).unwrap();
    assert!(saved.contains("fresh"));
}

#[test]
fn offline_capture_still_saves_the_note() {
    let qot = Qot::new();
    // Signed in to a server that isn't there.
    std::fs::write(
        qot.dir.path().join("credentials.json"),
        json!({
            "server": "http://127.0.0.1:9", "email": "me@example.com",
            "access_token": "a", "refresh_token": "r"
        })
        .to_string(),
    )
    .unwrap();

    qot.cmd()
        .args(["get", "milk"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Created note: get milk"))
        .stderr(predicate::str::contains("not synced"));

    let server_free = Qot { dir: qot.dir };
    std::fs::remove_file(server_free.dir.path().join("credentials.json")).unwrap();
    server_free
        .cmd()
        .arg("list")
        .assert()
        .success()
        .stdout("1. get milk\n");
}

#[test]
fn logout_forgets_credentials_but_keeps_notes() {
    let server = MockServer::start();
    let revoke = server.mock(|when, then| {
        when.method(POST).path("/api/auth/logout");
        then.status(200).json_body(json!({ "message": "ok" }));
    });
    empty_pull(&server);
    server.mock(|when, then| {
        when.method(POST).path("/api/sync/push");
        then.status(200).json_body(json!({ "cursor": 1 }));
    });

    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd().args(["get", "milk"]).assert().success();
    qot.cmd().arg("logout").assert().success();

    revoke.assert();
    assert!(!qot.dir.path().join("credentials.json").exists());
    qot.cmd().arg("list").assert().stdout("1. get milk\n");
    qot.cmd()
        .arg("sync")
        .assert()
        .failure()
        .stderr(predicate::str::contains("Not signed in"));
}

#[test]
fn every_request_names_the_client_version() {
    let user_agent = format!(
        "qot-cli/{} ({}; {})",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH
    );
    let server = MockServer::start();
    let pull = server.mock(|when, then| {
        when.method(GET)
            .path("/api/sync/pull")
            .header("user-agent", &user_agent);
        then.status(200)
            .json_body(json!({ "changes": [], "cursor": 0, "more": false }));
    });
    let push = server.mock(|when, then| {
        when.method(POST)
            .path("/api/sync/push")
            .header("user-agent", &user_agent);
        then.status(200).json_body(json!({ "cursor": 1 }));
    });

    let qot = Qot::new();
    qot.sign_in(&server);
    qot.cmd().args(["get", "milk"]).assert().success();
    push.assert();
    pull.assert();
}
