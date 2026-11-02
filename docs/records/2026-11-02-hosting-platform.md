# Hosting platform for the sync server

Status: proposed
Date: 2026-11-02
Question: Where should `server_web` (Phoenix + Postgres) run in staging and
production?

## Answer

**Railway**, in a new workspace owned by Abstract Syntax, with Railway
Postgres. Revisit if cost at scale or multi-region latency starts to matter.
Fly.io is the runner-up and the planned exit: both run the same Dockerfile, so
moving costs a weekend, not a rewrite.

## What matters for this project

qot is run by one person, mostly through coding agents (local Claude Code and
cloud sessions at claude.ai/code), for years before it makes money. So the
criteria, in order:

1. **Agent operability.** An agent can deploy, read logs and diagnose a
   failure without a human copying output around, both locally and in a
   cloud session.
2. **Little to own.** Managed Postgres with backups, auto-deploy from GitHub,
   staging and prod without hand-written pipelines.
3. **Cheap while idle, predictable when not.**
4. **Longevity.** The vendor is likely to be around and actively developed.
5. **Fit for Phoenix.** Long-lived WebSockets (the `notes:user:*` channel),
   a release in Docker. Every candidate below handles this; it is not a
   differentiator for one small node.

The workload is tiny: one Phoenix node and one Postgres database holding a
per-user log of changes. No multi-region requirement, no clustering.

## Agent operability, including cloud sessions

This criterion decides it, so the detail is worth keeping.

**Local sessions.** Railway and Fly both work well. Railway ships an MCP
server (`railway mcp`, built on the CLI login) with tools for deploys, logs,
variables, environments and metrics, and it is already connected here. Fly
ships `flyctl`, which is very scriptable, plus an MCP server in flyctl (`fly
mcp server`) and a newer hosted one installed with `fly setup agent`.

**Cloud sessions (claude.ai/code, `claude --cloud`)** are a fresh VM with a
fresh clone. What carries over and what doesn't, per the Claude Code docs:

- MCP servers from `~/.claude.json` (user or local scope, which is how
  Railway and Neon are set up on this machine) do **not** carry over. A
  committed `.mcp.json` does. MCP connector traffic bypasses the network
  allowlist, and a session can wait for you to sign in to an MCP server.
- The default **Trusted** network allowlist covers package registries,
  GitHub, Docker Hub, `*.amazonaws.com` and so on, but **no hosting
  platform**: not `railway.com`, `fly.io`, `render.com` or `neon.tech`. Any
  host's CLI or API needs a **Custom** allowlist entry, or a **network
  secret** whose host list includes the API host (the proxy attaches the
  token and the host becomes reachable).
- Environment variables on a cloud environment are readable by anyone using
  it, so a token stored there should be narrowly scoped.
- GitHub works everywhere through the GitHub proxy.

What follows from that:

- **Deploys should not need an agent at all.** Merge to `main` → the
  platform deploys. Railway does this natively from GitHub, with "Wait for
  CI" holding a deploy until the GitHub Actions check suites pass. Fly needs
  a GitHub Actions workflow holding a deploy token, which is also fine. In
  both cases a cloud session sees the outcome through GitHub, which it can
  always reach.
- **Per-PR environments suit agent PRs.** Railway's PR environments spin up
  a temporary environment per pull request and delete it on merge or close.
  There is an explicit toggle for bot-opened PRs that names Claude Code. An
  agent's PR gets a live server to run the CLI against. On Fly you build this
  yourself in Actions. To let a cloud session reach those URLs, add
  `*.up.railway.app` to its Custom allowlist.
- **Debugging from a cloud session** needs platform access. For Railway,
  the cleanest option is the hosted MCP at `https://mcp.railway.com`, added
  to a committed `.mcp.json` and signed into with OAuth. Access can be scoped
  to the qot project, and tokens are short-lived and revocable. Its tool list
  is smaller than the local one (projects, deploys, feature flags, and a
  `railway-agent` for open-ended work like log analysis). Railway project
  tokens are rejected by the MCP server, but the CLI accepts them, so an
  environment-scoped project token plus a Custom allowlist for
  `backboard.railway.com` is the fallback for CLI use. For Fly, the
  equivalent is an app-scoped deploy token plus allowlisting `api.fly.io` /
  `api.machines.dev` and installing flyctl in a setup script. **Not yet
  tested in a cloud session**: try it when the pipeline is up.

Net: Railway is a little better for cloud sessions (deploys and previews come
from GitHub with nothing for the agent to authenticate, plus a hosted OAuth
MCP), and clearly better for PR-driven agent work.

## Options considered

