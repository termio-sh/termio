---
title: iOS TestFlight runbook — build, upload, and drive ASC from the API
status: active
type: design
created: 2026-08-06
updated: 2026-08-06
related:
  - macos-release-runbook.md
---

# iOS TestFlight runbook — build, upload, and drive ASC from the API

> How a TermioMobile build gets from this repo onto TestFlight, and how every
> App Store Connect step after the upload — copy, groups, testers, review —
> is driven from the ASC REST API instead of the website.

First executed end-to-end on 2026-08-06. Nothing here requires the ASC website
except one-time key creation. Account-specific values (key ids, issuer id,
app id) are deliberately **not** in this file — they live on the release
machine next to the keys.

## Credentials

Everything personal stays outside the repo:

| Item | Where it lives |
| --- | --- |
| ASC API key, **App Manager** role | `~/credentials/AuthKey_<KEYID>.p8` on the release machine; the key id is the `<KEYID>` in the filename |
| Issuer ID | ASC → Users and Access → Integrations → App Store Connect API (one UUID per team, shown above the key list); keep a copy next to the `.p8` |
| App id | `GET /v1/apps?filter[bundleId]=sh.termio.mobile` — resolve it from the bundle id, never hardcode |
| Team id | already in `ios/exportOptions.plist` (`teamID`) |

**Key roles matter.** A *Developer*-role key can read the whole API but
returns 403 on anything distribution-related (creating certificates, cloud
signing) — the macOS notarization key is exactly that, and it cannot upload
iOS builds. Archive/export/upload and all TestFlight mutations need an
**App Manager** key. A key's role is fixed at creation; mint a new one in
ASC → Users and Access → Integrations if needed, and download the `.p8` once.

## Build → upload

`ios/exportOptions.plist` is already set to `method=app-store-connect`,
`destination=upload`: exporting the archive **is** the upload. Version and
build number live in `project.pbxproj` (`MARKETING_VERSION`,
`CURRENT_PROJECT_VERSION`); bump the build number for every upload —
re-uploading an existing number is rejected.

```sh
cd ios
KEYID=<key id>                 # filename of the App Manager .p8
ISSUER=<issuer uuid>

xcodebuild archive \
  -project TermioMobile.xcodeproj -scheme TermioMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/TermioMobile.xcarchive \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/credentials/AuthKey_$KEYID.p8 \
  -authenticationKeyID $KEYID -authenticationKeyIssuerID $ISSUER

xcodebuild -exportArchive \
  -archivePath build/TermioMobile.xcarchive \
  -exportOptionsPlist exportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/credentials/AuthKey_$KEYID.p8 \
  -authenticationKeyID $KEYID -authenticationKeyIssuerID $ISSUER
```

`-allowProvisioningUpdates` plus the App Manager key does cloud signing — no
local Apple Distribution certificate or provisioning profile is needed, ever.
`ITSAppUsesNonExemptEncryption=NO` in `ios/Info.plist` skips the per-build
export-compliance questionnaire.

After upload, poll `GET /v1/builds?filter[app]=<app id>&sort=-uploadedDate`
until `processingState` leaves `PROCESSING` (5–30 min). `VALID` means the build
is installable by internal testers immediately.

## The API principle — why no website is needed

Everything ASC's website does to TestFlight state is a thin UI over
`https://api.appstoreconnect.apple.com/v1/*`, and the `.p8` key authenticates
straight to it. Two pieces:

**1. Auth is a self-signed ES256 JWT.** Header `{alg: ES256, kid: <key id>}`,
payload `{iss: <issuer id>, iat: now, exp: now+20min, aud:
"appstoreconnect-v1"}`, signed with the `.p8`. No OAuth dance, no browser, no
session. `openssl dgst -sha256 -sign` emits a DER signature; JWT wants raw
`r‖s`, so the DER integers are unpacked and zero-padded to 32 bytes each.

