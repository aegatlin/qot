//! Signed-in state, saved beside the notes with owner-only permissions.

use crate::api::Tokens;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Credentials {
    pub server: String,
    pub email: String,
    #[serde(flatten)]
    pub tokens: Tokens,
}

fn path(dir: &Path) -> PathBuf {
    dir.join("credentials.json")
}

pub fn load(dir: &Path) -> Result<Option<Credentials>, String> {
    match fs::read(path(dir)) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("credentials are unreadable: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

pub fn save(dir: &Path, creds: &Credentials) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let json = serde_json::to_vec_pretty(creds).map_err(|e| e.to_string())?;
    write_private(&path(dir), &json).map_err(|e| e.to_string())
}

pub fn remove(dir: &Path) -> Result<(), String> {
    match fs::remove_file(path(dir)) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
        _ => Ok(()),
    }
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    fs::write(path, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn creds() -> Credentials {
        Credentials {
            server: "http://localhost:4000".into(),
            email: "me@example.com".into(),
            tokens: Tokens {
                access_token: "a".into(),
                refresh_token: "r".into(),
            },
        }
    }

    #[test]
    fn round_trips_and_removes() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(dir.path()).unwrap(), None);
        save(dir.path(), &creds()).unwrap();
        assert_eq!(load(dir.path()).unwrap(), Some(creds()));
        remove(dir.path()).unwrap();
        assert_eq!(load(dir.path()).unwrap(), None);
        remove(dir.path()).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn is_readable_only_by_the_owner() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        save(dir.path(), &creds()).unwrap();
        let mode = fs::metadata(path(dir.path())).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}
