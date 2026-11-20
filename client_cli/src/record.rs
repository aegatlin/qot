//! `qot record`: the machine's own recorder writes a voice memo to a file.
//! Like `qot play`, the CLI links no audio library (the static Linux
//! builds have none of the system's sound libraries), so recording works
//! where a recorder is installed. Which recorder is a pure rule; `record`
//! is the I/O.

use std::io::Write;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant};

pub const RECORDER_ENV: &str = "QOT_RECORDER";

/// Set to 1 (or true, on, yes) to ask for text after every recording.
pub const TRANSCRIBE_ENV: &str = "QOT_TRANSCRIBE";

/// Whether a recording should be sent to the server for its text: only
/// when asked, by the flag or the environment.
pub fn wants_text(flag: bool, env: Option<String>) -> bool {
    flag || env.is_some_and(|v| {
        matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "on" | "yes"
        )
    })
}

/// What every client plays: AAC in an .m4a, as the iPhone records.
pub const MEDIA_TYPE: &str = "audio/mp4";
pub const EXTENSION: &str = "m4a";

/// The longest memo, as on the iPhone: ffmpeg stops itself there.
const MAX_SECONDS: u32 = 30 * 60;

/// How long a recorder may take to finish its file after being told to
/// stop, before it is interrupted, and then before it is given up on.
const STOP_GRACE: Duration = Duration::from_secs(3);

/// ffmpeg's input for the default microphone on each system qot knows how
/// to record on. PulseAudio's also covers PipeWire, which answers for it.
fn ffmpeg_input(os: &str) -> Option<&'static str> {
    match os {
        "macos" => Some("-f avfoundation -i :default"),
        "linux" => Some("-f pulse -i default"),
        _ => None,
    }
}

/// The command line that records to a file until told to stop:
/// `$QOT_RECORDER` if it isn't empty (it may carry arguments, and is run
/// through `sh`), else ffmpeg where it is installed and `os` is one whose
/// microphone qot knows how to name. `None` when this machine can't record.
pub fn recorder_command(
    env: Option<String>,
    os: &str,
    installed: impl Fn(&str) -> bool,
) -> Option<String> {
    env.filter(|v| !v.trim().is_empty()).or_else(|| {
        let input = ffmpeg_input(os).filter(|_| installed("ffmpeg"))?;
        Some(format!(
            "ffmpeg -hide_banner -loglevel error -y {input} -t {MAX_SECONDS} \
             -ac 1 -c:a aac -b:a 64k"
        ))
    })
}

/// What to say when this machine can't record.
pub fn no_recorder(os: &str) -> String {
    let how = if ffmpeg_input(os).is_some() {
        "Install ffmpeg"
    } else {
        "qot doesn't know this system's microphone. Install a recorder"
    };
    format!(
        "No recorder found. {how}, or set {RECORDER_ENV} to a command that records \
         to the file it is given (.{EXTENSION}, AAC) until it reads q on its input \
         or is interrupted."
    )
}

/// What ended a recording.
enum Stop {
    /// Enter, or the end of the input.
    Asked,
    /// Ctrl-C, which the recorder got too.
    Interrupted,
}

