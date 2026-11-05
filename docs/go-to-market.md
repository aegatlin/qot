# Go-to-market (draft, open questions)

Not marketing; the question is what's free, what's paid, and why someone
would pay. Nothing here is decided.

## The shape being considered

The note-taking is free, forever: every client, unlimited notes, works fully
offline on one device. The paid product is the **managed cloud**: we run the
sync server so notes appear on your other devices.

This fits the architecture: clients are complete on their own, and the server
is a relay for opaque change blobs. "Free app, paid sync" is a well-trodden
model (Obsidian Sync, Bear Pro, Things Cloud being bundled into the price).

## Questions to settle

1. **Is sync itself paid, or only "more" sync?** Options:
   - Sync is paid from day one (simplest story; free = single device).
   - Free sync with limits (2 devices, or N notes, or 30-day history), paid
     removes them. Lowers the barrier, since sync *is* the product's promise
     ("on your other devices by the time you look"), but costs infra for
     free users.
   - Free trial of sync (e.g. 30 days), then paid.
2. **Self-hosting.** The server is in this repo. Do we let people point
   `qot --server` at their own instance? That is a strong trust signal for an
   E2EE notes tool and costs us little, while most people will still pay to
   not run Postgres. Decided: yes, the code is AGPL-3.0 and self-hosting is allowed
   ([records/2026-11-04-open-source-or-closed.md](records/2026-11-04-open-source-or-closed.md)).
3. **What else is "managed cloud"?** Candidates that need a server:
   - Sync across devices (core)
   - Capture channels: email-to-note, SMS, a share link, webhooks
   - Version history / restore deleted notes
   - Opt-in pipelines that read notes (transcribe voice memos, AI tagging,
     reminders). These require the user to opt out of E2EE for that data
     (see CLAUDE.md), so they suit a higher tier.
4. **Price point and billing.** Roughly $2-5/month or $20-40/year is the
   range for single-purpose sync. Billing via Stripe on the web; on iOS,
   Apple rules apply to in-app purchase (or sell on the web only, and the
   app just signs in).
5. **Launch pricing.** Launch v1 with sync free while it's an early
   beta, saying plainly that it will become paid? Avoids building billing
   before anyone uses it, but the promise must be explicit in the terms.

## What v1 needs regardless

- An account limit or kill switch per user (so free beta sync can't be
  abused for bulk storage).
- A way to tell users about pricing changes (we have their email).
