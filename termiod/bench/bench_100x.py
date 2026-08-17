#!/usr/bin/env python3
"""
Anti-100x benchmark for termiod.

Thesis under test (from docs/design/20260730-termiod-session-protocol.md §C.6):
a session mux that must PARSE every PTY byte into a grid (tmux) throttles the
producer through PTY backpressure; a mux that TEES raw bytes and never parses
on the hot path (termiod) drains at wire speed and never throttles it. So the
"100x" terminal-emulator tax is an architectural property, not a tuning knob.

We flood a fixed payload from a producer whose stdout is a PTY, and measure the
wall-clock for the producer to finish AND all bytes to be consumed, under:

  direct            producer -> PTY -> dumb drain           (no mux; the floor)
  termiod (tee)     producer -> host raw tee -> (no client) (input replication)
  termiod (client)  producer -> host -> socket -> client    (full attach path)
  tmux              producer -> tmux (parses into grid)      (the parse tax)

Two payloads: plain text (conservative — tmux still parses every cell) and
ANSI-heavy (escape sequences stress the VT state machine, closer to Mitchell's
"100x").  Reports median of N runs.
"""

import os, sys, time, subprocess, json, pty, select, tempfile, shutil, statistics

HERE = os.path.dirname(os.path.abspath(__file__))
TERMIOD = os.environ.get("TERMIOD_BIN") or os.path.join(HERE, "..", "target", "release", "termiod")
ROWS, COLS = 50, 200
RUNS = 5


def gen_plain(path, mb):
    line = ("the quick brown fox jumps over the lazy dog 0123456789 " * 2 + "\n").encode()
    target = mb * 1024 * 1024
    with open(path, "wb") as f:
        buf = line * 4096
        written = 0
        while written < target:
            f.write(buf)
            written += len(buf)


def gen_ansi(path, mb):
    # Colored cells + cursor moves + SGR resets: heavy VT-parser work per byte.
    target = mb * 1024 * 1024
    parts = []
    for i in range(200):
        c = 31 + (i % 7)
        parts.append(f"\x1b[{c};1m\x1b[2mword{i:03d}\x1b[0m\x1b[K ".encode())
    row = b"".join(parts) + b"\r\n"
    _fill(path, row, target)


def _truecolor_row():
    # Every cell carries a distinct 24-bit SGR — no run-length coalescing; the
    # parser must apply a full colour state change per glyph (chafa/timg output).
    cells = []
    for i in range(COLS):
        r, g, b = (i * 7) % 256, (i * 13) % 256, (i * 29) % 256
        cells.append(f"\x1b[38;2;{r};{g};{b}m#".encode())
    return b"".join(cells)


def gen_truecolor(path, mb):
    _fill(path, _truecolor_row() + b"\r\n", mb * 1024 * 1024)


def gen_fullscreen(path, mb):
    # A TUI repainting: clear + home, then a full screen of truecolor, per frame.
    # Stresses cursor addressing + overwrite + per-cell colour together.
    row = _truecolor_row()
    frame = b"\x1b[2J\x1b[H" + b"".join(row + b"\r\n" for _ in range(ROWS))
    _fill(path, frame, mb * 1024 * 1024)


