---
title: Push-to-talk voice dictation — hold the space bar (iOS shipped, OpenAI)
status: active
type: rfc
created: 2026-07-04
updated: 2026-07-04
related:
260703-ios-terminal-input.md
---

# Push-to-talk voice dictation (macOS, OpenAI) + iOS terminal space key

> Hold the terminal keyboard's **space bar**, speak a prompt, release — Termio
> records the mic, transcribes it with OpenAI's `gpt-4o-transcribe`, and drops
> the text into the composer draft for you to review and send. Tap the space
> bar and it's just a space; hold it (when push-to-talk is on) and it's the mic
> — Doubao's long-press-spacebar, which also answers the "add a space key to the
> terminal keyboard" request in the same key. The interaction borrows Doubao's
> hold-to-talk (waveform + slide-to-cancel + explicit release = "done"); the
> optional cleanup pass is modeled on Typeless. Ships behind a user-supplied
> OpenAI API key.

## Status

**Shipped on iOS (2026-07-04).** The space bar *is* the push-to-talk button:
tap = space, hold = dictate, and with push-to-talk off it's a plain space bar.
Transcription runs **on the phone** (the phone POSTs the clip straight to
OpenAI; key in the device Keychain) — not through the Mac companion — chosen for
a self-contained first cut that works whether or not a Mac is paired. The Mac
companion backend (one key on the Mac, phone streams audio over the link) and
the macOS in-app hotkey remain the future path below.

Implemented across: `VoiceDictation.swift` (recorder + OpenAI client + Keychain
+ recording HUD), the space bar in `TerminalKeyboardView`, the dictation flow in
`ComposerBar`, `MobileSettings.pushToTalkEnabled`, and Settings ▸ Voice.

## Motivation

