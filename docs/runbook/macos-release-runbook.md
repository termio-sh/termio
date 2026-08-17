---
title: macOS release runbook — cut, notarize, publish termio.dmg
status: active
type: design
created: 2026-07-06
updated: 2026-07-12
related:
  - ../RELEASING.md
---

# macOS release runbook — cut, notarize, publish termio.dmg

> Operational runbook for shipping the macOS app: the one-time credential setup,
> the per-release "push a tag" flow, how to verify a release went out, and how to
> roll back or debug when it doesn't. `docs/RELEASING.md` is the conceptual
> overview; this is the checklist you actually execute against.

## What a release does

Pushing a `vX.Y.Z` tag fires `.github/workflows/release.yml` on a `macos-26`
runner, which:

1. Derives the version from the tag and the build number from
   `git rev-list --count HEAD` (monotonic → Sparkle always sees a higher
   `CFBundleVersion`).
2. Imports the Developer ID cert into a throwaway keychain and runs
   `scripts/build-app.sh` (embeds + signs Sparkle, Developer-ID-signs the bundle
   with the hardened runtime + secure timestamp).
3. Packages a `.dmg` with `create-dmg`.
4. Notarizes + staples the DMG with `notarytool`.
5. Signs the DMG's EdDSA appcast entry and **merges** it into the existing
   `appcast.xml` (pulled from R2 first, so history survives).
6. Uploads to Cloudflare R2: immutable `v<version>/termio.dmg`, stable
   `termio.dmg`, and `appcast.xml`.
7. Purges the stable DMG + appcast from Cloudflare's edge (if the purge token is
   set — otherwise skips with a notice).
8. Records a GitHub Release for the tag + auto-generated changelog.
9. Bumps the Homebrew cask in `termio-sh/homebrew-tap` (version + sha256 in
   `Casks/termio.rb`), pushed with the `TAP_DEPLOY_KEY` secret — a write deploy
   key on the tap repo. Skips with a notice if the secret is unset.

