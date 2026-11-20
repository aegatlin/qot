//! `qot_core` for the server, as an Erlang NIF (Rustler): `Qot.Core` in
//! `server_web`. Like `qot_ffi` and `qot_wasm` it adapts types only; the
//! rules stay in `qot_core`.
//!
//! The server holds a note as its changes in the account's log, in order,
//! so every function takes that list. Functions run on dirty schedulers:
//! building a note from its log is not a sub-millisecond job.

use qot_core::{AttachmentText, Note};
use rustler::{Binary, Env, NewBinary, NifMap};

/// What the server may know of a note.
#[derive(NifMap)]
struct NoteView {
    id: String,
    content: String,
    deleted: bool,
    heads: Vec<String>,
    attachments: Vec<AttachmentView>,
}

#[derive(NifMap)]
struct AttachmentView {
    id: String,
    kind: String,
    media_type: String,
    size: u64,
    duration_ms: Option<u64>,
    /// `none`, `pending` or `done`.
    text: String,
}

fn note(changes: &[Binary]) -> Result<Note, String> {
    let changes: Vec<&[u8]> = changes.iter().map(|c| c.as_slice()).collect();
    Note::from_changes(&changes).map_err(|e| e.to_string())
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.into()
}

/// The note these changes make.
#[rustler::nif(schedule = "DirtyCpu")]
fn read(changes: Vec<Binary>) -> Result<NoteView, String> {
    let note = note(&changes)?;
    Ok(NoteView {
        id: note.id(),
        content: note.content(),
        deleted: note.is_deleted(),
        heads: note.heads(),
        attachments: note
            .attachments()
            .into_iter()
            .map(|a| AttachmentView {
                id: a.id,
                kind: a.kind,
                media_type: a.media_type,
                size: a.size,
                duration_ms: a.duration_ms,
                text: match a.text {
                    AttachmentText::None => "none",
                    AttachmentText::Pending => "pending",
                    AttachmentText::Done => "done",
                }
                .to_string(),
            })
            .collect(),
    })
}

/// Writes an attachment's text into the note (`Note::fill_text`: once,
/// under any text already there). Returns the change to append to the log,
/// or `nil` when the attachment wasn't waiting for text.
#[rustler::nif(schedule = "DirtyCpu")]
fn fill_text<'a>(
    env: Env<'a>,
    changes: Vec<Binary>,
    attachment_id: String,
    text: String,
) -> Result<Option<Binary<'a>>, String> {
    let before = note(&changes)?;
    let after = before
        .fill_text(&attachment_id, &text)
        .map_err(|e| e.to_string())?;
    if after.heads() == before.heads() {
        return Ok(None);
    }
    let change = after
        .changes_since(before.heads())
        .map_err(|e| e.to_string())?;
    Ok(Some(binary(env, &change)))
}

rustler::init!("Elixir.Qot.Core");