Typing a paragraph-long prompt to a coding agent is the slowest part of driving
one — worse on the phone, and even on the Mac a spoken sentence beats a typed
one for intent-heavy prompts ("refactor the transport layer so the companion
owns the byte stream and add backpressure"). Every serious dictation product now
proves the same loop: **hold a key, talk, release, text lands in the field.**
Typeless (fn key → cleaned text), superwhisper (local Whisper), and Doubao's
mobile input method all converge on it.

Termio has no audio code today (verified: no `AVFoundation`/`Speech`/mic usage
anywhere except the QR scanner's video capture). This RFC adds the smallest
honest version of that loop, plus the trivial space-key fix the iOS custom
keyboard is missing.

Two independent deliverables, shippable in either order:

- **A — iOS terminal space key** (tiny, mechanical). The custom `inputView`
  keyboard has no space; add one to the catalog.
- **B — macOS push-to-talk voice dictation** (the real work). Opt-in, keyed on a
  user-supplied OpenAI key.

## Research inputs

Two references shaped the design. Full notes live in the agent research this RFC
was written from; the load-bearing conclusions:

### Doubao (豆包) — the interaction

- **Hold → speak → release** is the primary gesture, not a tap-toggle. The
  release is an *explicit turn boundary* ("I'm done") — this beats iOS
  dictation's 30-second silence timeout for discrete agent prompts, which can
  cut you off mid-thought.
- **Drag-target release**, borrowed from WeChat's `按住说话`: where you release
  chooses the outcome. Default zone → drop transcript into the field to edit;
  slide to send → commit immediately; slide to a cancel zone → discard, with an
  explicit "release to cancel" label. Zone entry gives visual + haptic feedback.
- **A live waveform** is the "I'm listening" signal; partial transcription
  streams into the field rather than appearing all at once on stop.
- **Keep "one dictated prompt" and "open-mic call mode" as separate features.**
  We only build the first. A continuous voice-call mode is explicitly out of
  scope.

### Typeless — the cleanup prompt

- Its value over raw ASR is a **post-transcription LLM pass**: strip fillers
  (um/uh), collapse repeats, and — the standout — **honor self-corrections**
  ("send it Tuesday, no, Wednesday" → keeps only "Wednesday"). Speech is treated
  as a stream of edits, not a literal transcript.
- The cleanup runs on a **user-editable prompt**, not a fixed style, and is
  **context-aware** (formal in Outlook, casual in iMessage). Termio's context is
  fixed and strong: *the target is a coding agent* — so the prompt's job is to
  preserve code, paths, identifiers, and shell syntax verbatim and **not**
  prose-ify them. That single constant is our differentiator.
- Default push-to-talk key is **fn** (present on every Mac, rarely bound).

### OpenAI audio models — the transcription

Verified against `developers.openai.com` (2026):

| Model | Role | Price |
| --- | --- | --- |
| `gpt-4o-transcribe` | Highest accuracy, request-response | **$0.006/min** |
| `gpt-4o-mini-transcribe` | Cheaper, slight accuracy trade-off | **$0.003/min** |
| `gpt-realtime-whisper` | Native streaming (WS/WebRTC), `delay: minimal` | **$0.017/min** |
| `whisper-1` | Legacy | $0.006/min |

**Decision: [`gpt-4o-transcribe`](https://developers.openai.com/api/docs/models/gpt-4o-transcribe)
over the `/v1/audio/transcriptions` endpoint, record-then-POST (non-realtime).**
It is a pure speech-to-text model (audio+text in → **text only** out), unlike
[`gpt-audio`](https://developers.openai.com/api/docs/models/gpt-audio) — a full
speech-in/speech-out conversation model on Chat Completions/Realtime at
~$32/$64 per 1M audio tokens (~10× the cost), which we explicitly don't want
(no spoken replies). Rationale:

- Our clip is a few seconds to a minute, and the text goes into the prompt
  *after* release — we do not need mid-speech tokens, which is the only reason to
  pay for the Realtime WS/WebRTC complexity.
- Cost is trivial: a 20 s dictation ≈ **$0.002**. Realtime is ~3× the price and
  forces a persistent socket for a feature that fires in bursts.
- Accuracy matters most — coding prompts are dense with identifiers, filenames,
  library names. `gpt-4o-transcribe` is the most accurate of the batch (≈4.1% WER
  vs Whisper-v3 ≈5.3% at the same price) and takes a **`prompt` bias hint** we
  can seed with repo/tool/framework names — the OpenAI analog of Typeless's
  Personal Dictionary.
- Streaming (`gpt-realtime-whisper`, `delay: "minimal"`) is the Phase-4 upgrade
  *iff* we later want live text under the finger. Not now.

## Design

### Part A — iOS terminal space key

The iOS keyboard is a fully custom `inputView` (`TerminalKeyboardView.swift`)
that replaces the system keyboard with a curated control-key catalog
(`TerminalKeyCatalog.all`, `TerminalKeyboardView.swift:14`). It ships Esc,
configurable control keys, digits, arrows, and Return — but **no space**. In
that mode a user cannot type a literal space into the terminal.

Add one catalog entry:

```swift
// TerminalKeyboardView.swift — in TerminalKeyCatalog.all
TerminalControlKey(
    id: "space", title: "space",
    detail: "Type a literal space",
    payload: Data([0x20])
),
```

Open questions for A:

- **Default-on or opt-in?** `defaultIDs` is currently
  `["shiftTab","tab","ctrlO","ctrlC","ctrlL"]`. A space is more universal than
  any control key; it likely belongs in the always-shown fixed core (the strip
  that already renders Esc / ⌫ / digits / arrows / Return at
  `TerminalKeyboardView.swift:238`) rather than the configurable slots — so it's
  always present and doesn't consume a user's 5 configurable picks.
- **Width.** A space bar reads as a wide key; the fixed core may want it rendered
  wider than a control key. Cosmetic, decide during implementation.

This is independent of everything below and can ship first.

### Part B — macOS push-to-talk

#### The loop

```
hotkey down ──▶ start AVAudioRecorder (.m4a/AAC), show waveform HUD
   (hold)  ──▶ live level meter animates the waveform
hotkey up   ──▶ stop recording, HUD → "transcribing…"
            ──▶ POST clip to /v1/audio/transcriptions (gpt-4o-transcribe)
            ──▶ [optional] cleanup LLM pass (Part B, phase 3)
            ──▶ insert text into the focused terminal surface (no CR)
   esc/cancel-zone during hold ──▶ discard, no request
```

**Default outcome is "insert, don't send"** — the transcript is pasted into the
focused terminal's input line (the agent's TUI prompt) *without* a carriage
return, so the user reviews and presses Return themselves. This is Doubao's
"release into the field to edit" default, and it's the safe one: dictation must
never fire a half-formed prompt (the same invariant `ComposerBar` already holds
on iOS — "only the send button submits, so dictation can never fire a
half-formed prompt", `ComposerBar.swift:14`). A held modifier on release (e.g.
release with ⌘) can opt into auto-send (append `\r`).

#### Where text goes

macOS has no composer bar — the terminal surface *is* the field. Insert routes
through the existing PTY write path (`PTYProcess.write`, `PTYProcess.swift:302`),
wrapped in bracketed paste when multi-line, mirroring iOS's
`sendComposedPrompt` (`TerminalViewController.swift:333`):

```swift
// pseudo — reuse the bracketed-paste convention already in the iOS composer
var payload = transcript
if payload.contains("\n") { payload = "\u{1B}[200~" + payload + "\u{1B}[201~" }
focusedSurface.write(Data(payload.utf8))   // no trailing \r → user reviews
```

#### The hotkey

Termio is a foreground AppKit app with a menu-bar tray. Push-to-talk needs
key-down **and** key-up (hold semantics), so a plain `KeyboardShortcut` is
insufficient. Options, in order of preference:

1. **In-window `NSEvent` local monitor** for `.keyDown`/`.keyUp` on a chosen
   combo (e.g. ⌥Space) — works while Termio is focused, no accessibility
   permission. **Recommended for MVP** — you're already looking at the terminal
   you're dictating into.
2. **Global** `NSEvent.addGlobalMonitorForEvents` or Carbon
   `RegisterEventHotKey` for a system-wide hold key (Typeless uses fn) — needs
   Accessibility/Input-Monitoring permission. Defer to a later phase; it's a
   permission prompt and an entitlement cost for a feature most users will
   trigger while looking at the app anyway.

fn specifically is a special modifier (`NSEvent.ModifierFlags.function`) and
awkward to capture reliably; prefer a normal combo for MVP.

#### Settings & secret storage

macOS Settings already has a 5-tab live-settings window. Add a **Voice** section
(or fold into an existing tab) with:

- **Enable push-to-talk** (off by default — the whole feature is opt-in).
- **OpenAI API key** — stored in the **Keychain**, following the app's existing
  generic-password pattern (`UsageMonitor.swift:249` reads Keychain items today).
  Service name `termio-openai-key`. Never in `UserDefaults`, never in git.
- **Hotkey** — the hold combo (default ⌥Space).
- **Transcription model** — `gpt-4o-transcribe` (default) / `gpt-4o-mini-transcribe`.
- **Cleanup pass** — off by default; toggle + an editable prompt (phase 3).
- **Vocabulary hint** — optional free text seeded into the transcription `prompt`
  field (repo, tool, framework names) to bias jargon.

`NSMicrophoneUsageDescription` goes in the app's Info.plist; request access via
`AVCaptureDevice.requestAccess(for: .audio)` on first use.

#### The cleanup prompt (phase 3, optional)

A second, cheap LLM call after transcription. Off by default (latency + cost +
a second failure mode); on for users who want Typeless-grade polish. The system
prompt is user-editable but ships with a coding-agent-tuned default:

> You clean up dictated text that will be sent to an AI coding agent. Remove
> filler words and false starts. When the speaker corrects themselves, keep only
> their final intent. Do **not** rephrase, summarize, or "improve" the wording.
> **Preserve verbatim**: code, file paths, identifiers, shell commands, flags,
> URLs, and any technical term — never prose-ify them. Output only the cleaned
> text, nothing else.

This is the one place Termio's fixed context ("target is a coding agent") turns
into a concrete advantage over general dictation apps.

### Phasing

- **Phase 1 — iOS hold-the-space-bar. ✅ Shipped.** Space bar in the terminal
  keyboard (tap = space, hold = dictate), `AVAudioRecorder` → `gpt-4o-transcribe`
  → insert into the composer draft (no auto-send). Live waveform HUD +
  slide-up-to-cancel + haptics. Settings ▸ Voice: push-to-talk toggle + Keychain
  API key. Transcription is phone-direct.
- **Phase 2 — Mac companion backend.** Route the clip over the companion link so
  the Mac holds one OpenAI key and does the transcription; the phone only
  records. Removes per-device key entry when paired.
- **Phase 3 — Typeless cleanup pass.** A cheap second LLM call, off by default,
  with the coding-agent-tuned editable prompt above (strip fillers + honor
  self-corrections; preserve code/paths verbatim).
- **Phase 4 — macOS in-app push-to-talk.** In-window ⌥Space hold → record →
  transcribe → insert into the focused terminal, reusing the same pipeline.
- **Phase 5 — future.** Streaming via `gpt-realtime-whisper` (live text under the
  finger); a global (Accessibility-permission) macOS hotkey.

## Non-goals

- **No continuous voice-call / open-mic mode.** One dictated turn per hold, full
  stop (Doubao keeps these separate; so do we).
- **No spoken responses / TTS.** Dictation is input-only.
- **No local/offline ASR.** Cloud-only, keyed on the user's OpenAI key. (A local
  Whisper option is a possible far-future privacy story, not this RFC.)
- **No always-on global hotkey in the MVP** — defer the Accessibility-permission
  path to Phase 2+.
- **No bundled API key.** The user brings their own OpenAI key; no termio-side
  proxy, no metering.

## Open questions

1. **Auto-send affordance.** Is release-with-⌘ the right "send now" gesture, or
   should the default be send-and-let-undo? Leaning insert-only default for
   safety.
2. **Space key placement** — fixed core vs configurable slot (see Part A).
3. **Cleanup default** — ship Phase 3 off (raw transcription is already good), or
   on for a more magical first run? Leaning off (latency honesty).
4. **Model exposure** — expose the model picker to users, or hardcode
   `gpt-4o-transcribe` and keep Settings small? Termio's ethos favors fewer
   knobs; maybe hide the picker until asked.

sudo