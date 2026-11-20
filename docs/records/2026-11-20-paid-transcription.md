# Cloud transcription, and the paid tier it starts

Status: direction decided (the owner, 2026-11-20; answer 1 superseded in part by 2026-11-20-pipelines-before-encryption.md); the details below are proposed, and the ones marked **open** wait for the owner
Date: 2026-11-20
Question: How does a recording get its text on a client that can't
transcribe (the CLI, the PWA), and what does qot charge for?

> **Since then:** the same day the owner decided the server may read and
> edit notes (`2026-11-20-pipelines-before-encryption.md`). Transcription
> is to become a server pipeline that writes the text into the note
> itself (#114); the client-sends-audio endpoint in answer 1 is built and
> stays as a second path. The plan, allowance, provider and billing
> parts stand.

## Answer

**The server offers speech-to-text, through a cloud provider, and that is
the first paid feature.** qot presumes nothing about which clients someone
has: a person with only the CLI and the PWA gets a memo's text too, so
"your iPhone transcribes it later" can't be the answer. Transcription costs
money per minute, which makes it an honest thing to charge for, and gives
the subscription planned in `docs/go-to-market.md` its first content.

On-device transcription stays the default where it exists (the iPhone): it
is free, private and needs no account.

1. **The client sends the audio to be transcribed; the server doesn't read
   stored blobs.** `POST /api/transcriptions`, the recording as the raw
   body, answers `{text}`. The server checks the account may use it, hands
   the bytes to the provider, returns the text and keeps neither (only how
   many seconds were used). The client writes the text into the note
   (`fill_text`), so the server still never writes notes. This is what
   end-to-end encryption needs anyway: once blobs are encrypted (#72) the
   stored copy is unreadable, and the plain audio in this one request is
   the whole of what the server hears. It replaces #102's sketch (a derived
   blob encrypted to the account's key), which needed #72 first.
2. **Opt-in twice over.** An account has transcription only when it has the
   paid plan, and a client sends a recording only when the person turned
   "Transcribe in the cloud" on for that device. Off by default,
   everywhere. The end-to-end default is unchanged: nothing is sent unless
   asked.
3. **Gated on the server**, like every paid feature (CLAUDE.md,
   Conventions): a `plan` on the user, checked by the endpoint. Clients
   only ask; a 402 says "not on this plan".
4. **The provider is configuration**: any service with OpenAI's
   `/v1/audio/transcriptions` shape (multipart upload, bearer key), set by
   `STT_API_URL`, `STT_API_KEY`, `STT_MODEL`. Without them the endpoint
   answers 503 and nothing else changes. **Open: which provider.**
   Recommended: OpenAI (`gpt-transcribe`), for the cleanest default terms;
   Groq's hosted Whisper is the cheap alternative with the same shape.
5. **A monthly allowance** per account (`STT_MONTHLY_SECONDS`), so one
   account can't run up a bill. **Open: how much.** At about half a cent a
   minute, 300 minutes a month costs about $1.35.
6. **Billing is Stripe, on the web**: Checkout for the subscription, the
   Customer Portal to manage or cancel, a webhook that sets the user's
   plan. Called with Req (four calls; `stripity_stripe` would bring
   hackney, which the server avoids). The PWA's Settings has the buttons;
   the CLI points there (`qot web`).
7. **The iPhone app sells nothing and says nothing about price.** It
   honours the plan the account has. Apple's rules for that are unsettled
   (below); the app transcribes on the device anyway, so on iOS the paid
   feature is nearly invisible.

## Order of work

1. The endpoint, the plan field (set by hand for the dogfooders), usage
   and the allowance; `qot record` asks for text when turned on. Testable
   as soon as a provider key is in fnox. (#111)
2. Stripe: checkout, portal, webhook, the PWA's Settings. (#112)
3. The PWA records (#101) and asks for text the same way.
4. Privacy policy and terms: the server and a named provider hear a
   recording sent for transcription; what is paid. Approved by the owner
   before the site is released.

## Open, for the owner

- The provider (4) and the allowance (5).
- The price. `go-to-market.md` guessed $2–5 a month or $20–40 a year.
- Whether sync stays free (go-to-market question 1). This record assumes
  yes for now: the paid plan adds transcription and nothing is taken away.
- The old Stripe webhook (`https://quantumofthought.com/payments/stripe/webhooks`,
  from the previous app) still fails and should be deleted in the Stripe
  dashboard; whether old products and customers there are kept.

## What was looked at

Researched 2026-11-20 from the providers' own pages; prices and terms
drift, and none of this was tested by us.

| Provider | $/min | Default terms | Note |
|---|---|---|---|
| OpenAI `gpt-transcribe` | 0.0045 | no training, no retention on this endpoint | older models end 2027-02-26 |
| Groq `whisper-large-v3` | 0.00185 | no retention by default; self-serve zero-retention; training terms not confirmed | open model, could be self-hosted later |
| Mistral Voxtral | 0.003 | zero retention on request | 13 languages |
| Deepgram, AssemblyAI | 0.0035–0.0052 | train on audio unless opted out | |
| ElevenLabs Scribe | 0.0033 | zero retention is enterprise only | |

All take .m4a and files up to 25 MB or more; a 30-minute memo is about
14 MB.

**Other ways to get the text**, not chosen as the answer:

- *Another device transcribes it* (an iPhone, when it next syncs): free
  and private, but presumes an Apple device. Still worth having later as
  the free path for people who own one (#109).
- *Whisper in the browser or the CLI*: private, but a 40–150 MB model
  download and awkward in the static CLI builds.
- *Our own speech model on the server*: no third party, but a GPU or slow
  CPU inference on Railway; revisit if volume or privacy asks for it.

**Apple's rules** (App Review Guidelines, read 2026-11-20): 3.1.1 wants
In-App Purchase for features unlocked in the app; 3.1.3(b) lets a
multiplatform app honour a subscription bought elsewhere "provided those
items are also available as in-app purchases". In the US storefront links
to web purchase are allowed today (under appeal); elsewhere the app may
not link to or mention buying on the web. Whether review accepts an app
that only honours a web subscription, with no purchase in the app, is not
settled; offering the plan as an In-App Purchase too is the fallback.

## Sources

- OpenAI: <https://developers.openai.com/api/docs/pricing>, <https://developers.openai.com/api/docs/guides/your-data>
- Groq: <https://console.groq.com/docs/speech-to-text>, <https://console.groq.com/docs/your-data>
- Mistral: <https://mistral.ai/news/voxtral-transcribe-2>
- Deepgram: <https://deepgram.com/pricing>; AssemblyAI: <https://www.assemblyai.com/pricing>; ElevenLabs: <https://elevenlabs.io/pricing/api>
- Stripe: <https://docs.stripe.com/billing/subscriptions/webhooks>, <https://docs.stripe.com/webhooks#verify-events>
- Apple: <https://developer.apple.com/app-store/review/guidelines/>
