use crate::storage::{FileSystemStorage, Storage};
use directories::ProjectDirs;
use std::path::PathBuf;

/// Overrides where notes are stored. Tests use it so they never touch a real
/// note store; it also lets a second store be pointed at by hand.
pub const DATA_DIR_ENV: &str = "QOT_DATA_DIR";

/// What the CLI shows of a note.
#[derive(Clone, Debug)]
pub struct Note {
    #[cfg_attr(not(test), allow(dead_code))]
    pub id: String,
    pub content: String,
}

pub struct NoteService {
    storage: FileSystemStorage,
}

fn data_dir() -> Result<PathBuf, String> {
    if let Some(dir) = std::env::var_os(DATA_DIR_ENV).filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    let proj_dirs =
        ProjectDirs::from("", "", "qot").ok_or("Failed to determine storage directory")?;
    Ok(proj_dirs.data_dir().to_path_buf())
}

impl NoteService {
    pub fn new() -> Result<Self, String> {
        let storage = FileSystemStorage::new(data_dir()?).map_err(|e| e.to_string())?;
        Ok(Self { storage })
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

    pub fn delete_by_index(&mut self, index: usize) -> Result<String, String> {
        let live: Vec<qot_core::Note> = self
            .load_all()?
            .into_iter()
            .filter(|n| !n.is_deleted())
            .collect();

        if index == 0 || index > live.len() {
            return Err(format!("Index {} out of range (1-{})", index, live.len()));
        }

        let note = &live[index - 1];
        let deleted = note.delete().map_err(|e| e.to_string())?;
        self.save(&deleted)?;
        Ok(note.content())
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

fn view(note: &qot_core::Note) -> Note {
    Note {
        id: note.id(),
        content: note.content(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread::sleep;
    use std::time::Duration;

    #[test]
    fn test_list_returns_notes_sorted_by_creation_time() {
        let temp_dir = tempfile::tempdir().unwrap();
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();

        let mut service = NoteService { storage };

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
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();

        let mut service = NoteService { storage };

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
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();

        let mut service = NoteService { storage };

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
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();
        let mut service = NoteService { storage };

        let note = service.create("buy milk").unwrap();
        service.delete_by_index(1).unwrap();

        assert!(service.list().unwrap().is_empty());
        let bytes = service.storage.get(&note.id).unwrap().unwrap();
        assert!(qot_core::Note::from_bytes(&bytes).unwrap().is_deleted());
    }

    #[test]
    fn delete_index_counts_only_live_notes() {
        let temp_dir = tempfile::tempdir().unwrap();
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();
        let mut service = NoteService { storage };

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
        let mut service = NoteService { storage };

        let err = service.list().unwrap_err();
        assert!(err.contains("broken"), "{err}");
    }
}
