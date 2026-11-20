//! `qot play`: a note's recording goes to a temporary file and the
//! machine's own audio player plays it. The CLI links no audio library (it
//! would need the system's sound libraries, which the static Linux builds
//! don't have). Which player is a pure rule; `play_file` is the I/O.

use std::path::Path;
use std::process::Command;

pub const PLAYER_ENV: &str = "QOT_PLAYER";

/// Players tried when `$QOT_PLAYER` isn't set, in order: the program, and
/// the command line that plays a file with it and then exits, showing no
/// window. `afplay` comes with macOS.
const PLAYERS: [(&str, &str); 3] = [
    ("afplay", "afplay"),
    ("ffplay", "ffplay -nodisp -autoexit -loglevel error"),
    ("mpv", "mpv --no-video --really-quiet"),
];

/// The command line that plays a file: `$QOT_PLAYER` if it isn't empty
/// (it may carry arguments, and is run through `sh`), else the first of
/// `PLAYERS` that `installed` says is here. `None` when there is none.
pub fn player_command(env: Option<String>, installed: impl Fn(&str) -> bool) -> Option<String> {
    env.filter(|v| !v.trim().is_empty()).or_else(|| {
        PLAYERS
            .iter()
            .find(|(program, _)| installed(program))
            .map(|(_, command)| command.to_string())
    })
}

/// What to say when no player was found.
pub fn no_player() -> String {
    format!(
        "No audio player found. Install ffmpeg (for ffplay) or mpv, or set {PLAYER_ENV} \
         to a command that plays a file. To get the file instead: qot export --dir <dir>"
    )
}

/// Whether `program` is an executable on `$PATH`.
pub fn installed(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| is_executable(&dir.join(program)))
    })
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Writes `bytes` to `file`, plays it with `command` and waits for the
/// player to finish. The file is removed either way.
pub fn play_file(command: &str, file: &Path, bytes: &[u8]) -> Result<(), String> {
    std::fs::write(file, bytes).map_err(|e| format!("Can't write {}: {e}", file.display()))?;
    let result = run(command, file);
    let _ = std::fs::remove_file(file);
    result
}

fn run(command: &str, file: &Path) -> Result<(), String> {
    // As `qot edit` runs the editor: the file is an argument, never spliced
    // into the script.
    let status = Command::new("sh")
        .arg("-c")
        .arg(format!("{command} \"$1\""))
        .arg("qot")
        .arg(file)
        .status()
        .map_err(|e| format!("Can't start the player ({command}): {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "The player ({command}) exited with an error. Set {PLAYER_ENV} to use another."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_environment_names_the_player() {
        let command = player_command(Some("vlc --play-and-exit".into()), |_| true);
        assert_eq!(command.as_deref(), Some("vlc --play-and-exit"));
    }

    #[test]
    fn an_empty_variable_does_not_count() {
        let command = player_command(Some("  ".into()), |p| p == "afplay");
        assert_eq!(command.as_deref(), Some("afplay"));
    }

    #[test]
    fn the_first_installed_player_is_used_with_its_quiet_arguments() {
        let command = player_command(None, |p| p == "mpv" || p == "ffplay");
        assert_eq!(
            command.as_deref(),
            Some("ffplay -nodisp -autoexit -loglevel error")
        );
    }

    #[test]
    fn no_player_is_none() {
        assert_eq!(player_command(None, |_| false), None);
        assert!(no_player().contains("QOT_PLAYER"));
    }
}
