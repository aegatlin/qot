# Issues are the backlog; the roadmap is retired

Status: decided
Date: 2026-11-08
Question: Now that every piece of work is a GitHub issue, does `docs/ROADMAP.md`
still earn its keep?

## Answer

**No. `docs/ROADMAP.md` is removed, and open GitHub issues are the whole
backlog.** This replaces the roadmap part of
[Where todos live](2026-11-02-task-tracking.md); the rest of that record
(plain issues, "**Who:** a person" for human tasks) stands.

To pick up after a break: `gh issue list`. Priorities between clients are in
CLAUDE.md's "Product" section (CLI, then PWA, then iOS, then a Mac app);
anything finer is said in the issues themselves.

## Why

- **It went stale.** On 2026-11-08 its "Where things stand" table still said
  the PWA and the website weren't deployed (both were in production) and
  listed #14 as next (CLI releases had shipped as `cli/v0.1.0`–`v0.1.2`).
  #14 and #19 were still open because nothing tied finishing the work to
  closing them. A second list that every PR has to remember to edit drifts,
  which is what the 2026-11-02 record said about a `TODO.md`.
- **Its content already lives elsewhere.** Each step was an issue; the
  "why" of each choice is in a record; the deferred work is issues closed as
  not planned (`gh issue list --state closed --search "reason:not-planned"`:
  #6, #8, #9, #11, #15, #16), reopened when a public launch makes them
  matter.
- **What was only in the roadmap became issues**: its "After dogfooding"
  directions (end-to-end encryption, a Mac app). Billing waits on #16.

## Options considered

- **Keep it and update it with every PR**: the cost that already failed.
- **A GitHub Projects board or milestones for order**: not needed while the
  open list fits on one screen. Add one when it doesn't.

The last version of the roadmap is in git history (`git log -- docs/ROADMAP.md`).
