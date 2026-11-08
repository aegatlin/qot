//! `qot edit <n>`: the note opens in $VISUAL / $EDITOR. The "editor" in these
//! tests is a small shell script, so nothing interactive runs.

use assert_cmd::Command;
use predicates::prelude::*;
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

    /// A `qot` with its own store and no editor settings from the person
    /// running the tests.
    fn cmd(&self) -> Command {
        let mut cmd = Command::cargo_bin("qot").unwrap();
        cmd.env("QOT_DATA_DIR", self.dir.path().join("data"))
            .env_remove("VISUAL")
            .env_remove("EDITOR")
            .env_remove("QOT_SERVER");
        cmd
    }

    fn add(&self, words: &[&str]) {
        self.cmd().args(words).assert().success();
    }

    /// An executable script standing in for an editor; `$1` is the file.
    fn editor(&self, name: &str, body: &str) -> PathBuf {
        let path = self.dir.path().join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn list(&self) -> String {
        let out = self.cmd().arg("list").output().unwrap();
        String::from_utf8(out.stdout).unwrap()
    }
}

#[test]
fn edit_saves_what_the_editor_wrote() {
    let qot = Qot::new();
    qot.add(&["get", "milk"]);
    let editor = qot.editor("ed.sh", r#"printf 'get oat milk\n' > "$1""#);
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", &editor)
        .assert()
        .success()
        .stdout(predicate::str::contains("Edited: get oat milk"));
    // The editor's final newline isn't kept as part of the note.
    assert_eq!(qot.list(), "1. get oat milk\n");
}

#[test]
fn the_editor_sees_the_current_text() {
    let qot = Qot::new();
    qot.add(&["first"]);
    qot.add(&["second"]);
    // Appends a line, so the result shows what the file held.
    let editor = qot.editor("ed.sh", r#"printf 'more\n' >> "$1""#);
    qot.cmd()
        .args(["edit", "2"])
        .env("EDITOR", &editor)
        .assert()
        .success();
    assert_eq!(qot.list(), "1. first\n2. second\nmore\n");
}

#[test]
fn e_is_short_for_edit() {
    let qot = Qot::new();
    qot.add(&["x"]);
    let editor = qot.editor("ed.sh", r#"printf 'y' > "$1""#);
    qot.cmd()
        .args(["e", "1"])
        .env("EDITOR", &editor)
        .assert()
        .success();
    assert_eq!(qot.list(), "1. y\n");
}

#[test]
fn visual_wins_over_editor() {
    let qot = Qot::new();
    qot.add(&["x"]);
    let visual = qot.editor("visual.sh", r#"printf 'from visual' > "$1""#);
    let editor = qot.editor("editor.sh", r#"printf 'from editor' > "$1""#);
    qot.cmd()
        .args(["edit", "1"])
        .env("VISUAL", &visual)
        .env("EDITOR", &editor)
        .assert()
        .success();
    assert_eq!(qot.list(), "1. from visual\n");
}

#[test]
fn an_editor_with_arguments_works() {
    // Like `code --wait`: the variable is a command line, not just a path.
    let qot = Qot::new();
    qot.add(&["x"]);
    let editor = qot.editor("ed.sh", r#"[ "$1" = "--wait" ] && printf 'waited' > "$2""#);
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", format!("{} --wait", editor.display()))
        .assert()
        .success();
    assert_eq!(qot.list(), "1. waited\n");
}

#[test]
fn unchanged_text_is_not_an_edit() {
    let qot = Qot::new();
    qot.add(&["same"]);
    let editor = qot.editor("ed.sh", "true");
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", &editor)
        .assert()
        .success()
        .stdout(predicate::str::contains("No changes"));
    assert_eq!(qot.list(), "1. same\n");
}

#[test]
fn an_emptied_note_is_not_saved_or_deleted() {
    let qot = Qot::new();
    qot.add(&["keep", "me"]);
    let editor = qot.editor("ed.sh", r#": > "$1""#);
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", &editor)
        .assert()
        .failure()
        .stderr(predicate::str::contains("qot delete 1"));
    assert_eq!(qot.list(), "1. keep me\n");
}

#[test]
fn a_failing_editor_leaves_the_note_alone() {
    let qot = Qot::new();
    qot.add(&["keep"]);
    let editor = qot.editor("ed.sh", r#"printf 'half-typed' > "$1"; exit 1"#);
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", &editor)
        .assert()
        .failure()
        .stderr(predicate::str::contains("unchanged"));
    assert_eq!(qot.list(), "1. keep\n");
}

#[test]
fn editing_a_note_that_isnt_there_is_an_error() {
    let qot = Qot::new();
    qot.add(&["only"]);
    let editor = qot.editor("ed.sh", r#"printf 'never' > "$1""#);
    qot.cmd()
        .args(["edit", "2"])
        .env("EDITOR", &editor)
        .assert()
        .failure()
        .stderr(predicate::str::contains("out of range"));
}

#[test]
fn the_temp_file_is_removed() {
    let qot = Qot::new();
    qot.add(&["x"]);
    // The editor records which file it was given.
    let log = qot.dir.path().join("opened");
    let editor = qot.editor(
        "ed.sh",
        &format!(
            r#"printf '%s' "$1" > '{}'; printf 'y' > "$1""#,
            log.display()
        ),
    );
    qot.cmd()
        .args(["edit", "1"])
        .env("EDITOR", &editor)
        .assert()
        .success();
    let opened = std::fs::read_to_string(&log).unwrap();
    assert!(
        !std::path::Path::new(&opened).exists(),
        "{opened} was left behind"
    );
}
