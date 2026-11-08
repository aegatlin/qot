# Secrets management for a solo developer

Status: decided
Date: 2026-11-02
Question: Where do qot's secrets (deploy secrets, API keys, later Stripe and
Apple keys) live, so that there is one place to find them, without paying in
setup or risk for a team that doesn't exist yet?

## Answer

**fnox with age, committed to the repo.** `fnox.toml` holds every deployed
environment's secrets, age-encrypted, with one profile per environment
(`staging`, `production`). fnox is the source of truth; `mise run
secrets:push:<env>` copies a profile to Railway, which holds the deployed copy.
One age key (`~/.config/fnox/age.txt`, shared with other personal projects)
decrypts everything.

Revisit when a second person needs production access, or when qot holds
something whose leak would really hurt (payment keys with real money behind
them, signing keys). The planned next step is described under "Upgrade path"
below. It changes `fnox.toml`'s providers, not the workflow.

## What the problem actually is

For one person, the main failure isn't theft. It's **sprawl**: keys scattered
across dashboards, `.env` files on old laptops, a password manager note, a
Railway variable nobody can read back. Rotating something then means hunting
for it first. The criteria, in order:

1. **One place**, for every environment, that survives a new laptop.
2. **No plaintext at rest** in the repo, the shell history or agent
   transcripts.
3. **Little to run or pay for**: no server, no seat pricing.
4. **Works with agents**: local sessions can use secrets when told to;
   cloud sessions shouldn't need them at all.
5. **An exit path** if the tool is abandoned.

### Threat model (solo, pre-revenue)

- **Laptop compromise** is the big one, and it already loses everything: the
  Railway CLI session, the `gh` token, browser sessions. Keeping prod secrets
  encrypted at rest on that same laptop adds little exposure beyond what is
  already there. Disk encryption and a screen lock matter more.
- **Repo leak** (private repo made public, a GitHub breach, a fork): the
  ciphertext is useless without the age key. This is where encrypted-in-git
  beats a plaintext `.env` by a wide margin.
- **Age key leak**: every secret in every project that uses that key is
  readable, **including old values in git history**. The response is to
  rotate the secrets themselves, not just the age key. A single age key
  across projects trades a bigger blast radius for less to manage. That's
  acceptable for now; a per-project key is a cheap change later.
- **Age key loss**: everything encrypted with it is gone. That's mostly
  recoverable for qot (every secret can be regenerated or reissued by its
  provider), but painful. **Back up `age.txt` in a password manager.**
- **Agents**: an agent that can run `fnox get` can read anything. Grant
  secrets per command or task, and keep the age key off cloud VMs.

## Why fnox in particular

- **It is a front for providers, not a vault.** Each secret names its
  provider: age (ciphertext in `fnox.toml`), 1Password, Bitwarden, AWS/GCP/
  Azure secret managers, Vault, Doppler, the OS keychain. Profiles can mix
  them, e.g. dev in age and prod in AWS. So outgrowing age means changing
  one profile's provider. Scripts that call `fnox exec` / `fnox export` keep
  working.
- **mise integration.** mise's secrets docs list fnox as the recommended
  option (experimental, fnox ≥ 1.39). A task gets only the keys it lists:
  `[tasks.deploy] secrets = ["DATABASE_URL"]`, or `mise run --secrets KEY
  task`. A profile can be chosen per `MISE_ENV`. Not used yet. Today
  `scripts/secrets-push` calls `fnox export` directly, which is equivalent.
  It's worth adopting once more tasks need secrets.
- **Agent features**: `fnox proxy` gives an agent placeholders and injects
  real credentials only into allowed HTTPS requests. Leases issue short-lived
  cloud credentials instead of long-lived keys. Neither is used yet.
- **Exit path, verified**: an age-provider value is base64 of a standard age
  file (it decodes to `age-encryption.org/v1…`). On 2026-11-02, `base64 -d |
  age -d -i ~/.config/fnox/age.txt` produced the same value as `fnox get`.
  So if fnox disappeared, the secrets are still readable with plain `age`.

**Risks**: fnox is young (repository created 2025-10-18, ~2.3k stars), mostly
one maintainer (jdx, who also maintains mise), and its mise integration is
marked experimental. The verified exit path is what makes that acceptable.

## Options considered

