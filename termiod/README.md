# termiod — durable session host

> **A session lives in a host. Viewers only attach.**  
> **Composable** · **Direct.** Local is remote to localhost. Detach ≠ kill.

`termiod` is termio’s **session host**. Composable parts (host · protocol · clients · pipes). Direct path (client → host → PTY). The CLI is a **reference client**, not the architecture.

Full model: [`ARCHITECTURE.md`](ARCHITECTURE.md) · design: `docs/design/20260730-termiod-session-mux.md` · epic [#164](https://github.com/jiweiyuan/termio/issues/164) · POC [#170](https://github.com/jiweiyuan/termio/issues/170)–[#172](https://github.com/jiweiyuan/termio/issues/172) · draft PR [#177](https://github.com/jiweiyuan/termio/pull/177).

```
  clients (Mac / iOS / CLI)          host (termiod)
         │                                │
         │   Session Protocol             │ owns PTYs
         ├──── Unix socket (local) ──────►│
         └──── SSH pipe (remote) ────────►│──► shell / agent
```

## Build

```sh
cd termiod
cargo build            # ./target/debug/termiod
cargo build --release
```

One binary = **host** (`serve`) + **clients** (`attach`, `list`, …) + **SSH transport helpers** (`remote …`).

## Host (local)

```sh
termiod serve          # foreground host (usually auto-started)
```

Socket: `$XDG_RUNTIME_DIR/termiod/termiod.sock`, else `/tmp/termiod-<uid>/termiod.sock`  
(`0700` dir, `0600` socket). Override: `TERMIOD_SOCK`.

## Clients (local)

```sh
termiod attach demo                    # create-on-missing; Ctrl-\ detaches
termiod attach build -- npm run dev
termiod list
termiod list --json
termiod create --name api --cwd ~/proj -- bash
termiod send api "npm test"            # inject without attach
termiod set-status api needs_you --title "Review requested"
termiod kill api
```

Multi-client: several `attach` to the same session — output fans out. There
is one writer: the newest `mode:"interact"` claim wins, while
`mode:"observe"` never claims it. A demoted writer remains attached.
Non-writer input/resize receives a typed `not_writer` error; writer changes
and accepted resizes are event frames.

## Session Protocol v0.1

Framed stream: `[kind:u8][len:u32 BE][payload]`

| kind | payload | meaning |
| --- | --- | --- |
| `C` | `op`-tagged JSON | control and correlated responses |
| `D` | raw bytes | PTY I/O (hot path) |
| `R` | `rows:u16, cols:u16` | resize (TIOCSWINSZ) |
| `E` | `ev`-tagged JSON | status, writer, resize, exit, and roster events |

Frames are capped at 16 MiB; writers split `D` into chunks of at most 64 KiB.
Unknown control operations/events are ignored, while an unknown frame kind is
a typed `proto_error` followed by channel close.

Every v0.1 channel begins with `hello` and declares `role:"control"` or
`role:"attach"`, a protocol range, and capabilities. The host negotiates
protocol 1 and the capability intersection (`events`, `send_wait`), returning
its stable `host_id` and a connection-scoped `client_id`. An incompatible
range gets `hello_err` and an immediate close. A first v0 control operation
without `hello` is accepted as a legacy connection with no capabilities, so
old clients continue to work.

Requests may carry `seq`; responses echo it as `re`. Control channels can
`subscribe` to roster/status events, `wait` for session state, and call
`set_status` for workstream metadata. `create` accepts optional
`workstream {agent_id, project, worktree}`; `list` exposes status/title,
attachment count, and writer identity.

Later: host-side vt snapshot / diffs (not in this POC). No panes inside the
host (zmx lesson).

## Remote (SSH is a pipe)

Transport is **system OpenSSH** only — no public listener. The **host still runs on the VPS**; SSH only reaches it.

```sh
termiod remote deploy my-vps           # cross-compile musl → ~/.local/bin/termiod
termiod remote list my-vps
termiod remote attach my-vps demo -- bash
termiod remote open my-vps --cwd '~/proj' --agent shell
```

`my-vps` = `~/.ssh/config` alias. Close the laptop; reattach — agent kept running on the VPS. See [`DEPLOY.md`](DEPLOY.md).

## Test

```sh
cargo build
python3 smoke_test.py          # 27 local checks (16 v0 + 11 v0.1)
python3 remote_smoke_test.py   # #171/#172 — 8 checks via fake-ssh
```

## Layout

| path | part |
| --- | --- |
| `src/daemon.rs` · `session.rs` · `pty.rs` | **Host** |
| `src/protocol.rs` | **Protocol** |
| `src/client.rs` · `main.rs` | **Reference client** |
| `src/remote.rs` | **SSH transport** helpers |
| `ARCHITECTURE.md` | Clean model |
