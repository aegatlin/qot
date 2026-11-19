import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, type Page, test } from "@playwright/test";
import { Attachment, initSync, Note } from "../src/core/qot_wasm.js";
import { API, Cli, Server } from "./harness";

// Voice memos end to end (docs/records/2026-11-19-attachments-and-voice-memos.md):
// a device records a memo, and the PWA shows the note, plays the recording
// once it has arrived, and deletes both everywhere.
//
// Nothing here can record, so the test is the phone: it makes the note with
// the same core the iPhone uses, puts it in a CLI device's store to be
// synced, and uploads the recording itself.

initSync({ module: readFileSync(new URL("../src/core/qot_wasm_bg.wasm", import.meta.url)) });

const server = new Server();
test.beforeAll(async () => server.start());
test.afterAll(async () => server.stop());

/** One second of a 440 Hz tone: a real file the browser can play. */
function tone(): Uint8Array {
  const rate = 8000;
  const samples = rate;
  const wav = Buffer.alloc(44 + samples * 2);
  wav.write("RIFF", 0);
  wav.writeUInt32LE(36 + samples * 2, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); // PCM
  wav.writeUInt16LE(1, 22); // mono
  wav.writeUInt32LE(rate, 24);
  wav.writeUInt32LE(rate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i++) {
    wav.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 8000), 44 + i * 2);
  }
  return new Uint8Array(wav);
}

/** The phone records a memo: its note goes into the device's store. */
function record(phone: Cli, text: string, bytes: Uint8Array) {
  const audio = new Attachment(Attachment.newId(), "audio", "audio/wav", bytes.length, 1000, "done");
  const note = Note.withAttachment(text, audio);
  mkdirSync(join(phone.dir, "notes"), { recursive: true });
  writeFileSync(join(phone.dir, "notes", `${note.id}.note`), note.toBytes());
  return { noteId: note.id, blobId: audio.id };
}

const blobUrl = (id: string) => `${API}/api/blobs/${id}`;

async function upload(phone: Cli, memo: { noteId: string; blobId: string }, bytes: Uint8Array) {
  const response = await fetch(`${blobUrl(memo.blobId)}?note_id=${memo.noteId}`, {
    method: "PUT",
    headers: { authorization: `Bearer ${phone.accessToken()}`, "content-type": "audio/wav" },
    body: new Blob([bytes as BlobPart]),
  });
  expect(response.status).toBe(204);
}

async function onServer(phone: Cli, blobId: string): Promise<number> {
  return (await fetch(blobUrl(blobId), { headers: { authorization: `Bearer ${phone.accessToken()}` } })).status;
}

async function signIn(page: Page, phone: Cli, email: string) {
  const login = phone.login(email);
  const code = await login.code;
  await page.goto(await server.signInLink(email));
  await page.getByLabel("Code").fill(code);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByTestId("sync-status")).toHaveText("Synced");
  await login.exited;
}

test("a recorded memo shows up with its text, plays once it arrives, and is deleted everywhere", async ({ page }) => {
  const phone = new Cli();
  await signIn(page, phone, `e2e-memo-${Date.now()}@example.com`);
  const bytes = tone();

  // The phone records. Its note syncs at once; the recording is still on
  // its way.
  const memo = record(phone, "call the plumber", bytes);
  expect(phone.run("sync").status).toBe(0);
  expect(phone.run("list").stdout).toBe("1. [audio 0:01] call the plumber\n");

  const list = page.getByRole("list", { name: "Notes" });
  const row = list.getByRole("link", { name: /call the plumber/ });
  await expect(row).toContainText("audio 0:01", { timeout: 10_000 });
  await row.click();
  await expect(page.getByLabel("Edit note")).toHaveValue("call the plumber");
  const recording = page.getByTestId("recording");
  await expect(recording).toContainText("Voice memo 0:01");
  await expect(recording).toContainText("Audio on its way");

  // The recording arrives, and plays.
  await upload(phone, memo, bytes);
  await recording.getByRole("button", { name: "Try again" }).click();
  const audio = recording.locator("audio");
  await expect(audio).toBeVisible();
  await expect
    .poll(() => audio.evaluate((el: HTMLAudioElement) => (Number.isFinite(el.duration) ? Math.round(el.duration) : -1)))
    .toBe(1);
  expect(await audio.evaluate((el: HTMLAudioElement) => el.error)).toBeNull();

  // The export from the terminal has the same bytes.
  const out = join(phone.dir, "backup");
  const exported = phone.run("export", "--dir", out);
  expect(exported.status, exported.stderr).toBe(0);
  expect(new Uint8Array(readFileSync(join(out, "attachments", `${memo.blobId}.wav`)))).toEqual(bytes);

  // Reopening the note plays from this browser's copy, even offline.
  await page.getByRole("button", { name: "‹ Notes" }).click();
  await page.context().setOffline(true);
  await row.click();
  await expect(recording.locator("audio")).toBeVisible();
  await page.context().setOffline(false);

  // Deleting the note in the browser deletes the recording on the server
  // and the note on the phone.
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  await expect(page.getByText("No notes yet")).toBeVisible();
  await expect.poll(() => onServer(phone, memo.blobId), { timeout: 10_000 }).toBe(404);
  await expect.poll(() => phone.run("list").stdout, { timeout: 10_000 }).toContain("No notes yet");
});

test("the recording can be removed and the text kept, or the text cleared and the recording kept", async ({ page }) => {
  const phone = new Cli();
  await signIn(page, phone, `e2e-memo-parts-${Date.now()}@example.com`);
  const bytes = tone();
  const keepText = record(phone, "buy a washer", bytes);
  const keepAudio = record(phone, "um, testing", bytes);
  expect(phone.run("sync").status).toBe(0);
  await upload(phone, keepText, bytes);
  await upload(phone, keepAudio, bytes);

  const list = page.getByRole("list", { name: "Notes" });
  const recording = page.getByTestId("recording");

  // Remove the audio: an ordinary text note is left.
  await list.getByRole("link", { name: /buy a washer/ }).click({ timeout: 10_000 });
  await expect(recording.locator("audio")).toBeVisible();
  await recording.getByRole("button", { name: "Remove audio" }).click();
  await recording.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(recording).toHaveCount(0);
  await expect(page.getByLabel("Edit note")).toHaveValue("buy a washer");
  await expect.poll(() => onServer(phone, keepText.blobId), { timeout: 10_000 }).toBe(404);
  await expect.poll(() => phone.run("list").stdout, { timeout: 10_000 }).toContain("buy a washer");
  expect(phone.run("list").stdout).not.toContain("] buy a washer");

  // Clear the text: the recording is still a note, titled as a voice memo.
  await list.getByRole("link", { name: /um, testing/ }).click();
  await page.getByLabel("Edit note").fill("");
  await page.getByRole("button", { name: "‹ Notes" }).click();
  await expect(list.getByRole("link", { name: /Voice memo 0:01/ })).toBeVisible();
  await expect.poll(() => phone.run("list").stdout, { timeout: 10_000 }).toMatch(/^\d\. \[audio 0:01\]$/m);
  expect(await onServer(phone, keepAudio.blobId)).toBe(200);
});
