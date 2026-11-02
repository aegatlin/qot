mod api;
mod credentials;
mod service;
mod storage;

use api::{Api, Poll};
use clap::{CommandFactory, Parser, Subcommand};
use credentials::Credentials;
use service::NoteService;
use std::process::exit;
use std::time::{Duration, Instant};

/// Where `qot login` signs in unless told otherwise.
const SERVER_ENV: &str = "QOT_SERVER";
const DEFAULT_SERVER: &str = "http://localhost:4000";
/// How long a background sync after a command may take before giving up.
const QUICK_SYNC: Duration = Duration::from_secs(3);

#[derive(Parser)]
#[command(name = "qot")]
#[command(about = "Quantum of Thought - A note capture CLI")]
#[command(after_help = "EXAMPLES:\n  \
    qot get milk          # Create a new note (implicit)\n  \
    qot add buy eggs      # Create a new note (explicit)\n  \
    qot list              # Show all notes\n  \
    qot delete 2          # Delete note #2\n  \
    qot login me@x.com    # Sign in to sync between devices\n  \
    qot sync              # Sync now")]
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
    /// Delete a note by its index number
    #[command(visible_alias = "d")]
    Delete {
        /// The index number shown in 'qot list' (e.g., 1, 2, 3)
        index: usize,
    },
    /// Sign in so notes sync between your devices
    Login {
        email: String,
        /// Server to sign in to (default: $QOT_SERVER, else http://localhost:4000)
        #[arg(long)]
        server: Option<String>,
    },
    /// Sign out on this device (notes stay)
    Logout,
    /// Push local changes and pull everyone else's
    #[command(visible_alias = "s")]
    Sync,
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
        Some(Commands::Delete { index }) => {
            delete_note(&mut notes, index);
            quick_sync(&mut notes);
        }
        Some(Commands::Login { email, server }) => login(&mut notes, &email, server),
        Some(Commands::Logout) => logout(&notes),
        Some(Commands::Sync) => sync_now(&mut notes),
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

fn login(notes: &mut NoteService, email: &str, server: Option<String>) {
    let server = server
        .or_else(|| std::env::var(SERVER_ENV).ok().filter(|s| !s.is_empty()))
        .unwrap_or_else(|| DEFAULT_SERVER.to_string());
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

    match notes.sync(&api, &mut creds) {
        Ok(r) => println!("Synced: {} sent, {} received", r.pushed, r.pulled),
        Err(e) => eprintln!("(not synced yet: {e})"),
    }
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
