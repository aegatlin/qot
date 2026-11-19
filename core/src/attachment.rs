//! Media on a note: a recording, later an image or a video.
//!
//! The bytes are never in the note. A note holds a small description of each
//! attachment, and the bytes travel as a blob with the attachment's id
//! (`docs/records/2026-11-19-attachments-and-voice-memos.md`).
//!
//! Each attachment is its own map at the note's root, under
//! `attachment:<id>`, rather than an entry in one shared `attachments` map:
//! two devices that each added the first attachment to an older note would
//! both create that shared map, and one device's attachment would vanish in
//! the merge. Separate root keys can't collide.
//!
//! A client that doesn't know an attachment's `kind`, or some of its fields,
//! still lists it and never drops it: edits touch only the keys they name.

use crate::{CONTENT, Note, NoteError, NoteResult, now_secs, sealed, sealed_at};
use automerge::{
    AutoCommit, ChangeHash, ObjId, ObjType, ROOT, ReadDoc, ScalarValue, Value,
    transaction::Transactable,
};
use uuid::Uuid;

const PREFIX: &str = "attachment:";
const KIND: &str = "kind";
const MEDIA_TYPE: &str = "media_type";
const SIZE: &str = "size";
const DURATION_MS: &str = "duration_ms";
const TEXT: &str = "text";
const PENDING: &str = "pending";
const DONE: &str = "done";

/// The kind of a recording.
pub const AUDIO: &str = "audio";

/// Whether an attachment's text (a recording's transcript) is in the note.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentText {
    /// No text is expected from this attachment.
    None,
    /// Text is expected and hasn't been written into the note yet.
    Pending,
    /// The text was written into the note's content.
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
    /// A UUIDv7 made by the capturing client; also the blob's id.
    pub id: String,
    /// `audio`; later `image`, `video`. Unknown kinds are kept as they are.
    pub kind: String,
    /// e.g. `audio/mp4`.
    pub media_type: String,
    /// Bytes.
    pub size: u64,
    pub duration_ms: Option<u64>,
    pub text: AttachmentText,
}

impl Attachment {
    /// An id for a new attachment.
    pub fn new_id() -> String {
        Uuid::now_v7().to_string()
    }

    /// A short description for clients that can't show the attachment:
    /// `audio 0:42`, or `image, 2 MB` for anything without a length.
    pub fn label(&self) -> String {
        match self.duration_ms {
            Some(ms) => {
                let secs = ms / 1000;
                let (h, m, s) = (secs / 3600, secs / 60 % 60, secs % 60);
                if h > 0 {
                    format!("{} {h}:{m:02}:{s:02}", self.kind)
                } else {
                    format!("{} {m}:{s:02}", self.kind)
                }
            }
            None => format!("{}, {}", self.kind, size_label(self.size)),
        }
    }
}

fn size_label(bytes: u64) -> String {
    const KB: u64 = 1000;
    const MB: u64 = 1000 * KB;
    const GB: u64 = 1000 * MB;
    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{} MB", (bytes + MB / 2) / MB)
    } else if bytes >= KB {
        format!("{} KB", (bytes + KB / 2) / KB)
    } else {
        format!("{bytes} B")
    }
}

impl Note {
    /// A new note that starts with an attachment: a voice memo, whose
    /// content is its transcript (empty if there is none yet).
    pub fn with_attachment(content: &str, attachment: &Attachment) -> NoteResult<Note> {
        Note::new(content).attach(attachment)
    }

    /// The note's attachments, oldest first (ids are UUIDv7).
    pub fn attachments(&self) -> Vec<Attachment> {
        read_all(&self.doc, None)
    }

    pub fn attachment(&self, id: &str) -> Option<Attachment> {
        self.attachments().into_iter().find(|a| a.id == id)
    }

    /// True when there is nothing to keep: no text and no attachments. Such
    /// a note is discarded by editors; a recording with no text is not.
    pub fn is_empty(&self) -> bool {
        self.content().trim().is_empty() && self.attachments().is_empty()
    }

    pub fn attach(&self, attachment: &Attachment) -> NoteResult<Note> {
        if Uuid::parse_str(&attachment.id).is_err() {
            return Err(NoteError(format!(
                "attachment id is not a UUID: {}",
                attachment.id
            )));
        }
        if attachment.kind.is_empty() {
            return Err(NoteError("attachment has no kind".into()));
        }
        let key = key(&attachment.id);
        let mut doc = self.branch();
        if doc.get(ROOT, key.as_str())?.is_some() {
            return Err(NoteError(format!(
                "note already has attachment {}",
                attachment.id
            )));
        }
        let map = doc.put_object(ROOT, key.as_str(), ObjType::Map)?;
        doc.put(&map, KIND, attachment.kind.as_str())?;
        doc.put(&map, MEDIA_TYPE, attachment.media_type.as_str())?;
        doc.put(&map, SIZE, attachment.size)?;
        if let Some(ms) = attachment.duration_ms {
            doc.put(&map, DURATION_MS, ms)?;
        }
        match attachment.text {
            AttachmentText::None => {}
            AttachmentText::Pending => doc.put(&map, TEXT, PENDING)?,
            AttachmentText::Done => doc.put(&map, TEXT, DONE)?,
        }
        Ok(sealed(doc))
    }