/// Records to `file` with `command` until Enter or Ctrl-C (or until the
/// recorder stops by itself), and returns how long it ran. The recorder is
/// told to stop the way ffmpeg expects: `q` on its input, then an interrupt
/// if it is still going.
pub fn record(command: &str, file: &Path) -> Result<Duration, String> {
    let (stops, stopped) = mpsc::channel();
    // Ctrl-C reaches the recorder as well (same terminal), which then
    // finishes its file; qot must outlive it to save the note.
    let on_interrupt = stops.clone();
    ctrlc::set_handler(move || {
        let _ = on_interrupt.send(Stop::Interrupted);
    })
    .map_err(|e| format!("Can't listen for Ctrl-C: {e}"))?;

    // The file is an argument, never spliced into the script.
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(format!("{command} \"$1\""))
        .arg("qot")
        .arg(file)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .map_err(|e| format!("Can't start the recorder ({command}): {e}"))?;
    let started = Instant::now();

    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        let _ = stops.send(Stop::Asked);
    });

    let stop = loop {
        match stopped.recv_timeout(Duration::from_millis(50)) {
            Ok(stop) => break Some(stop),
            Err(RecvTimeoutError::Disconnected) => break Some(Stop::Asked),
            Err(RecvTimeoutError::Timeout) => {}
        }
        if exited(&mut child)?.is_some() {
            break None;
        }
    };
    let length = started.elapsed();

    match stop {
        // It stopped by itself: at the longest memo, or because it failed.
        None => {
            let status = child.wait().map_err(|e| e.to_string())?;
            if status.success() {
                Ok(length)
            } else {
                Err(failed(command))
            }
        }
        Some(stop) => {
            let asked = matches!(stop, Stop::Asked);
            if asked && let Some(mut input) = child.stdin.take() {
                let _ = input.write_all(b"q\n");
            }
            drop(child.stdin.take());
            let mut status = wait_for(&mut child, STOP_GRACE)?;
            let interrupted = !asked || status.is_none();
            if status.is_none() {
                interrupt(&child);
                status = wait_for(&mut child, STOP_GRACE)?;
            }
            match status {
                None => {
                    let _ = child.kill();
                    let _ = child.wait();
                    Err(format!("The recorder ({command}) didn't stop."))
                }
                // An interrupted recorder reports failure (ffmpeg: 255)
                // with a good file, so there the file decides.
                Some(status) if !status.success() && !interrupted => Err(failed(command)),
                Some(_) => Ok(length),
            }
        }
    }
}

fn failed(command: &str) -> String {
    format!(
        "The recorder ({command}) exited with an error. Check that this terminal may use \
         the microphone, or set {RECORDER_ENV} to use another recorder."
    )
}

fn exited(child: &mut Child) -> Result<Option<ExitStatus>, String> {
    child.try_wait().map_err(|e| e.to_string())
}

/// The recorder's exit status, if it exited within `limit`.
fn wait_for(child: &mut Child, limit: Duration) -> Result<Option<ExitStatus>, String> {
    let deadline = Instant::now() + limit;
    loop {
        if let Some(status) = exited(child)? {
            return Ok(Some(status));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Sends the recorder (the shell and what it runs) an interrupt.
fn interrupt(child: &Child) {
    let _ = Command::new("kill")
        .arg("-INT")
        .arg(child.id().to_string())
        .status();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_is_asked_for_only_by_the_flag_or_the_environment() {
        assert!(!wants_text(false, None));
        assert!(wants_text(true, None));
        assert!(wants_text(false, Some("1".into())));
        assert!(wants_text(false, Some(" On ".into())));
        assert!(!wants_text(false, Some("0".into())));
        assert!(!wants_text(false, Some("".into())));
    }

    #[test]
    fn the_environment_names_the_recorder() {
        let command = recorder_command(Some("rec -c 1".into()), "freebsd", |_| false);
        assert_eq!(command.as_deref(), Some("rec -c 1"));
    }

    #[test]
    fn an_empty_variable_does_not_count() {
        assert_eq!(recorder_command(Some(" ".into()), "macos", |_| false), None);
    }

    #[test]
    fn ffmpeg_records_the_default_microphone_as_aac() {
        let mac = recorder_command(None, "macos", |p| p == "ffmpeg").unwrap();
        assert!(mac.contains("-f avfoundation -i :default"), "{mac}");
        assert!(mac.contains("-c:a aac"), "{mac}");
        assert!(mac.contains("-t 1800"), "{mac}");
        let linux = recorder_command(None, "linux", |p| p == "ffmpeg").unwrap();
        assert!(linux.contains("-f pulse -i default"), "{linux}");
    }

    #[test]
    fn no_ffmpeg_is_no_recorder() {
        assert_eq!(recorder_command(None, "macos", |_| false), None);
        assert!(no_recorder("macos").contains("Install ffmpeg"));
    }

    #[test]
    fn a_system_qot_does_not_know_needs_its_own_recorder() {
        assert_eq!(recorder_command(None, "freebsd", |_| true), None);
        let text = no_recorder("freebsd");
        assert!(text.contains(RECORDER_ENV), "{text}");
        assert!(!text.contains("Install ffmpeg"), "{text}");
    }
}
