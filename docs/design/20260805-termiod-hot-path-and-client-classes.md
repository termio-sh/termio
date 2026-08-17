---
title: Hot path, attach join point, and client classes
status: draft
type: design
created: 2026-08-05
updated: 2026-08-16
related:
  - 20260730-termiod-session-protocol.md
  - 20260805-termiod-device-architecture.md
  - 20260731-termiod-vt-sidecar-spike.md
---

# Design: Hot path, attach join point, and client classes

> A review of the Grok refinements against the shipped POC. The architecture is
> settled; what is missing is three *unwritten invariants* the code currently
> gets right by accident, and one prologue the client invents for itself.

**Evidence policy** (inherited from
[termiod-session-protocol.md](20260730-termiod-session-protocol.md)): Superlogical
statements are labeled **Announced** (Mitchell's ~10:40 architecture video,
his replies, superlogical.com), **Inferred**, or **Unknown**. No wire spec is
published; nothing here guesses at one. Positioning is settled in
`CLAUDE.md` and is not re-argued.

---

## A. Executive recommendation

Of the ten Grok refinements: **four accept as written, four modify, two reject.**
None of them changes the architecture, because the architecture is right and
partly shipped. The value in this round is elsewhere — three things are load
bearing, undocumented, and currently correct only because of implementation
details nobody wrote down:

1. **The attach join point has no spec.** Grok's #1 asks for "attach without
   pausing the PTY". That is already true: `begin_snapshot_barrier`
   (`termiod/src/session.rs`) never touches the PTY read loop — it flips the
   *attaching client* to `SnapshotPending`, buffers that client's bytes, and
   lets everyone else keep flowing. Correctness rests entirely on the sidecar
   command channel being a **lossless FIFO shared by `Write` and `Snapshot`**:
   the snapshot boundary is "after every `Write` enqueued before this
   `Snapshot`", and the per-client buffer starts at the same instant. **The FIFO
   *is* the sequence number.** Write that down as a normative invariant with a
   regression test (§E, D1); do **not** put a `seq` on the wire (§C.2).

2. **The snapshot prologue is invented by the client.** `render_snapshot`
   (`termiod/src/client.rs:693`) emits `ESC[2J ESC[H` before the host's VT
   payload. That prologue is a client-local guess: `2J` does not reset the
   scrolling region, alt-screen, DECAWM, charsets, or pending SGR. Two clients
   will diverge on reattach-over-dirty-screen, which breaks the
   synchronized-state-machine guarantee §C.5 spends a paragraph defending.
   **The prologue belongs to the host, inside the `S` payload** (D2).

3. **The anti-100× invariant has a second shadow cost.** Risk #10 bounded the
   *per-client* backlog (4 MiB, `CLIENT_BACKLOG_CAP`) — shipped. But the
   **sidecar command queue is unbounded** (`std_mpsc::channel::<SidecarCommand>`,
   `session.rs:1064`). Refusing to block byte delivery on the VT parse means a
   slow parse now accumulates *the whole PTY output* in a queue instead. It is
   the same bug as risk #10, one hop upstream, and it is not written anywhere
   (D4). **Closed 2026-08-16** by `SidecarQueue`: the channel stays unbounded and
   fire-and-forget, and a byte budget beside it decides when to stop feeding the
   VT. The degrade is `vt_stale`, never a dropped byte — in either direction.

Everything else in this doc is naming, policy wording, and PR sequencing.

---

## B. Keep — settled, do not reopen

