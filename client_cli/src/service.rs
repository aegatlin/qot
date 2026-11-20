use crate::api::{Api, ApiError};
use crate::credentials::{self, Credentials};
use crate::storage::{FileSystemStorage, Storage};
use directories::ProjectDirs;
use qot_core::sync::{SyncState, apply_pulled, mark_pushed, plan_push};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The most changes one push may carry (the server's limit).
const PUSH_CHUNK: usize = 500;

/// Overrides where notes are stored. Tests use it so they never touch a real
/// note store; it also lets a second store be pointed at by hand.
pub const DATA_DIR_ENV: &str = "QOT_DATA_DIR";

/// What the CLI shows of a note.
#[derive(Clone, Debug)]
pub struct Note {
    pub id: String,
    pub content: String,
    pub attachments: Vec<qot_core::Attachment>,
}

impl Note {
    /// The note on one line of output: a marker for each attachment, which
    /// a terminal can't show (`[audio 0:42]`), then the text.
    pub fn line(&self) -> String {
        let mut parts: Vec<String> = self
            .attachments
            .iter()
            .map(|a| format!("[{}]", a.label()))
            .collect();
        if !self.content.is_empty() {
            parts.push(self.content.clone());
        }
        parts.join(" ")
    }
}

/// What `qot export --dir` wrote.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ExportReport {
    pub notes: usize,
    pub attachments: usize,
    /// Attachments the server doesn't have (yet), by id.
    pub missing: Vec<String>,
}

pub struct NoteService {
    storage: FileSystemStorage,
    dir: PathBuf,
}

/// What a sync moved.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct SyncReport {
    pub pushed: usize,
    pub pulled: usize,
}

/// What `qot status` reports about the local store.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Counts {
    pub live: usize,
    pub unsynced: usize,
}

pub fn data_dir() -> Result<PathBuf, String> {
    if let Some(dir) = std::env::var_os(DATA_DIR_ENV).filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    let proj_dirs =
        ProjectDirs::from("", "", "qot").ok_or("Failed to determine storage directory")?;
    Ok(proj_dirs.data_dir().to_path_buf())
}

impl NoteService {
    pub fn new() -> Result<Self, String> {
        Self::at(data_dir()?)
    }

    pub fn at(dir: PathBuf) -> Result<Self, String> {
        let storage = FileSystemStorage::new(dir.clone()).map_err(|e| e.to_string())?;
        Ok(Self { storage, dir })
    }

    pub fn dir(&self) -> &std::path::Path {
        &self.dir
    }

    /// Pushes local changes, then pulls until caught up. The sync state is
    /// saved after every step, so an interrupted sync resumes where it
    /// stopped and anything repeated is harmless.
    pub fn sync(&mut self, api: &Api, creds: &mut Credentials) -> Result<SyncReport, String> {
        let mut report = SyncReport::default();
        let mut state = self.load_state()?;

        let notes = self.load_all()?;
        for chunk in plan_push(&notes, &state).chunks(PUSH_CHUNK) {
            authed(api, creds, &self.dir, |token| api.push(token, chunk))?;
            state = mark_pushed(&state, chunk);
            self.save_state(&state)?;
            report.pushed += chunk.len();
        }

        loop {
            let page = authed(api, creds, &self.dir, |token| api.pull(token, state.cursor))?;
            let notes: BTreeMap<String, qot_core::Note> =
                self.load_all()?.into_iter().map(|n| (n.id(), n)).collect();
            let (changed, next) =
                apply_pulled(&notes, &state, &page.changes).map_err(|e| e.to_string())?;
            for note in changed.values() {
                self.save(note)?;
            }
            state = next;
            self.save_state(&state)?;
            report.pulled += page.changes.len();
            if !page.more {
                break;
            }
        }

        Ok(report)
    }

    /// Deletes the account on the server and forgets this device's sync
    /// position. Notes on this device stay; the caller forgets credentials.
    pub fn delete_account(
        &self,
        api: &Api,
        creds: &mut Credentials,
        confirm: &str,
    ) -> Result<(), String> {
        authed(api, creds, &self.dir, |token| {
            api.delete_account(token, confirm)
        })?;
        self.forget_sync_state()
    }

