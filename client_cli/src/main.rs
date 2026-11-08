mod api;
mod credentials;
mod edit;
mod service;
mod storage;

use api::{Api, Poll};
use clap::{CommandFactory, Parser, Subcommand};
use credentials::Credentials;
use service::{Counts, NoteService};
use std::process::exit;
use std::time::{Duration, Instant};

/// Where `qot login` signs in unless told otherwise.
const SERVER_ENV: &str = "QOT_SERVER";
const DEFAULT_SERVER: &str = "https://api.quantumofthought.com";
/// How long a background sync after a command may take before giving up.
const QUICK_SYNC: Duration = Duration::from_secs(3);

#[derive(Parser)]
#[command(name = "qot")]
#[command(about = "Quantum of Thought - A note capture CLI")]
#[command(after_help = "EXAMPLES:\n  \
    qot get milk          # Create a new note (implicit)\n  \
    qot add buy eggs      # Create a new note (explicit)\n  \
    qot list              # Show all notes\n  \
    qot edit 2            # Edit note #2 in $VISUAL / $EDITOR\n  \
    qot delete 2          # Delete note #2\n  \
    qot login me@x.com    # Sign in to sync between devices\n  \
    qot sync              # Sync now\n  \
    qot status            # Account, server and what's waiting to sync\n  \
    qot export > n.json   # All notes as JSON")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Note content (when not using a subcommand)
    #[arg(trailing_var_arg = true, allow_hyphen_values = true, hide = true)]
    content: Vec<String>,
}

#[derive(Subcommand)]
enum Commands {
    /// Create a new note
    #[command(visible_alias = "a")]
    Add {
        /// The content of the note
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        content: Vec<String>,
    },
    /// List all notes with their indices
    #[command(visible_alias = "l")]
    List,
    /// Edit a note in $VISUAL or $EDITOR (default vi)
    #[command(visible_alias = "e")]
    Edit {
        /// The index number shown in 'qot list' (e.g., 1, 2, 3)
        index: usize,
    },
    /// Delete a note by its index number
    #[command(visible_alias = "d")]
    Delete {
        /// The index number shown in 'qot list' (e.g., 1, 2, 3)
        index: usize,
    },
    /// Sign in so notes sync between your devices
    Login {
        email: String,
        /// Server to sign in to (default: $QOT_SERVER, else https://api.quantumofthought.com)
        #[arg(long)]
        server: Option<String>,
    },
    /// Sign out on this device (notes stay)
    Logout,
    /// Push local changes and pull everyone else's
    #[command(visible_alias = "s")]
    Sync,
    /// Print every note as JSON (id, created_at, content)
    Export,
    /// Show the account, server and notes on this device (no network)
    Status,
    /// Delete your account and synced notes on the server (notes on this device stay)
    DeleteAccount,
}

