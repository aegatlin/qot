# Release tags are pushed by hand

Status: decided
Date: 2026-11-06
Question: Who creates release tags (`cli/v*`, `server/v*`, later `ios/v*`),
now that cloud agent sessions can't push tags?

## Answer

**A person pushes every release tag by hand**, for every component. No
workflow creates tags. A release is: bump the version (where the component
has one), merge, then push the tag on the merge commit from your own
machine. Claude Code running locally may push `cli/v*` tags when asked
(`.claude/settings.json` allows it); cloud sessions can't.

## Why

- **Cloud sessions can't push tags, by design.** In Anthropic-hosted cloud
  sessions every git push goes through Anthropic's GitHub proxy, which keeps
  the GitHub credential outside the session's VM. The proxy "rejects branch
  deletions and pushes of anything other than a branch, such as a tag"
  ([Claude Code docs, GitHub proxy][proxy]). Tried on 2026-11-06 from two
  sessions: `git push origin cli/v0.1.1` got a 403 with
  `ERR push contains a ref outside refs/heads/*; only branch updates are
  permitted.`, answered by the proxy (no `X-Github-Request-Id`, unlike
  GitHub's own responses in the same push). No GitHub-side setting
  (token, ruleset, App permission) changes it.
- **One rule for every component.** Tag-on-bump (below) would work for all
  of them, but it adds a token to renew, a workflow to maintain, and a new
  habit for the server (bumping `mix.exs`), while rollbacks stay manual
  anyway. Releasing is rare while dogfooding, so the manual step costs less
  than the machinery.
- **Releases stay a deliberate act.** A tag is what ships to Homebrew,
  production and (later) TestFlight; it is fine for that to need a person.

## Options considered

- **Tag-on-bump** (turned down for now): a workflow on every push to `main`
  reads each component's version (`client_cli/Cargo.toml`,
  `server_web/mix.exs`, `client_apple/project.yml`) and creates the
  `<component>/vX.Y.Z` tag when it doesn't exist. It fits every current and
  planned component, would let a cloud agent release by merging a version
  bump, and is a known pattern (release-please, release-plz and Changesets
  tag on merging a release PR; smaller actions such as
  [salsify/action-detect-and-tag-new-version][salsify] tag on a version
  change). Costs: tags pushed with `GITHUB_TOKEN` don't start other
  workflows ([GitHub docs][token]), so it needs a GitHub App token or a
  fine-grained token renewed yearly; versions only move forward, so a server
  rollback is still a hand-pushed tag.
- **A "Release" workflow started by hand** (`workflow_dispatch`, component
  and version as inputs): the proxy allows GitHub API calls, so an agent
  could start it. Same token problem, and the version file could drift from
  what shipped.
- **Push from a local Claude Code session**: works with the person's own git
  credentials; kept as allowed for `cli/v*`.

Revisit if releases become frequent, or if more than one person releases.

## Sources

- [Claude Code docs: Configure cloud environments, GitHub proxy][proxy]
- [GitHub docs: GITHUB_TOKEN (events it creates don't start workflow runs)][token]
- [release-plz](https://release-plz.dev/),
  [release-please](https://github.com/googleapis/release-please),
  [changesets/action](https://github.com/changesets/action)
- [salsify/action-detect-and-tag-new-version][salsify],
  [tamasfe/auto-tag](https://github.com/tamasfe/auto-tag)

[proxy]: https://code.claude.com/docs/en/cloud-environments#github-proxy
[token]: https://docs.github.com/en/actions/concepts/security/github_token
[salsify]: https://github.com/salsify/action-detect-and-tag-new-version
