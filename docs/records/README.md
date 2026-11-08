# Records

Research, ideation and decisions, kept so the reasoning outlives the
conversation that produced it. qot is meant to run for years; a record is how a
future reader (or agent) finds out *why* something is the way it is, and what
was considered and turned down.

## Conventions

- One file per question: `YYYY-MM-DD-short-slug.md`, dated when it was
  written. The date prefix keeps the folder in order.
- Start with a header block:

  ```
  Status: research | proposed | decided | superseded by <file>
          | decided (<part> superseded by <file>)
  Date: YYYY-MM-DD
  Question: one sentence
  ```

- Lead with the answer (or "open"), then the reasoning, then the options
  considered, then sources. Mark claims that come from third-party sites or
  that were not verified; prices and features drift.
- Records are history. Once a record is `decided`, don't rewrite it to match
  a later change of mind: write a new record and set the old one's status to
  `superseded by …` (or `decided (<part> superseded by …)` when only part
  changed). Small corrections (typos, dead links) are fine.
- Agents read records and act on them, so a superseded record (or part) also
  gets a short `> **Since then:** …` note under its header saying what is true
  now. Update this index in the same change.
- Actionable follow-ups belong in the issue tracker, linked from
  the record, not tracked in the record itself.

## Index

| Date | Record | Status |
|---|---|---|
| 2026-11-02 | [Hosting platform for the sync server](2026-11-02-hosting-platform.md) | decided |
| 2026-11-02 | [Secrets management for a solo developer](2026-11-02-secrets-management.md) | decided |
| 2026-11-02 | [Where todos live](2026-11-02-task-tracking.md) | decided (its roadmap part superseded 2026-11-08) |
| 2026-11-04 | [Domain layout](2026-11-04-domain-layout.md) | decided (hosting of `app.`/`www.` and the sign-in host superseded 2026-11-06) |
| 2026-11-04 | [Repo layout for many clients](2026-11-04-repo-layout-for-clients.md) | decided (its XcodeGen part superseded 2026-11-08) |
| 2026-11-04 | [Open source or closed source](2026-11-04-open-source-or-closed.md) | decided |
| 2026-11-06 | [Release tags are pushed by hand](2026-11-06-release-tags-by-hand.md) | decided |
| 2026-11-06 | [Hosting the PWA and the website](2026-11-06-hosting-the-pwa-and-website.md) | decided |
| 2026-11-06 | [Sign-in through the PWA](2026-11-06-sign-in-through-the-pwa.md) | decided |
| 2026-11-08 | [A committed, Apple-native Xcode project](2026-11-08-apple-native-project.md) | decided |
| 2026-11-08 | [Issues are the backlog; the roadmap is retired](2026-11-08-issues-are-the-backlog.md) | decided |
| 2026-11-08 | [Why the Apple apps don't use automerge-swift](2026-11-08-why-not-automerge-swift.md) | decided |
| 2026-11-08 | [Sign in with Apple on Apple devices](2026-11-08-sign-in-with-apple.md) | decided |