fn main() {
    let cli = Cli::parse();

    let mut notes =
        NoteService::new().unwrap_or_else(|e| fail(&format!("Failed to initialize: {e}")));

    match cli.command {
        Some(Commands::Add { content }) => add(&mut notes, &content),
        Some(Commands::List) => {
            quick_sync(&mut notes);
            list_notes(&mut notes);
        }
        Some(Commands::Edit { index }) => edit_note(&mut notes, index),
        Some(Commands::Delete { index }) => {
            delete_note(&mut notes, index);
            quick_sync(&mut notes);
        }
        Some(Commands::Login { email, server }) => login(&mut notes, &email, server),
        Some(Commands::Logout) => logout(&notes),
        Some(Commands::Sync) => sync_now(&mut notes),
        Some(Commands::Export) => {
            quick_sync(&mut notes);
            match notes.export() {
                Ok(json) => println!("{json}"),
                Err(e) => fail(&format!("Error exporting notes: {e}")),
            }
        }
        Some(Commands::DeleteAccount) => delete_account(&notes),
        Some(Commands::Status) => status(&notes),
        None if cli.content.is_empty() => {
            Cli::command().print_help().unwrap();
        }
        None => add(&mut notes, &cli.content),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    exit(1)
}

fn add(notes: &mut NoteService, words: &[String]) {
    if words.is_empty() {
        fail("Error: note content cannot be empty");
    }
    match notes.create(&words.join(" ")) {
        Ok(note) => println!("Created note: {}", note.content),
        Err(e) => fail(&format!("Error creating note: {e}")),
    }
    quick_sync(notes);
}

fn list_notes(notes: &mut NoteService) {
    match notes.list() {
        Ok(list) if list.is_empty() => println!("No notes yet. Create one with: qot get milk"),
        Ok(list) => {
            for (i, note) in list.iter().enumerate() {
                println!("{}. {}", i + 1, note.content);
            }
        }
        Err(e) => fail(&format!("Error listing notes: {e}")),
    }
}

/// Opens the note in the person's editor and saves what they wrote. The
/// note on disk is only touched once the editor has exited cleanly.
fn edit_note(notes: &mut NoteService, index: usize) {
    let base = notes
        .live_note(index)
        .unwrap_or_else(|e| fail(&format!("Error editing note: {e}")));
    let original = base.content();
    let command = edit::editor_command(std::env::var("VISUAL").ok(), std::env::var("EDITOR").ok());
    let file = std::env::temp_dir().join(format!("qot-{}-{}.txt", base.id(), std::process::id()));
    let written = edit::open_in_editor(&command, &file, &edit::file_text(&original))
        .unwrap_or_else(|e| fail(&e));
    match edit::outcome(&original, &written) {
        edit::Outcome::Unchanged => println!("No changes."),
        edit::Outcome::Empty => fail(&format!(
            "The note is empty, so it wasn't saved. To delete it, run: qot delete {index}"
        )),
        edit::Outcome::Changed(text) => {
            match notes.save_edit(&base, &text) {
                Ok(note) => println!("Edited: {}", note.content),
                Err(e) => fail(&format!("Error saving note: {e}")),
            }
            quick_sync(notes);
        }
    }
}

fn delete_note(notes: &mut NoteService, index: usize) {
    match notes.delete_by_index(index) {
        Ok(content) => println!("Deleted: {content}"),
        Err(e) => fail(&format!("Error deleting note: {e}")),
    }
}

fn signed_in(notes: &NoteService) -> Option<Credentials> {
    credentials::load(notes.dir()).unwrap_or_else(|e| fail(&e))
}

/// A best-effort sync around everyday commands. Offline is normal: the
/// note is saved locally either way and goes up on the next sync.
fn quick_sync(notes: &mut NoteService) {
    if let Some(mut creds) = signed_in(notes) {
        let api = Api::new(&creds.server, QUICK_SYNC);
        if let Err(e) = notes.sync(&api, &mut creds) {
            eprintln!("(not synced: {e})");
        }
    }
}

fn sync_now(notes: &mut NoteService) {
    let mut creds =
        signed_in(notes).unwrap_or_else(|| fail("Not signed in. Run: qot login <email>"));
    let api = Api::new(&creds.server, Duration::from_secs(30));
    match notes.sync(&api, &mut creds) {
        Ok(r) => println!("Synced: {} sent, {} received", r.pushed, r.pulled),
        Err(e) => fail(&format!("Sync failed: {e}")),
    }
}

/// The server to sign in to: `--server`, else `$QOT_SERVER` (if not empty),
/// else production.
fn resolve_server(flag: Option<String>, env: Option<String>) -> String {
    flag.or_else(|| env.filter(|s| !s.is_empty()))
        .unwrap_or_else(|| DEFAULT_SERVER.to_string())
}

fn login(notes: &mut NoteService, email: &str, server: Option<String>) {
    let server = resolve_server(server, std::env::var(SERVER_ENV).ok());
    let api = Api::new(&server, Duration::from_secs(30));

    let start = api
        .start_device_login(email)
        .unwrap_or_else(|e| fail(&format!("Couldn't start sign-in: {e}")));

    println!("We emailed a sign-in link to {email}.");
    println!("Open it and enter this code:\n\n    {}\n", start.user_code);
    println!("Waiting for you to confirm…");

    let deadline = Instant::now() + Duration::from_secs(start.expires_in);
    let tokens = loop {
        match api.poll_device_login(&start.device_code) {
            Ok(Poll::Done(tokens)) => break tokens,
            Ok(Poll::Pending) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_secs(start.interval))
            }
            Ok(Poll::Pending) => fail("The sign-in link expired. Run qot login again."),
            Ok(Poll::Failed(reason)) => fail(&format!("Sign-in failed: {reason}")),
            // A dropped connection while waiting is worth another try.
            Err(_) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_secs(start.interval.max(1)))
            }
            Err(e) => fail(&format!("Sign-in failed: {e}")),
        }
    };

    let mut creds = Credentials {
        server,
        email: email.to_string(),
        tokens,
    };
    // A different account must not inherit this device's sync position.
    notes.forget_sync_state().unwrap_or_else(|e| fail(&e));
    credentials::save(notes.dir(), &creds).unwrap_or_else(|e| fail(&e));
    println!("Signed in as {email}.");
    if let Some(url) = &start.app_url {
        println!(
            "Your notes are on the web too: {url} (the browser you confirmed in is signed in)."
        );
    }

    match notes.sync(&api, &mut creds) {
        Ok(r) => println!("Synced: {} sent, {} received", r.pushed, r.pulled),
        Err(e) => eprintln!("(not synced yet: {e})"),
    }
}

fn delete_account(notes: &NoteService) {
    let mut creds =
        signed_in(notes).unwrap_or_else(|| fail("Not signed in. Run: qot login <email>"));
    println!(
        "This deletes the account {} on {} and every note synced there.",
        creds.email, creds.server
    );
    println!("Notes on this device stay. Type the email to confirm:");
    let mut typed = String::new();
    std::io::stdin()
        .read_line(&mut typed)
        .unwrap_or_else(|e| fail(&format!("Not deleted: {e}")));
    let typed = typed.trim();
    if !typed.eq_ignore_ascii_case(creds.email.trim()) {
        fail("Not deleted: that isn't the email you're signed in with.");
    }

    let api = Api::new(&creds.server, Duration::from_secs(30));
    notes
        .delete_account(&api, &mut creds, typed)
        .unwrap_or_else(|e| fail(&format!("Not deleted: {e}")));
    credentials::remove(notes.dir()).unwrap_or_else(|e| fail(&e));
    println!("Account deleted. Your notes stay on this device (qot export saves them).");
}

