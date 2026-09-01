---
name: macos-rebuild-dev
description: "Kill the running termio dev app, rebuild it with SwiftPM, and relaunch it as a foreground app. Invoke when the user says 'rebuild', 'rebuild app', 'restart app', 'relaunch', '重新编译', or '重启 app'."
---

# Rebuild App (local development)

Kill the running **dev** build, rebuild it as the isolated `termio-dev.app` bundle,
and relaunch — so every rebuild reflects the current Dock icon and, crucially, does
**not** disturb an installed release build you use daily.

## The dev channel

termio ships a `TERMIO_CHANNEL=dev` build that is a fully separate app from the
release one, so both can run at the same time:

| | release | dev (this skill) |
| --- | --- | --- |
| Bundle | `termio.app` (usually `/Applications`) | `termio-dev.app` (repo root) |
| Bundle id | `sh.termio.app` | `sh.termio.app.dev` |
| State + sockets | `~/Library/Application Support/termio` | `…/termio-dev` |
| User config | `~/.termio` | `~/.termio-dev` |
| Daemon socket | `$TMPDIR/termiod-<uid>` | `…-dev` |
| Daemon launchd job | `sh.termio.termiod` | `sh.termio.termiod.dev` |
| Companion port | 8787 | 8788 |
| CLI on PATH | `termio` | `termio-dev` |
| Sparkle auto-update | on | **no update feed** (dev never self-updates) |

All of this falls out of the `.dev` bundle-id suffix via `Sources/termio/Companion/AppChannel.swift`
(paths + port) and `scripts/build-app.sh` (id, name, `SUFeedURL` deletion, CLI rebind).
Sparkle.framework itself is embedded on both channels — the binary links it either
way — so a dev bundle still carries it; it just has nothing to check.

termio is a plain SwiftPM executable (`Package.swift` → `executableTarget` named
`termio`); `swift build` alone produces a bare binary with **no Dock icon**. So this
skill builds the real bundle via `scripts/build-app.sh`. For a dev build the script
auto-picks a real codesigning identity from **your own** keychain (any "Apple
Development" / "Developer ID Application" cert — a free Apple ID gives you one) so the
dev app can post macOS notifications; `usernoted` rejects an ad-hoc signature outright,
so an unsigned dev build can **never** banner. A contributor with **no** signing cert
falls back to ad-hoc automatically — the build still succeeds, they just don't get
notifications. Set `SIGN_IDENTITY=…` to force a specific one. The app runs
unsandboxed with `.exec` PTYs — see `CLAUDE.md`. The icon is `packaging/icon-static.svg`,
rasterized to `packaging/AppIcon.png` by `scripts/render-icon.sh` (needs headless
Chrome). Note: dev and release currently share the same icon art and differ only by
name ("termio dev") — a tinted dev icon is a possible follow-up.

## Instructions

When invoked, execute these steps sequentially:

1. **Kill only the running dev app + its tunnel.** Both channels' inner binary is
   named `termio` (`CFBundleExecutable`), so `pkill -x termio` would kill the release
   app too. Match the dev bundle **path** instead. SIGKILL skips the app's
   `willTerminate` cleanup, so also reap the companion tunnel it spawned on the dev
   port (8788):
   ```bash
   pkill -9 -f "termio-dev.app/Contents/MacOS/termio" || true
   pkill -9 -f "cloudflared tunnel --url http://127.0.0.1:8788" || true
   pkill -9 -f "tunelo port 8788" || true
   ```

2. **Build the dev bundle** from the committed `packaging/AppIcon.png` — do *not*
   re-render the icon (see "Icons" below). Show the tail of the output; if the
   build fails, show the error and **stop — do NOT relaunch**:
   ```bash
   TERMIO_CHANNEL=dev ./scripts/build-app.sh 2>&1 | tail -12
   ```

3. **Re-register the dev bundle with LaunchServices, then refresh the Dock cache.**
   macOS resolves an app's icon by its bundle id (`sh.termio.app.dev`); `lsregister -f`
   forces our path to win and `killall Dock` drops the cached icon:
   ```bash
   LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
   "$LSREG" -f "$PWD/termio-dev.app"
   touch ./termio-dev.app
   killall Dock 2>/dev/null || true
   ```

4. **Relaunch via `open`** (NOT `nohup` on the inner binary — that bypasses
   LaunchServices). `open`'s `--stdout` / `--stderr` still capture logs:
   ```bash
   open ./termio-dev.app --stdout /tmp/termio-dev.log --stderr /tmp/termio-dev.log
   echo "launched ./termio-dev.app (logs: /tmp/termio-dev.log)"
   ```

5. **Report** the result: whether the build succeeded and the app relaunched, or
   what went wrong. If the window doesn't appear, check `/tmp/termio-dev.log`.

## Icons

`scripts/render-icon.sh` rasterizes `packaging/icon-static.svg` into
`packaging/AppIcon.png` (and the iOS asset) through headless Chrome — and its
output is **not reproducible**: rendering the same SVG twice writes two different
files, neither matching the committed one. Running it on every rebuild therefore
dirtied the tree with two unreviewable binary diffs, cost a Chrome launch, and
risked overwriting hand-touched artwork. So it is not part of this loop.

Re-render only when the SVG actually changed, and commit the PNGs as their own
change:

```bash
./scripts/render-icon.sh && git add packaging/AppIcon.png \
  ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Notes

- This builds **release configuration** (via `build-app.sh`) into the dev *channel*
  bundle, so it's a few seconds slower than a bare `swift build`. For quick code-only
  iteration without a bundle, run `swift build` and launch
  `"$(swift build --show-bin-path)/termio"` directly — but that has no Dock icon and,
  running unbundled, uses `AppChannel.suffix == ""` (i.e. the *release* state dir and
  port 8787), so it is **not** isolated. Use the bundle when you need isolation.
- A concurrent SwiftPM process holding the `.build` lock can make a build emit
  spurious errors mid-write; if that happens, just rerun.
- Do NOT modify `Package.swift` or sources during a rebuild.
- After rebuilding a UI change, pair this with the `app-screenshot-debug` skill to
  actually *see* the result.
