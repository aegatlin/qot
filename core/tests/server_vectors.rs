//! Test vectors for the server's binding (`vectors/server.json`): notes as
//! the server holds them, a change log each, with what reading and editing
//! them must give. `Qot.CoreTest` (Elixir, through `qot_nif`) replays them,
//! and so does this file, so the binding can't drift from the core.
//!
//! Generated from real notes, then committed:
//! `cargo test -p qot_core --test server_vectors -- --ignored regenerate`.

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use qot_core::{AUDIO, Attachment, AttachmentText, Note};
use serde::{Deserialize, Serialize};

const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors/server.json");

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Vectors {
    about: String,
    cases: Vec<Case>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Case {
    name: String,
    /// The note's changes as the account's log holds them, base64, in order.
    log: Vec<String>,
    /// What reading the log gives.
    read: Read,
    /// `fill_text(attachment, text)` on the log, if the case has one.
    fill: Option<Fill>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Read {
    id: String,
    content: String,
    deleted: bool,
    attachments: Vec<Seen>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Seen {
    id: String,
    kind: String,
    media_type: String,
    size: u64,
    duration_ms: Option<u64>,
    text: String,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Fill {
    attachment: String,
    text: String,
    /// Whether a change comes back (false: it wasn't waiting for text).
    changes: bool,
    /// The note's content with that change applied.
    content: String,
    /// A change a device made from the same log meanwhile, and the content
    /// once both are in the log, if the case has one.
    meanwhile: Option<String>,
    content_with_both: Option<Vec<String>>,
}

fn status(text: AttachmentText) -> &'static str {
    match text {
        AttachmentText::None => "none",
        AttachmentText::Pending => "pending",
        AttachmentText::Done => "done",
    }
}

fn read(note: &Note) -> Read {
    Read {
        id: note.id(),
        content: note.content(),
        deleted: note.is_deleted(),
        attachments: note
            .attachments()
            .into_iter()
            .map(|a| Seen {
                id: a.id,
                kind: a.kind,
                media_type: a.media_type,
                size: a.size,
                duration_ms: a.duration_ms,
                text: status(a.text).to_string(),
            })
            .collect(),
    }
}

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

/// A log: the first version whole, then each later version's changes.
fn log(versions: &[&Note]) -> Vec<String> {
    let mut out = vec![B64.encode(versions[0].to_bytes())];
    for pair in versions.windows(2) {
        out.push(B64.encode(pair[1].changes_since(pair[0].heads()).unwrap()));
    }
    out
}

fn build() -> Vectors {
    let mut cases = Vec::new();

    let v1 = Note::new("milk");
    let v2 = v1.update("oat milk").unwrap();
    cases.push(Case {
        name: "a text note, edited once".into(),
        log: log(&[&v1, &v2]),
        read: read(&v2),
        fill: None,
    });

    let gone = v2.delete().unwrap();
    cases.push(Case {
        name: "a deleted note is a tombstone".into(),
        log: log(&[&v1, &v2, &gone]),
        read: read(&gone),
        fill: None,
    });

    let audio = memo(AttachmentText::Pending);
    let waiting = Note::with_attachment("", &audio).unwrap();
    cases.push(Case {
        name: "a memo waiting for its text gets it".into(),
        log: log(&[&waiting]),
        read: read(&waiting),
        fill: Some(Fill {
            attachment: audio.id.clone(),
            text: " call the plumber\n".into(),
            changes: true,
            content: "call the plumber".into(),
            meanwhile: None,
            content_with_both: None,
        }),
    });

    let audio = memo(AttachmentText::Pending);
    let titled = Note::with_attachment("plumber", &audio).unwrap();
    let typed = titled.update("the plumber").unwrap();
    cases.push(Case {
        name: "text typed meanwhile merges with the transcript".into(),
        log: log(&[&titled]),
        read: read(&titled),
        fill: Some(Fill {
            attachment: audio.id.clone(),
            text: "on Tuesday at nine".into(),
            changes: true,
            content: "plumber\non Tuesday at nine".into(),
            meanwhile: Some(B64.encode(typed.changes_since(titled.heads()).unwrap())),
            content_with_both: Some(vec!["the plumber\non Tuesday at nine".into()]),
        }),
    });

    let audio = memo(AttachmentText::Pending);
    let waiting = Note::with_attachment("", &audio).unwrap();
    let filled = waiting.fill_text(&audio.id, "call the plumber").unwrap();
    let cleared = filled.update("").unwrap();
    cases.push(Case {
        name: "a transcript deleted by hand is not written again".into(),
        log: log(&[&waiting, &filled, &cleared]),
        read: read(&cleared),
        fill: Some(Fill {
            attachment: audio.id.clone(),
            text: "call the plumber".into(),
            changes: false,
            content: "".into(),
            meanwhile: None,
            content_with_both: None,
        }),
    });

    let audio = memo(AttachmentText::None);
    let plain = Note::with_attachment("no text wanted", &audio).unwrap();
    cases.push(Case {
        name: "a recording nobody asked text for is left alone".into(),
        log: log(&[&plain]),
        read: read(&plain),
        fill: Some(Fill {
            attachment: audio.id.clone(),
            text: "call the plumber".into(),
            changes: false,
            content: "no text wanted".into(),
            meanwhile: None,
            content_with_both: None,
        }),
    });

    Vectors {
        about: "Test vectors for the server's binding; see core/tests/server_vectors.rs. \
                Generated, do not edit."
            .into(),
        cases,
    }
}

fn load() -> Vectors {
    serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap()
}

#[test]
#[ignore = "rewrites the committed vectors"]
fn regenerate() {
    let json = serde_json::to_string_pretty(&build()).unwrap();
    std::fs::write(PATH, json + "\n").unwrap();
}

#[test]
fn the_core_gives_what_the_vectors_say() {
    let vectors = load();
    assert!(vectors.cases.len() >= 6);
    for case in &vectors.cases {
        let bytes: Vec<Vec<u8>> = case.log.iter().map(|c| B64.decode(c).unwrap()).collect();
        let log: Vec<&[u8]> = bytes.iter().map(Vec::as_slice).collect();
        let note = Note::from_changes(&log).unwrap();
        assert_eq!(read(&note), case.read, "{}", case.name);

        let Some(fill) = &case.fill else { continue };
        let filled = note.fill_text(&fill.attachment, &fill.text).unwrap();
        assert_eq!(
            filled.heads() != note.heads(),
            fill.changes,
            "{}",
            case.name
        );
        assert_eq!(filled.content(), fill.content, "{}", case.name);
        if let (Some(meanwhile), Some(expected)) = (&fill.meanwhile, &fill.content_with_both) {
            let both = filled
                .apply_changes(&B64.decode(meanwhile).unwrap())
                .unwrap();
            assert!(expected.contains(&both.content()), "{}", case.name);
        }
    }
}
