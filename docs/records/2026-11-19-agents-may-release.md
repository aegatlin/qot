# Agents may release when the owner has authorized it

Status: decided
Date: 2026-11-19
Question: May an agent push release tags and move the production branches,
and how does a release workflow move a branch past commits that change
workflow files?

## Answer

**An agent may cut a release when the repo owner has authorized it**, in
that session or in the agent's memory: push `cli/v*`, `server/v*`, `web/v*`
and `site/v*` tags, and move `production`, `production-web` and
`production-site` (force-push included). Without that authorization the
old rule holds: agents don't push tags or deploy production. The owner
gave it as a standing rule on 2026-11-19. This supersedes the "agents
don't push tags, locally or in the cloud" part of
[Release tags are pushed by hand](2026-11-06-release-tags-by-hand.md); the
rest of that record stands (no workflow creates tags; cloud sessions can't
push tags, because Anthropic's GitHub proxy allows branch pushes only).

**The release workflows move their branch with a deploy key**, not the
workflow's `GITHUB_TOKEN`: `RELEASE_DEPLOY_KEY`, a secret of the
`production` GitHub environment, given to `actions/checkout` as `ssh-key`
in the promote job of `release-server.yml`, `release-web.yml` and
`release-site.yml`.

## Why

- **Releases were waiting on one person for a mechanical step.** The
  voice memo release (server 0.5.0, web 0.5.0, site 0.4.0, CLI 0.3.0) was
  built and checked by an agent that then couldn't ship it. A release is
  still deliberate: the owner says so first.
- **`GITHUB_TOKEN` can't push workflow changes.** The `server/v0.5.0` run
  passed CI and failed at the promote step: `refusing to allow a GitHub App
  to create or update workflow .github/workflows/apple.yml without
  workflows permission`. The commits between two releases had changed
  workflow files, and moving `production` brings them to that branch. The
  `workflows` permission can't be granted to `GITHUB_TOKEN` in a workflow's
  `permissions`. That release was made by pushing the three branches by
  hand, then running the smoke workflows.
- **A deploy key is the narrowest credential that works**: one repo, no
  account-wide token, no expiry to renew, and as an environment secret only
  jobs that name the `production` environment can read it. A push made
  with it does start workflows, unlike one made with `GITHUB_TOKEN`;
  nothing runs on pushes to the production branches, so nothing changes.

## Options considered

- **A fine-grained personal token with Workflows write**: works, but it
  is tied to a person's account and expires within a year (like
  `HOMEBREW_TAP_TOKEN`).
- **A GitHub App**: the right answer with several maintainers; more to set
  up than one key for one push.
- **Deploying through Railway's API instead of a branch**: needs a Railway
  token in GitHub, a wider credential than a key that can only write to
  this repo.
- **Keeping workflow changes out of releases**: not possible; any commit
  on main may change a workflow.

## Sources

- The failed run: "Release server" 44517947558 on `server/v0.5.0`.
- [GitHub docs: deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
- [actions/checkout: `ssh-key`](https://github.com/actions/checkout#usage)
