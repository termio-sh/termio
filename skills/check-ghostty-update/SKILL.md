---
name: check-ghostty-update
description: "Check whether ghostty (the terminal core termio embeds via the termio-sh/libghostty-swift fork) has shipped anything worth pulling since the binary termio is currently pinned to. Resolves the pinned ghostty sha, diffs it against ghostty main, filters the gap for changes that actually reach termio's embedded VT/terminal core (dropping app-chrome / packaging / i18n noise), and gives a keep-waiting-or-pull-now verdict. Invoke when the user says 'check ghostty update', 'is ghostty out of date', 'did ghostty ship anything major', 'should I bump ghostty/libghostty', '看看 ghostty 有没有更新', '检查 ghostty 更新', 'ghostty 有什么重大更新', or '要不要更新 libghostty'."
---

# Check ghostty update

termio does **not** build ghostty itself — it embeds ghostty's terminal core through
the **`termio-sh/libghostty-swift`** fork, whose weekly CI rebuilds `GhosttyKit.xcframework`
against ghostty `main` and publishes it as a `storage.X.Y.Z` release ([[termio-libghostty-swift]]).
So "is ghostty up to date" really means: **how far is ghostty `main` ahead of the sha baked
into the binary termio is pinned to, and is anything in that gap relevant to termio?**

termio is an **embedder**, so only a slice of ghostty's changes matter. Weight the diff
accordingly — see *Signal vs. noise* below. Local self-build is impossible on this Mac
(Tahoe/zig deadlock); updating the binary always goes through the fork's CI.

## What this skill does NOT do

Report only. It does not tag the fork, trigger CI, or bump any pin. Those are the
follow-up the verdict points to (and separate skills / explicit asks).

## Procedure

Run these steps and report; everything is read-only `gh` + `grep`.

### 1. Resolve the ghostty sha termio is currently on

The pin chain is: termio `Package.resolved` → fork version tag → that tag's `Package.swift`
names a `storage.X.Y.Z` binary → that storage release's **title** carries the ghostty sha
(format `... · ghostty v1.3.1-<N>-g<sha>`).

```bash
REPO=$(git rev-parse --show-toplevel)
FORK=termio-sh/libghostty-swift
GHOSTTY=ghostty-org/ghostty

VER=$(grep -A6 '"identity" : "libghostty-swift"' "$REPO/Package.resolved" \
      | grep '"version"' | head -1 | sed -E 's/.*"version" : "([^"]+)".*/\1/')
STORAGE=$(gh api "repos/$FORK/contents/Package.swift?ref=$VER" --jq '.content' \
      | base64 -d | grep -oE 'storage\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
NAME=$(gh release view "$STORAGE" --repo "$FORK" --json name --jq '.name')
CUR=$(echo "$NAME" | grep -oE 'g[0-9a-f]{7,}' | sed 's/^g//')
echo "termio pin: fork $VER → $STORAGE → ghostty $NAME (sha $CUR)"
```

If any of these come back empty, fall back: the fork's **latest** `storage.*` release is
usually what a fresh resolve would pick —
`gh release list --repo $FORK | grep storage | head -1` — and note the discrepancy.

### 2. Diff against ghostty main

```bash
gh api "repos/$GHOSTTY/compare/$CUR...main" \
  --jq '"ahead: \(.ahead_by), head: \(.commits[-1].sha[0:7]) @ \(.commits[-1].commit.author.date[0:10])"'
```

- `ahead: 0` → **you are current. Stop and report "nothing to pull."**
- Otherwise capture `ahead_by` and the head sha/date for the report.

### 3. Pull the gap and separate signal from noise

```bash
gh api "repos/$GHOSTTY/compare/$CUR...main" \
  --jq '.commits[].commit.message | split("\n")[0]' > /tmp/ghostty_gap.txt
wc -l /tmp/ghostty_gap.txt
```

**Signal — changes that reach termio's embedded core (surface these):**
prefixes `lib-vt:`, `terminal:`, `terminal/…:`, `renderer:`, `font:`, `kitty` (graphics /
keyboard / protocol), `osc`, `selection`, `sixel`, `hyperlink`, `unicode`, `perf` /
`throughput`, scrollback, resize/reflow, mode/DEC private modes.

**Noise — termio host-manages IO and ships its own AppKit/SwiftUI chrome, so ignore:**
`macOS:` (splits, tabs, title bar, NSScrollPocket, HIG), `gtk`/`gnome`, `pkg/…` /
`apple-sdk` / build.zig, `i18n`/translation, `nushell`/shell-integration, `docs`,
`ci`, `gitignore`, VOUCHED/changelog.

```bash
grep -iE 'lib-vt|terminal[:/]|renderer|kitty|osc|selection|sixel|hyperlink|unicode|scrollback|reflow|throughput|perf|font' /tmp/ghostty_gap.txt \
  | grep -ivE 'macos:|gtk|gnome|pkg/|apple-sdk|i18n|translat|nushell|docs:|^ci|gitignore|vouched' \
  | sort -u
```

Read the survivors yourself — the grep is a first pass, not the judgement. For any that
look big (memory/perf wins, a new VT/embedder API termio could use, a protocol termio
renders like kitty graphics), confirm it isn't *already* in the pinned binary by date
(a commit older than the binary's build date is already in) or with a compare:
`gh api repos/$GHOSTTY/compare/<that-sha>...$CUR --jq .status` → `ahead`/`identical` = already have it.

### 4. Verdict

Give a short, honest call:

- **Nothing relevant** (gap is all app-chrome/packaging/i18n) → "no reason to bump; the
  Monday cron will roll it forward on its own." This is the common case — ghostty is
  high-velocity but most of it is app-layer.
- **Something relevant but minor** → name it, say it'll arrive with the next weekly build,
  no rush.
- **Something genuinely major** (big perf/memory win, a VT/embedder API termio wants, a
  correctness fix in a path termio exercises) → name it with its PR #, and offer the
  pull-now path.

### Pull-now path (only when the verdict warrants it)

The binary can't be built locally. To pull ghostty early:
1. Manually dispatch the fork's CI against a specific ghostty ref — the fork's
   `.github/workflows/build.yml` takes a `ghostty_ref` input (default builds `main` HEAD):
   `gh workflow run build.yml --repo termio-sh/libghostty-swift -f ghostty_ref=main`
   (or pin an exact sha). It publishes a new `storage.X.Y.Z` + `X.Y.Z` tag (~30 min).
2. Bump termio's pin (`Package.swift` `from:` + re-resolve `Package.resolved`), and the
   iOS `TermioMobile.xcodeproj` pin if the phone should get it too (it pins the fork
   separately — see [[termio-libghostty-swift]]).
3. `macos-rebuild-dev` and verify.

## Notes

- ghostty cuts stable tags rarely (last was `v1.3.1`, 2026-03), and the fork tracks
  `main`, so termio typically rides **~1400+ commits ahead of ghostty's newest stable
  tag**. "No new ghostty release" ≠ "nothing new" — always compare against `main`, never
  against tags.
- The fork's own semver (`1.0.x`) is the *wrapper* version and is decoupled from ghostty's
  version; a wrapper-only change (like the Swift-side `InMemoryTerminalSession` fixes) bumps
  the fork tag while **reusing** the same `storage.*` ghostty binary. That's why step 1
  reads the storage tag from the pinned tag's `Package.swift` rather than assuming
  `storage.<same-version>`.
- Needs the `gh` CLI authenticated. All calls are read-only.
