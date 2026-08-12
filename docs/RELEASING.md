# Releasing Silky

Releases are cut automatically by `.github/workflows/release.yml`.

## Cut a release

1. Edit `version.env` on `main`: bump `MARKETING_VERSION` (and `BUILD_NUMBER`).
2. Commit and push to `main`.

The workflow then:

1. Builds the app with SwiftPM and packages it via `Scripts/package_app.sh`
   (`RELEASE_BUILD=1`, stable bundle id `com.jack.app.v2`).
2. Signs with the Developer ID certificate and notarizes — only if the
   signing secrets are configured; otherwise the build is ad-hoc signed
   (fine for testing, but Gatekeeper will warn first-time downloaders).
3. Creates a GitHub Release `v<version>` with `Silky-<version>.dmg` (first
   install) and `Silky-<version>.zip` (what Sparkle downloads).
4. Signs the zip with the Sparkle EdDSA key and regenerates `appcast.xml`,
   committing it back to `main`.

## How updates reach users

The app polls `https://raw.githubusercontent.com/Thiagoxp95/jack/main/appcast.xml`
(hourly, and on demand via the status-bar menu "Check for Updates…"). Updates
download silently; a card appears at the bottom of the sidebar with a
**Restart to update** button once the update is ready.

Dev builds (`swift run`, per-workspace bundle ids, missing `SUFeedURL`) never
check for updates.

## Secrets

| Secret | Required | Purpose |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | yes (for auto-updates) | ed25519 private key; public half is baked into the app (`SUPublicEDKey`) |
| `MACOS_CERT_P12` | no | base64 Developer ID Application certificate (.p12) |
| `MACOS_CERT_PASSWORD` | no | password for the .p12 |
| `APP_STORE_CONNECT_API_KEY_P8` | no | App Store Connect API key contents, for notarization |
| `APP_STORE_CONNECT_KEY_ID` | no | key id |
| `APP_STORE_CONNECT_ISSUER_ID` | no | issuer id |

The Sparkle keypair was generated with Sparkle's `generate_keys`. The private
key lives in the repo owner's Keychain and at `~/.jack-sparkle/ed25519-private.key`
on the owner's machine; `SPARKLE_PRIVATE_KEY` is already set on the repo.
Forks must generate their own pair (`generate_keys` from the Sparkle
distribution), put the public key in `Scripts/package_app.sh`
(`SPARKLE_PUBLIC_ED_KEY`) and set their own secret — and change
`SPARKLE_FEED_URL` to their fork.

## Local release (without CI)

```bash
RELEASE_BUILD=1 Scripts/package_app.sh release
ditto -c -k --sequesterRsrc --keepParent Silky.app Silky-<version>.zip
SPARKLE_PRIVATE_KEY_FILE=~/.jack-sparkle/ed25519-private.key \
  Scripts/make_appcast.sh Silky-<version>.zip
# upload the zip + dmg to the GitHub release, commit appcast.xml
```
