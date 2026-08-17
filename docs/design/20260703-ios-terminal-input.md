---
title: iOS terminal input & attachments
status: active
type: design
created: 2026-07-03
updated: 2026-07-04
---

# iOS terminal input & attachments

> How the iPhone app talks to a live agent session — the composer, the terminal
> keyboard, and the attachment flow — and what we adopt (and deliberately skip)
> from Telegram-iOS's attachment menu.

## Principles

- **The TUI is the chat.** The session view is terminal + composer; no bubble
  UI, no separate chat tab. Everything below feeds bytes into the PTY.
- **One atomic write per message.** The composer sends the whole draft in a
  single PTY write (multiline wrapped in bracketed paste + `\r`); Return in the
  field never submits, only Send does. Keystroke streaming lost to this design
  in every 2026 agent client we surveyed (Moshi, Orca, Happy).
- **Native pickers over custom chrome.** Telegram builds ~80K LOC of custom
  attachment UI because it needs 10+ tab types and its own gallery. We need
  three sources (photos, camera, files) and iOS ships a picker for each.
- **Agents take file paths.** An attachment is uploaded to the Mac and its
  absolute path lands in the draft (Moshi's pattern, over the companion
  WebSocket instead of SCP). The draft itself is the "caption".

## Current input surface

| Piece | File | Design |
| --- | --- | --- |
| Composer | `ios/Sources/ComposerBar.swift` | Blur pill, growing text view, Send = one atomic write; (+) attach button appears only for companion-backed sessions |
| Slash panel | `ComposerBar.swift` | Telegram-style: draft starting `/` with no whitespace opens a prefix-filtered command list (max 4 rows); tap = send, arrow = insert-for-args |
| Terminal key bar | `ios/Sources/TerminalKeyBar.swift` | Custom accessory bar (Esc/Tab/Ctrl/arrows/⌫/paste); one-shot Ctrl with lock; auto-repeat arrows/⌫ |
| Terminal keyboard | `ios/Sources/TerminalKeyboardView.swift` | `inputView`-swap keyboard (⌨︎ pill toggles it like 🌐); fixed core Esc/1-4/arrows + configurable `TerminalKeyCatalog` zone; the single raw-key surface |
| Attachments | `ios/Sources/TerminalViewController.swift` | See below |