    /// Removes an attachment and keeps the note's text. The caller deletes
    /// the blob; sync tells the server (`plan_push`).
    pub fn detach(&self, id: &str) -> NoteResult<Note> {
        let key = key(id);
        let mut doc = self.branch();
        if doc.get(ROOT, key.as_str())?.is_none() {
            return Err(NoteError(format!("note has no attachment {id}")));
        }
        doc.delete(ROOT, key.as_str())?;
        Ok(sealed(doc))
    }

    /// Writes an attachment's text (a transcript) into the note, once: if
    /// the attachment is waiting for text, `text` is added to the content
    /// and the attachment is marked done, in one commit. If it isn't
    /// waiting, the note is returned unchanged, so a second transcription
    /// of the same recording on this device adds nothing.
    pub fn fill_text(&self, id: &str, text: &str) -> NoteResult<Note> {
        self.fill_text_at(id, text, now_secs())
    }

    fn fill_text_at(&self, id: &str, text: &str, secs: u64) -> NoteResult<Note> {
        let Some(attachment) = self.attachment(id) else {
            return Err(NoteError(format!("note has no attachment {id}")));
        };
        if attachment.text != AttachmentText::Pending {
            return Ok(self.clone());
        }
        let mut doc = self.branch();
        let text = text.trim();
        if !text.is_empty() {
            let content = self.content();
            let joined = if content.trim().is_empty() {
                text.to_string()
            } else {
                format!("{}\n{text}", content.trim_end())
            };
            let Some((_, obj)) = doc.get(ROOT, CONTENT)? else {
                return Err(NoteError("note has no content".into()));
            };
            doc.update_text(&obj, joined)?;
        }
        let Some((_, map)) = doc.get(ROOT, key(id).as_str())? else {
            return Err(NoteError(format!("note has no attachment {id}")));
        };
        doc.put(&map, TEXT, DONE)?;
        Ok(sealed_at(doc, secs))
    }

    /// The ids of the attachments the note had at `heads`. Unknown or
    /// malformed heads are an error.
    pub(crate) fn attachment_ids_at(&self, heads: &[String]) -> NoteResult<Vec<String>> {
        let hashes = heads
            .iter()
            .map(|h| {
                h.parse::<ChangeHash>()
                    .map_err(|e| NoteError(format!("bad head {h}: {e}")))
            })
            .collect::<NoteResult<Vec<_>>>()?;
        for hash in &hashes {
            if self.doc.get_change_by_hash(hash).is_none() {
                return Err(NoteError(format!("unknown head {hash}")));
            }
        }
        Ok(read_all(&self.doc, Some(&hashes))
            .into_iter()
            .map(|a| a.id)
            .collect())
    }
}

fn key(id: &str) -> String {
    format!("{PREFIX}{id}")
}

/// Every attachment in the document, now or as it was at `at`.
fn read_all(doc: &AutoCommit, at: Option<&[ChangeHash]>) -> Vec<Attachment> {
    let keys: Vec<String> = match at {
        Some(heads) => doc.keys_at(ROOT, heads).collect(),
        None => doc.keys(ROOT).collect(),
    };
    let mut all: Vec<Attachment> = keys
        .iter()
        .filter_map(|k| {
            let id = k.strip_prefix(PREFIX)?;
            let found = match at {
                Some(heads) => doc.get_at(ROOT, k.as_str(), heads),
                None => doc.get(ROOT, k.as_str()),
            };
            match found {
                Ok(Some((Value::Object(ObjType::Map), map))) => Some(read_one(doc, &map, id, at)),
                _ => None,
            }
        })
        .collect();
    all.sort_by(|a, b| a.id.cmp(&b.id));
    all
}

