#!/usr/bin/env python3
"""End-to-end smoke test for the termiod POC (#170 acceptance).

Drives the `termiod` binary through real PTYs and asserts the durable-session
contract: attach → type → detach → the session survives → reattach sees the
same process; multi-client fan-out; single-writer input; newest-client resize;
inject-without-attach; kill.

Usage:
    cargo build && python3 smoke_test.py [path/to/termiod]

Exits 0 if every check passes, 1 otherwise.
"""

import fcntl
import hashlib
import json
import os
import pty
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import termios
import time

BIN = sys.argv[1] if len(sys.argv) > 1 else "./target/debug/termiod"
SOCK_DIR = "/tmp/termiod-smoke"
ENV = dict(
    os.environ,
    TERMIOD_SOCK=f"{SOCK_DIR}/termiod.sock",
    TERMIOD_KEYFRAME_EVERY="4",
    TERM="xterm-256color",
)

FAILURES = []


def check(name, ok):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        FAILURES.append(name)


def cli(*args):
    return subprocess.run(
        [BIN, *args], env=ENV, capture_output=True, text=True
    )


def cli_out(*args):
    return cli(*args).stdout.strip()


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("socket closed mid-frame")
        data += chunk
    return data


def decode_snapshot(payload):
    """Decode an S payload enough to assert its visible grid.

    Two formats share one header. v2 (raw-plane clients) carries VT sequences —
    the host describes content and the *client* decides colour, so there is no
    cell grid to walk; the visible text is recovered by stripping escapes. v1
    (grid_diff clients) carries packed cells and is walked directly.
    """
    if len(payload) < 12 or payload[0] not in (1, 2):
        raise ValueError("invalid snapshot header")
    is_vt = payload[0] == 2
    rows, cols, cursor_x, cursor_y = struct.unpack(">HHHH", payload[1:9])
    alt_screen = payload[9] == 1
    title_len = struct.unpack(">H", payload[10:12])[0]
    cells_offset = 12 + title_len
    title = payload[12:cells_offset].decode()
    if is_vt:
        body = payload[cells_offset:]
        if len(body) < 4:
            raise ValueError("invalid snapshot vt length")
        vt_len = struct.unpack(">I", body[0:4])[0]
        if len(body) != 4 + vt_len:
            raise ValueError("invalid snapshot vt payload")
        vt = body[4:].decode("utf-8", "replace")
        plain = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", vt)
        plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", plain)
        plain = re.sub(r"\x1b[()][A-Za-z0-9]", "", plain)
        plain = plain.replace("\x1b", "")
        lines = [line.rstrip("\r") for line in plain.split("\n")]
        lines += [""] * max(0, rows - len(lines))
        return {
            "rows": rows,
            "cols": cols,
            "cursor_x": cursor_x,
            "cursor_y": cursor_y,
            "alt_screen": alt_screen,
            "title": title,
            "lines": lines,
            "vt": vt,
        }
    cell_bytes = payload[cells_offset:]
    if len(cell_bytes) != rows * cols * 16:
        raise ValueError("invalid snapshot cell count")
    lines = []
    for row in range(rows):
        line = []
        for col in range(cols):
            offset = (row * cols + col) * 16
            codepoint = struct.unpack(">I", cell_bytes[offset : offset + 4])[0]
            line.append(chr(codepoint) if codepoint else " ")
        lines.append("".join(line))
    return {
        "rows": rows,
        "cols": cols,
        "cursor_x": cursor_x,
        "cursor_y": cursor_y,
        "alt_screen": alt_screen,
        "title": title,
        "lines": lines,
    }


def decode_history(payload):
    """Decode the Phase 1d H payload into newest-first text rows."""
    if len(payload) < 9 or payload[0] != 1:
        raise ValueError("invalid history header")
    cols = struct.unpack(">H", payload[1:3])[0]
    first_offset = struct.unpack(">I", payload[3:7])[0]
    row_count = struct.unpack(">H", payload[7:9])[0]
    cell_bytes = payload[9:]
    if len(payload) > 64 * 1024 or len(cell_bytes) != row_count * cols * 16:
        raise ValueError("invalid history cell count")
    lines = []
    for row in range(row_count):
        line = []
        for col in range(cols):
            offset = (row * cols + col) * 16
            codepoint = struct.unpack(">I", cell_bytes[offset : offset + 4])[0]
            line.append(chr(codepoint) if codepoint else " ")
        lines.append("".join(line))
    return {
        "cols": cols,
        "first_offset": first_offset,
        "row_count": row_count,
        "lines": lines,
    }


def decode_file_chunk(payload):
    """Decode a §C.12 F frame: re u64be, offset u64be, last u8, bytes."""
    if len(payload) < 17:
        raise ValueError("invalid file chunk header")
    re_id, offset = struct.unpack(">QQ", payload[0:16])
    last = payload[16] == 1
    return {"re": re_id, "offset": offset, "last": last, "data": payload[17:]}


def recv_file_body(client, re_id, timeout=4.0):
    """Collect F chunks for one fs_read until the flagged last chunk."""
    body = b""
    end = time.time() + timeout
    chunks = []
    while time.time() < end:
        kind, payload = client.recv_frame(max(0.05, end - time.time()))
        if kind != "F":
            continue
        chunk = decode_file_chunk(payload)
        if chunk["re"] != re_id:
            continue
        chunks.append(chunk)
        body += chunk["data"]
        if chunk["last"]:
            return body, chunks
    raise EOFError("no final file chunk")


def send_upload_chunk(client, upload_id, offset, data):
    """Encode a §C.12 U frame: id_len u8, id, offset u64be, bytes."""
    uid = upload_id.encode()
    client.send_frame("U", bytes([len(uid)]) + uid + struct.pack(">Q", offset) + data)


def upload_credit_of_one(client, upload_id, body, chunk=64 * 1024 - 64, start=0):
    """Send the body chunk by chunk, holding each until the previous ack."""
    sent = start
    while True:
        piece = body[sent : sent + chunk]
        send_upload_chunk(client, upload_id, sent, piece)
        ack, _ = client.recv_matching(
            lambda kind, msg: kind == "C"
            and msg.get("op") in ("upload_ack", "error")
        )
        if ack is None or ack[1].get("op") != "upload_ack":
            return sent, ack
        sent = ack[1]["offset"]
        if sent >= len(body):
            return sent, ack


def decode_grid(payload):
    """Decode a Phase 1e G payload into its dirty full-width rows."""
    if len(payload) < 16 or payload[0] != 1:
        raise ValueError("invalid grid-diff header")
    frame_seq = struct.unpack(">I", payload[1:5])[0]
    rows, cols, cursor_x, cursor_y = struct.unpack(">HHHH", payload[5:13])
    alt_screen = payload[13] == 1
    row_count = struct.unpack(">H", payload[14:16])[0]
    expected = 16 + row_count * (2 + cols * 16)
    if len(payload) != expected:
        raise ValueError("invalid grid-diff row count")
    dirty_rows = []
    offset = 16
    for _ in range(row_count):
        row_index = struct.unpack(">H", payload[offset : offset + 2])[0]
        offset += 2
        line = []
        for col in range(cols):
            cell_offset = offset + col * 16
            codepoint = struct.unpack(">I", payload[cell_offset : cell_offset + 4])[0]
            line.append(chr(codepoint) if codepoint else " ")
        offset += cols * 16
        dirty_rows.append((row_index, "".join(line)))
    return {
        "frame_seq": frame_seq,
        "rows": rows,
        "cols": cols,
        "cursor_x": cursor_x,
        "cursor_y": cursor_y,
        "alt_screen": alt_screen,
        "dirty_rows": dirty_rows,
    }


