# Sign in with Apple on Apple devices

Status: decided
Date: 2026-11-08
Question: The iPhone sign-in (the app shows a code, you open an emailed link
in a browser and type the code there) is clunky. What should signing in on
Apple devices be?

## Answer

**Sign in with Apple is the main way in on Apple devices; the email device
sign-in stays as the fallback and the way every other client signs in.**

- The app shows Apple's `SignInWithAppleButton`, asking for the email scope,
  with a nonce. It sends Apple's identity token and the raw nonce to
  `POST /api/auth/apple {identity_token, nonce}`.
- The server verifies the token itself: RS256 signature against Apple's
  published keys (`https://appleid.apple.com/auth/keys`, cached), `iss`
  `https://appleid.apple.com`, `aud` one of our client ids (the bundle id
  `llc.abstractsyntax.qot`), not expired, and `nonce` equal to the SHA-256
  of the raw nonce. No Apple secret is needed for this.
- **Which account:** a user with that Apple `sub` → that user. Otherwise, if
  the token's email is verified and an account has that email
  (case-insensitive) → that account, now linked to the `sub`. Otherwise a new
  account with that email. Then tokens, the same shape as the device
  sign-in's.

## Why

- One tap with Face ID, no inbox, no browser: the lowest-friction sign-in an
  iPhone has, and the HIG's own control.
- It keeps one account per person: someone who signed in to the CLI with
  their email and then taps Sign in with Apple (sharing their real email)
  lands in the same account, with the same notes.
- No email is sent, so the sign-in rate limits (there to stop email abuse)
  don't apply.

## Costs and open ends

- **Hide My Email makes a separate account.** Apple gives a
  `@privaterelay.appleid.com` address; the CLI and the PWA sign in by email,
  so the same person signing in there with their real address gets a
  different account and different notes. For now the sign-in screen says so
  (share your email to use qot everywhere). The fix is Sign in with Apple on
  the web too (Apple JS in the PWA, needing a Services ID and domain
  verification), then the CLI's device sign-in can be approved from a PWA
  signed in with Apple. Tracked as an issue.
- **Deleting an account must revoke the Apple tokens** before App Store
  review (App Review Guideline 5.1.1(v)), which needs a Sign in with Apple
  key and the REST API. Not needed for TestFlight; tracked as an issue.
- **The capability** (`com.apple.developer.applesignin`) must be on the App
  ID. Xcode's automatic signing adds it locally; Xcode Cloud can't register
  it, so it has to exist before a cloud build exports.

## Options considered

- **The email code typed in the app**, AutoFilled from Mail: smallest change,
  one account per email everywhere, but still a trip through the inbox.
- **Passkeys**: Face ID after the first sign-in, and they work in the PWA and
  on the Mac, but the first sign-in still verifies an email and WebAuthn is
  the most server work of the three. Worth revisiting for the web.
- **Keep the device sign-in only**: what made us ask.

## Sources

- Apple, "Authenticating users with Sign in with Apple" and "Verifying a
  user" (token claims, keys endpoint): https://developer.apple.com/documentation/signinwithapple
- App Review Guidelines 5.1.1(v), account deletion:
  https://developer.apple.com/app-store/review/guidelines/