Result: `https://downloads.termio.sh/termio.dmg` serves the notarized build (the
website Download button), existing installs auto-update via Sparkle from
`https://downloads.termio.sh/appcast.xml` (the app's `SUFeedURL`), and
`brew install --cask termio-sh/tap/termio` serves the new version.

## Fixed facts (this project)

| Thing | Value |
| --- | --- |
| Repo | `termio-sh/termio` (private) |
| Apple Team ID | `<TEAM_ID>` (<YOUR_NAME>) |
| Developer ID Application | `<YOUR_NAME> (<TEAM_ID>)` — SHA-1 `<CERT_SHA1>` |
| ASC API key (Team key "termio") | Key ID `<ASC_KEY_ID>`, Issuer ID `<ASC_ISSUER_ID>`, role **Developer** |
| ASC `.p8` backup | `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` (also `~/credentials/`) |
| Sparkle public key | `SUPublicEDKey = zm3UpFrDf8tFcctK2vkEhrms6oFTp50AUb824lP9BAw=` (shared with oakreader) |
| Cloudflare account ID | `<CF_ACCOUNT_ID>` |
| R2 bucket | `termio-downloads` (custom domain `downloads.termio.sh`) |
| R2 S3 endpoint | `https://<CF_ACCOUNT_ID>.r2.cloudflarestorage.com` |

These are identifiers, not secrets — the real secrets (the `.p8` bytes, the cert
password, the R2 secret access key) live only in GitHub Secrets and your vault.

> **Termio needs no provisioning profile.** Unlike oakreader (which declares a
> restricted `keychain-access-groups` entitlement and therefore embeds a
> Developer ID profile), Termio has no restricted entitlements, so plain
> Developer-ID signing + notarization is enough. Don't copy oakreader's
> `PROVISIONING_PROFILE` step.

## GitHub secrets inventory

The workflow reads these eleven secrets. **None is a GitHub token** — Actions
injects `GITHUB_TOKEN` automatically. Check state with
`gh secret list --repo termio-sh/termio`.

| Secret | Purpose | Required |
| --- | --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of the Developer ID `.p12` (cert + key) | ✅ |
| `DEVELOPER_ID_CERT_PASSWORD` | that `.p12`'s password | ✅ |
| `ASC_API_KEY` | base64 of the App Store Connect `.p8` | ✅ |
| `ASC_KEY_ID` | 10-char key ID (`<ASC_KEY_ID>`) | ✅ |
| `ASC_ISSUER_ID` | account issuer UUID | ✅ |
| `SPARKLE_ED_KEY` | Sparkle EdDSA private key (shared w/ oakreader) | ✅ |
| `R2_ACCESS_KEY_ID` | R2 S3 access key ID | ✅ |
| `R2_SECRET_ACCESS_KEY` | R2 S3 secret access key | ✅ |
| `R2_ENDPOINT` | `https://<accountid>.r2.cloudflarestorage.com` | ✅ |
| `CLOUDFLARE_ZONE_ID` | termio.sh zone ID (for cache purge) | ⚪ |
| `CLOUDFLARE_API_TOKEN` | Zone→Cache Purge token | ⚪ |
| `TAP_DEPLOY_KEY` | write deploy key for `termio-sh/homebrew-tap` (cask bump) | ⚪ |

⚪ = optional. Without the two Cloudflare cache secrets the release still
succeeds; the purge step just skips. Without `TAP_DEPLOY_KEY` the Homebrew cask
bump skips too (the tap still serves the previous version). The stable copies
are uploaded with `Cache-Control: no-cache`, so they mostly aren't edge-cached
anyway.

### Gotcha: setting secret values from the shell

`gh secret set NAME` with **no piped value** prompts `? Paste your secret:` and
reads it without echoing — use this. Do **not** paste a `!printf ... | gh ...`
one-liner into a normal terminal: zsh treats the leading `!` as history
expansion and dies with `zsh: event not found`. (The `!` prefix only means
"run in the Termio session"; it isn't part of the command.)

```sh
gh secret set R2_SECRET_ACCESS_KEY --repo termio-sh/termio   # prompts, no echo
```

## One-time setup

Do these once. Most are shared with oakreader (same Apple account, same R2
account, same Sparkle key), but GitHub secrets are write-only, so each value must
be set on Termio's repo directly — you can't copy them across repos.

### 1. Cloudflare R2 bucket + domain (required)

The `termio-downloads` bucket and `downloads.termio.sh` custom domain already
exist. To recreate from scratch: R2 → create bucket **`termio-downloads`** →
Settings → Custom Domains → add `downloads.termio.sh`. Verify:

```sh
wrangler r2 bucket list | grep termio-downloads
curl -sI https://downloads.termio.sh/appcast.xml   # 404 before first release is fine
```

### 2. R2 S3 token → `R2_ACCESS_KEY_ID` + `R2_SECRET_ACCESS_KEY` (required)

**Dashboard (recommended):** R2 → **Manage R2 API Tokens** → Create API Token →
permission **Object Read & Write**, scoped to `termio-downloads`. The result page
shows an **Access Key ID** and a **Secret Access Key** (secret shown once — copy
now). Ignore the Bearer "Token value"; the workflow uses the S3 API only.

```sh
gh secret set R2_ACCESS_KEY_ID     --repo termio-sh/termio
gh secret set R2_SECRET_ACCESS_KEY --repo termio-sh/termio
gh secret set R2_ENDPOINT          --repo termio-sh/termio   # https://<accountid>.r2.cloudflarestorage.com
```

**CLI derivation (alternative):** an R2 S3 credential is derived from a normal
account API token — `AccessKeyID = token id`, `SecretAccessKey = sha256(token
value)`. Only works if you POST to `/accounts/{id}/tokens` with a credential that
has **API Tokens → Write** (or the Global API Key). The wrangler OAuth session
**cannot** do this — it returns `9109 Unauthorized` — so the dashboard is the
path of least resistance.

### 3. Developer ID certificate → `DEVELOPER_ID_CERT_P12` + `_PASSWORD` (required)

If the identity is already in your login keychain (`security find-identity -v -p
codesigning | grep "Developer ID"`), export it non-interactively:

```sh
P12="$TMPDIR/devid.p12"; PW="$(openssl rand -hex 12)"
security export -t identities -f pkcs12 -P "$PW" -o "$P12"
base64 -i "$P12" | gh secret set DEVELOPER_ID_CERT_P12 --repo termio-sh/termio
printf '%s' "$PW" | gh secret set DEVELOPER_ID_CERT_PASSWORD --repo termio-sh/termio
rm -f "$P12"
```

(macOS may pop a keychain "allow access to the private key" dialog — approve it.)

### 4. App Store Connect API key → `ASC_API_KEY` + `ASC_KEY_ID` + `ASC_ISSUER_ID` (required)

App Store Connect → Users and Access → Integrations → App Store Connect API →
**Team Keys** → Generate. Name it `termio`, role **Developer** (minimum for
notarization). Download the `.p8` **once** (`AuthKey_<KEYID>.p8`). The **Issuer
ID** is shown above the key list — one per account, shared across all keys.

```sh
KEYID=<ASC_KEY_ID>                                  # filename = AuthKey_<KEYID>.p8
base64 -i ~/Downloads/AuthKey_$KEYID.p8 | gh secret set ASC_API_KEY --repo termio-sh/termio
printf '%s' "$KEYID"                              | gh secret set ASC_KEY_ID    --repo termio-sh/termio
gh secret set ASC_ISSUER_ID --repo termio-sh/termio   # prompts; paste the issuer UUID
# Back up the .p8 — it can never be re-downloaded:
mkdir -p ~/.appstoreconnect/private_keys && cp ~/Downloads/AuthKey_$KEYID.p8 ~/.appstoreconnect/private_keys/
chmod 700 ~/.appstoreconnect ~/.appstoreconnect/private_keys && chmod 600 ~/.appstoreconnect/private_keys/*.p8
```

### 5. Sparkle signing key → `SPARKLE_ED_KEY` (required)

The same EdDSA key oakreader uses (one key signs any number of apps).
`scripts/setup-release.sh` verifies the keychain key matches
`packaging/Info.plist`'s `SUPublicEDKey` and sets the secret:

```sh
./scripts/setup-release.sh
```

The public key must stay `zm3UpFrDf8tFcctK2vkEhrms6oFTp50AUb824lP9BAw=`. If the
keychain key ever differs, the appcast signatures won't validate and updates will
silently fail.

### 6. Cache-purge token → `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ZONE_ID` (optional)

My Profile → **API Tokens** → Create Custom Token:

- Permission: **`Zone` → `Cache Purge` → `Purge`** (a *zone* permission — an
  account-scoped token cannot purge; delete any empty extra permission rows).
- **Zone Resources:** Include → **termio.sh** (least privilege; "All zones" also
  works).
- Do **not** use the Global API Key.

```sh
gh secret set CLOUDFLARE_API_TOKEN --repo termio-sh/termio   # the token value
gh secret set CLOUDFLARE_ZONE_ID   --repo termio-sh/termio   # the termio.sh zone ID
```

Once set, the purge is fully automatic on every tag — there is no per-release
cache step to run by hand.

## Per-release runbook

Termio is **trunk-based** (since 2026-07-19): `main` is the single default
branch and the development trunk. Feature work goes on short-lived branches →
PR → merge into `main`; there is no separate `dev`/`release` branch. A release
is just a `vX.Y.Z` tag on `main` — the tag *is* the release marker.

1. Make sure CI is green on `main` and everything meant for the release is
   merged there.
2. Pick the next version (semver), e.g. `0.1.0`. Nothing in the repo needs
   editing — the tag *is* the version.
3. Tag `main` and push the tag:

   ```sh
   git checkout main
   git pull --ff-only            # be at the tip you want to ship
   git tag v0.1.0
   git push origin v0.1.0
   ```

   No merge, no release branch — the tag on `main` triggers the release.

4. Watch the **Release** workflow:

   ```sh
   gh run watch --repo termio-sh/termio $(gh run list --repo termio-sh/termio -w Release -L1 --json databaseId -q '.[0].databaseId')
   ```

5. When it's green, run the verification below.

To re-run a failed release after fixing a secret, delete + re-push the tag
(`git push --delete origin v0.1.0 && git tag -d v0.1.0`, then re-tag) — the
version must not go backwards.

## Verify a release

```sh
V=0.1.0
# Stable + versioned DMG resolve (200) and are non-trivial in size:
curl -sI https://downloads.termio.sh/termio.dmg        | head -1
curl -sI https://downloads.termio.sh/v$V/termio.dmg    | head -1
# Appcast's NEWEST item advertises the new version (items are newest-first,
# so read the head — the tail shows the oldest surviving entries):
curl -s  https://downloads.termio.sh/appcast.xml | grep -i "sparkle:version\|shortVersionString" | head -4
# Download + validate the notarization ticket stapled to the DMG:
curl -sL https://downloads.termio.sh/v$V/termio.dmg -o /tmp/termio.dmg
xcrun stapler validate /tmp/termio.dmg          # → The validate action worked!
# Gatekeeper verdict on the app itself — mount the DMG and assess the .app.
# Do NOT `spctl -t open` the DMG file: the DMG container is notarized+stapled
# but never codesigned (only the .app inside is), so that check always says
# "rejected, source=no usable signature" — on good releases too.
hdiutil attach /tmp/termio.dmg -nobrowse -quiet -mountpoint /tmp/termio-mount
spctl -a -vv /tmp/termio-mount/termio.app       # → accepted, source=Notarized Developer ID
defaults read /tmp/termio-mount/termio.app/Contents/Info.plist CFBundleShortVersionString  # → $V
hdiutil detach /tmp/termio-mount -quiet
```

Then confirm auto-update end-to-end: launch an older build and check that Sparkle
offers the new version (Settings → check for updates).

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Build/sign step fails "no identity found" | `DEVELOPER_ID_CERT_P12`/`_PASSWORD` missing or wrong | Re-export the `.p12` (§3); confirm password |
| Notarize step: "invalid" / "not signed with a valid Developer ID" | hardened runtime or timestamp missing | `build-app.sh` adds `--options runtime --timestamp` only with a real `SIGN_IDENTITY`; ensure the workflow passes it |
| Notarize step: auth error | `ASC_*` secret wrong, or key role too low | Verify Key ID/Issuer/`.p8`; role must be ≥ Developer |
| Upload step: 403 / SignatureDoesNotMatch | `R2_ACCESS_KEY_ID`/`SECRET`/`ENDPOINT` wrong or token lacks write | Recreate the R2 Object R/W token (§2) |
| Appcast has only the newest item | previous `appcast.xml` not pulled from R2 before `generate_appcast` | it's pulled automatically; check the R2 read didn't 403 |
| Users don't see the update | `SUPublicEDKey` ≠ `SPARKLE_ED_KEY`, or edge still cached | verify keys match (§5); set the purge token (§6) or wait out the TTL |
| Purge step prints a skip notice | `CLOUDFLARE_API_TOKEN`/`ZONE_ID` unset | optional — set them (§6) for instant updates |
| `zsh: event not found` setting a secret | leading `!` history expansion | use the interactive `gh secret set NAME` prompt |

## Rollback

Artifacts are immutable per version, so "rollback" = re-point the stable copies
at a known-good build and drop the bad appcast item.

1. Re-upload the last good DMG as the stable copy and regenerate the appcast so
   its newest item points at that version (simplest: re-run the release workflow
   on the last good tag).
2. Purge the edge (`CLOUDFLARE_API_TOKEN` set) or wait out the TTL.
3. Delete the bad GitHub Release + tag if the build was never fit to ship.

Because `CFBundleVersion` is the commit count, a genuine fix must ship as a
*newer* tag — never try to re-publish a lower version to "undo" one.