    /// Live notes, oldest first, as a JSON array of `{id, created_at,
    /// content}`: everything a person wrote, readable without qot. A note
    /// with attachments also lists them (`attachments`: `id`, `kind`,
    /// `media_type`, `size`, `duration_ms`).
    pub fn export(&mut self) -> Result<String, String> {
        export_json(&self.list()?, &BTreeMap::new())
    }

    /// Writes the export to `dir`: `notes.json`, and each attachment's bytes
    /// under `attachments/`, fetched from the server (the CLI keeps none of
    /// its own), named in the JSON as `file`. The notes are written even
    /// when some attachment can't be fetched; `signed_in` is needed only if
    /// there are attachments.
    pub fn export_to(
        &mut self,
        dir: &std::path::Path,
        signed_in: Option<(&Api, &mut Credentials)>,
    ) -> Result<ExportReport, String> {
        let notes = self.list()?;
        let io = |e: std::io::Error| format!("Can't write to {}: {e}", dir.display());
        std::fs::create_dir_all(dir).map_err(io)?;
        let wanted: Vec<&qot_core::Attachment> =
            notes.iter().flat_map(|n| &n.attachments).collect();
        let mut report = ExportReport {
            notes: notes.len(),
            ..Default::default()
        };
        let mut files: BTreeMap<String, String> = BTreeMap::new();
        let mut failure = None;

        match signed_in {
            Some((api, creds)) if !wanted.is_empty() => {
                std::fs::create_dir_all(dir.join("attachments")).map_err(io)?;
                for a in &wanted {
                    match authed(api, creds, &self.dir, |token| api.get_blob(token, &a.id)) {
                        Ok(Some(bytes)) => {
                            let file = format!("attachments/{}.{}", a.id, extension(&a.media_type));
                            std::fs::write(dir.join(&file), bytes).map_err(io)?;
                            files.insert(a.id.clone(), file);
                            report.attachments += 1;
                        }
                        Ok(None) => report.missing.push(a.id.clone()),
                        Err(e) => {
                            failure = Some(format!("Couldn't fetch attachment {}: {e}", a.id));
                            break;
                        }
                    }
                }
            }
            None if !wanted.is_empty() => {
                failure = Some(
                    "Some notes have attachments, which are fetched from the server.                      Sign in first: qot login <email>"
                        .to_string(),
                );
            }
            _ => {}
        }

        let json = export_json(&notes, &files)?;
        std::fs::write(dir.join("notes.json"), json + "\n").map_err(io)?;
        match failure {
            Some(message) => Err(message),
            None => Ok(report),
        }
    }

