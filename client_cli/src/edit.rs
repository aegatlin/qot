//! `qot edit`: the note goes to a temporary file, the person's editor opens
//! it, and what they saved comes back. The rules (which editor, what counts
//! as a change) are pure; `open_in_editor` is the I/O.

use std::path::Path;
use std::process::Command;

/// What the editor's result means for the note.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Unchanged,
    /// Nothing but whitespace. Not saved: deleting is `qot delete`'s job, and
    /// an editor mishap shouldn't cost a note.
    Empty,
    Changed(String),
}

/// `$VISUAL`, else `$EDITOR`, else `vi`, as git chooses. Empty values don't
/// count. The result is a command line (it may carry arguments, like
/// `code --wait`), run through `sh`.
pub fn editor_command(visual: Option<String>, editor: Option<String>) -> String {
    [visual, editor]
        .into_iter()
        .flatten()
        .find(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "vi".to_string())
}

/// The file the editor opens: the note, ending with a newline as text files
/// do (`outcome` drops it again).
pub fn file_text(original: &str) -> String {
    if original.ends_with('\n') {
        original.to_string()
    } else {
        format!("{original}\n")
    }
}

/// What the editor left in the file, compared with the note it was given.
/// Editors end files with a newline; one the note didn't have is dropped.
pub fn outcome(original: &str, file: &str) -> Outcome {
    let text = match file.strip_suffix('\n') {
        Some(stripped) if !original.ends_with('\n') => stripped,
        _ => file,
    };
    if text == original {
        Outcome::Unchanged
    } else if text.trim().is_empty() {
        Outcome::Empty
    } else {
        Outcome::Changed(text.to_string())
    }
}

/// Writes `text` to `file`, runs `command` on it with the terminal attached,
/// and returns what the file holds afterwards. The file is removed either
/// way. A failing editor is an error, so a half-finished edit isn't saved.
pub fn open_in_editor(command: &str, file: &Path, text: &str) -> Result<String, String> {
    std::fs::write(file, text).map_err(|e| format!("Can't write {}: {e}", file.display()))?;
    let result = run(command, file).and_then(|()| {
        std::fs::read_to_string(file).map_err(|e| format!("Can't read {}: {e}", file.display()))
    });
    let _ = std::fs::remove_file(file);
    result
}

fn run(command: &str, file: &Path) -> Result<(), String> {
    // `sh -c '<command> "$1"' qot <file>`: the command may have arguments;
    // the file is passed as an argument, never spliced into the script.
    let status = Command::new("sh")
        .arg("-c")
        .arg(format!("{command} \"$1\""))
        .arg("qot")
        .arg(file)
        .status()
        .map_err(|e| format!("Can't start the editor ({command}): {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "The editor ({command}) exited with an error; the note is unchanged."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn some(s: &str) -> Option<String> {
        Some(s.to_string())
    }

    #[test]
    fn visual_then_editor_then_vi() {
        assert_eq!(
            editor_command(some("code --wait"), some("nano")),
            "code --wait"
        );
        assert_eq!(editor_command(None, some("nano")), "nano");
        assert_eq!(editor_command(some("  "), some("nano")), "nano");
        assert_eq!(editor_command(None, None), "vi");
        assert_eq!(editor_command(some(""), some("")), "vi");
    }

    #[test]
    fn the_file_ends_with_a_newline_like_any_text_file() {
        assert_eq!(file_text("get milk"), "get milk\n");
        assert_eq!(file_text("list\n"), "list\n");
        // And reading it back unchanged is no change.
        assert_eq!(
            outcome("get milk", &file_text("get milk")),
            Outcome::Unchanged
        );
    }

    #[test]
    fn the_editors_final_newline_is_not_a_change() {
        assert_eq!(outcome("get milk", "get milk\n"), Outcome::Unchanged);
        assert_eq!(outcome("get milk", "get milk"), Outcome::Unchanged);
    }

    #[test]
    fn a_note_that_ended_with_a_newline_keeps_it() {
        assert_eq!(outcome("list\n", "list\n"), Outcome::Unchanged);
        assert_eq!(
            outcome("list\n", "list\nmore\n"),
            Outcome::Changed("list\nmore\n".into())
        );
    }

    #[test]
    fn only_one_trailing_newline_is_the_editors() {
        assert_eq!(outcome("a", "a\n\n"), Outcome::Changed("a\n".into()));
    }

    #[test]
    fn whitespace_only_is_empty() {
        assert_eq!(outcome("get milk", ""), Outcome::Empty);
        assert_eq!(outcome("get milk", " \n\n"), Outcome::Empty);
    }

    #[test]
    fn new_text_is_a_change() {
        assert_eq!(
            outcome("get milk", "get oat milk\n"),
            Outcome::Changed("get oat milk".into())
        );
    }
}