fn status(notes: &NoteService) {
    let creds = signed_in(notes);
    let counts = notes
        .counts()
        .unwrap_or_else(|e| fail(&format!("Error reading notes: {e}")));
    print!(
        "{}",
        render_status(
            creds.as_ref(),
            counts,
            &notes.dir().display().to_string(),
            env!("CARGO_PKG_VERSION"),
        )
    );
}

/// A name for the server, so production and staging can't be mistaken for
/// each other at a glance.
fn server_label(url: &str) -> &'static str {
    let host = url
        .split("://")
        .nth(1)
        .unwrap_or(url)
        .split(['/', ':'])
        .next()
        .unwrap_or("");
    match host {
        "api.quantumofthought.com" => "production",
        "staging-api.quantumofthought.com" => "staging",
        "localhost" | "127.0.0.1" | "[::1]" => "local",
        _ => "custom",
    }
}

/// The `qot status` page. Never includes tokens.
fn render_status(creds: Option<&Credentials>, counts: Counts, dir: &str, version: &str) -> String {
    let mut out = String::new();
    match creds {
        Some(c) => {
            out += &format!("Account   {}\n", c.email);
            out += &format!("Server    {} ({})\n", c.server, server_label(&c.server));
        }
        None => out += "Account   not signed in (sign in with: qot login <email>)\n",
    }
    let waiting = match counts.unsynced {
        0 => "all synced".to_string(),
        n => format!("{n} not synced yet"),
    };
    out += &format!("Notes     {}, {waiting}\n", counts.live);
    out += &format!("Data      {dir}\n");
    out += &format!("Version   qot {version}\n");
    out
}

fn logout(notes: &NoteService) {
    if let Some(creds) = signed_in(notes) {
        // Revoke on the server if it's reachable; signing out locally is what matters.
        let _ = Api::new(&creds.server, QUICK_SYNC).logout(&creds.tokens.refresh_token);
    }
    credentials::remove(notes.dir()).unwrap_or_else(|e| fail(&e));
    notes.forget_sync_state().unwrap_or_else(|e| fail(&e));
    println!("Signed out. Your notes stay on this device.");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn creds(server: &str) -> Credentials {
        Credentials {
            server: server.into(),
            email: "me@example.com".into(),
            tokens: api::Tokens {
                access_token: "secret-access".into(),
                refresh_token: "secret-refresh".into(),
            },
        }
    }

    #[test]
    fn labels_known_servers() {
        assert_eq!(
            server_label("https://api.quantumofthought.com"),
            "production"
        );
        assert_eq!(
            server_label("https://api.quantumofthought.com/"),
            "production"
        );
        assert_eq!(
            server_label("https://staging-api.quantumofthought.com"),
            "staging"
        );
        assert_eq!(server_label("http://localhost:4000"), "local");
        assert_eq!(server_label("http://127.0.0.1:4000"), "local");
        assert_eq!(server_label("https://qot.example.com"), "custom");
        // A lookalike host is not production.
        assert_eq!(
            server_label("https://api.quantumofthought.com.evil.example"),
            "custom"
        );
    }

    #[test]
    fn status_signed_in() {
        let counts = Counts {
            live: 3,
            unsynced: 1,
        };
        let page = render_status(
            Some(&creds("https://api.quantumofthought.com")),
            counts,
            "/data",
            "0.1.1",
        );
        assert_eq!(
            page,
            "Account   me@example.com\n\
             Server    https://api.quantumofthought.com (production)\n\
             Notes     3, 1 not synced yet\n\
             Data      /data\n\
             Version   qot 0.1.1\n"
        );
        assert!(!page.contains("secret"));
    }

    #[test]
    fn status_signed_out() {
        let counts = Counts {
            live: 0,
            unsynced: 0,
        };
        let page = render_status(None, counts, "/data", "0.1.1");
        assert!(page.starts_with("Account   not signed in (sign in with: qot login <email>)\n"));
        assert!(!page.contains("Server"));
        assert!(page.contains("Notes     0, all synced\n"));
    }

    #[test]
    fn defaults_to_production() {
        assert_eq!(
            resolve_server(None, None),
            "https://api.quantumofthought.com"
        );
    }

    #[test]
    fn env_overrides_default() {
        let env = Some("https://staging-api.quantumofthought.com".to_string());
        assert_eq!(
            resolve_server(None, env),
            "https://staging-api.quantumofthought.com"
        );
    }

    #[test]
    fn empty_env_is_ignored() {
        assert_eq!(resolve_server(None, Some(String::new())), DEFAULT_SERVER);
    }

    #[test]
    fn flag_overrides_env() {
        let flag = Some("http://localhost:4000".to_string());
        let env = Some("https://staging-api.quantumofthought.com".to_string());
        assert_eq!(resolve_server(flag, env), "http://localhost:4000");
    }
}
