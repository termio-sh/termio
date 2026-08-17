---
name: asc
description: Drive App Store Connect from the terminal with the `asc` CLI — TestFlight builds, groups, testers and What to Test notes; App Store versions, metadata, keywords, screenshots and release notes; submissions and review health; signing, provisioning and notarization; crash and beta-feedback triage; pricing, subscriptions and Apple Ads. Use whenever the task touches App Store Connect, TestFlight, an App Store release or submission, or an iOS/macOS build upload. Route to the matching file under references/ before running commands.
---

# asc — App Store Connect from the CLI

`asc` is installed via Homebrew (`brew install asc`). It is the only tool that
should touch App Store Connect here — do not hand-roll JWTs or curl the API.

This skill is a router. Read the one reference that matches the task, not the
whole set. Each reference is a self-contained playbook with the exact commands.

## Before anything

Every command needs credentials. Check first:

```sh
asc auth status      # active profile
asc doctor           # diagnose a broken or missing setup
```

If nothing is stored, register a key (Key ID + Issuer ID + `.p8` from
https://appstoreconnect.apple.com/access/integrations/api):

```sh
asc auth login --name <label> --key-id <KEY_ID> --issuer-id <UUID> \
  --private-key <path/to/AuthKey_XXXX.p8> --network
```

Most commands need an app or build ID rather than a name — see
`references/asc-id-resolver.md`.

## Routing table

| Task | Read |
| --- | --- |
| Flags, output formats, pagination, discovery — how to shape any `asc` command | `references/asc-cli-usage.md` |
| Turn an app / build / version / group / tester name into an ID | `references/asc-id-resolver.md` |
| TestFlight groups, testers, distribution, What to Test notes | `references/asc-testflight-orchestration.md` |
| Build processing status, finding the latest build, retention cleanup | `references/asc-build-lifecycle.md` |
| TestFlight crashes, beta feedback, hangs, launch diagnostics | `references/asc-crash-triage.md` |
| Build, archive, export, bump version/build numbers, upload an IPA/PKG | `references/asc-xcode-build.md` |
| Stage a version, publish, submit for review | `references/asc-release-flow.md` |
| Validation failures, stuck submissions, cancel and retry decisions | `references/asc-submission-health.md` |
| Pull, edit, validate and apply App Store metadata and keywords | `references/asc-metadata-sync.md` |
| Write release notes (What's New) from git log or bullets | `references/asc-whats-new-writer.md` |
| Translate metadata into more locales | `references/asc-localize-metadata.md` |
| Offline ASO / keyword audit of pulled metadata | `references/asc-aso-audit.md` |
| Capture, frame and upload screenshots (simulator pipeline) | `references/asc-shots-pipeline.md` |
| Fix screenshot dimensions, alpha channels, validation errors | `references/asc-screenshot-resize.md` |
| Bundle IDs, capabilities, certificates, provisioning profiles | `references/asc-signing-setup.md` |
| Developer ID signing + notarization for distribution outside the App Store | `references/asc-notarization.md` |
| Territory-specific / PPP pricing | `references/asc-ppp-pricing.md` |
| Subscription and IAP display names across locales | `references/asc-subscription-localization.md` |
| Reconcile the ASC catalog with RevenueCat | `references/asc-revenuecat-catalog-sync.md` |
| Apple Ads campaigns, ad groups, keywords, reports | `references/asc-apple-ads.md` |
| Repo-local multi-step automations (`.asc/workflow.json`) | `references/asc-workflow.md` |
| Create a new app record (browser automation — no public API) | `references/asc-app-create-ui.md` |
| Submit an entry to the asc Wall of Apps | `references/asc-wall-submit.md` |

References cross-name each other by their old skill names — a line saying
"route to `asc-submission-health`" means `references/asc-submission-health.md`
in this skill.

## Provenance

Vendored from https://github.com/rorkai/app-store-connect-cli-skills at the
commit `asc install-skills` pins (recorded per file in `skills-lock.json`).
Upstream ships these as 23 separate top-level skills; here they are flattened
into this one skill's `references/`, with each skill's own `references/` folder
nested under `references/<skill-name>/` and its links rewritten to match. The
prose is otherwise verbatim — do not hand-edit it. To update, run
`asc install-skills`, then re-flatten from `~/.agents/skills/asc-*` and delete
the global copies.