    /// Forgets what has been synced, so the next sign-in starts afresh.
    /// Notes stay.
    pub fn forget_sync_state(&self) -> Result<(), String> {
        match std::fs::remove_file(self.state_path()) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
            _ => Ok(()),
        }
    }

    fn state_path(&self) -> PathBuf {
        self.dir.join("sync.json")
    }

    fn load_state(&self) -> Result<SyncState, String> {
        match std::fs::read(self.state_path()) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(SyncState::default()),
            Err(e) => Err(e.to_string()),
        }
    }

    fn save_state(&self, state: &SyncState) -> Result<(), String> {
        let json = serde_json::to_vec(state).map_err(|e| e.to_string())?;
        std::fs::write(self.state_path(), json).map_err(|e| e.to_string())
    }

    /// How many live notes this device holds, and how many notes (deleted
    /// ones included) have changes that haven't been pushed yet. Reads only
    /// local files.
    pub fn counts(&self) -> Result<Counts, String> {
        let notes = self.load_all()?;
        let state = self.load_state()?;
        Ok(Counts {
            live: notes.iter().filter(|n| !n.is_deleted()).count(),
            unsynced: plan_push(&notes, &state).len(),
        })
    }

    pub fn create(&mut self, content: &str) -> Result<Note, String> {
        let note = qot_core::Note::new(content);
        self.save(&note)?;
        Ok(view(&note))
    }

    /// Live notes, oldest first. Deleted notes stay in storage as tombstones
    /// so the delete can sync, but are not listed.
    pub fn list(&mut self) -> Result<Vec<Note>, String> {
        Ok(self
            .load_all()?
            .iter()
            .filter(|n| !n.is_deleted())
            .map(view)
            .collect())
    }

    /// Deletes the note; returns it as it was listed.
    pub fn delete_by_index(&mut self, index: usize) -> Result<String, String> {
        let note = self.live_note(index)?;
        let deleted = note.delete().map_err(|e| e.to_string())?;
        self.save(&deleted)?;
        Ok(view(&note).line())
    }

    /// The live note at `index` as `qot list` numbers them (from 1).
    pub fn live_note(&self, index: usize) -> Result<qot_core::Note, String> {
        let mut live: Vec<qot_core::Note> = self
            .load_all()?
            .into_iter()
            .filter(|n| !n.is_deleted())
            .collect();
        if index == 0 || index > live.len() {
            return Err(format!("Index {} out of range (1-{})", index, live.len()));
        }
        Ok(live.swap_remove(index - 1))
    }

    /// The live note at `index` and its recordings (audio attachments), in
    /// the note's order.
    pub fn recordings(&self, index: usize) -> Result<(Note, Vec<qot_core::Attachment>), String> {
        let note = view(&self.live_note(index)?);
        let recordings = note
            .attachments
            .iter()
            .filter(|a| a.kind == qot_core::AUDIO)
            .cloned()
            .collect();
        Ok((note, recordings))
    }

    /// A recording's bytes, from the server: the CLI keeps none.
    pub fn recording_bytes(
        &self,
        recording: &qot_core::Attachment,
        api: &Api,
        creds: &mut Credentials,
    ) -> Result<Vec<u8>, String> {
        authed(api, creds, &self.dir, |token| {
            api.get_blob(token, &recording.id)
        })
        .map_err(|e| format!("Couldn't fetch the recording: {e}"))?
        .ok_or_else(|| {
            "The recording isn't on the server (yet). Sync the device that made it, \
                 then play it again."
                .to_string()
        })
    }

    /// Saves `text` as an edit of `base` (the note as it was shown in the
    /// editor), merged into the note as it is on disk now, so a change that
    /// synced in while the editor was open is kept.
    pub fn save_edit(&mut self, base: &qot_core::Note, text: &str) -> Result<Note, String> {
        let current = match self.storage.get(&base.id()).map_err(|e| e.to_string())? {
            Some(bytes) => qot_core::Note::from_bytes(&bytes)
                .map_err(|e| format!("note {} is unreadable: {e}", base.id()))?,
            None => base.clone(),
        };
        let saved = edited(&current, base, text).map_err(|e| e.to_string())?;
        self.save(&saved)?;
        Ok(view(&saved))
    }

    fn save(&self, note: &qot_core::Note) -> Result<(), String> {
        self.storage
            .set(&note.id(), &note.to_bytes())
            .map_err(|e| e.to_string())
    }

    /// Every stored note, tombstones included, sorted by UUIDv7 (creation time).
    fn load_all(&self) -> Result<Vec<qot_core::Note>, String> {
        let mut ids = self.storage.list().map_err(|e| e.to_string())?;
        ids.sort();
        let mut notes = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(bytes) = self.storage.get(&id).map_err(|e| e.to_string())? {
                let note = qot_core::Note::from_bytes(&bytes)
                    .map_err(|e| format!("note {id} is unreadable: {e}"))?;
                notes.push(note);
            }
        }
        Ok(notes)
    }
}

/// An edit made against `base` (what the editor was shown), merged into
/// `current` (the note now). `update` diffs from the note it's called on, so
/// diffing from `base` keeps changes `current` has that `base` lacked.
fn edited(
    current: &qot_core::Note,
    base: &qot_core::Note,
    text: &str,
) -> qot_core::NoteResult<qot_core::Note> {
    current.merge(&base.update(text)?)
}

/// Runs `call` with the access token, refreshing it once if it was refused.
fn authed<T>(
    api: &Api,
    creds: &mut Credentials,
    dir: &std::path::Path,
    call: impl Fn(&str) -> Result<T, ApiError>,
) -> Result<T, String> {
    match call(&creds.tokens.access_token) {
        Err(ApiError::Unauthorized) => {
            creds.tokens.access_token = api
                .refresh(&creds.tokens.refresh_token)
                .map_err(|e| e.to_string())?;
            credentials::save(dir, creds)?;
            call(&creds.tokens.access_token).map_err(|e| e.to_string())
        }
        other => other.map_err(|e| e.to_string()),
    }
}

