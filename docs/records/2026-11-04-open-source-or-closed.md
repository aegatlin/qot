# Open source or closed source

Status: proposed
Date: 2026-11-04
Question: Should qot's code be open source, given that it is meant to become
a solo business selling managed cloud services (sync, capture channels,
pipelines) on top of free clients?

## Answer (proposed)

**Open source, copyleft, with the copyright kept in one hand.** Concretely:

1. Make `aegatlin/qot` public now, under **AGPL-3.0** for the whole repo
   (today it is GPL-3.0; see "The license" below).
2. Keep sole copyright: don't merge outside code without a contributor
   agreement that allows relicensing (a CLA). Issues and ideas from friends
   are fine; code is where this matters.
3. Sell the service, not the code. Paid features run on the server
   (sync quotas, capture channels, pipelines), never as a flag a client
   checks.
4. The name and logo are the product's identity, separate from the code.
   Register the trademark when money is on the line, not before; a short
   trademark policy ("forks must rename") can go in the README any time.

This keeps every option open. With sole copyright, a later version can still
move to a source-available licence (FSL) or close entirely. Only versions
already published stay AGPL forever.

Why decide now, though monetization is far off: [#14](https://github.com/aegatlin/qot/issues/14)
needs the GitHub Releases to be public for the `curl … | sh` installer to
work, and a public repo has free Actions minutes (macOS runners cost 10×
Linux on private repos). The alternative is a separate public releases repo,
which works but is extra machinery to avoid a decision that leans one way
anyway.

## Why open fits qot in particular

- **The E2EE promise is checkable only if the client is.** "The server never
  reads note content" is the core trust claim (CLAUDE.md). Users of the
  products qot most resembles expect to verify it: Standard Notes, Ente,
  Bitwarden, Proton's apps, Signal and Joplin all publish their clients,
  and most publish their servers too. Obsidian is the notable closed
  exception, and it gets away with it because notes are plain Markdown files
  on your disk; qot's notes are Automerge documents, so an open `qot_core` is
  also the guarantee that your data is readable without us.
- **The code is not the moat.** The server is a deliberately thin relay of
  opaque blobs; anyone competent could rewrite it in a week. What a paying
  user buys is: it runs, it is on every device, capture works from the
  Action button, and someone keeps it running. Closing the code protects
  little that is hard to copy.
- **Self-hosters are not lost revenue.** People who will run Postgres and a
  Phoenix release to sync a notes app were never going to pay $3/month.
  They are, however, the people who recommend tools. Standard Notes and
  Bitwarden both let you self-host and both sell plans to the rest.
- **The real risk for a solo product is obscurity, not competition.** A
  public repo of a well-built Rust + Elixir app is itself marketing
  (Hacker News, "show me the code" readers, the author's portfolio).
- **Dogfooding friends can read it, file issues and build it**, with no
  collaborator invites.

## What open costs, and how the proposal handles it

| Risk | How likely / how bad | Mitigation |
|---|---|---|
| Someone hosts the server and sells it cheaper | Low: tiny market, thin margins, and AGPL forces them to publish their changes | AGPL; the brand; most value is in clients and ops, not the relay |
| A clone appears on the App Store | Real for any popular app, open or closed (closed apps get cloned from screenshots too) | GPL-family code can't be shipped by third parties on the App Store without the holder's consent; Apple has pulled GPL apps on a copyright holder's complaint (VLC, 2011). Plus a trademark complaint. |
| Paid features bypassed by patching the client | Only if they live in the client | Rule 3: gate on the server |
| Outside contributions lock the licence | Real: each contributor's code is theirs, so relicensing or shipping on the App Store needs their consent | Rule 2: CLA, or don't take code PRs |
| Companies won't touch AGPL | Irrelevant: qot sells to individuals, not to companies embedding the code | — |
| Secrets in git history become public | One-time risk at the flip | Scan history before going public (`fnox.toml` is age-encrypted; Railway config isn't in the repo) |
| Visible half-finished work, public critique | Mostly psychological | Accept it; the roadmap already says what's deferred |

## The license

The repo is GPL-3.0 today. That covers distributed binaries (CLI, iOS app)
but not the server: GPL obligations trigger on distribution, and running a
modified server as a service isn't distribution. **AGPL-3.0** closes that
gap (network use counts) and is otherwise the same licence, so switching is
a one-file change while the author is the only copyright holder. Plausible
(MIT → AGPL in 2020) and Joplin (to AGPL in 2022, with a CLA) made the same
move for the same reason. Dependencies are MIT, Apache-2.0 and MPL-2.0
(Automerge, Phoenix, UniFFI), all compatible with AGPL-3.0 (not checked
crate by crate; `cargo deny` can confirm).

**App Store.** The FSF's view is that Apple's terms add restrictions the GPL
forbids, so a third party can't distribute GPL code there. The copyright
holder isn't bound by their own licence and can ship it, which is how
Signal, Standard Notes and Proton ship GPL/AGPL iOS apps. This is also why
rule 2 matters most for the iOS app: contributed code without a CLA would
need each contributor's permission.

## Options considered

1. **Closed source (private repo).** Maximum control, no clones from source.
   But it costs the E2EE trust argument, needs a separate public repo or host
   for release binaries now, and protects code that isn't the moat. It is
   also the one choice that is easy to reverse later (you can always open
   up), which is its strongest argument; but the sole-copyright rule gets
   most of that reversibility while being open.
2. **Open core** (clients open, server closed). Common (Bitwarden keeps
   some enterprise features under a separate licence). For qot the server is
   the least valuable code to hide, and a closed server makes self-hosting,
   the strongest trust signal, impossible.
3. **Fair source: FSL** (Sentry, 2023). Source available; anyone may use and
   self-host but not run a competing service; each version becomes Apache-2.0
   or MIT after two years. Good protection against hosted competitors, but
   not OSI open source, and some of the privacy crowd treats it with
   suspicion. Worth reconsidering for the server if a hosted competitor ever
   actually appears; with sole copyright, that's a later switch for new
   versions.
4. **Permissive (MIT/Apache).** Most goodwill, least protection: anyone may
   ship a closed fork, including on the App Store. No reason to choose it
   for a product meant to earn money.
5. **AGPL, sole copyright (proposed).**

## What would change this

- A competitor actually hosting a qot server for money: move the server to
  FSL for new versions.
- Paid features that can only live in the client (unlikely given the
  architecture): reconsider open core for those.
- Taking investment: investors sometimes prefer closed or FSL; the CLA keeps
  that possible.

## Sources

Third-party reporting; not verified beyond what the links say.

- Standard Notes: AGPL-3.0, self-hostable server, paid plans; acquired by
  Proton in 2024 with a commitment to stay open.
  [TechRadar](https://www.techradar.com/pro/security/proton-has-acquired-encrypted-note-taking-app-standard-notes),
  [is it really FOSS?](https://isitreallyfoss.com/projects/standard-notes)
- Ente: AGPL-3.0 clients and server, funded by its paid photo plans.
  [Reclaim The Net](https://reclaimthenet.org/google-photos-and-icloud-photos-alternative-ente-open-sources-its-server-code),
  [GitHub Sponsors page](https://github.com/sponsors/ente-io)
- Obsidian: closed; community reasoning (no official statement found) is
  protecting Sync revenue. [Obsidian forum thread](https://forum.obsidian.md/t/open-sourcing-of-obsidian/1515?page=6)
- Plausible's MIT → AGPL switch and later CLA.
  [Plausible blog](https://plausible.io/blog/open-source-licenses),
  [LWN](https://lwn.net/Articles/834120/)
- Joplin's switch to AGPL with a CLA.
  [Joplin news](https://joplinapp.org/news/20221221-agpl/)
- FSL. [fsl.software](https://fsl.software/),
  [Sentry's announcement](https://blog.sentry.io/introducing-the-functional-source-license-freedom-without-free-riding/)
- GPL and the App Store (mostly 2011 sources; Apple's terms may have
  changed). [Engadget](https://www.engadget.com/2011-01-09-the-gpl-the-app-store-and-you.html),
  [The Next Web on VLC](https://thenextweb.com/news/apple-officially-pulls-vlc-from-the-app-store),
  [Pidgin](https://developer.pidgin.im/wiki/WhyNoiOSVersion)
- Clones of open source apps in stores.
  [Cult of Mac on Lugaru](https://www.cultofmac.com/news/humble-indie-bundle-devs-fight-off-mac-app-store-source-code-copycats),
  [iTWire on VLC clones](https://itwire.com/open-source/google-ignores-licence-violating-clones-of-vlc)
