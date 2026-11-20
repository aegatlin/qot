//! `qot web`: opens the web app that belongs to the server this device
//! syncs with.

use assert_cmd::Command;
use predicates::prelude::*;
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
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

    /// A stand-in for a browser: writes down the address it is given.
    fn browser(&self) -> (PathBuf, PathBuf) {
        let opened = self.dir.path().join("opened");
        let script = self.dir.path().join("browser.sh");
        std::fs::write(
            &script,
            format!("#!/bin/sh\necho \"$1\" > {}\n", opened.display()),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        (script, opened)
    }

    fn cmd(&self) -> Command {
        let mut cmd = Command::cargo_bin("qot").unwrap();
        cmd.env("QOT_DATA_DIR", self.dir.path().join("data"))
            .env_remove("QOT_SERVER");
        cmd
    }

    fn sign_in(&self, server: &str, app_url: Option<&str>) {
        let mut creds = json!({
            "server": server,
            "email": "me@example.com",
            "access_token": "a",
            "refresh_token": "r"
        });
        if let Some(url) = app_url {
            creds["app_url"] = json!(url);
        }
        std::fs::create_dir_all(self.dir.path().join("data")).unwrap();
        std::fs::write(
            self.dir.path().join("data/credentials.json"),
            creds.to_string(),
        )
        .unwrap();
    }

    fn opens(&self) -> String {
        let (browser, opened) = self.browser();
        self.cmd()
            .env("BROWSER", browser)
            .arg("web")
            .assert()
            .success();
        std::fs::read_to_string(opened).unwrap().trim().to_string()
    }
}

#[test]
fn signed_out_opens_the_production_app() {
    let qot = Qot::new();
    assert_eq!(qot.opens(), "https://app.quantumofthought.com");
}

#[test]
fn opens_the_app_the_server_named_at_sign_in() {
    let qot = Qot::new();
    qot.sign_in("https://qot.example.com", Some("https://notes.example.com"));
    assert_eq!(qot.opens(), "https://notes.example.com");
}

#[test]
fn a_sign_in_from_before_app_urls_were_kept_uses_the_known_servers() {
    let qot = Qot::new();
    qot.sign_in("https://staging-api.quantumofthought.com", None);
    assert_eq!(qot.opens(), "https://staging-app.quantumofthought.com");

    let local = Qot::new();
    local.sign_in("http://localhost:4000", None);
    assert_eq!(local.opens(), "http://localhost:5173");
}

#[test]
fn says_the_address_it_opens() {
    let qot = Qot::new();
    let (browser, _) = qot.browser();
    qot.cmd()
        .env("BROWSER", browser)
        .arg("web")
        .assert()
        .success()
        .stdout(predicate::str::contains("https://app.quantumofthought.com"));
}

#[test]
fn a_server_whose_app_is_unknown_is_an_error() {
    let qot = Qot::new();
    qot.sign_in("https://qot.example.com", None);
    let (browser, opened) = qot.browser();
    qot.cmd()
        .env("BROWSER", browser)
        .arg("web")
        .assert()
        .failure()
        .stderr(predicate::str::contains("qot login"));
    assert!(!opened.exists());
}

#[test]
fn a_browser_that_fails_still_leaves_the_address() {
    let qot = Qot::new();
    qot.cmd()
        .env("BROWSER", "false")
        .arg("web")
        .assert()
        .failure()
        .stdout(predicate::str::contains("https://app.quantumofthought.com"));
}