/// When a note was created, from its UUIDv7 id, as RFC 3339 UTC to the
/// second. `None` for an id that isn't a v7 UUID.
fn created_at(id: &str) -> Option<String> {
    let (secs, _nanos) = uuid::Uuid::parse_str(id).ok()?.get_timestamp()?.to_unix();
    Some(rfc3339(secs))
}

fn rfc3339(unix_secs: u64) -> String {
    let (days, rem) = (unix_secs / 86_400, unix_secs % 86_400);
    let (y, m, d) = civil_from_days(days as i64);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// Days since 1970-01-01 to a (year, month, day) date: Howard Hinnant's
/// `civil_from_days`.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

fn view(note: &qot_core::Note) -> Note {
    Note {
        id: note.id(),
        content: note.content(),
        attachments: note.attachments(),
    }
}

/// The export's JSON. `files` maps an attachment id to the file its bytes
/// were written to, relative to the JSON.
fn export_json(notes: &[Note], files: &BTreeMap<String, String>) -> Result<String, String> {
    let notes: Vec<serde_json::Value> = notes
        .iter()
        .map(|n| {
            let mut note = serde_json::json!({
                "id": n.id,
                "created_at": created_at(&n.id),
                "content": n.content,
            });
            if !n.attachments.is_empty() {
                let attachments: Vec<serde_json::Value> = n
                    .attachments
                    .iter()
                    .map(|a| {
                        let mut entry = serde_json::json!({
                            "id": a.id,
                            "kind": a.kind,
                            "media_type": a.media_type,
                            "size": a.size,
                        });
                        if let Some(ms) = a.duration_ms {
                            entry["duration_ms"] = ms.into();
                        }
                        if let Some(file) = files.get(&a.id) {
                            entry["file"] = file.as_str().into();
                        }
                        entry
                    })
                    .collect();
                note["attachments"] = attachments.into();
            }
            note
        })
        .collect();
    serde_json::to_string_pretty(&notes).map_err(|e| e.to_string())
}

/// A file extension for an exported attachment, from its media type.
pub fn extension(media_type: &str) -> String {
    let known = match media_type {
        "audio/mp4" | "audio/x-m4a" => "m4a",
        "audio/mpeg" => "mp3",
        "image/jpeg" => "jpg",
        "video/quicktime" => "mov",
        _ => "",
    };
    if !known.is_empty() {
        return known.to_string();
    }
    // Otherwise the subtype, if it is plain enough to be a file extension.
    match media_type.split_once('/') {
        Some((_, sub))
            if !sub.is_empty()
                && sub.len() <= 8
                && sub.chars().all(|c| c.is_ascii_alphanumeric()) =>
        {
            sub.to_ascii_lowercase()
        }
        _ => "bin".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_edit_keeps_a_change_that_arrived_while_editing() {
        // Opened at "milk"; meanwhile another device made it "oat milk";
        // the editor's result adds a line to what it was shown.
        let base = qot_core::Note::new("milk");
        let other_device = qot_core::Note::from_bytes(&base.to_bytes()).unwrap();
        let current = base
            .merge(&other_device.update("oat milk").unwrap())
            .unwrap();
        let saved = edited(&current, &base, "milk\neggs").unwrap();
        assert_eq!(saved.content(), "oat milk\neggs");
    }

    #[test]
    fn edit_by_index_saves_and_lists_the_new_text() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();
        service.create("first").unwrap();
        sleep(Duration::from_millis(10));
        service.create("second").unwrap();
        let base = service.live_note(2).unwrap();
        assert_eq!(base.content(), "second");
        let note = service.save_edit(&base, "second, edited").unwrap();
        assert_eq!(note.content, "second, edited");
        let contents: Vec<_> = service
            .list()
            .unwrap()
            .into_iter()
            .map(|n| n.content)
            .collect();
        assert_eq!(contents, ["first", "second, edited"]);
    }

    #[test]
    fn live_note_index_out_of_range_is_an_error() {
        let temp_dir = tempfile::tempdir().unwrap();
        let service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();
        assert!(service.live_note(1).unwrap_err().contains("out of range"));
    }

    #[test]
    fn an_exported_attachment_gets_a_sensible_extension() {
        assert_eq!(extension("audio/mp4"), "m4a");
        assert_eq!(extension("image/jpeg"), "jpg");
        assert_eq!(extension("image/png"), "png");
        assert_eq!(extension("video/mp4"), "mp4");
        assert_eq!(extension("model/x-holo"), "bin");
        assert_eq!(extension("../../etc/passwd"), "bin");
        assert_eq!(extension(""), "bin");
    }

    #[test]
    fn rfc3339_formats_unix_seconds_in_utc() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(1_793_770_899), "2026-11-04T05:41:39Z");
    }

    #[test]
    fn created_at_reads_the_time_from_a_v7_id() {
        assert_eq!(
            created_at("019a4d62-9a38-7000-8000-000000000000").as_deref(),
            Some("2025-11-04T05:41:39Z")
        );
        assert_eq!(created_at("not-a-uuid"), None);
        // v4 ids carry no time.
        assert_eq!(created_at("c2302a7f-1b0d-4f0b-9d5c-6c1d4b9e0b8a"), None);
    }
    use std::thread::sleep;
    use std::time::Duration;

    #[test]
    fn test_list_returns_notes_sorted_by_creation_time() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();

        // Create first note
        let note1 = service.create("First note").unwrap();

        // Small delay to ensure different timestamps
        sleep(Duration::from_millis(10));

        // Create second note
        let note2 = service.create("Second note").unwrap();

        // Small delay to ensure different timestamps
        sleep(Duration::from_millis(10));

        // Create third note
        let note3 = service.create("Third note").unwrap();

        // List all notes
        let notes = service.list().unwrap();

        // Verify we have all three notes
        assert_eq!(notes.len(), 3);

        // Verify they're in chronological order (oldest first)
        assert_eq!(notes[0].id, note1.id);
        assert_eq!(notes[0].content, "First note");

        assert_eq!(notes[1].id, note2.id);
        assert_eq!(notes[1].content, "Second note");

        assert_eq!(notes[2].id, note3.id);
        assert_eq!(notes[2].content, "Third note");
    }

    #[test]
    fn test_delete_by_index() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();

        // Create three notes
        service.create("First note").unwrap();
        sleep(Duration::from_millis(10));
        service.create("Second note").unwrap();
        sleep(Duration::from_millis(10));
        service.create("Third note").unwrap();

        // Verify we have 3 notes
        assert_eq!(service.list().unwrap().len(), 3);

        // Delete the second note (index 2)
        let deleted_content = service.delete_by_index(2).unwrap();
        assert_eq!(deleted_content, "Second note");

        // Verify we now have 2 notes
        let notes = service.list().unwrap();
        assert_eq!(notes.len(), 2);
        assert_eq!(notes[0].content, "First note");
        assert_eq!(notes[1].content, "Third note");
    }

    #[test]
    fn test_delete_by_index_out_of_range() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();

        // Create one note
        service.create("Only note").unwrap();

        // Try to delete index 0 (invalid)
        let result = service.delete_by_index(0);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("out of range"));

        // Try to delete index 2 (out of range)
        let result = service.delete_by_index(2);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("out of range"));

        // Verify note is still there
        assert_eq!(service.list().unwrap().len(), 1);
    }

    #[test]
    fn delete_keeps_a_tombstone_in_storage_so_it_can_sync() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();

        let note = service.create("buy milk").unwrap();
        service.delete_by_index(1).unwrap();

        assert!(service.list().unwrap().is_empty());
        let bytes = service.storage.get(&note.id).unwrap().unwrap();
        assert!(qot_core::Note::from_bytes(&bytes).unwrap().is_deleted());
    }

    #[test]
    fn delete_index_counts_only_live_notes() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();

        service.create("first").unwrap();
        sleep(Duration::from_millis(2));
        service.create("second").unwrap();
        sleep(Duration::from_millis(2));
        service.create("third").unwrap();

        assert_eq!(service.delete_by_index(1).unwrap(), "first");
        assert_eq!(service.delete_by_index(1).unwrap(), "second");
        let notes = service.list().unwrap();
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].content, "third");
    }

    #[test]
    fn an_unreadable_note_is_reported_not_silently_emptied() {
        let temp_dir = tempfile::tempdir().unwrap();
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();
        storage.set("broken", b"not automerge").unwrap();
        let mut service = NoteService::at(temp_dir.path().to_path_buf()).unwrap();

        let err = service.list().unwrap_err();
        assert!(err.contains("broken"), "{err}");
    }
}
