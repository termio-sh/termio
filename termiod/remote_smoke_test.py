#!/usr/bin/env python3
"""Remote-orchestration smoke test for #171/#172 without a real VPS.

A fake `ssh` on PATH runs the remote command *locally* (dropping -t/-o flags),
standing in for the SSH transport. `TERMIOD_REMOTE_BIN` points the `remote`
subcommands at the local binary. This exercises the real orchestration in
`remote.rs` — build the remote command line, capture the created session id
over the "transport", attach over a PTY, and prove the session survives the
"ssh" process going away (the remote analogue of detach ≠ kill) — end to end.

It does NOT test cross-arch scp/install (a Linux binary can't run on macOS);
that path is covered by the cross-compile build + DEPLOY.md manual steps.

Usage: cargo build && python3 remote_smoke_test.py [path/to/termiod]
"""

import json
import os
import pty
import select
import subprocess
import sys
import tempfile
import time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "./target/debug/termiod")
WORK = tempfile.mkdtemp(prefix="termiod-remote-")
FAKE = os.path.join(WORK, "bin")
os.makedirs(FAKE)

# Fake ssh: ignore flags + host, run the last arg as a local shell command.
with open(os.path.join(FAKE, "ssh"), "w") as f:
    f.write('#!/usr/bin/env bash\nargs=("$@")\nexec bash -lc "${args[${#args[@]}-1]}"\n')
os.chmod(os.path.join(FAKE, "ssh"), 0o755)

ENV = dict(
    os.environ,
    PATH=FAKE + os.pathsep + os.environ["PATH"],
    TERMIOD_SOCK=f"{WORK}/termiod.sock",
    TERMIOD_REMOTE_BIN=BIN,
    TERM="xterm-256color",
)

FAILURES = []


def check(name, ok):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        FAILURES.append(name)


def run(*args):
    return subprocess.run([BIN, *args], env=ENV, capture_output=True, text=True)


def sessions():
    # Query the daemon directly (local list) to inspect state.
    out = subprocess.run(
        [BIN, "list", "--json"], env=ENV, capture_output=True, text=True
    ).stdout.strip()
    try:
        return json.loads(out)
    except Exception:
        return []


def spawn_pty(args):
    master, slave = pty.openpty()
    p = subprocess.Popen(
        [BIN, *args], stdin=slave, stdout=slave, stderr=slave, env=ENV, close_fds=True
    )
    os.close(slave)
    return p, master


def read_until(master, needle, timeout=5.0):
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


def cleanup():
    for s in sessions():
        run("kill", s["id"])
    # The temp-socket daemon idles harmlessly; its socket dir is removed below.


def main():
    print("\n# remote over a fake-ssh transport (#171/#172 orchestration)")

    # 1. remote list on an empty host auto-starts the remote daemon.
    r = run("remote", "list", "localhost")
    check("remote list works over ssh transport", r.returncode == 0)

    # 2. remote open: ensure(no-deploy) → create durable session → attach.
    p, m = spawn_pty(
        ["remote", "open", "localhost", "--no-deploy", "--agent", "shell", "--name", "rmt"]
    )
    read_until(m, "attaching")
    read_until(m, "attached to rmt")
    os.write(m, b"PS1=P>; echo REMOTE_MARKER\r")
    check("remote open: session runs and echoes", b"REMOTE_MARKER" in read_until(m, "REMOTE_MARKER"))
    listed = [s for s in sessions() if s["name"] == "rmt"]
    check("remote open: durable session registered", len(listed) == 1)
    pid_before = listed[0]["pid"] if listed else None

    # 3. Detach the transport (Ctrl-\) — the remote analogue of the ssh link
    #    dropping. Session must survive.
    os.write(m, b"\x1c")
    try:
        p.wait(timeout=5)
        clean = True
    except subprocess.TimeoutExpired:
        p.kill()
        clean = False
    check("transport teardown exits the remote client cleanly", clean)
    time.sleep(0.3)
    survivors = [s for s in sessions() if s["name"] == "rmt"]
    check("session survives ssh disconnect (detach ≠ kill)", len(survivors) == 1)

    # 4. remote attach reconnects to the same process.
    p2, m2 = spawn_pty(["remote", "attach", "localhost", "rmt"])
    read_until(m2, "attached to rmt")
    os.write(m2, b"echo REMOTE_AGAIN\r")
    check("remote attach: reconnect works", b"REMOTE_AGAIN" in read_until(m2, "REMOTE_AGAIN"))
    same = [s for s in sessions() if s["name"] == "rmt"]
    check("remote attach: same process (pid unchanged)", bool(same) and same[0]["pid"] == pid_before)
    os.write(m2, b"\x1c")
    p2.wait(timeout=5)

    # 5. remote list shows it in JSON.
    r = run("remote", "list", "localhost", "--json")
    check("remote list --json shows the remote session", '"name": "rmt"' in r.stdout)

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
        import shutil

        shutil.rmtree(WORK, ignore_errors=True)
