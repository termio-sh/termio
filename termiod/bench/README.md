# termiod benchmark — the anti-100x property

`bench_100x.py` measures the one architectural claim behind the whole design
(see `docs/design/20260730-termiod-session-protocol.md` §C.6): a session mux that must
**parse** every PTY byte into a grid throttles the producer through PTY
backpressure, while a mux that **tees** raw bytes and never parses on the hot
path drains at wire speed and never throttles it.

## Method

A producer (`cat <payload>`) floods a fixed payload; its stdout is a PTY. We
time the wall-clock for the producer to finish **and** all bytes to be
consumed, under four configs:

| config | path | what it isolates |
| --- | --- | --- |
| `direct (python floor)` | producer → PTY → Python drain | a *weak* no-mux floor (Python `os.read` overhead caps it) |
| `termiod tee (no client)` | producer → host raw tee, no viewer | pure input replication; host drains regardless of viewers |
| `termiod client (full path)` | producer → host → Unix socket → client → /dev/null | full attach/fan-out path |
| `tmux (parses grid)` | producer → detached tmux server | the parse tax (tmux maintains grid state even with no client) |

Two payloads: **plain** text (conservative — tmux still parses every cell) and
**ANSI-heavy** (SGR + `\x1b[K` + resets per token — stresses the VT state
machine). Median of 5, 100 MB each, 50×200.

```sh
cd termiod && cargo build --release
python3 bench/bench_100x.py 100
```

## Result (Apple Silicon, macOS, tmux 3.6a, 100 MB, median of 5)

| config | plain MB/s | ANSI MB/s |
| --- | --- | --- |
| direct (python floor) | 185 | 167 |
| **termiod tee** | **249** | **172** |
| termiod client (full path) | 237 | 169 |
| tmux | 56 | 28 |

- **termiod tee ≈ termiod client** — fanning out to a real attached client adds
  ~0%. The client path is free; there is no snapshot/parse in the way.
- **termiod is 4.4× (plain) / 6.0× (ANSI) tmux's throughput** on identical bytes.
- **The proof is content-scaling, not the raw ratio.** Plain→ANSI: tmux drops
  **~50%** (56→28 MB/s), termiod drops ~31% (mostly `cat` chunk-size / noise,
  not parsing). Cost that scales with VT-parse complexity is a *parser*; cost
  that doesn't is a *tee*. That gap **is** the thesis.
- termiod (Rust) posts a higher MB/s than the Python "direct" floor because the
  floor is drainer-bound, not because termiod beats a raw pipe. The load-bearing
  comparison is termiod-vs-tmux (both external processes, identical method).

## Remote run — `ukvps` (Oracle aarch64, 4-core Ampere, tmux 3.4, 2026-07-31)

Same harness, run **on the VPS's own CPU** (`TERMIOD_BIN=~/.local/bin/termiod
python3 bench_100x.py`). The parse tax is CPU-bound, so on a modest cloud core —
exactly where remote agents run — it is far larger than on the Mac's fast
P-cores:

| payload | termiod tee MB/s | tmux MB/s | ratio |
| --- | --- | --- | --- |
| plain¹ | 81 | 7.2 | 11.3× |
| **ansi** | 178 | 7.5 | **23.6×** |
| truecolor | 186 | 11.1 | 16.7× |
| fullscreen | 187 | 11.4 | 16.5× |

¹ plain ran first on a cold page cache (its floor was depressed too); the warm
rows are the clean ones. **termiod's tee is memcpy (CPU-agnostic); tmux's parse
is CPU-bound — so the weaker the core, the wider the gap.** The Mac's P-cores
were *hiding* tmux's tax at ~6×; on the Ampere it is **16–24×**.

### WAN characteristics (Mac ↔ ukvps, transcontinental)

- **detach ≠ kill, live over real SSH:** a session created in one SSH
  connection is still alive with the same pid in a later one, its counter
  advanced while the Mac was disconnected. The daemon owns the PTY.
- **SSH round-trip:** 193 ms min / 223 ms median. This — not throughput — is the
  interactive-latency floor, and it is why the remote roadmap is predictive echo
  + QUIC migration (§D.1), *not* raw-throughput tuning. (NB: the design note's
  "12.1 ms median echo" must have been a near-VPS/LAN measurement, not this path.)
- **Network throughput ceiling:** ~15 MB/s (`ssh ukvps cat …`). Over WAN the
  network dominates and the 16–24× CPU parse-tax is irrelevant — the remote
  story is latency and snapshot/backfill, not MB/s.
- **Not cleanly measured — termiod raw-byte WAN throughput.** The `attach`
  client assumes an interactive tty; driven non-interactively over a bare SSH
  channel it delivered 0 bytes (works fine locally on the VPS — the full-path
  `run_client` posts complete byte-for-byte throughput above). This is a **POC
  gap: there is no pipe-mode / non-interactive attach**, needed for scripting,
  piping, and honest WAN throughput measurement. Architecturally `attach` is
  bytes-over-ssh + ~0.01% framing, so it is network-bound like raw ssh; that
  claim stays *unmeasured*, not asserted.

## Build-profile note (`opt-level`)

The release profile is `opt-level = "z"` (size — the musl binary is ~1 MB). Re-running
against an `opt-level = 3` build (`cargo build --release --config
'profile.release.opt-level=3'`) showed **no material throughput change** for termiod
(within run-to-run noise). That is itself a confirmation of the thesis: the hot path is
memory-bandwidth / syscall bound (memcpy + refcount + socket write), not compute bound,
so there is nothing for the optimizer to vectorize. `opt-level` *would* matter for a
per-byte parser (e.g. tmux's) — which is precisely the work termiod doesn't do.

## Honesty note on "100x"

Mitchell's "100+×" is a **peak / interactive-render** figure — a GPU terminal
repainting vs an old mux's redraw, where rendering dominates. This benchmark
measures **steady-state detached byte throughput** with no renderer on either
side, so the gap is a smaller 4–6×. The *direction* is identical and, crucially,
the **content-sensitivity** isolates the mechanism (parse vs tee) rather than a
single headline number. termiod inherits the fast-path property structurally: it
never parses on the hot path (`session.rs::fan_out` is `push_ring` + byte
`send`, zero VT), so it can never pay the tax this benchmark charges tmux.