| Kept | Where it lives | Why it is closed |
| --- | --- | --- |
| **Anti-100× invariant** — byte delivery never blocks on host VT parse | §A, CLAUDE.md #1 | Measured 4.4–6.0× tmux; independently converged on by Superlogical (**Announced**: *"the teeing happens ahead of the server"*) |
| **`S` → `ready` → `H`/`D` attach shape** | §C.6, shipped | Same shape Superlogical describes (**Announced**); already implemented including newest-first `H` |
| **Presentation boundary** — host describes state, client's libghostty decides looks | device doc §4 | Learned by shipping the violation; `S` v2 is formatter VT with `palette:false` |
| **SSH-only trust plane; never embed SSH or crypto** | CLAUDE.md #3, §H #8 | A trust choice, not a performance one. Their WebSocket-over-HTTP is a browser-first choice (**Announced**, *"not at all guaranteed to be final"*) — different axis, not a rebuttal |
| **Single writer, many readers; observers never claim** | CLAUDE.md #6, §C.5 | Newest-claim-wins is deterministic (`recompute_writer`, max `seq`) and observable |
| **No nested window manager; layout is a client concern** | CLAUDE.md #5, §H #7 | This is what Grok #4 is reaching for, and it is already law |
| **Device identity = `host_id`, routes are plural** | device doc §2 | Alias-keyed state forks the day the user changes networks |
| **Resource cursor + bounded ring + `gap:true`** | §C.10, `resource.rs` | Generalised reconnect; the terminal plane should adopt the *mechanism*, not rename itself after it |
| **Agent workstream events on the wire** | §C.4, device doc §7 | One of the three rows in device doc §7 that is actually defensible. Untouched by this round |

---

## C. Rejected

### C.1 The `Block` / `Session` rename (Grok #4)