def _fill(path, unit, target):
    with open(path, "wb") as f:
        buf = unit * max(1, (1 << 20) // len(unit))
        written = 0
        while written < target:
            f.write(buf)
            written += len(buf)


def drain_fd(fd):
    total = 0
    while True:
        try:
            r, _, _ = select.select([fd], [], [], 5.0)
        except (OSError, ValueError):
            break
        if not r:
            break
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError:
            break
        if not chunk:
            break
        total += len(chunk)
    return total


def run_direct(payload):
    """producer on a real PTY, drained by a Python select-loop to EOF.

    NB: this is a *weak* floor — Python's per-read overhead caps it well below a
    C/Rust drainer, which is why the Rust termiod paths can post a higher MB/s
    than "direct". The load-bearing comparison is termiod-vs-tmux (both external
    processes, identical wall-clock method), plus how each scales with content.
    """
    t0 = time.perf_counter()
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp("cat", ["cat", payload])
        except Exception:
            os._exit(127)
    drain_fd(fd)
    os.waitpid(pid, 0)
    try:
        os.close(fd)
    except OSError:
        pass
    return time.perf_counter() - t0


class Termiod:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="termiod-bench-")
        self.sock = os.path.join(self.dir, "t.sock")
        self.env = {**os.environ, "TERMIOD_SOCK": self.sock}
        self.proc = subprocess.Popen(
            [TERMIOD, "serve"], env=self.env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if os.path.exists(self.sock):
                break
            time.sleep(0.02)

    def cli(self, *args, **kw):
        return subprocess.run([TERMIOD, *args], env=self.env,
                              capture_output=True, text=True, **kw)

    def sessions(self):
        out = self.cli("list", "--json").stdout.strip()
        if not out:
            return []
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            return []
        return data if isinstance(data, list) else data.get("sessions", [])

    def wait_gone(self, name, timeout=120):
        while timeout > 0:
            if not any(s.get("name") == name or s.get("id") == name
                       for s in self.sessions()):
                return
            time.sleep(0.01)
            timeout -= 0.01

    def run_tee(self, payload):
        """Host drains PTY at raw speed; NO client attached (pure tee)."""
        name = f"tee{int(time.perf_counter()*1e6)%100000}"
        t0 = time.perf_counter()
        self.cli("create", "--name", name, "--", "sh", "-lc", f"exec cat {payload}")
        self.wait_gone(name)
        return time.perf_counter() - t0

    def run_client(self, payload):
        """Full path: create+attach, client drains bytes to /dev/null, exits on session exit."""
        name = f"cli{int(time.perf_counter()*1e6)%100000}"
        t0 = time.perf_counter()
        with open(os.devnull, "wb") as null:
            subprocess.run([TERMIOD, "attach", name, "--", "sh", "-lc",
                            f"exec cat {payload}"],
                           env=self.env, stdout=null, stderr=subprocess.DEVNULL)
        self.wait_gone(name)
        return time.perf_counter() - t0

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        shutil.rmtree(self.dir, ignore_errors=True)


def have_tmux():
    return shutil.which("tmux") is not None


def run_tmux(payload):
    """Producer inside a detached tmux server, which parses every byte into its grid."""
    sock = f"bench{int(time.perf_counter()*1e6)%100000}"
    name = "s"
    base = ["tmux", "-L", sock]
    t0 = time.perf_counter()
    subprocess.run(base + ["new-session", "-d", "-x", str(COLS), "-y", str(ROWS),
                           "-s", name, f"cat {payload}"],
                   capture_output=True)
    while True:
        r = subprocess.run(base + ["has-session", "-t", name], capture_output=True)
        if r.returncode != 0:
            break
        time.sleep(0.01)
    dt = time.perf_counter() - t0
    subprocess.run(base + ["kill-server"], capture_output=True)
    return dt


def bench(label, fn, payload, size_bytes):
    times = []
    for _ in range(RUNS):
        times.append(fn(payload))
    med = statistics.median(times)
    mbps = (size_bytes / (1024 * 1024)) / med if med else float("inf")
    return label, med, mbps


# name → (generator, size_mb). Heavy payloads are smaller so tmux's slow parse
# keeps total runtime bounded; throughput is size-independent past fixed cost.
PAYLOADS = [
    ("plain", gen_plain, 100),
    ("ansi", gen_ansi, 100),
    ("truecolor", gen_truecolor, 40),
    ("fullscreen", gen_fullscreen, 40),
]


def main():
    only = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].isdigit() else None
    specs = [(n, g, s) for n, g, s in PAYLOADS if not only or n == only]
    tmp = tempfile.mkdtemp(prefix="bench-payload-")
    paths = {}
    for name, gen, mb in specs:
        p = os.path.join(tmp, f"{name}.bin")
        print(f"generating {name} ({mb} MB)…", flush=True)
        gen(p, mb)
        paths[name] = (p, os.path.getsize(p))

    td = Termiod()
    results, sizes = {}, {}
    try:
        for name, _, mb in specs:
            path, sz = paths[name]
            sizes[name] = mb
            rows = []
            rows.append(bench("direct (python floor)", run_direct, path, sz))
            rows.append(bench("termiod tee (no client)", td.run_tee, path, sz))
            rows.append(bench("termiod client (full path)", td.run_client, path, sz))
            if have_tmux():
                rows.append(bench("tmux (parses grid)", run_tmux, path, sz))
            results[name] = rows
    finally:
        td.close()

    print()
    tee_by_payload, tmux_by_payload = {}, {}
    for pname, rows in results.items():
        base = next((mbps for lbl, _, mbps in rows if lbl.startswith("direct")), None)
        tmux_mbps = next((mbps for lbl, _, mbps in rows if lbl.startswith("tmux")), None)
        tee = next((m for l, _, m in rows if "tee" in l), None)
        tee_by_payload[pname], tmux_by_payload[pname] = tee, tmux_mbps
        print(f"── {pname} payload ({sizes[pname]} MB) [{ROWS}x{COLS}, median of {RUNS}] ──")
        print(f"{'config':<30}{'median s':>12}{'MB/s':>12}{'vs floor':>12}")
        for lbl, med, mbps in rows:
            rel = f"{mbps/base:.2f}x" if base else "—"
            print(f"{lbl:<30}{med:>12.3f}{mbps:>12.1f}{rel:>12}")
        if tee and tmux_mbps:
            print(f"  → termiod tee is {tee/tmux_mbps:.1f}x tmux on the {pname} payload")
        print()

    # The architectural proof: cost that scales with VT-parse complexity is a
    # parser; cost that doesn't is a tee. Compare each mux's plain→ansi drop.
    if {"plain", "ansi"} <= set(tee_by_payload) and all(tmux_by_payload.values()):
        tee_drop = 1 - tee_by_payload["ansi"] / tee_by_payload["plain"]
        tmux_drop = 1 - tmux_by_payload["ansi"] / tmux_by_payload["plain"]
        print("── content-scaling (plain → ANSI-heavy) ──")
        print(f"termiod tee throughput drop: {tee_drop*100:5.1f}%   (tee: content-insensitive)")
        print(f"tmux      throughput drop:   {tmux_drop*100:5.1f}%   (parser: content-sensitive)")
        print("A tee should barely move; a grid-parser should fall. That gap is the thesis.")

    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