Removed by decision (don't rebuild): chat-bubble view (2026-07-03), raw-key
attention chip row (2026-07-03 — duplicate of the terminal keyboard; if prompt
answering returns, it's semantic approval cards, not keys).

## Attachment flow (v1, shipped)

```
(+) → UIAlertController action sheet
        ├─ Photo Library → PHPickerViewController (images, limit 1)
        │     → UIImage → downscale ≤2048px JPEG q0.8 → upload("photo.jpg")
        └─ Choose File  → UIDocumentPickerViewController (.item, asCopy: true)
              → Data(contentsOf:) → upload(lastPathComponent)

upload(name, data):  cap 8 MB → base64 over companion WS
  .upload(projectID, name, base64) → Mac writes <root>/.termio/uploads/<ts>-<name>
  → .uploaded(path) → path inserted into draft (space-separated)
```

Server side: `ws.maximumMessageSize = 16 MB`; timestamp prefix makes names
collision-free. E2E verified 2026-07-03 except the Mac handler needed an app
restart to go live.

## Telegram-iOS study (2026-07-03)

Sparse clone of `TelegramMessenger/Telegram-iOS`, modules `AttachmentUI`,
`MediaPickerUI`, `Camera`, `ICloudResources`, `LegacyMediaPickerUI`,
`TelegramUI`. What their attachment menu actually is, distilled:

### Container (the half-sheet with tabs)

- Fully custom ASDisplayNode sheet, **two snap points**: collapsed ≈75% of
  screen and full height (`AttachmentUI/Sources/AttachmentContainer.swift`).
  Snapping is velocity-driven (±300 pt/s) with a distance fallback (past half
  → collapse); dismiss on dim-tap, X, or a −60 pt over-drag.
- Tabs are an enum (`AttachmentButtonType`: gallery/file/location/poll/…);
  each tab's controller conforms to an `AttachmentContainable` protocol whose
  interesting members are `isPanGestureEnabled` (inner scroll vs sheet-drag
  arbitration) and `mediaPickerContext` (reactive selection count + caption).
  Controllers are reused across switches via `resetForReuse()`.
- The caption field + Send button (`AttachmentTextInputPanelNode`) belongs to
  the **container**, not the tabs — caption survives tab switches through the
  shared `mediaPickerContext`; the Send button renders the selection count.

### Photo tab (`MediaPickerUI`)

- Own PHAsset grid (3 columns, 128 pt opportunistic thumbnails) — which is why
  Telegram must handle iOS 14 `.limited` access with a "Manage" banner +
  `presentLimitedLibraryPicker`. The price of a custom grid is owning the
  permission UX.
- **Live camera tile**: the first grid cell is a tall 1×2 tile hosting a real
  `AVCaptureSession` (`MediaPickerScreen.swift:737`); `startCapture()` /
  `stopCapture()` track sheet visibility. Tap opens the full camera screen.
- Multi-select = numbered circles (selection order shown as 1, 2, 3…),
  long-press = preview, default limit 10.
- Size/quality: a "high quality" user toggle, downscaling delegated to the
  send pipeline — validated up front, no progress UI inside the picker.

### File tab

- Options are "Photo or Video" (gallery as file), **Recent files** (from their
  own history), and "iCloud Drive" → `UIDocumentPickerViewController` in
  `.open` mode with `allowsMultipleSelection = true`, types `["public.item"]`
  (`LegacyMediaPickerUI/Sources/LegacyICloudFilePicker.swift`).
- Because they use `.open` (in-place) rather than `asCopy`, they pay the full
  security-scope tax: `startAccessingSecurityScopedResource`, base64-encoded
  bookmark data, `NSMetadataQuery` to wait out undownloaded iCloud files,
  `NSFileCoordinator` reads (`ICloudResources/Sources/ICloudResources.swift`).
- Size limits are validated immediately on pick; over-limit shows an upsell
  screen. No picker-level upload progress there either.

## What we adopt (v1.1) — SHIPPED 2026-07-03

All six items below are implemented (`TerminalViewController.swift`,
`ComposerBar.swift`, `Info.plist`) and the photo path is verified end-to-end
in the simulator against a live companion: two photos multi-selected with
numbered circles → sequential upload → both real-filename paths
(`<ts>-IMG_0111.jpg`) in the draft and on disk under `.termio/uploads/`.
Smoke test: `testAttachPhotoBatchUploadsToCompanion` (skips without a live
companion; drives PHPicker by normalized coordinates because XCUITest
queries against the picker's remote a11y tree hang the runner). Camera
still needs a physical-device check — the iOS 26 simulator *does* report a
camera, so the Camera row shows there too.

1. **Camera source.** Third action in the sheet: Camera →
   `UIImagePickerController(sourceType: .camera)` → same
   `jpegPayload`/`upload` path. Needs `NSCameraUsageDescription`. We
   deliberately skip Telegram's live camera tile — an always-running
   `AVCaptureSession` inside a picker is their signature flourish, not ours.
2. **Multi-select photos.** `PHPickerConfiguration.selectionLimit = 10`
   (Telegram's default limit), `selection = .ordered` so numbered circles come
   for free from the system picker. Upload sequentially; paths append
   space-separated into the draft (already supported by `insertDraft`).
3. **Real filenames.** Use `itemProvider.suggestedName` (fallback
   `photo-<n>.jpg`) instead of the constant `photo.jpg` — an agent reading
   `~/.termio/uploads/` benefits from names, and multi-select makes the
   constant name embarrassing.
4. **Multi-select files.** `allowsMultipleSelection = true` on the document
   picker; keep `asCopy: true` — it sidesteps the entire security-scope /
   bookmark / NSMetadataQuery machinery Telegram maintains for `.open`. We
   copy the bytes to the Mac anyway; in-place access buys us nothing.
5. **Upfront size validation** (Telegram pattern, already half-present): check
   the 8 MB cap per file *before* reading/encoding, and for multi-uploads show
   progress as a count in the attach slot ("2/5") instead of the bare spinner.
6. **Busy ≠ blocked.** Keep uploads non-modal (spinner in the attach slot, the
   composer stays editable) — matches Telegram's validate-then-fire model; no
   progress HUD.

Explicitly validated by the study, no change needed:

- **PHPicker over a custom grid.** Out-of-process, zero photo permission,
  `.limited` access is a non-problem. Telegram's Manage-banner machinery is
  the cost of owning the grid; we don't pay it.
- **Draft-as-caption.** Telegram's shared caption field across tabs is
  conceptually our draft + inserted paths. Nothing to build.

## v1.2: the attachment sheet (SHIPPED 2026-07-04)

User verdict on v1.1's bare `UIAlertController`: not good enough — "no image
preview, and the popup just hugs the bottom edge". So the deferred half-sheet
got built, in its cheap form (`AttachmentSheetViewController.swift`):

- `UISheetPresentationController` with `.medium()/.large()` detents + grabber
  — system physics, zero hand-rolled pan/snap code.
- Anatomy faithful to Telegram's gallery tab (user pushed back on a first cut
  that used a top action bar): circled ✕ + centered "Recents ⌄" header
  (tapping it opens the full system picker — Telegram opens its album list
  there), an edge-to-edge 3-column PHAsset recents grid (fetch limit 120,
  `PHCachingImageManager` thumbnails) whose FIRST CELL is a dark camera tile
  (tap → full camera; the live AVCaptureSession feed stays deferred), a
  selection ring on every photo that fills blue with the ordinal when picked
  (cap 10), and a chrome-material bottom tab bar (Gallery active · File) that
  swaps to a full-width blue `Add n` button once anything is selected —
  Telegram's tabs-to-sendbar swap, distilled.
- This DOES cost the photo permission PHPicker avoided
  (`NSPhotoLibraryUsageDescription`); denied/limited degrades to a hint label
  and the three buttons — the Photos button (PHPicker) remains the
  no-permission path. `.limited` shows just the granted subset.
- Export goes through `PHImageManager.requestImage` (2048pt aspect-fit,
  network-allowed for iCloud originals) into the same JPEG + queue path;
  original filenames survive via `PHAssetResource.originalFilename`.

XCUITest notes: the sheet grid is in-process (id `attach.grid`), so element
queries are safe again — only PHPicker's remote tree needs the
coordinate-tap workaround. Each `xcodebuild test` run re-prompts photo
permission; XCTest's implicit interruption monitor answers it with DENY and
that sticks in TCC, so the smoke test resets via
`simctl privacy reset photos` and answers the alert explicitly through the
springboard proxy ("Allow Full Access").

## Motion & type language (from the 2026-07-04 Telegram animation study)

Constants transplanted from Telegram-iOS source (Display /
ContainedViewLayoutTransition, CheckNode, AttachmentPanel,
AnimatedCountLabelNode) — use these before inventing new ones:

- **Durations**: 0.2s button state, 0.25s panel/bar swaps (slide + fade, no
  hard cuts), 0.45s sheet snaps. Their spring: damping 124 / stiffness 900 /
  mass 5 (≈0.92 damping ratio).
- **Selection bounce** (CheckNode): select = 1.0→0.9 (0.08s) → 1.1 (0.13s) →
  1.0 (0.10s); deselect = 0.9-dip and return. Implemented on the photo ring.
- **Button press** = opacity only: 0.4 instantly on touch-down, ease back
  0.2s on release. No scaling. Implemented on the camera tile.
- **Haptics are SPARSE**: Telegram fires none on photo selection — only
  `.error` on the selection-limit breach (implemented) and impact on
  reorder/destructive. Don't sprinkle selection haptics.
- **Counters**: SF Rounded + tabular digits everywhere a number lives
  (`UIFont.roundedCounter` in GlassControls.swift) — ring badges, Add n,
  upload n/m. Tab labels 10pt medium; nav/header titles 17pt semibold.
- Composer send button springs in on the empty⇄draft transition only
  (damping 0.6, scale 0.5→1), the iMessage/Telegram appearance, not a blink
  per keystroke; the attach slot crossfades busy⇄idle.

Control dimensions, measured from their source (AttachmentPanel /
MediaPickerScreen / SolidRoundedButtonNode / MediaPickerGridItem) and
adopted in the sheet:

| control | Telegram | ours |
| --- | --- | --- |
| Sheet ✕ circle | 44pt, 16pt side inset | 44pt / 16pt ✓ |
| Nav row in sheet | 44pt | header row 44pt (grid top 64) ✓ |
| Tab panel | 62pt tall, 30pt icons, 20pt side inset | 66pt bar, 24pt SF symbols, 20pt ✓ |
| Tab label | 10pt medium | ✓ |
| Full-width action button | 48pt tall, r24, 17pt title | 48pt capsule, 17pt rounded semibold ✓ |
| Selection circle | 29pt, 3pt corner inset, ordinal 16/15pt | 29pt / 3pt / 15pt ✓ |
| Caption-bar send circle | 34pt | composer (+) is 34pt ✓ |

## Deferred (documented so we don't re-litigate)
- **Live camera tile** — see above.
- **Recent-files list** — needs upload history on the Mac side first.
- **Background/resumable upload, >8 MB files** — raise the cap only when a
  real file that size shows up in practice; chunking over the WS is the next
  step, not multipart HTTP.

## Not built yet (input, ranked)

1. Semantic approval cards — host parses the agent's prompt options, streams
   them over the wire protocol; option-labeled buttons, not raw keys.
2. Stop button ≡ Esc while status = working (send button morphs; ChatGPT
   pattern).
3. Chat-lens view over the transcript JSONL (Moshi Chat Mode equivalent).
4. Voice hold-to-talk.
