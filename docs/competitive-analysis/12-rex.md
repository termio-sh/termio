---
title: "Competitive analysis: Rex (Superlogical)"
status: draft
type: research
created: 2026-10-30
updated: 2026-10-30
---

# Competitive analysis: Rex (Superlogical)

> What Rex's shipped artifacts and live server show about how it pairs, streams, renders and sizes terminals, and what that means for termio.

Rex Beta 0.1.0 on macOS, and the iOS beta 0.1.0 (1542), read in October 2026.

## Evidence and limits

The iOS binary was not analyzed. `devicectl` copies an app's data container but not its bundle, the debugger is refused, and TestFlight lists the build as iOS-only. Nothing below comes from iOS client code.

| Label | Source |
| --- | --- |
| Docs | API text embedded in the server binary, `rex api describe` |
| Live | The running server, with an iPhone attached |
| Symbols | Go symbols in the server, Swift field metadata and strings in the Mac client |
| Container | The iOS app's data container |
| Inferred | A conclusion none of the above states directly |

## Shape

Rex is a Go server (`libghostty`, `tsnet`, `coder/websocket`) and Swift clients on libghostty-vt with their own Metal renderer (Symbols). The server owns sessions, windows, splits, floating layers, zoom, focus, labels, block owners and terminal sizes. The client owns the visible session, the sidebar, font size, scroll position and text selection (Docs, Symbols).

## Pairing

There is no pairing step and no token.

- The server joins the tailnet as its own node and serves HTTPS on it (Docs, Live).
- The iPhone stores one record: a name and that node's URL (Container).
- The server identified the phone as `kind: tailscale`, with its login name and node (Live).
- With `allow_tailnet_members` false, only the Tailscale user who signed the device in gets through, checked on every call. Others receive 403 (Docs).

A remote machine runs its own Rex server. Rex has no SSH carrier (Docs).

## Transport

- One control WebSocket carries JSON method calls and events (Docs).
- One binary data WebSocket per block carries a Ghostty snapshot, then raw bytes (Docs).
- A resume sends a token and the exact count of bytes received, and the server continues from the next byte with no snapshot (Docs).
- A resize is an APC marker in the byte stream, so the client resizes its VT at that exact byte (Docs).
- Clients send only `key`, `paste`, `mouse`, `wheel` and `focus` events. The server encodes them and answers terminal queries (Docs, Symbols).

## Why it feels smooth

- The server does not encode a grid per frame. Bytes go to the client, which parses and draws them (Docs, Symbols).
- The Mac client shares its Metal device, pipelines and glyph store between views, keeps rows between frames, and tracks per-row generations (Symbols).
- The iPhone keeps a disk copy of the session layout, `RexSync/Snapshots/*.rexsnapshot`, and a Metal shader cache (Container). Drawing the layout before the network answers is Inferred.
- The network matters. The Rex host measured for this study had 16 ms RTT on a direct tailnet path, while termio's test hosts had about 141 ms. termio added about 0 ms per keystroke over plain SSH on the same host. Rex has no local echo (Symbols), so comparisons need one host.

## Terminal width

One client decides each block's size.

- While a block has an owner, its size and colors come from that client (Docs).
- Other clients' requests are stored in `desired` and not applied (Docs, Live).
- `own_block take` claims at once. `request` claims only an unowned block (Docs).
- When an owner leaves, the most recent claimant in line takes over, with any `take` ahead of every `request`. A reconnecting owner gets the block back unless the owner has changed since (Docs).

With the iPhone attached, the Mac owned all three blocks and the phone had requested no size (Live).

**Unknown:** how the phone shows a block wider than its screen, and whether typing there claims ownership. The one observation ended when the phone disconnected.

## What this means for termio

| Topic | Rex | termio | Judgement |
| --- | --- | --- | --- |
| Identity over Tailscale | Login alone | Pairing token as well | Worth a design note: it removes the token rows from Settings. It changes termiod's authentication. |
| Size | Explicit owner | Latest person who used it; leaving never resizes | Keep termio's rule. A phone that drops on every lock would hand ownership back and forth under Rex's. |
| Remote carrier | Tailnet only | SSH | Keep SSH. It reaches every Linux box with no setup. |
| Server upgrade | Ends every PTY | `execve` handoff keeps them | termio is ahead. |
| Launch | Cached layout on disk | Not studied here | Candidate for the iOS app, once measured. |