class WireClient:
    """Small protocol client used to test the v0.1 wire directly."""

    def __init__(self, role="control", caps=None, hello=True, proto=1, min_proto=1, path=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path or ENV["TERMIOD_SOCK"])
        self.hello = None
        if hello:
            self.send_control(
                {
                    "op": "hello",
                    "proto": proto,
                    "min_proto": min_proto,
                    "role": role,
                    "caps": caps or [],
                    "client": "smoke-test/0.1",
                }
            )
            kind, self.hello = self.recv_frame()
            assert kind == "C"

    def send_frame(self, kind, payload):
        if isinstance(payload, dict):
            payload = json.dumps(payload, separators=(",", ":")).encode()
        self.sock.sendall(kind.encode() + struct.pack(">I", len(payload)) + payload)

    def send_control(self, message):
        self.send_frame("C", message)

    def send_data(self, data):
        self.send_frame("D", data)

    def send_resize(self, rows, cols):
        self.send_frame("R", struct.pack(">HH", rows, cols))

    def recv_frame(self, timeout=3.0):
        self.sock.settimeout(timeout)
        header = recv_exact(self.sock, 5)
        kind = chr(header[0])
        payload = recv_exact(self.sock, struct.unpack(">I", header[1:])[0])
        if kind in ("C", "E"):
            payload = json.loads(payload)
        return kind, payload

    def recv_matching(self, predicate, timeout=4.0):
        end = time.time() + timeout
        seen = []
        while time.time() < end:
            try:
                frame = self.recv_frame(max(0.05, end - time.time()))
            except (socket.timeout, EOFError):
                break
            seen.append(frame)
            if predicate(*frame):
                return frame, seen
        return None, seen

    def drain(self, duration=0.25):
        end = time.time() + duration
        frames = []
        while time.time() < end:
            try:
                frames.append(self.recv_frame(max(0.01, end - time.time())))
            except (socket.timeout, EOFError):
                break
        return frames

    def close(self):
        self.sock.close()


def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def spawn_attach(extra_args, rows=24, cols=80):
    """Spawn `termiod attach <extra_args>` wired to a fresh PTY."""
    master, slave = pty.openpty()
    set_winsize(master, rows, cols)
    p = subprocess.Popen(
        [BIN, "attach", *extra_args],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=ENV,
        close_fds=True,
    )
    os.close(slave)
    return p, master


def read_until(master, needle, timeout=4.0):
    if isinstance(needle, str):
        needle = needle.encode()
    data = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            if needle in data:
                return data
    return data


def drain(master, dur=0.4):
    end = time.time() + dur
    data = b""
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
    return data


def session_pid(name):
    try:
        rows = json.loads(cli_out("list", "--json"))
    except Exception:
        return None
    for s in rows:
        if s["name"] == name or s["id"] == name:
            return s["pid"]
    return None


def session_size(name):
    for s in json.loads(cli_out("list", "--json")):
        if s["name"] == name or s["id"] == name:
            return (s["rows"], s["cols"])
    return None


def session_info(name):
    for session in json.loads(cli_out("list", "--json")):
        if session["name"] == name or session["id"] == name:
            return session
    return None


def cleanup():
    try:
        for s in json.loads(cli_out("list", "--json")):
            cli("kill", s["id"])
    except Exception:
        pass