fn read_one(doc: &AutoCommit, map: &ObjId, id: &str, at: Option<&[ChangeHash]>) -> Attachment {
    let scalar = |prop: &str| -> Option<ScalarValue> {
        let found = match at {
            Some(heads) => doc.get_at(map, prop, heads),
            None => doc.get(map, prop),
        };
        match found {
            Ok(Some((Value::Scalar(v), _))) => Some(v.into_owned()),
            _ => None,
        }
    };
    let string = |prop: &str| match scalar(prop) {
        Some(ScalarValue::Str(s)) => s.to_string(),
        _ => String::new(),
    };
    let number = |prop: &str| match scalar(prop) {
        Some(ScalarValue::Uint(n)) => Some(n),
        Some(ScalarValue::Int(n)) => u64::try_from(n).ok(),
        Some(ScalarValue::F64(n)) if n >= 0.0 => Some(n as u64),
        _ => None,
    };
    Attachment {
        id: id.to_string(),
        kind: string(KIND),
        media_type: string(MEDIA_TYPE),
        size: number(SIZE).unwrap_or(0),
        duration_ms: number(DURATION_MS),
        text: match string(TEXT).as_str() {
            PENDING => AttachmentText::Pending,
            DONE => AttachmentText::Done,
            _ => AttachmentText::None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn memo(text: AttachmentText) -> Attachment {
        Attachment {
            id: Attachment::new_id(),
            kind: AUDIO.into(),
            media_type: "audio/mp4".into(),
            size: 340_000,
            duration_ms: Some(42_500),
            text,
        }
    }

    #[test]
    fn a_note_starts_with_no_attachments() {
        let note = Note::new("milk");
        assert!(note.attachments().is_empty());
        assert!(!note.is_empty());
        assert!(Note::new("  \n").is_empty());
    }

    #[test]
    fn a_voice_memo_is_a_note_with_its_transcript_and_recording() {
        let audio = memo(AttachmentText::Done);
        let note = Note::with_attachment("call the plumber", &audio).unwrap();
        assert_eq!(note.content(), "call the plumber");
        assert_eq!(note.attachments(), vec![audio.clone()]);
        assert_eq!(note.attachment(&audio.id), Some(audio));
    }

    #[test]
    fn a_recording_with_no_text_is_not_an_empty_note() {
        let note = Note::with_attachment("", &memo(AttachmentText::Pending)).unwrap();
        assert_eq!(note.content(), "");
        assert!(!note.is_empty());
    }

    #[test]
    fn attachments_round_trip_through_bytes() {
        let audio = memo(AttachmentText::Pending);
        let note = Note::with_attachment("", &audio).unwrap();
        let copy = Note::from_bytes(&note.to_bytes()).unwrap();
        assert_eq!(copy.attachments(), vec![audio]);
    }

    #[test]
    fn attachments_are_listed_oldest_first() {
        let (a, b) = (memo(AttachmentText::None), memo(AttachmentText::None));
        let note = Note::new("x").attach(&b).unwrap().attach(&a).unwrap();
        let ids: Vec<String> = note.attachments().into_iter().map(|x| x.id).collect();
        assert_eq!(ids, vec![a.id, b.id]);
    }

    #[test]
    fn a_bad_attachment_is_refused() {
        let note = Note::new("x");
        let mut bad = memo(AttachmentText::None);
        bad.id = "nope".into();
        assert!(note.attach(&bad).is_err());
        let mut bad = memo(AttachmentText::None);
        bad.kind = String::new();
        assert!(note.attach(&bad).is_err());
        let audio = memo(AttachmentText::None);
        let note = note.attach(&audio).unwrap();
        assert!(note.attach(&audio).is_err());
    }

    #[test]
    fn removing_the_recording_keeps_the_text() {
        let audio = memo(AttachmentText::Done);
        let note = Note::with_attachment("call the plumber", &audio).unwrap();
        let text_only = note.detach(&audio.id).unwrap();
        assert!(text_only.attachments().is_empty());
        assert_eq!(text_only.content(), "call the plumber");
        assert!(text_only.detach(&audio.id).is_err());
    }

    #[test]
    fn clearing_the_text_keeps_the_recording() {
        let audio = memo(AttachmentText::Done);
        let note = Note::with_attachment("call the plumber", &audio).unwrap();
        let audio_only = note.update("").unwrap();
        assert_eq!(audio_only.attachments(), vec![audio]);
        assert!(!audio_only.is_empty());
    }

    #[test]
    fn two_devices_adding_attachments_to_an_old_note_keep_both() {
        // The reason attachments aren't entries in one shared map.
        let bytes = Note::new("trip").to_bytes();
        let (a, b) = (memo(AttachmentText::None), memo(AttachmentText::None));
        let phone = Note::from_bytes(&bytes).unwrap().attach(&a).unwrap();
        let laptop = Note::from_bytes(&bytes).unwrap().attach(&b).unwrap();
        let merged = phone.merge(&laptop).unwrap();
        assert_eq!(merged.attachments().len(), 2);
        assert_eq!(laptop.merge(&phone).unwrap().attachments().len(), 2);
    }

    #[test]
    fn a_text_edit_and_a_removed_recording_merge() {
        let audio = memo(AttachmentText::Done);
        let note = Note::with_attachment("call the plumber", &audio).unwrap();
        let edited = note.update("call the plumber today").unwrap();
        let removed = note.detach(&audio.id).unwrap();
        let merged = edited.merge(&removed).unwrap();
        assert_eq!(merged.content(), "call the plumber today");
        assert!(merged.attachments().is_empty());
    }

    #[test]
    fn a_deleted_note_keeps_its_attachments_for_sync_to_clean_up() {
        let audio = memo(AttachmentText::Done);
        let note = Note::with_attachment("x", &audio).unwrap();
        let deleted = note.delete().unwrap();
        assert!(deleted.is_deleted());
        assert_eq!(deleted.attachments(), vec![audio]);
    }

    #[test]
    fn a_pending_transcript_is_filled_in_once() {
        let audio = memo(AttachmentText::Pending);
        let note = Note::with_attachment("", &audio).unwrap();
        let filled = note.fill_text(&audio.id, " call the plumber \n").unwrap();
        assert_eq!(filled.content(), "call the plumber");
        assert_eq!(
            filled.attachment(&audio.id).unwrap().text,
            AttachmentText::Done
        );

        let again = filled.fill_text(&audio.id, "call the plumber").unwrap();
        assert_eq!(again.content(), "call the plumber");
        assert_eq!(again.heads(), filled.heads());
    }

    #[test]
    fn a_transcript_is_added_after_text_already_typed() {
        let audio = memo(AttachmentText::Pending);
        let note = Note::with_attachment("for Sam\n", &audio).unwrap();
        let filled = note.fill_text(&audio.id, "call the plumber").unwrap();
        assert_eq!(filled.content(), "for Sam\ncall the plumber");
    }

    #[test]
    fn silence_fills_in_as_done_with_no_text() {
        let audio = memo(AttachmentText::Pending);
        let note = Note::with_attachment("", &audio).unwrap();
        let filled = note.fill_text(&audio.id, "  ").unwrap();
        assert_eq!(filled.content(), "");
        assert_eq!(
            filled.attachment(&audio.id).unwrap().text,
            AttachmentText::Done
        );
    }

    #[test]
    fn filling_in_a_missing_attachment_is_an_error() {
        assert!(
            Note::new("x")
                .fill_text(&Attachment::new_id(), "hi")
                .is_err()
        );
    }

    #[test]
    fn an_unknown_kind_and_unknown_fields_survive_edits() {
        // A future client's attachment, built by hand: a kind and a field
        // this code has never heard of.
        let note = Note::new("holiday");
        let id = Attachment::new_id();
        let mut doc = note.branch();
        let map = doc
            .put_object(ROOT, key(&id).as_str(), ObjType::Map)
            .unwrap();
        doc.put(&map, KIND, "hologram").unwrap();
        doc.put(&map, MEDIA_TYPE, "model/x-holo").unwrap();
        doc.put(&map, SIZE, 2_400_000_u64).unwrap();
        doc.put(&map, "depth", 7_u64).unwrap();
        let note = sealed(doc);

        let edited = note
            .update("holiday photos")
            .unwrap()
            .attach(&memo(AttachmentText::None))
            .unwrap();
        let copy = Note::from_bytes(&edited.to_bytes()).unwrap();
        let kept = copy.attachment(&id).unwrap();
        assert_eq!(kept.kind, "hologram");
        assert_eq!(kept.label(), "hologram, 2 MB");
        let (_, map) = copy.doc.get(ROOT, key(&id).as_str()).unwrap().unwrap();
        assert!(copy.doc.get(&map, "depth").unwrap().is_some());
    }

    #[test]
    fn labels_say_what_a_client_cannot_show() {
        let mut audio = memo(AttachmentText::None);
        assert_eq!(audio.label(), "audio 0:42");
        audio.duration_ms = Some(3_725_000);
        assert_eq!(audio.label(), "audio 1:02:05");
        audio.duration_ms = None;
        audio.kind = "image".into();
        audio.size = 900;
        assert_eq!(audio.label(), "image, 900 B");
        audio.size = 1_500_000_000;
        assert_eq!(audio.label(), "image, 1.5 GB");
    }

    #[test]
    fn attachments_as_they_were_at_earlier_heads() {
        let audio = memo(AttachmentText::Done);
        let with = Note::with_attachment("x", &audio).unwrap();
        let without = with.detach(&audio.id).unwrap();
        assert_eq!(
            without.attachment_ids_at(&with.heads()).unwrap(),
            vec![audio.id]
        );
        assert!(
            without
                .attachment_ids_at(&without.heads())
                .unwrap()
                .is_empty()
        );
        assert!(
            without
                .attachment_ids_at(&Note::new("other").heads())
                .is_err()
        );
    }
}
