use std::fs;
use std::path::PathBuf;

pub type StorageResult<T> = Result<T, StorageError>;

#[derive(Debug)]
pub enum StorageError {
    IoError(std::io::Error),
}

impl From<std::io::Error> for StorageError {
    fn from(e: std::io::Error) -> Self {
        StorageError::IoError(e)
    }
}

impl std::fmt::Display for StorageError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            StorageError::IoError(e) => write!(f, "I/O error: {}", e),
        }
    }
}

impl std::error::Error for StorageError {}

/// Universal storage interface. There is no delete: a deleted note is a
/// tombstone inside the note itself, so the delete can sync.
pub trait Storage {
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>>;
    fn set(&self, key: &str, value: &[u8]) -> StorageResult<()>;
    fn list(&self) -> StorageResult<Vec<String>>;
}

/// Filesystem-based storage using platform-specific directories
pub struct FileSystemStorage {
    notes_dir: PathBuf,
}

impl FileSystemStorage {
    pub fn new(base_path: PathBuf) -> StorageResult<Self> {
        let notes_dir = base_path.join("notes");
        fs::create_dir_all(&notes_dir)?;
        Ok(Self { notes_dir })
    }

    fn note_path(&self, uuid: &str) -> PathBuf {
        self.notes_dir.join(format!("{}.note", uuid))
    }
}

impl Storage for FileSystemStorage {
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>> {
        let path = self.note_path(key);
        if path.exists() {
            Ok(Some(fs::read(path)?))
        } else {
            Ok(None)
        }
    }

    fn set(&self, key: &str, value: &[u8]) -> StorageResult<()> {
        let path = self.note_path(key);
        fs::write(path, value)?;
        Ok(())
    }

    fn list(&self) -> StorageResult<Vec<String>> {
        let entries = fs::read_dir(&self.notes_dir)?;
        let mut uuids = Vec::new();

        for entry in entries {
            let entry = entry?;
            let path = entry.path();

            // Only include .note files
            if let Some(extension) = path.extension()
                && extension == "note"
                && let Some(stem) = path.file_stem()
            {
                uuids.push(stem.to_string_lossy().to_string());
            }
        }

        Ok(uuids)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_storage_can_initialize() {
        let temp_dir = TempDir::new().unwrap();
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf());
        assert!(storage.is_ok());
    }

    #[test]
    fn test_get_nonexistent_returns_none() {
        let temp_dir = TempDir::new().unwrap();
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();
        let result = storage.get("nonexistent-uuid");
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }

    #[test]
    fn test_set_and_get() {
        let temp_dir = TempDir::new().unwrap();
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();
        let uuid = "test-uuid-123";
        let data = b"test data";

        storage.set(uuid, data).unwrap();
        let retrieved = storage.get(uuid).unwrap();

        assert_eq!(retrieved, Some(data.to_vec()));
    }

    #[test]
    fn test_list_returns_notes() {
        let temp_dir = TempDir::new().unwrap();
        let storage = FileSystemStorage::new(temp_dir.path().to_path_buf()).unwrap();

        let uuid1 = "test-list-uuid-1";
        let uuid2 = "test-list-uuid-2";
        let uuid3 = "test-list-uuid-3";

        storage.set(uuid1, b"data1").unwrap();
        storage.set(uuid2, b"data2").unwrap();
        storage.set(uuid3, b"data3").unwrap();

        let list = storage.list().unwrap();
        assert_eq!(list.len(), 3);
        assert!(list.contains(&uuid1.to_string()));
        assert!(list.contains(&uuid2.to_string()));
        assert!(list.contains(&uuid3.to_string()));
    }
}