**2. Every entity is plain JSON:API REST.** `GET` to read, `POST` to create,
`PATCH` to edit, `DELETE` to remove — same resource names the website shows.
Editing TestFlight copy is literally a `PATCH` with the new text; it takes
effect immediately and (for description/what-to-test) triggers no re-review.

Reusable helper (Python, stdlib only — this exact shape ran the 2026-08-06
launch):

```python
import json, time, base64, subprocess, tempfile, os, urllib.request

KEY_ID = os.environ['ASC_KEY_ID']            # e.g. from ~/credentials
KEY = os.path.expanduser(f'~/credentials/AuthKey_{KEY_ID}.p8')
ISSUER = os.environ['ASC_ISSUER_ID']

def make_jwt():
    b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b'=')
    now = int(time.time())
    signing_input = (b64(json.dumps({'alg': 'ES256', 'kid': KEY_ID, 'typ': 'JWT'}).encode())
        + b'.' + b64(json.dumps({'iss': ISSUER, 'iat': now, 'exp': now + 1200,
                                 'aud': 'appstoreconnect-v1'}).encode()))
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(signing_input); path = f.name
    der = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', KEY, path],
                         capture_output=True).stdout
    os.unlink(path)
    i = 2; l = der[i+1]; r = der[i+2:i+2+l]; i += 2 + l   # DER SEQUENCE → r, s
    l = der[i+1]; s = der[i+2:i+2+l]
    raw = (r.lstrip(b'\x00').rjust(32, b'\x00') + s.lstrip(b'\x00').rjust(32, b'\x00'))
    return (signing_input + b'.' + b64(raw)).decode()

TOKEN = make_jwt()

def api(path, method='GET', body=None):
    req = urllib.request.Request('https://api.appstoreconnect.apple.com' + path,
        headers={'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'},
        data=json.dumps(body).encode() if body else None, method=method)
    try:
        r = urllib.request.urlopen(req)
        return r.status, (json.load(r) if r.status != 204 else None)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)
```

## Entity map — what to touch for each job

| Job | Entity | Call |
| --- | --- | --- |
| Beta App Description + feedback email (per locale) | `betaAppLocalizations` | `GET /v1/apps/{app}/betaAppLocalizations` for ids, then `PATCH /v1/betaAppLocalizations/{id}` with `{description, feedbackEmail}`; `POST` to add a locale (`en-US`, `zh-Hans`) |
| What to Test (per build, per locale) | `betaBuildLocalizations` | `GET /v1/builds/{build}/betaBuildLocalizations`, then `PATCH` `{whatsNew}` / `POST` with build relationship |
| Tester groups | `betaGroups` | `POST` with `isInternalGroup` / `publicLinkEnabled`; internal group gets `hasAccessToAllBuilds: true` so future builds auto-appear |
| Add a build to the external group | relationship | `POST /v1/betaGroups/{id}/relationships/builds` |
| Testers | `betaTesters` | `POST` with email + group relationship (internal testers must be ASC team users) |
| Review contact + notes + demo video | `betaAppReviewDetails` | `PATCH /v1/betaAppReviewDetails/{app}` — **all contact fields must be sent together**; a partial PATCH missing `contactPhone` 409s |
| Submit for beta review | `betaAppReviewSubmissions` | `POST` with build relationship → `betaReviewState: WAITING_FOR_REVIEW` |

To change TestFlight copy later: edit the text, `PATCH` the localization, done —
no build, no review, effective immediately.

## Review rules worth remembering

- **First build of each marketing version** goes through Beta App Review
  (1–2 days). Later builds of the *same* version reach external testers with no
  review. Iterate under one version; bump the version when a re-review is
  acceptable.
- Internal testing never waits for review.
- Review notes lead with the Blink/Termius framing: commands run on the user's
  **own Mac**, no third-party server, no account (so no demo credentials — the
  QR pairing replaces them), and a demo video of pairing + live use is linked
  because the reviewer has no Mac running Termio.
- Builds expire after **90 days**; audiences that rely on the public link need
  at least one build per 90-day window to keep it alive.
- External-tester ceiling is 10,000; the public link draws from that pool.
