//! `qot status`: who you are, where you sync, and what is waiting, offline.

use assert_cmd::Command;
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

    fn sign_in(&self, server: &str) {
        std::fs::write(
            self.dir.path().join("credentials.json"),
            json!({
                "server": server,
                "email": "me@example.com",
                "access_token": "secret-access",
                "refresh_token": "secret-refresh"
            })
            .to_string(),
        )
        .unwrap();
    }
}

#[test]
fn signed_out_says_so_and_how_to_sign_in() {
    let qot = Qot::new();
    qot.cmd()
        .arg("status")
        .assert()
        .success()
        .stdout(predicate::str::contains("not signed in"))
        .stdout(predicate::str::contains("qot login <email>"))
        .stdout(predicate::str::contains("Server").not())
        .stdout(predicate::str::contains("Notes     0"))
        .stdout(predicate::str::contains(
            qot.dir.path().to_string_lossy().as_ref(),
        ))
        .stdout(predicate::str::contains(env!("CARGO_PKG_VERSION")));
}

#[test]
fn signed_in_shows_account_and_labelled_server_but_no_tokens() {
    let qot = Qot::new();
    qot.sign_in("https://api.quantumofthought.com");
    qot.cmd()
        .arg("status")
        .assert()
        .success()
        .stdout(predicate::str::contains("Account   me@example.com"))
        .stdout(predicate::str::contains(
            "Server    https://api.quantumofthought.com (production)",
        ))
        .stdout(predicate::str::contains("secret").not());
}

#[test]
fn status_makes_no_network_calls() {
    let server = MockServer::start();
    let any = server.mock(|when, then| {
        when.any_request();
        then.status(500);
    });
    let qot = Qot::new();
    qot.sign_in(&server.base_url());
    qot.cmd()
        .arg("status")
        .assert()
        .success()
        .stdout(predicate::str::contains("(local)"));
    any.assert_calls(0);
}

#[test]
fn counts_live_notes_and_those_waiting_to_sync() {
    let qot = Qot::new();
    for words in [["get", "milk"], ["buy", "eggs"], ["call", "mom"]] {
        qot.cmd().args(words).assert().success();
    }
    qot.cmd().args(["delete", "3"]).assert().success();
    qot.cmd()
        .arg("status")
        .assert()
        .success()
        // The deleted note is hidden but its tombstone still has to go up.
        .stdout(predicate::str::contains("Notes     2, 3 not synced yet"));
}

#[test]
fn says_all_synced_after_a_sync() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/api/sync/push");
        then.status(200).json_body(json!({ "cursor": 1 }));
    });
    server.mock(|when, then| {
        when.method(GET).path("/api/sync/pull");
        then.status(200)
            .json_body(json!({ "changes": [], "cursor": 1, "more": false }));
    });
    let qot = Qot::new();
    qot.sign_in(&server.base_url());
    qot.cmd().args(["get", "milk"]).assert().success();
    qot.cmd()
        .arg("status")
        .assert()
        .success()
        .stdout(predicate::str::contains("Notes     1, all synced"));
}