def main():
    os.makedirs(SOCK_DIR, exist_ok=True)
    cleanup()

    print("\n# 1. attach → type → detach → session survives → reattach")
    p1, m1 = spawn_attach(["demo", "--", "bash", "--norc"], rows=30, cols=120)
    read_until(m1, "attached to demo")
    os.write(m1, b"PS1=P>; echo MARKER_ONE\r")
    got = read_until(m1, "MARKER_ONE")
    check("attach: session echoes typed command", b"MARKER_ONE" in got)
    check("resize: newest client claim (30x120)", session_size("demo") == (30, 120))
    pid_before = session_pid("demo")
    check("session has a pid", pid_before is not None)

    # Detach with Ctrl-\ (0x1c). Session must survive.
    os.write(m1, b"\x1c")
    try:
        p1.wait(timeout=5)
        detached_clean = True
    except subprocess.TimeoutExpired:
        p1.kill()
        detached_clean = False
    check("detach: attach client exits cleanly", detached_clean)
    time.sleep(0.3)
    check("detach ≠ kill: session still listed", session_pid("demo") is not None)

    # Reattach: different window size (newest-client claim), same process.
    p2, m2 = spawn_attach(["demo"], rows=40, cols=100)
    read_until(m2, "attached to demo")
    replay = drain(m2, 0.4)
    check("reattach: ring replay shows prior output", b"MARKER_ONE" in replay)
    os.write(m2, b"echo MARKER_TWO\r")
    check("reattach: input works", b"MARKER_TWO" in read_until(m2, "MARKER_TWO"))
    check("reattach: same process (pid unchanged)", session_pid("demo") == pid_before)
    check("reattach: newest-client resize (40x100)", session_size("demo") == (40, 100))
    os.write(m2, b"\x1c")
    p2.wait(timeout=5)
    cli("kill", "demo")

    print("\n# 2. multi-client fan-out + single-writer input")
    a1p, a1 = spawn_attach(["fan", "--", "cat"], rows=26, cols=90)
    read_until(a1, "attached to fan")
    a2p, a2 = spawn_attach(["fan"], rows=34, cols=110)  # newest ⇒ writer
    read_until(a2, "attached to fan")

    # Inject via `send` (always applied); cat echoes to *both* clients.
    cli("send", "fan", "PINGPONG")
    check("fan-out: client 1 sees injected output", b"PINGPONG" in read_until(a1, "PINGPONG"))
    check("fan-out: client 2 sees injected output", b"PINGPONG" in read_until(a2, "PINGPONG"))

    # Single writer = newest (a2). Input from a1 (not writer) is ignored.
    os.write(a1, b"FROM_A1\r")
    time.sleep(0.4)
    leaked = drain(a2, 0.4)
    check("single-writer: non-writer input ignored", b"FROM_A1" not in leaked)
    os.write(a2, b"FROM_A2\r")
    check("single-writer: writer input applied", b"FROM_A2" in read_until(a2, "FROM_A2"))

    os.write(a2, b"\x1c")
    a2p.wait(timeout=5)
    deadline = time.time() + 3
    while time.time() < deadline and session_size("fan") != (26, 90):
        time.sleep(0.05)
    check(
        "writer failover: promoted reference client reclaims its size",
        session_size("fan") == (26, 90),
    )
    drain(a1, 0.5)
    os.write(a1, b"\x1c")
    a1p.wait(timeout=5)
    cli("kill", "fan")

    print("\n# 3. observe streams full output without claiming writer")
    observe_writer, observe_master = spawn_attach(
        ["observe-pipe", "--", "bash", "--norc"]
    )
    read_until(observe_master, "attached to observe-pipe")
    before_observe = session_info("observe-pipe") or {}
    writer_before = before_observe.get("writer_client_id")

    observer = subprocess.Popen(
        [BIN, "attach", "observe-pipe", "--observe", "--no-create"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=ENV,
    )
    observer_attached = False
    writer_unchanged = False
    for _ in range(50):
        observed = session_info("observe-pipe") or {}
        if observed.get("attached_clients") == 2:
            observer_attached = True
            writer_unchanged = (
                writer_before is not None
                and observed.get("writer_client_id") == writer_before
            )
            break
        time.sleep(0.05)
    check(
        "observe: stdin EOF does not detach the observer",
        observer_attached and observer.poll() is None,
    )
    check("observe: writer ownership is unchanged", writer_unchanged)

    observe_payload = (
        "OBSERVE_FULL_0123456789" * 2048 + "OBSERVE_END_UNIQUE"
    ).encode()
    os.write(
        observe_master,
        b"python3 -c 'import sys;sys.stdout.write(\"OBSERVE_FULL_0123456789\"*2048+bytes([79,66,83,69,82,86,69,95,69,78,68,95,85,78,73,81,85,69]).decode());sys.stdout.flush()'\r",
    )
    read_until(observe_master, "OBSERVE_END_UNIQUE")
    cli("kill", "observe-pipe")
    try:
        observed_stdout, _ = observer.communicate(timeout=5)
        observer_clean = observer.returncode == 0
    except subprocess.TimeoutExpired:
        observer.kill()
        observed_stdout, _ = observer.communicate()
        observer_clean = False
    check(
        "observe: stdout pipe receives the full payload",
        observer_clean and observe_payload in observed_stdout,
    )
    try:
        observe_writer.wait(timeout=5)
    except subprocess.TimeoutExpired:
        observe_writer.kill()
    os.close(observe_master)

    print("\n# 4. inject-without-attach + kill")
    sid = cli_out("create", "--name", "inj", "--", "bash", "--norc")
    check("create returns an id", bool(sid))
    time.sleep(0.3)
    cli("send", "inj", f"echo INJECTED > {SOCK_DIR}/inj.txt")
    time.sleep(0.5)
    ok = os.path.exists(f"{SOCK_DIR}/inj.txt") and "INJECTED" in open(f"{SOCK_DIR}/inj.txt").read()
    check("send: inject without attach reaches the shell", ok)
    cli("kill", "inj")
    time.sleep(0.3)
    check("kill: session removed", session_pid("inj") is None)

    print("\n# 5. v0.1 hello negotiation + legacy fallback + request ids")
    h1 = WireClient(caps=["events", "not-a-host-cap"])
    h2 = WireClient(caps=["events"])
    check(
        "hello: negotiates protocol and capability intersection",
        h1.hello["op"] == "hello_ok"
        and h1.hello["proto"] == 1
        and h1.hello["caps"] == ["events"],
    )
    check(
        "hello: host id is stable and client ids are connection-scoped",
        h1.hello["host_id"] == h2.hello["host_id"]
        and h1.hello["client_id"] != h2.hello["client_id"],
    )
    h1.close()
    h2.close()

    grid_without_snapshot = WireClient(caps=["grid_diff"])
    check(
        "hello: grid_diff is dropped unless snapshot is also negotiated",
        "grid_diff" not in grid_without_snapshot.hello["caps"],
    )
    grid_without_snapshot.close()

    incompatible = WireClient(hello=False)
    incompatible.send_control(
        {
            "op": "hello",
            "proto": 2,
            "min_proto": 2,
            "role": "control",
            "caps": [],
            "client": "future-client",
        }
    )
    kind, refused = incompatible.recv_frame()
    try:
        incompatible.sock.settimeout(1)
        closed = incompatible.sock.recv(1) == b""
    except socket.timeout:
        closed = False
    check(
        "hello: incompatible range is refused and closed",
        kind == "C"
        and refused["op"] == "hello_err"
        and refused["code"] == "incompatible"
        and refused["supported"] == [1]
        and closed,
    )
    incompatible.close()

    legacy = WireClient(hello=False)
    legacy.send_control({"op": "list"})
    kind, legacy_reply = legacy.recv_frame()
    check(
        "legacy: first non-hello v0 request still works",
        kind == "C" and legacy_reply["op"] == "sessions",
    )
    legacy.close()

    sequenced = WireClient()
    sequenced.send_control({"op": "list", "seq": 41})
    kind, seq_reply = sequenced.recv_frame()
    check(
        "request ids: response echoes seq as re",
        kind == "C" and seq_reply["op"] == "sessions" and seq_reply["re"] == 41,
    )
    sequenced.close()

    print("\n# 6. snapshot bootstrap boundary + legacy ring replay")
    snapshot_id = cli_out(
        "create",
        "--name",
        "snapshot-boundary",
        "--",
        "python3",
        "-u",
        "-c",
        "import time; "
        "[print(f'HISTORY_{i:03}', flush=True) for i in range(80)]; "
        "print('SNAPSHOT_KNOWN', flush=True); "
        "time.sleep(1.5); print('LIVE_AFTER_READY', flush=True); time.sleep(30)",
    )
    time.sleep(0.5)
    snapshot_dims = session_size(snapshot_id)
    requested_rows = 1 if snapshot_dims[0] != 1 else 2
    requested_cols = 1 if snapshot_dims[1] != 1 else 2

    snapshot_client = WireClient(role="attach", caps=["snapshot", "scrollback"])
    snapshot_client.send_control(
        {
            "op": "attach",
            "target": snapshot_id,
            "mode": "observe",
            "rows": requested_rows,
            "cols": requested_cols,
            "seq": 70,
        }
    )
    attached = snapshot_client.recv_frame()
    snapshot_frame = snapshot_client.recv_frame()
    ready_frame = snapshot_client.recv_frame()
    decoded = (
        decode_snapshot(snapshot_frame[1]) if snapshot_frame[0] == "S" else None
    )
    check(
        "attached: observer receives authoritative session dimensions",
        attached[0] == "C"
        and attached[1].get("op") == "attached"
        and (attached[1].get("rows"), attached[1].get("cols")) == snapshot_dims
        and (requested_rows, requested_cols) != snapshot_dims,
    )
    check(
        "snapshot: attached dimensions match the S header",
        decoded is not None
        and (attached[1].get("rows"), attached[1].get("cols"))
        == (decoded["rows"], decoded["cols"]),
    )
    check(
        "snapshot: attached is followed by S with the known grid, then ready",
        attached[0] == "C"
        and attached[1].get("op") == "attached"
        and snapshot_frame[0] == "S"
        and decoded is not None
        and "SNAPSHOT_KNOWN" in "\n".join(decoded["lines"])
        and ready_frame[0] == "E"
        and ready_frame[1].get("ev") == "ready"
        and ready_frame[1].get("session") == snapshot_id,
    )
    history_frames = snapshot_client.drain(0.5)
    history_chunks = [
        decode_history(payload) for kind, payload in history_frames if kind == "H"
    ]
    history_text = "\n".join(
        line for chunk in history_chunks for line in chunk["lines"]
    )
    check(
        "scrollback: H follows ready, is newest-first, and contains scrolled lines",
        len(history_chunks) >= 2
        and history_chunks[0]["first_offset"] == 1
        and all(
            newer["first_offset"] + newer["row_count"]
            == older["first_offset"]
            for newer, older in zip(history_chunks, history_chunks[1:])
        )
        and all(len(payload) <= 64 * 1024 for kind, payload in history_frames if kind == "H")
        and "HISTORY_000" in history_text
        and all(kind != "H" for kind, _ in (attached, snapshot_frame, ready_frame)),
    )
    live, _ = snapshot_client.recv_matching(
        lambda kind, payload: kind == "D" and b"LIVE_AFTER_READY" in payload,
        timeout=3.0,
    )
    check("snapshot: live D starts only after ready", live is not None)
    snapshot_client.close()

    snapshot_only = WireClient(role="attach", caps=["snapshot"])
    snapshot_only.send_control(
        {
            "op": "attach",
            "target": snapshot_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 75,
        }
    )
    snapshot_only_frames = snapshot_only.drain(0.5)
    check(
        "scrollback: snapshot-only client gets S and ready but never H",
        any(kind == "S" for kind, _ in snapshot_only_frames)
        and any(
            kind == "E" and payload.get("ev") == "ready"
            for kind, payload in snapshot_only_frames
        )
        and all(kind != "H" for kind, _ in snapshot_only_frames),
    )
    snapshot_only.close()

    legacy_attach = WireClient(role="attach", caps=[])
    legacy_attach.send_control(
        {
            "op": "attach",
            "target": snapshot_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 71,
        }
    )
    legacy_frames = legacy_attach.drain(0.5)
    check(
        "snapshot: client without cap gets ring D and never S",
        any(kind == "D" and b"SNAPSHOT_KNOWN" in payload for kind, payload in legacy_frames)
        and all(kind != "S" for kind, _ in legacy_frames),
    )
    legacy_attach.close()
    cli("kill", snapshot_id)

    barrier_id = cli_out("create", "--name", "resize-barrier", "--", "cat")
    barrier_writer = WireClient(role="attach", caps=["events"])
    barrier_writer.send_control(
        {
            "op": "attach",
            "target": barrier_id,
            "mode": "interact",
            "rows": 24,
            "cols": 80,
            "seq": 72,
        }
    )
    barrier_writer.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "attached"
    )
    barrier_writer.drain()

    barrier_snapshot = WireClient(role="attach", caps=["snapshot", "events"])
    barrier_snapshot.send_control(
        {
            "op": "attach",
            "target": barrier_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 73,
        }
    )
    barrier_snapshot.recv_matching(
        lambda kind, msg: kind == "E" and msg.get("ev") == "ready"
    )

    barrier_legacy = WireClient(role="attach", caps=["events"])
    barrier_legacy.send_control(
        {
            "op": "attach",
            "target": barrier_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 74,
        }
    )
    barrier_legacy.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "attached"
    )
    barrier_snapshot.drain()
    barrier_legacy.drain()

    barrier_writer.send_data(b"PRE_BARRIER\n")
    barrier_snapshot.recv_matching(
        lambda kind, payload: kind == "D" and b"PRE_BARRIER" in payload
    )
    barrier_legacy.recv_matching(
        lambda kind, payload: kind == "D" and b"PRE_BARRIER" in payload
    )
    barrier_snapshot.drain()
    barrier_legacy.drain()

    barrier_writer.send_resize(31, 97)
    barrier_writer.send_data(b"POST_BARRIER\n")
    fresh_snapshot, snapshot_seen = barrier_snapshot.recv_matching(
        lambda kind, payload: kind == "S", timeout=3.0
    )
    fresh_decoded = (
        decode_snapshot(fresh_snapshot[1]) if fresh_snapshot is not None else None
    )
    check(
        "resize barrier: fresh S has new dimensions and precedes post-resize D",
        fresh_decoded is not None
        and (fresh_decoded["rows"], fresh_decoded["cols"]) == (31, 97)
        and all(kind != "D" for kind, _ in snapshot_seen[:-1]),
    )
    barrier_ready = barrier_snapshot.recv_frame()
    post_resize, resumed_frames = barrier_snapshot.recv_matching(
        lambda kind, payload: kind == "D" and b"POST_BARRIER" in payload,
        timeout=3.0,
    )
    check(
        "resize barrier: every S is followed by ready before D resumes",
        barrier_ready[0] == "E"
        and barrier_ready[1].get("ev") == "ready"
        and barrier_ready[1].get("session") == barrier_id
        and post_resize is not None,
    )

    legacy_resized, legacy_seen = barrier_legacy.recv_matching(
        lambda kind, payload: kind == "E"
        and payload.get("ev") == "resized"
        and (payload.get("rows"), payload.get("cols")) == (31, 97),
        timeout=3.0,
    )
    legacy_post, legacy_resumed = barrier_legacy.recv_matching(
        lambda kind, payload: kind == "D" and b"POST_BARRIER" in payload,
        timeout=3.0,
    )
    legacy_tail = barrier_legacy.drain()
    check(
        "resize barrier: v0 client gets resized and never S",
        legacy_resized is not None
        and legacy_post is not None
        and all(
            kind != "S"
            for kind, _ in legacy_seen + legacy_resumed + legacy_tail
        ),
    )

    barrier_writer.close()
    barrier_snapshot.close()
    barrier_legacy.close()
    cli("kill", barrier_id)

    print("\n# 7. capability-gated grid diffs + periodic keyframes")
    grid_id = cli_out(
        "create",
        "--name",
        "grid-diff",
        "--",
        "sh",
        "-c",
        "stty -echo; exec cat",
    )
    time.sleep(0.2)
    grid_writer = WireClient(role="attach", caps=["events"])
    grid_writer.send_control(
        {
            "op": "attach",
            "target": grid_id,
            "mode": "interact",
            "rows": 24,
            "cols": 80,
            "seq": 80,
        }
    )
    grid_writer.recv_matching(
        lambda kind, payload: kind == "C" and payload.get("op") == "attached"
    )
    grid_writer.drain(0.3)

    raw_peer = WireClient(role="attach", caps=[])
    raw_peer.send_control(
        {
            "op": "attach",
            "target": grid_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 81,
        }
    )
    raw_peer.recv_matching(
        lambda kind, payload: kind == "C" and payload.get("op") == "attached"
    )
    raw_peer.drain()

    grid_peer = WireClient(role="attach", caps=["snapshot", "grid_diff"])
    grid_peer.send_control(
        {
            "op": "attach",
            "target": grid_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 82,
        }
    )
    grid_bootstrap = [grid_peer.recv_frame() for _ in range(3)]
    check(
        "grid diff: attach bootstraps as attached -> S -> ready",
        grid_bootstrap[0][0] == "C"
        and grid_bootstrap[0][1].get("op") == "attached"
        and grid_bootstrap[1][0] == "S"
        and grid_bootstrap[2][0] == "E"
        and grid_bootstrap[2][1].get("ev") == "ready",
    )

    for index in range(12):
        grid_writer.send_data(f"GRID_DIFF_{index:02}\n".encode())
        time.sleep(0.12)

    raw_last, raw_seen = raw_peer.recv_matching(
        lambda kind, payload: kind == "D" and b"GRID_DIFF_11" in payload,
        timeout=4.0,
    )
    grid_live = grid_peer.drain(3.0)
    decoded_grids = [decode_grid(payload) for kind, payload in grid_live if kind == "G"]
    grid_text = "\n".join(
        line for grid in decoded_grids for _, line in grid["dirty_rows"]
    )
    check(
        "grid diff: known text arrives in G and no downstream D reaches the client",
        "GRID_DIFF_00" in grid_text
        and decoded_grids
        and all(kind != "D" for kind, _ in grid_bootstrap + grid_live),
    )
    check(
        "grid diff: raw and parsed planes coexist on one session",
        raw_last is not None
        and any(kind == "D" for kind, _ in raw_seen)
        and decoded_grids,
    )

    keyframe_indexes = [
        index for index, (kind, _) in enumerate(grid_live) if kind == "S"
    ]
    keyframe_ok = False
    if keyframe_indexes:
        keyframe_index = keyframe_indexes[0]
        keyframe_ok = (
            keyframe_index + 1 < len(grid_live)
            and grid_live[keyframe_index + 1][0] == "E"
            and grid_live[keyframe_index + 1][1].get("ev") == "ready"
            and any(kind == "G" for kind, _ in grid_live[:keyframe_index])
            and any(kind == "G" for kind, _ in grid_live[keyframe_index + 2 :])
        )
    frame_sequences = [grid["frame_seq"] for grid in decoded_grids]
    check(
        "grid diff: cadence=4 emits S + ready, then G resumes with increasing frame_seq",
        keyframe_ok
        and all(
            newer > older
            for older, newer in zip(frame_sequences, frame_sequences[1:])
        ),
    )

    grid_peer.drain()
    grid_writer.send_resize(29, 91)
    grid_writer.send_data(b"GRID_RESIZE_0\n")
    resize_keyframe, resize_seen = grid_peer.recv_matching(
        lambda kind, payload: kind == "S", timeout=3.0
    )
    resize_ready = grid_peer.recv_frame() if resize_keyframe is not None else None
    grid_writer.send_data(b"GRID_RESIZE_1\n")
    time.sleep(0.12)
    grid_writer.send_data(b"GRID_RESIZE_2\n")
    resized_grid, _ = grid_peer.recv_matching(
        lambda kind, payload: kind == "G"
        and "GRID_RESIZE" in "\n".join(
            line for _, line in decode_grid(payload)["dirty_rows"]
        ),
        timeout=3.0,
    )
    check(
        "grid diff: resize discards pre-boundary G and resumes after S + ready",
        resize_keyframe is not None
        and all(kind != "G" for kind, _ in resize_seen[:-1])
        and resize_ready is not None
        and resize_ready[0] == "E"
        and resize_ready[1].get("ev") == "ready"
        and resized_grid is not None,
    )

    grid_writer.close()
    raw_peer.close()
    grid_peer.close()
    cli("kill", grid_id)

    print("\n# 8. v0.1 single-writer errors and writer events")
    wire_id = cli_out("create", "--name", "wire-writer", "--", "cat")
    w1 = WireClient(role="attach", caps=["events"])
    w1.send_control(
        {
            "op": "attach",
            "target": wire_id,
            "mode": "interact",
            "rows": 24,
            "cols": 80,
            "seq": 1,
        }
    )
    attached1, _ = w1.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "attached"
    )
    w1.drain()

    w2 = WireClient(role="attach", caps=["events"])
    w2.send_control(
        {
            "op": "attach",
            "target": wire_id,
            "mode": "interact",
            "rows": 30,
            "cols": 100,
            "seq": 2,
        }
    )
    attached2, _ = w2.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "attached"
    )
    changed, _ = w1.recv_matching(
        lambda kind, msg: kind == "E"
        and msg.get("ev") == "writer_changed"
        and msg.get("writer") == w2.hello["client_id"]
    )
    check(
        "writer policy: newest interactive attach wins and emits writer_changed",
        attached1 is not None
        and attached2 is not None
        and attached2[1]["writer"] is True
        and changed is not None,
    )
    w1.send_data(b"REJECT_ME\r")
    rejected, _ = w1.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "error"
        and msg.get("code") == "not_writer"
    )
    check(
        "writer policy: non-writer D receives typed not_writer",
        rejected is not None and rejected[1]["retryable"] is False,
    )
    w2.close()
    promoted, _ = w1.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "resize_claim"
        and msg.get("writer") == w1.hello["client_id"]
    )
    check(
        "writer policy: promoted writer receives a resize claim",
        promoted is not None,
    )
    w1.close()
    cli("kill", wire_id)

    print("\n# 9. v0.1 subscriptions, status metadata, and waits")
    sub = WireClient(caps=["events", "send_wait"])
    sub.send_control(
        {"op": "subscribe", "events": ["roster", "status"], "seq": 50}
    )
    subscribed, _ = sub.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "ok"
        and msg.get("re") == 50
    )
    sub.send_control(
        {
            "op": "create",
            "name": "metadata",
            "argv": ["cat"],
            "workstream": {
                "agent_id": "codex",
                "project": "termio",
                "worktree": "termiod-v01",
            },
            "seq": 51,
        }
    )
    created, seen = sub.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "created"
        and msg.get("re") == 51
    )
    metadata_id = created[1]["id"] if created else None
    roster = next(
        (
            frame
            for frame in seen
            if frame[0] == "E"
            and frame[1].get("ev") == "roster"
            and frame[1].get("action") == "created"
        ),
        None,
    )
    if roster is None and metadata_id:
        roster, _ = sub.recv_matching(
            lambda kind, msg: kind == "E"
            and msg.get("ev") == "roster"
            and msg.get("action") == "created"
            and msg.get("session") == metadata_id
        )
    check(
        "subscribe: roster creation streams as an E frame",
        subscribed is not None and metadata_id is not None and roster is not None,
    )

    sub.send_control(
        {
            "op": "set_status",
            "id": metadata_id,
            "status": "needs_you",
            "title": "Review requested",
            "seq": 52,
        }
    )
    status_event, seen = sub.recv_matching(
        lambda kind, msg: kind == "E"
        and msg.get("ev") == "status"
        and msg.get("session") == metadata_id
        and msg.get("status") == "needs_you"
    )
    status_ok = any(
        kind == "C" and msg.get("op") == "ok" and msg.get("re") == 52
        for kind, msg in seen
    )
    if not status_ok:
        ok_frame, _ = sub.recv_matching(
            lambda kind, msg: kind == "C"
            and msg.get("op") == "ok"
            and msg.get("re") == 52
        )
        status_ok = ok_frame is not None
    check(
        "set_status: update fans out E status and correlates its reply",
        status_event is not None
        and status_event[1].get("title") == "Review requested"
        and status_ok,
    )
    metadata = next(
        (s for s in json.loads(cli_out("list", "--json")) if s["id"] == metadata_id),
        {},
    )
    check(
        "metadata: list exposes status, agent id, title, attachment roster",
        metadata.get("status") == "needs_you"
        and metadata.get("agent_id") == "codex"
        and metadata.get("title") == "Review requested"
        and metadata.get("attached_clients") == 0
        and metadata.get("writer_client_id") is None,
    )

    wait_id = cli_out("create", "--name", "wait-exit", "--", "sleep", "30")
    waiter = WireClient(caps=["send_wait"])
    waiter.send_control(
        {
            "op": "wait",
            "target": wait_id,
            "until": ["exited"],
            "timeout_ms": 5000,
            "seq": 61,
        }
    )
    time.sleep(0.1)
    cli("kill", wait_id)
    wait_result, _ = waiter.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "wait_result"
        and msg.get("re") == 61
    )
    check(
        "wait: exited event resolves wait_result before timeout",
        wait_result is not None
        and wait_result[1]["status"] == "exited"
        and wait_result[1].get("timed_out", False) is False,
    )
    waiter.close()
    sub.close()
    if metadata_id:
        cli("kill", metadata_id)

    print("\n# 10. tombstones: a dead session says what happened to it (§6)")
    # Its own daemon on its own socket, because this section kills a daemon
    # outright and the sections above share the suite's one.
    grave_dir = "/tmp/termiod-smoke-graves"
    shutil.rmtree(grave_dir, ignore_errors=True)
    os.makedirs(grave_dir, exist_ok=True)
    grave_sock = f"{grave_dir}/termiod.sock"
    grave_env = dict(ENV, TERMIOD_SOCK=grave_sock)

    def grave_daemon():
        proc = subprocess.Popen(
            [BIN, "serve"], env=grave_env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        for _ in range(100):
            if os.path.exists(grave_sock):
                break
            time.sleep(0.05)
        time.sleep(0.25)
        return proc

    grave_seq = [500]

    def grave_request(client, message):
        # Distinct request ids per call: the daemon caches replies by id for
        # idempotent retry, so reusing one replays the earlier answer.
        grave_seq[0] += 1
        client.send_control({**message, "seq": grave_seq[0]})
        while True:
            kind, reply = client.recv_frame()
            if kind == "C" and reply.get("op") in ("sessions", "created", "ok", "error"):
                return reply

    def grave_list(client):
        return grave_request(client, {"op": "list"})

    def grave_create(client, name, command):
        reply = grave_request(client, {
            "op": "create", "argv": ["/bin/sh", "-c", command],
            "rows": 24, "cols": 80, "name": name,
        })
        return reply.get("id")

    def graves_by_name(client):
        return {t["name"]: t for t in grave_list(client).get("tombstones", [])}

    daemon = grave_daemon()
    client = WireClient(path=grave_sock)
    grave_create(client, "victim", "sleep 300")
    time.sleep(0.3)
    check(
        "tombstones: a live session is not a tombstone",
        [s["name"] for s in grave_list(client)["sessions"]] == ["victim"]
        and not grave_list(client).get("tombstones"),
    )

    # SIGKILL, not SIGTERM: the daemon must not get to run any shutdown code,
    # or the crash path would be tested against a graceful exit.
    daemon.kill()
    daemon.wait()
    client.close()
    if os.path.exists(grave_sock):
        os.remove(grave_sock)

    daemon = grave_daemon()
    client = WireClient(path=grave_sock)
    listing = grave_list(client)
    lost = {t["name"]: t for t in listing.get("tombstones", [])}
    check(
        "tombstones: a session the daemon died under is reported, not silently gone",
        listing["sessions"] == [] and "victim" in lost,
    )
    check(
        "tombstones: a lost session is daemon_lost with no invented exit status",
        lost.get("victim", {}).get("reason") == "daemon_lost"
        and lost.get("victim", {}).get("exit_status") is None,
    )

    doomed = grave_create(client, "doomed", "sleep 300")
    time.sleep(0.3)
    grave_request(client, {"op": "kill", "id": doomed})
    time.sleep(0.6)
    killed = graves_by_name(client).get("doomed", {})
    check("tombstones: an explicit kill is recorded as killed", killed.get("reason") == "killed")

    grave_create(client, "quitter", "exit 7")
    time.sleep(0.6)
    exited = graves_by_name(client).get("quitter", {})
    check(
        "tombstones: a process that exits keeps its exit status",
        exited.get("reason") == "exited" and exited.get("exit_status") == 7,
    )
    check(
        "tombstones: newest death sorts first",
        [t["name"] for t in grave_list(client).get("tombstones", [])][0] == "quitter",
    )

    client.close()
    daemon.terminate()
    daemon.wait()
    if os.path.exists(grave_sock):
        os.remove(grave_sock)
    daemon = grave_daemon()
    client = WireClient(path=grave_sock)
    reasons = {name: t["reason"] for name, t in graves_by_name(client).items()}
    check(
        "tombstones: history survives a restart without re-mourning the buried",
        reasons == {"victim": "daemon_lost", "doomed": "killed", "quitter": "exited"},
    )
    client.close()
    daemon.terminate()
    daemon.wait()
    shutil.rmtree(grave_dir, ignore_errors=True)

    print("\n# 11. file request plane: fs.list pages + stubs, fs.read chunks (§C.12)")
    proj = f"{SOCK_DIR}/fileplane"
    shutil.rmtree(proj, ignore_errors=True)
    os.makedirs(f"{proj}/src", exist_ok=True)
    os.makedirs(f"{proj}/.git", exist_ok=True)
    with open(f"{proj}/.git/config", "w") as f:
        f.write("[core]\n")
    with open(f"{proj}/README.md", "w") as f:
        f.write("file plane preview bytes")
    with open(f"{proj}/src/lib.rs", "w") as f:
        f.write("pub fn hello() {}\n")
    os.symlink("/", f"{proj}/escape")

    ungated = WireClient(caps=["events"])
    ungated.send_control(
        {"op": "fs_list", "root": proj, "paths": ["."], "seq": 90}
    )
    denied, _ = ungated.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "error"
        and msg.get("code") == "denied"
        and msg.get("re") == 90
    )
    check("files: fs_list without the capability is denied", denied is not None)
    ungated.close()

    fs = WireClient(caps=["files"])
    fs.send_control(
        {"op": "fs_list", "root": proj, "paths": [".", "src", "escape"], "seq": 91}
    )
    listed, _ = fs.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "fs_listed" and msg.get("re") == 91
    )
    by_path = {l["path"]: l for l in (listed[1]["listings"] if listed else [])}
    root_entries = {e["name"]: e for e in by_path.get(".", {}).get("entries", [])}
    check(
        "fs.list: batched paths answer per-path with sorted entries and a seq stamp",
        listed is not None
        and "seq" in listed[1]
        and set(by_path) == {".", "src", "escape"}
        and [e["name"] for e in by_path["."]["entries"]]
        == sorted(e["name"] for e in by_path["."]["entries"])
        and by_path["src"]["entries"][0]["name"] == "lib.rs"
        and by_path["src"]["entries"][0]["kind"] == "file",
    )
    check(
        "fs.list: VCS dirs are unloaded_dir stubs, symlinks carry their target",
        root_entries.get(".git", {}).get("kind") == "unloaded_dir"
        and root_entries.get("escape", {}).get("kind") == "symlink"
        and root_entries.get("escape", {}).get("symlink_target") == "/"
        and root_entries.get("src", {}).get("kind") == "dir",
    )
    check(
        "fs.list: a path escaping the root fails alone, not the batch",
        by_path.get("escape", {}).get("error") is not None
        and by_path.get("src", {}).get("error") is None,
    )

    fs.send_control({"op": "fs_read", "path": f"{proj}/README.md", "seq": 92})
    header, _ = fs.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "fs_file" and msg.get("re") == 92
    )
    body, chunks = recv_file_body(fs, 92)
    check(
        "fs.read: header + flagged F chunks deliver the file",
        header is not None
        and header[1]["size"] == len("file plane preview bytes")
        and header[1]["truncated"] is False
        and body == b"file plane preview bytes",
    )

    fs.send_control(
        {"op": "fs_read", "path": f"{proj}/README.md", "offset": 5, "length": 5, "seq": 93}
    )
    ranged, _ = fs.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "fs_file" and msg.get("re") == 93
    )
    ranged_body, _ = recv_file_body(fs, 93)
    check(
        "fs.read: range windows the file",
        ranged is not None and ranged[1]["offset"] == 5 and ranged_body == b"plane",
    )

    big = f"{proj}/big.bin"
    with open(big, "wb") as f:
        f.write(os.urandom(1024 * 1024 + 4096))
    fs.send_control({"op": "fs_read", "path": big, "seq": 94})
    capped, _ = fs.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "fs_file" and msg.get("re") == 94
    )
    capped_body, capped_chunks = recv_file_body(fs, 94, timeout=8.0)
    check(
        "fs.read: 1 MiB soft cap truncates and says so, chunks stay ≤64 KiB",
        capped is not None
        and capped[1]["truncated"] is True
        and len(capped_body) == 1024 * 1024
        and all(len(c["data"]) <= 64 * 1024 - 17 for c in capped_chunks)
        and sum(1 for c in capped_chunks if c["last"]) == 1,
    )
    fs.close()
    shutil.rmtree(proj, ignore_errors=True)

    print("\n# 12. uploads: credit-of-one chunks, verify, confinement, temp: reap (§C.12)")
    updir = f"{SOCK_DIR}/uploads"
    shutil.rmtree(updir, ignore_errors=True)
    os.makedirs(f"{updir}/assets", exist_ok=True)

    up = WireClient(caps=["upload"])
    body = os.urandom(150_000)
    up.send_control(
        {
            "op": "upload_open",
            "root": updir,
            "dest": "assets/drop.bin",
            "size": len(body),
            "sha256": hashlib.sha256(body).hexdigest(),
            "seq": 100,
        }
    )
    opened, _ = up.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "upload_opened" and msg.get("re") == 100
    )
    upload_id = opened[1]["upload_id"] if opened else None
    check("upload: open returns an upload id", upload_id is not None)

    sent, _ = upload_credit_of_one(up, upload_id, body)
    up.send_control({"op": "upload_commit", "upload_id": upload_id, "seq": 101})
    committed, _ = up.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "upload_committed"
        and msg.get("re") == 101
    )
    landed = committed[1]["path"] if committed else None
    check(
        "upload: credit-of-one chunks land the exact bytes after commit",
        sent == len(body)
        and landed is not None
        and open(landed, "rb").read() == body
        and (os.stat(landed).st_mode & 0o777) == 0o644
        and os.listdir(f"{updir}/assets") == ["drop.bin"],
    )

    up.send_control(
        {
            "op": "upload_open",
            "root": updir,
            "dest": "assets/liar.bin",
            "size": 4,
            "sha256": hashlib.sha256(b"good").hexdigest(),
            "seq": 102,
        }
    )
    lying, _ = up.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "upload_opened" and msg.get("re") == 102
    )
    lying_id = lying[1]["upload_id"]
    send_upload_chunk(up, lying_id, 0, b"evil")
    up.recv_matching(lambda kind, msg: kind == "C" and msg.get("op") == "upload_ack")
    up.send_control({"op": "upload_commit", "upload_id": lying_id, "seq": 103})
    refused, _ = up.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "error" and msg.get("re") == 103
    )
    check(
        "upload: commit verifies sha256 and leaves nothing behind",
        refused is not None
        and "sha256" in refused[1]["message"]
        and not os.path.exists(f"{updir}/assets/liar.bin")
        and os.listdir(f"{updir}/assets") == ["drop.bin"],
    )

    send_upload_chunk(up, "u_nonesuch", 0, b"zz")
    ghost, _ = up.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "error"
    )
    check("upload: a chunk for an unknown id is a typed error", ghost is not None)

    # Resume: the upload outlives the connection that opened it, so a client
    # that lost its link re-opens and is told where the bytes stopped.
    resume_body = os.urandom(200_000)
    resume_open = {
        "op": "upload_open",
        "root": updir,
        "dest": f"assets/resume-{os.getpid()}.bin",
        "size": len(resume_body),
        "sha256": hashlib.sha256(resume_body).hexdigest(),
        "seq": 110,
    }
    dying = WireClient(caps=["upload"])
    dying.send_control(resume_open)
    half, _ = dying.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "upload_opened" and msg.get("re") == 110
    )
    resume_id = half[1]["upload_id"]
    fresh_offset = half[1].get("offset")
    partial, _ = upload_credit_of_one(dying, resume_id, resume_body[:120_000])
    dying.close()

    up.send_control(dict(resume_open, seq=111))
    reopened, _ = up.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "upload_opened" and msg.get("re") == 111
    )
    resumed_at = reopened[1].get("offset") if reopened else None
    check(
        "upload: re-opening resumes at the bytes already landed",
        fresh_offset == 0
        and reopened is not None
        and reopened[1]["upload_id"] == resume_id
        and resumed_at == partial
        and partial > 0,
    )
    upload_credit_of_one(up, resume_id, resume_body, start=resumed_at)
    up.send_control({"op": "upload_commit", "upload_id": resume_id, "seq": 112})
    resume_done, _ = up.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "upload_committed"
        and msg.get("re") == 112
    )
    check(
        "upload: only the tail is re-sent and the whole file still verifies",
        resume_done is not None
        and open(resume_done[1]["path"], "rb").read() == resume_body,
    )

    up.send_control(
        {
            "op": "upload_open",
            "root": updir,
            "dest": "../escape.bin",
            "size": 1,
            "sha256": hashlib.sha256(b"x").hexdigest(),
            "seq": 104,
        }
    )
    escaped, _ = up.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "error" and msg.get("re") == 104
    )
    check(
        "upload: a dest escaping the root is refused at open",
        escaped is not None and not os.path.exists(f"{SOCK_DIR}/escape.bin"),
    )

    paste_session = cli_out("create", "--name", "paste-target", "--", "cat")
    time.sleep(0.2)
    paste = b"fake png bytes"
    up.send_control(
        {
            "op": "upload_open",
            "dest": "temp:paste-1.png",
            "session": paste_session,
            "size": len(paste),
            "sha256": hashlib.sha256(paste).hexdigest(),
            "seq": 105,
        }
    )
    paste_opened, _ = up.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "upload_opened" and msg.get("re") == 105
    )
    paste_id = paste_opened[1]["upload_id"]
    upload_credit_of_one(up, paste_id, paste)
    up.send_control({"op": "upload_commit", "upload_id": paste_id, "seq": 106})
    paste_done, _ = up.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "upload_committed"
        and msg.get("re") == 106
    )
    paste_path = paste_done[1]["path"] if paste_done else None
    check(
        "upload: temp: lands 0600 in the session scratch dir",
        paste_path is not None
        and f"session-{paste_session}" in paste_path
        and open(paste_path, "rb").read() == paste
        and (os.stat(paste_path).st_mode & 0o777) == 0o600,
    )
    cli("kill", paste_session)
    reaped = False
    for _ in range(40):
        if paste_path and not os.path.exists(paste_path):
            reaped = True
            break
        time.sleep(0.1)
    check("upload: the scratch dir is reaped with its session", reaped)
    up.close()
    shutil.rmtree(updir, ignore_errors=True)

    print("\n# 13. fs.match: lazy name index, watcher-kept, coverage-honest (§C.12)")
    matchdir = f"{SOCK_DIR}/matchproj"
    shutil.rmtree(matchdir, ignore_errors=True)
    os.makedirs(f"{matchdir}/src/deep", exist_ok=True)
    os.makedirs(f"{matchdir}/docs", exist_ok=True)
    with open(f"{matchdir}/src/main.rs", "w") as f:
        f.write("fn main() {}\n")
    with open(f"{matchdir}/src/deep/hidden.rs", "w") as f:
        f.write("\n")
    with open(f"{matchdir}/docs/guide.md", "w") as f:
        f.write("# guide\n")

    def fs_match(client, seq, query, limit=10):
        client.send_control(
            {"op": "fs_match", "root": matchdir, "query": query, "limit": limit, "seq": seq}
        )
        reply, _ = client.recv_matching(
            lambda kind, msg: kind == "C"
            and msg.get("op") == "fs_matched"
            and msg.get("re") == seq
        )
        return reply[1] if reply else None

    matcher = WireClient(caps=["files", "resources", "events"])
    unindexed = fs_match(matcher, 110, "main")
    check(
        "fs.match: before any subscribe there is no index — coverage 0.0",
        unindexed is not None
        and unindexed["coverage"] == 0.0
        and unindexed["paths"] == [],
    )

    matcher.send_control(
        {"op": "subscribe_resource", "resource": matchdir, "seq": 111}
    )
    matcher.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "subscribed"
    )
    indexed = None
    seq_counter = [120]
    deadline = time.time() + 6
    while time.time() < deadline:
        seq_counter[0] += 1
        reply = fs_match(matcher, seq_counter[0], "guide")
        if reply and reply["coverage"] == 1.0:
            indexed = reply
            break
        time.sleep(0.1)
    check(
        "fs.match: the first subscribe builds the index to coverage 1.0",
        indexed is not None and indexed["paths"] == ["docs/guide.md"],
    )
    ranked = fs_match(matcher, 130, "rs")
    check(
        "fs.match: fuzzy ranking prefers the shorter basename hit",
        ranked is not None
        and ranked["paths"][:1] == ["src/main.rs"]
        and "src/deep/hidden.rs" in ranked["paths"],
    )

    with open(f"{matchdir}/src/created_later.rs", "w") as f:
        f.write("\n")
    fresh = None
    deadline = time.time() + 6
    while time.time() < deadline:
        seq_counter[0] += 1
        reply = fs_match(matcher, seq_counter[0], "created_later")
        if reply and reply["paths"]:
            fresh = reply
            break
        time.sleep(0.1)
    check(
        "fs.match: the watcher keeps the index incremental",
        fresh is not None and fresh["paths"] == ["src/created_later.rs"],
    )
    matcher.close()
    shutil.rmtree(matchdir, ignore_errors=True)

    print("\n# 14. git: resource kind — status as a subscription, read-only (§C.13)")
    gitproj = f"{SOCK_DIR}/gitproj"
    shutil.rmtree(gitproj, ignore_errors=True)
    os.makedirs(gitproj, exist_ok=True)

    def git(*args):
        return subprocess.run(
            ["git", "-C", gitproj, "-c", "user.email=smoke@termio", "-c", "user.name=smoke", *args],
            capture_output=True,
            text=True,
        )

    git("init", "-q", "-b", "main")
    with open(f"{gitproj}/tracked.txt", "w") as f:
        f.write("line one\n")
    git("add", "tracked.txt")
    git("commit", "-q", "-m", "initial")

    nogit = WireClient(caps=["resources", "events"])
    nogit.send_control(
        {"op": "subscribe_resource", "resource": f"git:{gitproj}", "seq": 140}
    )
    ungated_git, _ = nogit.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "error"
        and msg.get("code") == "denied"
        and msg.get("re") == 140
    )
    check("git: the kind is gated on the git capability", ungated_git is not None)
    nogit.close()

    gw = WireClient(caps=["resources", "git", "events"])
    gw.send_control(
        {"op": "subscribe_resource", "resource": f"git:{gitproj}", "seq": 141}
    )
    gsubscribed, _ = gw.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "subscribed" and msg.get("re") == 141
    )
    first_batch, _ = gw.recv_matching(
        lambda kind, msg: kind == "E" and msg.get("ev") == "git_changed",
        timeout=6.0,
    )
    check(
        "git: subscribe reuses the C.10 shape and the first batch carries branch metadata",
        gsubscribed is not None
        and gsubscribed[1]["resource"].startswith("git:")
        and gsubscribed[1]["gap"] is True
        and first_batch is not None
        and first_batch[1].get("branch") == "main"
        and first_batch[1].get("head")
        and first_batch[1].get("updated_statuses") == [],
    )

    with open(f"{gitproj}/tracked.txt", "a") as f:
        f.write("line two\n")
    dirty, _ = gw.recv_matching(
        lambda kind, msg: kind == "E"
        and msg.get("ev") == "git_changed"
        and any(e["path"] == "tracked.txt" for e in msg.get("updated_statuses", [])),
        timeout=6.0,
    )
    dirty_status = (
        next(e["status"] for e in dirty[1]["updated_statuses"] if e["path"] == "tracked.txt")
        if dirty
        else None
    )
    check(
        "git: a worktree edit publishes the two-axis tracked status",
        dirty is not None
        and dirty_status
        == {"tracked": {"index_status": "unmodified", "worktree_status": "modified"}},
    )
    dirty_seq = dirty[1]["seq"] if dirty else 0

    git("add", "tracked.txt")
    with open(f"{gitproj}/fresh.txt", "w") as f:
        f.write("untracked\n")
    staged_seen = None
    untracked_seen = None
    deadline = time.time() + 8
    while time.time() < deadline and not (staged_seen and untracked_seen):
        got, _ = gw.recv_matching(
            lambda kind, msg: kind == "E" and msg.get("ev") == "git_changed",
            timeout=max(0.1, deadline - time.time()),
        )
        if got is None:
            break
        for entry in got[1].get("updated_statuses", []):
            if entry["path"] == "tracked.txt" and entry["status"] == {
                "tracked": {"index_status": "modified", "worktree_status": "unmodified"}
            }:
                staged_seen = got
            if entry["path"] == "fresh.txt" and entry["status"] == "untracked":
                untracked_seen = got
    check(
        "git: staging and untracked files land in the adopted vocabulary",
        staged_seen is not None and untracked_seen is not None,
    )

    resumer = WireClient(caps=["resources", "git", "events"])
    resumer.send_control(
        {
            "op": "subscribe_resource",
            "resource": f"git:{gitproj}",
            "since": dirty_seq,
            "seq": 142,
        }
    )
    resumed, _ = resumer.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "subscribed" and msg.get("re") == 142
    )
    check(
        "git: a cursor inside the ring resumes without a gap",
        resumed is not None and resumed[1]["gap"] is False,
    )
    resumer.close()

    fresh_client = WireClient(caps=["resources", "git", "events"])
    fresh_client.send_control(
        {"op": "subscribe_resource", "resource": f"git:{gitproj}", "seq": 143}
    )
    fresh_sub, fresh_seen = fresh_client.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "subscribed" and msg.get("re") == 143
    )
    full_state, _ = fresh_client.recv_matching(
        lambda kind, msg: kind == "E" and msg.get("ev") == "git_changed",
        timeout=4.0,
    )
    full_paths = {e["path"] for e in (full_state[1]["updated_statuses"] if full_state else [])}
    check(
        "git: a gap subscriber is served the full state at the current cursor",
        fresh_sub is not None
        and fresh_sub[1]["gap"] is True
        and full_state is not None
        and full_state[1]["seq"] == fresh_sub[1]["seq"]
        and {"tracked.txt", "fresh.txt"} <= full_paths,
    )
    fresh_client.close()

    with open(f"{gitproj}/tracked.txt", "a") as f:
        f.write("line three\n")
    gw.send_control({"op": "git_diff", "root": gitproj, "path": "tracked.txt", "seq": 144})
    unstaged_diff, _ = gw.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "git_diff_result"
        and msg.get("re") == 144
    )
    gw.send_control(
        {"op": "git_diff", "root": gitproj, "path": "tracked.txt", "staged": True, "seq": 145}
    )
    staged_diff, _ = gw.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "git_diff_result"
        and msg.get("re") == 145
    )
    check(
        "git.diff: worktree and staged diffs are distinct unified diffs",
        unstaged_diff is not None
        and "+line three" in unstaged_diff[1]["diff"]
        and unstaged_diff[1]["truncated"] is False
        and staged_diff is not None
        and "+line two" in staged_diff[1]["diff"]
        and "+line three" not in staged_diff[1]["diff"],
    )
    gw.close()
    shutil.rmtree(gitproj, ignore_errors=True)

    print("\n# 15. fs.search: streamed git grep, limit, cancel by request id (§C.12)")
    searchdir = f"{SOCK_DIR}/searchproj"
    shutil.rmtree(searchdir, ignore_errors=True)
    os.makedirs(f"{searchdir}/src", exist_ok=True)

    def sgit(*args):
        return subprocess.run(
            ["git", "-C", searchdir, "-c", "user.email=smoke@termio", "-c", "user.name=smoke", *args],
            capture_output=True,
            text=True,
        )

    sgit("init", "-q", "-b", "main")
    with open(f"{searchdir}/src/lib.rs", "w") as f:
        f.write("fn alpha() {}\n// NEEDLE: in a tracked file\n")
    sgit("add", "-A")
    sgit("commit", "-q", "-m", "content")
    with open(f"{searchdir}/notes.md", "w") as f:
        f.write("NEEDLE appears untracked: here\n")

    def collect_search(client, seq, query, limit=1000, timeout=6.0):
        client.send_control(
            {"op": "fs_search", "root": searchdir, "query": query, "limit": limit, "seq": seq}
        )
        hits, done = [], None
        end = time.time() + timeout
        while time.time() < end and done is None:
            try:
                kind, msg = client.recv_frame(max(0.05, end - time.time()))
            except (socket.timeout, EOFError):
                break
            if kind == "E" and msg.get("ev") == "search_results" and msg.get("request") == seq:
                hits.extend(msg["matches"])
            elif kind == "C" and msg.get("op") in ("fs_searched", "error") and msg.get("re") == seq:
                done = msg
        return hits, done

    searcher = WireClient(caps=["files", "events"])
    hits, done = collect_search(searcher, 150, "NEEDLE")
    by_path = {h["path"] for h in hits}
    check(
        "fs.search: results stream as events, then one terminal reply",
        done is not None
        and done["op"] == "fs_searched"
        and done["matches"] == len(hits) == 2
        and done["limit_hit"] is False
        and done["canceled"] is False
        and by_path == {"src/lib.rs", "notes.md"}
        and all("NEEDLE" in h["text"] and h["line"] >= 1 for h in hits),
    )

    hits, done = collect_search(searcher, 151, "NEEDLE", limit=1)
    check(
        "fs.search: the limit stops the stream and says so",
        done is not None
        and done.get("limit_hit") is True
        and done["matches"] == len(hits) == 1,
    )

    with open(f"{searchdir}/huge.txt", "w") as f:
        for index in range(400_000):
            f.write(f"NEEDLE line {index}\n")
    searcher.send_control(
        {
            "op": "fs_search",
            "root": searchdir,
            "query": "NEEDLE",
            "limit": 10_000_000,
            "seq": 152,
        }
    )
    searcher.send_control({"op": "cancel", "request": 152, "seq": 153})
    cancel_ok = None
    cancel_done = None
    streamed_before_done = 0
    end = time.time() + 10
    while time.time() < end and (cancel_ok is None or cancel_done is None):
        try:
            kind, msg = searcher.recv_frame(max(0.05, end - time.time()))
        except (socket.timeout, EOFError):
            break
        if kind == "C" and msg.get("op") == "ok" and msg.get("re") == 153:
            cancel_ok = msg
        elif kind == "E" and msg.get("ev") == "search_results" and msg.get("request") == 152:
            streamed_before_done += len(msg["matches"])
        elif kind == "C" and msg.get("op") == "fs_searched" and msg.get("re") == 152:
            cancel_done = msg
    trailing = searcher.drain(0.5)
    check(
        "fs.search: cancel by request id ends the stream early",
        cancel_ok is not None
        and cancel_done is not None
        and cancel_done["canceled"] is True
        and cancel_done["matches"] < 400_000
        and all(
            not (kind == "E" and payload.get("ev") == "search_results")
            for kind, payload in trailing
        ),
    )

    searcher.send_control({"op": "cancel", "request": 9999, "seq": 154})
    idempotent, _ = searcher.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "ok" and msg.get("re") == 154
    )
    check("fs.search: cancelling a finished request is ok, not an error", idempotent is not None)
    searcher.close()
    shutil.rmtree(searchdir, ignore_errors=True)

    print()
    if FAILURES:
        print(f"FAILED ({len(FAILURES)}): " + ", ".join(FAILURES))
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        cleanup()