| | Agent operability | Postgres | Staging / previews | Idle cost (approx.) | Longevity | Verdict |
|---|---|---|---|---|---|---|
| **Railway** | Local MCP (CLI) + hosted OAuth MCP; GitHub-native deploys | Built in, same project; scheduled volume backups | Environments; PR environments, incl. bot PRs | Hobby $5/mo or Pro $20/mo, which counts as usage credit | Growing, VC-backed | **Chosen** |
| **Fly.io** | flyctl (excellent), flyctl MCP, hosted MCP via `fly setup agent` | Managed Postgres, ~$38/mo Basic\*; or self-run on a Machine | Separate apps; previews are DIY in Actions | ~$40–50/mo with Managed Postgres\* | Established, Elixir-friendly | Runner-up / exit |
| **Render** | MCP server (create resources, deploy, env vars) | Managed; free tier expires after 30 days; paid from ~$6/mo\* | Preview environments, billed as services | Pro workspace ~$25/mo flat + services\* | Established | Viable; nothing it does better here |
| **DigitalOcean App Platform** | Official MCP (strongest on databases) | Managed, ~$15/mo single node\* | Not confirmed | ~$5 app + $15 DB\* | Public company, stable | Viable, more knobs, less polish |
| **Heroku** | Weak; no MCP found | Heroku Postgres | Review apps (Cedar) | $5 Eco dynos up; Fir from $25\* | Sustaining-engineering mode since 2026-02-06: no new features | **Rejected**: don't start a multi-year project on a frozen platform |
| **Gigalixir** | CLI only | Managed, ~$10/mo\*; free tier has no backups | No PR previews | ~$10/200 MB\* | Small, Elixir-only | Rejected: niche, thin agent tooling |
| **VPS + Kamal** (Hetzner etc.) | Whatever you build (SSH) | You run it and back it up | You build it | ~€5/mo | You are the vendor | Rejected for now: cheapest, most to own |
| **Railway app + Neon Postgres** | Neon has a hosted MCP (connected locally) | Branch per environment or PR; point-in-time restore; scale to zero | Neon branches pair with PR envs | Neon free tier, then usage | Acquired by Databricks (2025) | Worth revisiting if Railway's backups or restores disappoint |

\* From third-party pricing roundups (2026), not checked against the
vendor's own page. Verify before budgeting.

Not evaluated: Northflank, Koyeb, Vercel (its Functions model doesn't fit a
long-lived Phoenix node with WebSockets), Cloud Run / ECS (too much to own).

### Why not Fly, given the existing company account

Fly is the most Phoenix-native host (clustering over its private network,
global anycast, a large Elixir community), and the Abstract Syntax account
already exists. None of that is needed for one node in one region. Its
Managed Postgres costs several times more at idle than Railway's. Per-PR
environments would have to be built and maintained in Actions. And cost
predictability is a common complaint in 2026 roundups (inter-region private
network traffic has been billed since February 2026). If qot ever needs
multi-region nodes close to users, revisit.

## Things to watch on Railway

- **Backups**: daily (kept 6 days), weekly (27 days) and monthly
  (89 days) schedules per volume; restore creates a new volume in the same
  project and environment. Railway still calls the feature "under
  development". "Wiping a volume deletes all backups". So also keep an
  off-platform `pg_dump` (roadmap: "Postgres backups, and one tested
  restore").
- **Wait for CI** holds a deploy until GitHub Actions check suites finish
  (failed → skipped, two-hour timeout). It isn't meant for must-run steps,
  so run migrations as a pre-deploy command or on boot, not in a workflow.
- Railway has only a few regions (four, per one 2026 roundup). Fine for
  now.
- Billing is per workspace: create an Abstract Syntax workspace with the
  company card rather than using the personal "CEO" one.

## Sources

- Claude Code docs: [cloud environments](https://code.claude.com/docs/en/cloud-environments)
  (network levels, default allowlist, network secrets, what carries over),
  [Claude Code in the cloud](https://code.claude.com/docs/en/claude-code-on-the-web)
- Railway docs: [remote MCP server](https://docs.railway.com/ai/remote-mcp-server),
  [environments / PR environments](https://docs.railway.com/guides/environments),
  [backups](https://docs.railway.com/reference/backups),
  [GitHub autodeploys / Wait for CI](https://docs.railway.com/guides/github-autodeploys),
  [pricing](https://docs.railway.com/pricing)
- Fly.io docs: [MCP](https://docs.fly.io/model-context-protocol),
  [Managed Postgres](https://fly.io/docs/mpg), [pricing](https://fly.io/pricing.md)
- [Render pricing](https://render.com/pricing)
- [Gigalixir tiers and pricing](https://docs.gigalixir.com/tiers-pricing)
- [DigitalOcean PostgreSQL reference](https://docs.digitalocean.com/products/databases/postgresql/reference/index.html.md)
- Heroku's status: [Heroku enters sustaining engineering mode (DEV)](https://dev.to/deployhq/heroku-enters-sustaining-engineering-mode-what-it-means-and-when-to-consider-alternatives-2kb5),
  [Northflank: Railway vs Heroku](https://northflank.com/blog/railway-vs-heroku)
- Third-party roundups (treat prices as approximate):
  [sota.io pricing comparison](https://sota.io/blog/railway-vs-render-vs-fly-pricing-2026),
  [temps.sh on Fly pricing](https://temps.sh/blog/fly-io-pricing-2026),
  [Render on agent deploy platforms](https://render.com/articles/best-cloud-platforms-for-coding-agent-deploys-in-2026-render-vs-vercel-vs-railwa)
  (written by a vendor),
  [DEV: Fly vs Railway vs Render for solo builders](https://dev.to/whoffagents/flyio-vs-railway-vs-render-honest-paas-comparison-for-solo-saas-builders-in-2026-454l)
