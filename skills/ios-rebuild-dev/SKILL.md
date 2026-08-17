---
name: ios-rebuild-dev
description: "Rebuild TermioMobile and install + relaunch it on the connected iPhone (or the booted simulator with 'sim'), pointed at this Mac's companion server. Invoke when the user says 'rebuild ios', 'rebuild the iphone app', 'run on my phone', 'preview on iphone', 'ios rebuild', '重新编译 ios', or '装到手机上'."
---

# Rebuild iOS App (local development)

Build `TermioMobile`, install it on the user's iPhone, and relaunch it connected
to this Mac's companion server — the iOS equivalent of `macos-rebuild-dev`.

Everything is already scripted in `ios/dev-run.sh`: it finds the first connected
iPhone via `xctrace`, builds Debug with `xcodebuild` (automatic provisioning,
derived data in `ios/build/`), installs with `devicectl`, and launches
`sh.termio.mobile` with `-roster-url ws://<this Mac's en0 IP>:8787` so the app
talks to the companion server in the running Mac termio. `--terminate-existing`
kills the previous instance, so rerunning the script IS the edit-preview loop.

## Instructions

When invoked, execute these steps sequentially:

1. **Decide the target.** Default is a physical iPhone. If the user said
   "sim"/"simulator" (or no iPhone is reachable and they agree to fall back),
   use the simulator path in step 4 instead.

2. **Run the dev script** from the repo root. Show the tail of the output; on
   build failure show the error and **stop — do NOT install/launch**:
   ```bash
   ./ios/dev-run.sh 2>&1 | tail -20
   ```
   Pass a custom roster URL through as `./ios/dev-run.sh ws://host:8787` only if
   the user asked for one.

3. **Triage the common failures** instead of retrying blindly:
   - *"No iPhone found"* — the phone must be plugged in (or Wi-Fi paired) and
     have trusted this Mac. Show the `xcrun xctrace list devices` output the
     script printed and ask the user to connect/trust, or offer the simulator.
   - *Provisioning/signing errors* — the first device build needs Xcode signed
     into the personal team; tell the user to open `ios/TermioMobile.xcodeproj`
     once in Xcode and fix Signing & Capabilities, don't try to edit the pbxproj.
   - *Install OK but launch fails / app crashes on open* — iOS 16+ needs
     **Developer Mode** on (Settings ▸ Privacy & Security ▸ Developer Mode), and
     the developer certificate must be trusted (Settings ▸ General ▸ VPN &
     Device Management).
   - *App launches but shows no sessions* — the Mac termio app must be running
     (companion server on :8787) and the phone on the same network. Offer to run
     the `macos-rebuild-dev` skill to (re)start the Mac app.

4. **Simulator fallback** (only when asked or when no device is available).
   Pick the booted simulator if one exists, otherwise the first available
   iPhone from `xcrun simctl list devices available`:
   ```bash
   cd ios
   SIM=$(xcrun simctl list devices available | grep -m1 'iPhone.*Booted' \
       | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
   [[ -n "$SIM" ]] || SIM=$(xcrun simctl list devices available | grep -m1 'iPhone' \
       | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
   xcodebuild -project TermioMobile.xcodeproj -scheme TermioMobile \
       -configuration Debug -destination "platform=iOS Simulator,id=${SIM}" \
       -derivedDataPath build build 2>&1 | tail -12
   xcrun simctl boot "$SIM" 2>/dev/null || true
   open -a Simulator
   xcrun simctl install "$SIM" build/Build/Products/Debug-iphonesimulator/TermioMobile.app
   # The companion server refuses unauthenticated sockets after a 10s grace
   # window, so the roster URL MUST carry the pairing token (?t=…) or the app
   # loops "connected → unauthorized → reconnect" forever. Token lives in the
   # Mac app's defaults (readable by design), same as dev-run.sh.
   TOKEN=$(defaults read sh.termio.app companion.pairingToken 2>/dev/null || true)
   xcrun simctl launch --terminate-running-process "$SIM" sh.termio.mobile \
       -roster-url "ws://127.0.0.1:8787${TOKEN:+/?t=${TOKEN}}"
   ```
   In the simulator the Mac is `127.0.0.1`, not the en0 IP. Remember: simulator
   UserDefaults overrides only work via launch arguments, not `simctl defaults
   write` (see the `ios-sim-defaults` memory).

5. **Report** the result: device (name/UDID) or simulator, build outcome, and
   whether the app launched. If it built and launched, remind the user the app
   is pointed at `ws://<Mac IP>:8787` and needs the Mac termio app running.

## Notes

- Device builds require the iPhone unlocked during install; `devicectl` errors
  out on a locked passcode-protected phone.
- The script builds **Debug** — fine for previewing; there is no separate
  release/bundle step like the Mac app's icon dance.
- Do NOT modify `ios/dev-run.sh` or the pbxproj as part of a rebuild.
- After a UI change lands on the simulator, screenshots can be taken with
  `xcrun simctl io booted screenshot /tmp/ios.png`; on a physical phone, ask the
  user for a screenshot instead.
