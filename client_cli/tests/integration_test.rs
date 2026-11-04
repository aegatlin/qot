use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::TempDir;

/// A `qot` command with its own empty note store, so tests never read or
/// write the real one and never see each other's notes.
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
        cmd.env("QOT_DATA_DIR", self.dir.path());
        cmd
    }
}

#[test]
fn test_no_args_shows_help() {
    let qot = Qot::new();
    qot.cmd()
        .assert()
        .success()
        .stdout(predicate::str::contains("Usage"))
        .stdout(predicate::str::contains("EXAMPLES"));
}

#[test]
fn test_create_note_with_single_word() {
    let qot = Qot::new();
    qot.cmd()
        .arg("hello")
        .assert()
        .success()
        .stdout(predicate::str::contains("Created note"))
        .stdout(predicate::str::contains("hello"));
}

#[test]
fn test_create_note_with_multiple_words() {
    let qot = Qot::new();
    qot.cmd()
        .args(["get", "milk"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Created note"))
        .stdout(predicate::str::contains("get milk"));
}

#[test]
fn test_list_shows_placeholder() {
    Qot::new()
        .cmd()
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("No notes yet"));
}

#[test]
fn test_create_note_with_special_characters() {
    let qot = Qot::new();
    qot.cmd()
        .args(["buy", "eggs", "&", "milk"])
        .assert()
        .success()
        .stdout(predicate::str::contains("buy eggs & milk"));
}

#[test]
fn test_delete_with_no_index_shows_usage() {
    let qot = Qot::new();
    qot.cmd()
        .arg("delete")
        .assert()
        .failure()
        .stderr(predicate::str::contains("Usage: qot delete <INDEX>"));
}

#[test]
fn test_delete_with_invalid_index() {
    let qot = Qot::new();
    qot.cmd()
        .args(["delete", "abc"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("invalid digit found in string"));
}

#[test]
fn test_list_shows_numbered_indices() {
    let qot = Qot::new();
    qot.cmd().args(["add", "first", "note"]).assert().success();

    qot.cmd().args(["add", "second", "note"]).assert().success();

    // Now list should show numbered indices
    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::is_match(r"\d+\. .+").unwrap());
}

#[test]
fn test_get_milk_then_list_then_delete() {
    let qot = Qot::new();
    qot.cmd().args(["get", "milk"]).assert().success();
    qot.cmd().args(["add", "call", "mum"]).assert().success();

    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout("1. get milk\n2. call mum\n");

    qot.cmd()
        .args(["delete", "1"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Deleted: get milk"));

    qot.cmd()
        .arg("list")
        .assert()
        .success()
        .stdout("1. call mum\n");
}

#[test]
fn version_prints_the_crate_version() {
    let qot = Qot::new();
    qot.cmd()
        .arg("--version")
        .assert()
        .success()
        .stdout(format!("qot {}\n", env!("CARGO_PKG_VERSION")));
}
