// A voice memo as an iPhone would make it, for tests: the note, its
// attachment and some bytes standing in for the recording.
import { Attachment, Note } from "../src/core/qot_wasm";

export function memo(text = "call the plumber", textState = "done") {
  const audio = new Attachment(Attachment.newId(), "audio", "audio/mp4", 340_000, 42_000, textState);
  const note = Note.withAttachment(text, audio);
  return { note, audio, bytes: new Uint8Array([0, 1, 2, 255, 254, 3]) };
}
