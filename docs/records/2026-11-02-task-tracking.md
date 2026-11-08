# Where todos live

Status: decided (the roadmap part superseded by 2026-11-08-issues-are-the-backlog.md)
Date: 2026-11-02
Question: Where do todos go (code, ops, and things only a person can do), so
that after a month away the next one is easy to find, for you and for
agents?

## Answer

**Plain GitHub issues**, no labels for now. Issues for a person say "**Who:**
a person" in the body. `docs/ROADMAP.md` is the map: it orders issues into
steps and says why. `docs/records/` holds research and decisions. To pick up
after a break: open the roadmap, take the first open issue in the first
unfinished step (or run `gh issue list`).

## Why

- **One list, reachable everywhere.** `gh issue list`, the GitHub web page,
  the GitHub app. Cloud agent sessions (claude.ai/code) reach GitHub through
  the built-in GitHub proxy with no setup, so an agent can read the list,
  pick up an issue and close it with `Fixes #N` in a PR.
- **History.** A closed issue keeps its discussion and links to the PR that
  did the work.
- **No new vendor or bill**, for a project meant to run for years before
  revenue. The data stays next to the code.
- **Human tasks fit too.** "Back up the age key" (#3) is not code, but it
  belongs to this project's state, and this is where you'll look.

## Options considered

- **Linear**: a better tool for triage and cycles across many repos and
  people, and it can import GitHub issues later. For one person it's another
  vendor and subscription. Revisit with a team.
- **`TODO.md` in the repo**: no setup, and agents can edit it. But a list of
  checkboxes with no history either goes stale or grows enormous, and it only
  works if every session remembers to edit it. The roadmap was one before this
  change.
- **GitHub Projects board / labels**: skipped for now to keep it plain. Add a
  board or a few labels when the open list gets hard to scan.