| Option | What it is | Cost | Strengths | Weaknesses | Verdict |
|---|---|---|---|---|---|
| **fnox + age** | Encrypted values in a committed `fnox.toml`; providers pluggable | Free | One file for all envs; profiles; swap providers without changing workflow; mise task grants | Young; one maintainer | **Chosen** |
| **mise's own sops or age** | `env._.file` with a sops-encrypted `.env.json`, or `mise set --age-encrypt` | Free | No extra tool | Decrypted whenever mise loads the config, so the activated shell, every task and `mise env` see plaintext; age mode experimental | Rejected: too broad a blast radius for prod secrets |
| **sops + age** (standalone) | Encrypt whole YAML/JSON/env files, values only | Free | 10+ years old, CNCF sandbox, ~23k stars; KMS backends | Extra tooling for running commands with secrets; no per-task grants | Strong runner-up; the "boring" choice |
| **dotenvx** | Encrypted `.env`; public key committed, private key in `.env.keys` | Free (paid add-ons) | Familiar `.env` shape; from the dotenv author | Node-centric; one keypair per env file; secp256k1 instead of age | Rejected: fits a JS app better than a Rust/Elixir monorepo |
| **git-crypt** | Transparent file encryption in git (GPG) | Free | Invisible once set up | GPG; whole-file; easy to commit plaintext by mistake | Rejected |
| **1Password CLI** (`op run`, Environments, service accounts) | Vault references in config; values fetched at run time | Subscription, from ~$3–8/mo\* | Nothing secret in git; great sharing/audit; "1Password for Agents" | Subscription; service-account support for Environments unclear\* | Upgrade path for prod (works as a fnox provider) |
| **Doppler** | Hosted secrets platform with CLI | Free tier reported for ≤3 users\*; paid per user | Most polished CLI; native Railway sync | Closed source; another vendor holding prod secrets | Rejected for now |
| **Infisical** | Open-source secrets platform, cloud or self-hosted | Free tier\*; paid per identity | MIT core; Railway "secret sync" | A platform to configure; Railway sync needs an account token | Rejected for now; best fit if a team arrives |
| **Bitwarden Secrets Manager** | Hosted, open-source-ish | Free tier\* | Cheap; works as a fnox provider | Weaker developer experience | Not evaluated deeply |
| **Platform only** (Railway variables) | Secrets live only where they are used | Free | Nothing extra | Sprawl across platforms; no history; sealed values can't be read back | Rejected as the source of truth; it is the deployed copy |
| **Vault / OpenBao** | Self-hosted secrets server | Infra | The enterprise standard | A server to run and secure | Rejected: far too much for one person |

\* Third-party or unverified (2026 roundups, a community bug report).
Check before relying on it.

## How it fits the rest of the setup

- **Deploys need no secrets in GitHub.** Railway builds from GitHub, and
  production is promoted by moving a branch (see
  [hosting](2026-11-02-hosting-platform.md)). So no CI secret is needed yet.
- **Cloud agent sessions** (claude.ai/code) have no age key, so they can't
  decrypt `fnox.toml`. That's intended. A key an agent truly needs there
  goes in that environment's *network secrets*: the proxy attaches it to
  requests and the VM never sees it.
- **Railway sealed variables** are write-only: never returned by the API or
  `railway run`. With fnox as the source of truth, sealing production's
  secrets costs nothing and removes Railway as a place to read them back.
  Worth doing (#6, deferred while dogfooding: closed as not planned).

## Practices

- Add or rotate: `fnox -P <env> set KEY` (reads stdin or prompts hidden;
  never pass the value as an argument), commit, `mise run
  secrets:push:<env>`.
- Never print values. Compare with hashes when checking a copy.
- Values that are configuration rather than secrets (`PHX_HOST`,
  `DATABASE_SSL`) stay in Railway or in code, not in fnox. Railway-generated
  references (`DATABASE_URL`) stay references.
- `fnox scan` before committing. Today it flags four false positives
  (variable names, a test mock, `System.get_env` calls).

## Upgrade path

When a second person or real money arrives, in roughly this order:

1. Per-project age key, and one age recipient per person (age encrypts to
   several recipients; `fnox reencrypt` rewrites the values).
2. Move the `production` profile to a hosted provider (1Password or
   Infisical) through fnox, so production access is per person, audited and
   revocable. Keep dev and staging in age.
3. Short-lived credentials (fnox leases, OIDC from CI) where providers
   support them.

## Sources

- fnox: [site](https://fnox.jdx.dev/), [mise secrets overview](https://mise.jdx.dev/environments/secrets/),
  [mise + fnox integration](https://mise.jdx.dev/environments/secrets/fnox.html),
  [mise sops](https://mise.jdx.dev/environments/secrets/sops.html),
  [mise age](https://mise.jdx.dev/environments/secrets/age.html)
- [dotenvx encryption docs](https://dotenvx.com/docs/learn/encrypting/encrypted-files/)
- 1Password: [secure AI access](https://www.1password.dev/get-started/secure-ai-access),
  [August 2026 update](https://www.1password.community/announcements-52/august-2026-at-1password-smarter-sign-ins-secure-ai-agents-and-safer-developer-secrets-25431),
  [community report: service account can't read Environments](https://1password.community/discussions/developers/1password-cli-bug-report-service-account-cannot-read-environments/167547)
- Railway: [external secrets managers](https://railway.com/guides/external-secrets-manager);
  Infisical [Railway secret sync](https://infisical.com/docs/integrations/secret-syncs/railway)
- Claude Code [cloud environments: network secrets](https://code.claude.com/docs/en/cloud-environments)
- Roundups (directional; several are written by vendors):
  [Encore](https://encore.dev/articles/best-secrets-management-tools),
  [AI Coding Guild: Doppler vs Infisical vs 1Password](https://aicodingguild.com/blog/secrets-managers-compared-doppler-infisical-1password),
  [costbench: Doppler vs Infisical](https://costbench.com/compare/doppler-vs-infisical/),
  [capy.sc tier list](https://www.capy.sc/blog/best-secrets-management-tools-for-developers-2026)
- Repository facts from the GitHub API on 2026-11-02 (jdx/fnox, getsops/sops,
  dotenvx/dotenvx).