Grok proposes `Block` = 1:1 PTY, `Session` = roster of blocks + meta, `Layout` =
client-only. The third clause is already law (§H #7). The first two cost more
than they buy:

- **`session_id` is on the wire, on disk, and in the CLI.** Renaming touches
  `protocol.rs` (`Attach`/`Attached`/`Exited`/every `Event`), `tombstone.rs`
  (roster + graveyard files), `resource.rs` scoping, `devices.json`,
  `Session.deviceID` on the Swift side, `termio sessions` verbs, and
  `20260801-session-deep-link.md`'s URL scheme. That is a `proto:2` break for a synonym.
- **"Block" is already taken, twice.** Superlogical's site uses *terminal
  blocks* for prompt/output units (**Announced**), and Warp popularised the same
  meaning. Adopting it for "one PTY" guarantees a permanent explanation tax in
  every conversation with a user who has seen either product.
- **"Session = roster of blocks" is a noun we already have, twice.** A roster
  scoped to a machine is the **Device**; a roster scoped to a directory root is
  the **Workspace**. Adding a third container is how a host acquires a window
  manager one field at a time.

**Rejected.** The underlying rule — layout never crosses the wire — is kept and
restated in §D.1.

### C.2 Per-`D`-frame sequence numbers on the wire

Grok #1's mechanism ("`S@seq`, then `D` where `seq > at_seq`") needs every `D`
frame to carry a cursor, or the client cannot do the filtering the rule
describes. That is 8 bytes and a serialise step per chunk on the one path the
entire design exists to keep free — and it buys nothing, because **the host
already does the filtering** by buffering the attaching client. A cursor the
client cannot act on is a cursor that does not need to be sent.

**Rejected as a wire field. Accepted as an internal invariant** (D1). If a
future QUIC binding needs a resume cursor (§D.1 `attach {target, last_seen}`),
it is a *stream-scoped* value negotiated at attach, not a per-frame tax.

### C.3 Sticky writer as a policy (Grok #8)

"Agent sessions keep their writer" sounds protective and introduces three races
the current rule does not have:

- **Zombie owner.** A half-open TCP connection (phone through a NAT that stopped
  answering) holds the token. `remove_dead` only fires when a send *fails*,
  which for a wedged socket can be minutes. The Mac sitting in front of the user
  cannot type into their own agent, and no event explains why.
- **Recovery is undefined.** Sticky implies release; release implies a lease;
  a lease implies a TTL, a clock, and a steal verb. That is three new protocol
  concepts to solve a problem no bug report has yet described.
- **It fights failover.** `recompute_writer` promotes by highest attach `seq`;
  sticky needs a second ordering that survives disconnect, so two orderings now
  disagree after a crash.

**Rejected as a default policy. Accepted as an explicit, stateless modifier**
(D5): `attach {mode:"interact", claim:"polite"}` fails with `busy` when a live
writer exists, instead of silently demoting them. No lease, no TTL, no clock —
the caller decides, and the default stays newest-claim-wins.

### C.4 Compat sink in v1 (part of Grok #2)

A libghostty in the middle rendering for a non-libghostty terminal (**Announced**
as Superlogical's *compat mode*) is a coherent third client class and a direct
violation of the presentation boundary (device doc §4): the host must resolve
colour for a client that cannot. It also reintroduces the tmux tax *for that
client*, which is tolerable only because it is per-client and off the shared
tee — a nuance worth exactly zero engineering hours until a user asks.

**Deferred, not refuted.** Named in §D.3 so it has a home; out of scope for v1.

### C.5 Reusing the word "tombstone" for terminal overflow (part of Grok #5)

`termiod/src/tombstone.rs` already owns that word: *what a session was when it
died, and why* — a durability record, written to disk, read by the next daemon,
shown in the UI. Superlogical's tombstone (**Announced**) is an overflow marker
meaning "resync, your baseline is gone", which in Termio is spelled `gap`.
**Two different words for two different things is correct; unifying the
vocabulary here would collide a shipped concept with a wire signal.**

---

## D. Proposed model

### D.1 Nouns (unchanged; stated once so the next round does not relitigate)

```
Device (host_id) ──< Workspace ──< Session ──? Workstream
   │                     │             └──< Attachment >── Client
   └──< Route            └──< Resource (fs: …, cursor + ring + gap)
```

One rule, restated because it is what Grok #4 was correctly reaching for:
**anything that describes arrangement — panes, tabs, splits, focus, viewport —
is client state and never crosses the wire.** Superlogical reaches the same
place from the other side (**Announced**: native splits, *one connection per
PTY*); a split there is N attachments, not a host-side layout tree.

### D.2 Attach and resync — the join point, normatively

**Invariant (JOIN).** For each attaching client there exists exactly one
boundary B in the session's output byte stream such that: the `S` payload
reflects the terminal state after applying every byte before B, and the client
receives every byte from B onward, in order, exactly once. B is established by
enqueueing `Snapshot` on the sidecar FIFO in the same critical section that
flips the client to `SnapshotPending`. **The PTY is never paused, and no other
client's delivery is affected.**

Three corollaries, all of which are load-bearing and none of which is currently
written down:

1. **The sidecar channel must be lossless and ordered with respect to
   `Write`.** If bytes destined for the VT can ever be dropped or reordered
   (the obvious fix for D4's unbounded queue), B stops existing and `S` silently
   describes a screen that never occurred. The permitted degrade is therefore
   *never* "drop bytes to the VT" — it is "mark the VT stale and refuse
   snapshots" (D4).
2. **Snapshot failure has a defined fallback**, already implemented
   (`fallback_snapshot` → ring replay) and unspecified in the protocol doc.
   Ring replay is a *lossy* fallback: `RING_CAP` is 128 KiB, so a client
   resynced from the ring alone can land mid-escape. It must be reported, not
   silent.
3. **Resize is the same barrier, not a second mechanism.** Shipped:
   `SessionMsg::Resize` surfaces `TIOCSWINSZ` failure via `reject_resize` before
   mutating stored dims, then `Resize` + `Snapshot` land adjacently on the FIFO.
   Risks #10 and #11 in §F are stale — both are closed in the POC; their
   residuals are D4 and this corollary.

**The snapshot prologue is the host's.** `S` must be self-contained: applying it
to a client screen in *any* prior state — alt-screen active, scrolling region
set, charset shifted, SGR pending — must produce the same result as applying it
to a fresh terminal. Today the reference client prepends `ESC[2J ESC[H`, which
does none of that, and the Mac and iOS clients are free to prepend something
else. Where exactly the prologue comes from (a libghostty formatter option, or
termiod prepending a scoped reset) is §F.1.

### D.3 Client classes (Grok #2, accepted as capability profiles)

Not new nouns — three profiles over caps that already exist. A class is what a
client *negotiates*, and it is renegotiated per attach, not per client identity.

| Class | Negotiates | Receives | Owns | Loses | Status |
| --- | --- | --- | --- | --- | --- |
| **Replica** (default) | `snapshot`, `scrollback` | `S` → `ready` → `H`* → raw `D` | Its own libghostty; full native scrollback, selection, reflow | Nothing | Shipped |
| **Mirror** | `grid_diff` (requires `snapshot`) | `S` → `ready` → `G`, no downstream `D` | Nothing; the host's grid is the truth | Native scrollback and selection beyond the rows the host chose to send | Shipped, unrecommended (§D.4) |
| **Compat sink** | — | Host-rendered output for a non-libghostty terminal | Nothing | The presentation boundary | **Not built, deferred** (§C.4) |

The Mac and iOS clients are both **Replicas**. Mirror is a *state a Replica
enters under pressure*, not a device category — which is the substance of
Grok #3.

**The web client is a Replica too — this is the load-bearing finding.** The
obvious reading is that a browser has no libghostty and must therefore be a
Mirror, which would make Mirror a permanent client category and force §D.4's
rule to be loosened. That reading is wrong: **`libghostty-vt` compiles and runs
as a standalone Wasm module, no emscripten** — Mitchell's own work, ~400 KB, and
already load-bearing in several shipped projects (`@wterm/ghostty` from
vercel-labs, `ghostty-web`, `browstty`, `onyx-shell`, `vscode-bootty`,
`RemoteTTYs`). So the browser runs the same VT as the Mac, over the same raw `D`
bytes, and the class table needs no fourth row:

```
Mac / iOS :  raw D ──→ libghostty (native) ──→ Metal
Web       :  raw D ──→ libghostty (Wasm)   ──→ Canvas
                ↑ same bytes, same VT, same protocol
```

Three consequences worth stating so they are not re-derived:

1. **Non-negotiable #4 extends to the browser unchanged.** No second protocol
   for the web, exactly as there is none for the phone.
2. **The transport question is downstream of this one.** A Replica consumes
   reliable ordered bytes, so WSS suffices and WebTransport's datagrams buy
   nothing — the protocol doc's §D.1 refusal survives *because* of this choice,
   not in spite of the web client existing. Decide the VT first; the transport
   follows.
3. **The cost moves to rendering.** The VT is free and MIT; a browser renderer
   (glyphs, ligatures, cursor, selection, scroll) is not. Borrow one first —
   the same discipline that keeps us on system OpenSSH — and treat an in-house
   renderer as a later quality investment, not an entry ticket.

**Selection check before adopting any of those packages:** they resolve cells to
RGB in JS, and `@wterm/ghostty` documents its cell state as *pre-resolved 24-bit
RGB*. Confirm the palette can be injected from termio's theme so resolution
happens against the *viewer's* colours. If it cannot, that is `vt/src/lib.rs`'s
`palette: false` lesson recurring in a third place, and it disqualifies the
package.

### D.4 `G` policy — a pressure valve, never a transport choice

**Normative: a client MUST NOT select `grid_diff` on the basis of transport
class.** "Remote ⇒ prefer `G`" is wrong twice over:

1. **Capability.** A Mirror has no real scrollback and cannot select across
   history — it holds only the rows the host chose to send. This is the better
   argument and it survives any encoding improvement (**Announced**, Mitchell on
   why he rejects screen diffs: *"less performance and more making it very
   difficult to allow native scrollback, selection"*). It is also why compressing
   the wire cell does not promote `G`.
2. **Bandwidth.** Measured 2026-08-05 over SSH to `ukvps`, identical 300-line
   scroll: raw `D` 50,423 B / 16 frames against `G` 435,573 B / 18 frames —
   **8.6× worse**. Scrolling dirties every row, so dirty-row filtering filters
   nothing, and a 16-byte wire cell against ~1 byte of source text is a ~16×
   inflation. Secondary evidence; cite it second.

The two things `G` does buy: a **bound** (cost capped at frame-rate × screen no
matter what the PTY emits, so a `yes` flood cannot melt a metered link) and
**catch-up** (a client behind the window skips intermediate states instead of
replaying them). Legal selection signals: sustained backlog pressure, measured
loss, an explicit user "bounded bandwidth" mode, or a forced resync that would
otherwise drop the client. Illegal: "this connection is remote", "this client is
a phone".

**Precise form of the rule: selection is driven by capability, never by
transport.** A client that genuinely cannot run libghostty has no Replica mode
to degrade *from* and is a Mirror by capability — that is a fact about the
client, not a preference about the link. The distinction matters because the
web client looked like the case that would force this rule open, and does not
(§D.3): browsers can run the VT, so they are Replicas, and the rule needs no
loosening for them. Today no shipping client is a Mirror by capability; the only
candidate is a legacy terminal via the compat sink (§F.5).

Superlogical's synced-viewport is the mirror image of the same judgement
(**Announced**): shared scrolling ships as *additional opt-in frames*, never as
the transport.

**Known defect: the packed-cell path still ships resolved RGB.** The device doc
§4 states the presentation boundary absolutely — "Host must not send: resolved
RGB" — and the `S` v2 VT payload now honours it (`palette: false`). The packed
cell encoding that seeds and updates a Mirror does not: snapshot payload v1 is
`codepoint:u32be, foreground RGB, background RGB, attributes:u16be`
(`protocol.rs`), so a Mirror is coloured by the *host's* palette and cannot
apply the viewer's theme. The rule and the wire disagree, and the doc should not
pretend otherwise.

Priority is low precisely because §D.3 removed the pressure — no client is a
Mirror by capability, so this only affects a Replica temporarily under pressure,
where a wrong palette for a few seconds is the least of its problems. The fix
when it comes is a tagged colour — `{0: default} | {1: palette index u8} |
{2: rgb u24}` — which restores the boundary and shrinks the 16-byte cell at the
same time, taking a bite out of the measured 8.6× as a side effect. Doing it
before any client depends on Mirror keeps it additive; doing it after is a wire
break.

### D.5 Writer and resize

- **Writer: newest claim wins, observable.** Unchanged. Plus `claim:"polite"`
  (D5) so a client can ask for the token without stealing it, and `busy` so it
  learns why it did not get it.
- **Resize: the writer owns the one PTY size; a resize is a barrier.** Shipped
  as described in D.2 corollary 3.
- **Observers letterbox at authoritative dims** (Grok #7). `Attached` already
  carries `rows`/`cols` (`protocol.rs:332`, with `serde(default)` for v0 skew) —
  the §C.5 note calling this a POC gap is stale. The **residual gap is client
  conformance**, not the wire: the reference client still ignores `Resized`, and
  a client that parses at its own window size diverges on wrap. That is a
  conformance-suite item (PR 7), not a protocol change.

---

## E. Protocol deltas vs `20260730-termiod-session-protocol.md`

| # | Section | Delta | Kind |
| --- | --- | --- | --- |
| **D1** | §C.5 | Add invariant **JOIN** (§D.2) with its three corollaries, replacing the prose "resync: … one `S` snapshot". Explicitly: the PTY is never paused; the sidecar FIFO is the ordering authority; no wire `seq` | **Landed 2026-08-12** |
| **D2** | §C.6 | The `S` payload **includes its own prologue** and must be state-independent on apply. Clients MUST NOT prepend their own reset. Frame order after `attached` is fixed: `S` → `ready` → `H`* interleavable with `D` | **Landed 2026-08-13** (prologue in `format_vt`; the reference client and the Mac client apply raw) |
| **D3** | §C.6 | Replace the stage table's "who parses VT" column with the **client-class profiles** of §D.3. Stages describe the host's capability; classes describe what a client negotiates | Doc restructure |
| **D4** | §F #10 | Mark risk #10 **closed** (4 MiB `CLIENT_BACKLOG_CAP`, shipped) and both residuals closed too: (a) the degrade is **forced resync** — `S` + `ready` + `E{ev:"resynced", reason}`, dropping only on a second strike; (b) the sidecar command queue carries a 16 MiB budget whose only legal degrade is `E{ev:"vt_stale", reason}` (refuse snapshots, fall back to ring replay), never dropping bytes to the VT and never dropping a byte owed to a client | **Landed 2026-08-16** |
| **D5** | §C.4, §C.5 | `attach` gains `claim:"newest"|"polite"` (default `newest`, i.e. today's behaviour). `polite` returns `error{code:"busy"}` when a live writer exists. Supersedes the sticky-writer idea | Additive control field |
| **D6** | §C.6 | Normative: `grid_diff` MUST NOT be selected by transport class; legal selection signals enumerated (§D.4). Lead with the capability argument, cite the 8.6× second | Wording, normative |
| **D7** | §C.10 + §C.6 | State the shared mechanism once — *durable object + monotonic cursor + bounded ring + explicit gap signal* — and keep the two words distinct: **`gap`** = your baseline is unusable, resync; **tombstone** = this session is dead and here is why (`tombstone.rs`). The terminal plane adopts `gap`, not the word "tombstone" | Vocabulary |
| **D8** | §C.5 | Delete the stale "POC gap: `Attached` omits `rows`/`cols`" note; move the requirement into a **client conformance list** (parse at authoritative dims; honour `Resized`; honour `WriterChanged`) | Doc correction |
| **D9** | §F #11 | Mark closed — `reject_resize` surfaces `TIOCSWINSZ` failure before mutating dims, and the barrier is implemented | Doc correction |
| **D10** | §C.6 | Specify what a **forced resync owes**: `S` restores the screen, but `H` scrollback is staged at attach only, so a resynced client silently loses history. Either restage `H` on resync or say plainly that it is lost | Open semantics (see §F.4) |

Not changed by this round: framing, `hello`/caps, the error vocabulary, the
transport table, §D.1's QUIC binding, §H's rejection list.

---

## F. Open questions for a human

1. ~~**What is the snapshot prologue, exactly?**~~ **Answered 2026-08-13 by the
   test.** The formatter has no self-contained mode — it emits only state the
   host *has*, never the negation, and paints relative to the cursor it finds —
   so termiod prepends the reset. `DECSTR` is the right lead (it covers G2/G3,
   DECSCA, the saved cursor, keypad, and touches nothing the client owns) but is
   not sufficient: measured against libghostty, SGR, charsets, origin mode and
   autowrap all survive it, so each is re-asserted explicitly, then erase-and-home.
   `RIS` stays rejected — palette, title and scrollback are the client's.
   One consequence worth stating: the prologue leaves the alternate screen
   unconditionally, so the payload owes the re-entry, which the formatter already
   emits and the test now pins in both directions.
2. ~~**What should a wedged client cost a healthy one?**~~ **Answered 2026-08-16
   by PR 5: resync once, then drop.** The pathological case is bounded by never
   forgiving a strike — the resync zeroes what the client owes, so a second
   overflow proves it cannot keep up even from a clean start. What the resync
   discards is the point of it: retiring the queued megabytes is what lets a
   phone coming out of a tunnel rejoin at a screen instead of replaying a flood.
   The residual is D10, unchanged: the resynced client's scrollback is a hole.
3. **Do we speak Superlogical's protocol if it ships as open?** Described as
   *"predominantly part of libghostty"* and an *open protocol* (**Announced**).
   If both ends are libghostty anyway, a shared wire is plausible — and would
   retire most of §C. This is an ecosystem bet with a deadline attached to
   someone else's release, not an engineering preference.
4. **Does a resynced client get its scrollback back?** `H` is attach-only today.
   After a backlog resync the screen is right and the history is a hole the user
   cannot see. Restaging is bounded work (1 MiB cap already exists); saying "lost"
   is honest but surprising.
5. **Are legacy terminals a supported client at all?** Compat sink is the only
   way `ssh box && termiod attach` works in a non-libghostty terminal. Building
   it means the host renders — a deliberate, scoped exception to the presentation
   boundary. Not building it means the CLI is a debugging tool, not a product
   surface.
6. **Can a stale VT ever recover?** Today it cannot: once the sidecar budget
   bites, that session answers snapshots from the ring for the rest of its life,
   which for an agent session is days. The tempting fix — reset the VT and
   re-seed it from the 128 KiB ring once the queue drains — is refused here
   because it would make `S` silently approximate: the payload would claim a
   boundary it does not describe, which is exactly the failure invariant JOIN
   exists to prevent. An honest recovery needs a *marked* baseline (`gap:true`
   on the snapshot, §D7's vocabulary), not a quiet reseed.

7. **Should `polite` be the default for the Mac app?** Newest-claim-wins means
   glancing at a session on the phone silently demotes the Mac. That is correct
   for a single user with two devices *if* the demotion is visible; it is wrong
   the moment sharing exists (§F #3 of the protocol doc).

---

## G. Implementation PR order

Each step is small, independently shippable, and ordered so the spec lands
before the behaviour it constrains. PRs 1–3 add no features; they make the
current correctness *provable*.

| # | PR | Contents | Depends on |
| --- | --- | --- | --- |
| 1 | **Spec: join point and vocabulary** | Protocol doc D1, D7, D8, D9. No code | — |
| 2 | **Test: attach during a flood** — **landed 2026-08-12** (`termiod/tests/join_invariant.rs`) | A second client attaches mid-flood of a monotonic counter; the `S` payload is replayed through a VT and the sequence must run unbroken from the last complete line on that screen into the first line of the buffered stream, with the early client's delivery untouched. Proven to bite by dropping one buffered chunk in `finish_snapshot`: "the snapshot ends at 55861 but the stream resumes at 55868". **The flood must be unbroken** — a paced one lets the attach land in a gap, where an empty buffer hides a broken barrier and the test passes vacuously | 1 |
| 3 | **Test: snapshot applied to a dirty screen** — **landed 2026-08-13** (`termiod/tests/snapshot_prologue.rs`) | One case per state a client can be carrying when `S` arrives; each applies the payload after that state and diffs against a fresh terminal. It failed on five of nine before PR 4 — stale content showing through, alt-screen kept, origin mode re-basing the cursor addressing, a shifted charset turning the text into line-drawing glyphs, a pending SGR colouring the first row. Insert mode, autowrap-off and a scrolling region passed only because the fixture's content was short enough not to expose them; reverse video is a render-time flip the cell snapshot cannot see at all | 1 |
| 4 | **Host-owned snapshot prologue** — **landed 2026-08-13** | D2. `SNAPSHOT_PROLOGUE` prepended in `VtTerminal::format_vt`; `render_snapshot` and `TermiodSnapshot.render` stop synthesising a prelude and apply raw. Old clients that still prepend a reset stay correct (idempotent). The Mac's prelude was asymmetric in the same way the formatter is — it entered the alternate screen but never left it, so a primary-screen snapshot repainted onto the alt buffer | 3 |
| 5 | **Backlog degrade: resync before drop** — **landed 2026-08-16** | D4(a). `force_resync` retires the client's queued payloads by bumping a backlog *epoch* — the socket writer drops anything reserved under an older one — then takes a fresh snapshot barrier for that client alone and follows `S`/`ready` with `E{ev:"resynced"}`. Second strike drops. D10 is **deferred**: `H` is still attach-only, so a resynced client's scrollback is a hole it cannot see | 2 |
| 6 | **Sidecar queue budget** — **landed 2026-08-16** | D4(b). `SidecarQueue` charges every `Write` and credits it back when the VT has parsed it. At 16 MiB the session stops feeding the VT, marks it stale, emits `E{ev:"vt_stale"}`, disconnects Mirrors, and fails every pending and future snapshot into `fallback_snapshot`. `fan_out` is untouched, so no client loses a byte. **Stale is sticky** — see §F #7 | 2 |
| 7 | **Client conformance suite** | D3, D8. Replica and Mirror profiles; skew matrix; assert clients parse at authoritative dims and honour `Resized`/`WriterChanged` | 1 |
| 8 | **`claim:"polite"`** | D5. Additive `attach` field, `busy` error, Mac wiring (attach as observer with a visible badge instead of stealing) | 7 |
| 9 | **`G` policy wording + selection signals** | D6. Wording, plus removing any client-side "remote ⇒ `grid_diff`" heuristic if one has crept in | 7 |
| 10 | **(Conditional) wire-cell compression** | RLE spans, style separated from text. **Only if a Mirror client actually ships** — it does not promote `G`, it only makes the pressure valve cheaper | 9 |

---

## H. Consensus table — Grok refinement → Claude position

| # | Grok refinement | Position | Why (one line) |
| --- | --- | --- | --- |
| 1 | Attach without pausing the PTY: `S@seq`, then `D` where `seq > at_seq` | **Modify** | Already true and stronger in the POC (per-client buffering, FIFO-ordered snapshot); make it invariant JOIN + a test, not a wire `seq` the client cannot act on |
| 2 | Client classes: Replica / Mirror / Compat sink | **Accept, modified** | Good names — bind them to existing caps as *profiles*, not nouns; Compat sink is deferred because it breaks the presentation boundary |
| 3 | Demote `G`: never the remote/bad-net default | **Accept, strengthened** | Right conclusion, better reason available: a Mirror loses native scrollback and selection, which no encoding fixes; the 8.6× is corroboration, not the argument |
| 4 | Nouns: Block = PTY, Session = roster, Layout = client-only | **Reject (rename); accept (layout)** | `proto:2` break plus a name Warp and Superlogical already spent; the roster nouns exist as Device and Workspace, and layout-is-client-only is already law |
| 5 | Unify tombstone / gap / cursor across terminal + resource planes | **Modify** | Unify the *mechanism* (durable object + cursor + bounded ring + explicit gap); keep the words apart — `tombstone.rs` already means "this session died and here is why" |
| 6 | Per-client byte budget → tombstone (risk #10) | **Modify** | Budget shipped (4 MiB); change the degrade from *drop* to *forced resync*, and add the missing second budget on the unbounded sidecar queue |
| 7 | Wire `rows`/`cols` on `attached`; observers letterbox | **Accept — already shipped** | `protocol.rs:332`; the §C.5 "POC gap" note is stale. Residual is client conformance, not the wire |
| 8 | Optional sticky writer for agent sessions | **Reject (as policy); accept (as claim mode)** | Sticky needs a lease, a TTL, and a steal verb to survive a zombie owner; `claim:"polite"` gets the intent statelessly |
| 9 | Keep SSH trust default; do not copy WebSocket as product default | **Accept, no change** | CLAUDE.md #3. Theirs is a browser-first choice, explicitly not final (**Announced**); different axis |
| 10 | Agent workstream events stay the first-class differentiator | **Accept, no change** | One of the three rows in device doc §7 that the architecture convergence does not touch |

**Net:** 4 accept, 4 modify, 2 reject — and three findings neither side raised
(the unspecified snapshot prologue, the unbounded sidecar queue, and the
scrollback hole after a forced resync), which are what this round should
actually ship.
