#!/usr/bin/env python3
"""Contract harness: the Rust `termio` client against `scripts/termio`.

The frozen contract is what a script or an agent can depend on: the request
bytes the client puts on the wire, the reply it renders on stdout, and its exit
code. Those three are diffed against the shell client, and any divergence fails
the run.

Help text and error wording are deliberately NOT diffed. The Rust client parses
argv with clap, so it renders clap's help and clap's parse errors, and it exits
2 on a usage error where the shell client exited 1. That divergence is the
point: the shell client matched exact flag strings in a `case`, so it swallowed
any unrecognized `--flag` into the payload and never understood `--flag=value`.
Freezing its stderr would freeze those defects. Usage errors are instead
asserted on the property that matters — a non-zero exit, and nothing sent to
the app.

The mock lives under a short /private/tmp home because AF_UNIX paths cap at
104 bytes, and /private/tmp (not /tmp) keeps $PWD logical-path semantics
identical between sh and the Rust client.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "termio")
RUST = os.environ.get(
    "TERMIO_CLI_TEST_BIN",
    os.path.join(REPO, "termiod", "target", "debug", "termio"),
)

HOME = f"/private/tmp/termio-compat-{os.getpid()}"
SOCK_DIR = os.path.join(HOME, "Library/Application Support/termio")
SOCK = os.path.join(SOCK_DIR, "app.sock")
# The name the app bound before it was named for its binder. Both clients fall back
# to it so a checkout CLI can drive an older app; they must agree on when.
LEGACY_SOCK = os.path.join(SOCK_DIR, "session-control.sock")

failures = []
passes = 0


def check(name, condition, detail=""):
    global passes
    if condition:
        passes += 1
        print(f"  [PASS] {name}")
    else:
        failures.append(name)
        print(f"  [FAIL] {name}\n{detail}")


class MockApp:
    """One listener; each connection reads a request, replies from a queue."""

    def __init__(self, replies, hold=False):
        os.makedirs(SOCK_DIR, exist_ok=True)
        if os.path.exists(SOCK):
            os.unlink(SOCK)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(SOCK)
        self.server.listen(8)
        self.replies = list(replies)
        self.hold = hold
        self.requests = []
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            connection.settimeout(3)
            data = b""
            while True:
                if data:
                    try:
                        json.loads(data)
                        break
                    except ValueError:
                        pass
                try:
                    chunk = connection.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                data += chunk
            self.requests.append(data)
            if self.hold:
                time.sleep(3)
                connection.close()
                continue
            reply = self.replies.pop(0) if self.replies else b'{"ok":true}'
            try:
                connection.sendall(reply)
            except OSError:
                pass
            connection.close()

    def close(self):
        self.server.close()
        if os.path.exists(SOCK):
            os.unlink(SOCK)


def run(client, args, env_extra=None):
    env = {
        "HOME": HOME,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "PWD": HOME,
        "TERMIO_SESSION": "TEST-SESSION",
        # A dead daemon socket: the Rust client answers `read` from a local
        # daemon when one owns the target, and this harness diffs the
        # app-socket halves — so pin the daemon side to a path nothing serves
        # for both clients alike.
        "TERMIOD_SOCK": os.path.join(HOME, "no-daemon.sock"),
    }
    if env_extra:
        env.update(env_extra)
    completed = subprocess.run(
        [client] + args, env=env, cwd=HOME, capture_output=True, text=True, timeout=30
    )
    return completed.returncode, completed.stdout, completed.stderr


def compare(name, args, replies=None, env_extra=None, hold=False, no_server=False,
            expect_script=None):
    """Run both clients; diff request bytes, stdout, and exit code.

    stderr is the Rust client's own — see the module docstring.
    """
    surfaces = []
    # `expect_script` spells the same command the way the shell client had to be
    # told it, so a form only the Rust client accepts is still held to the same
    # wire bytes.
    for client, client_args in ((SCRIPT, expect_script or args), (RUST, args)):
        mock = None if no_server else MockApp(replies or [b'{"ok":true}'], hold=hold)
        code, out, err = run(client, client_args, env_extra)
        requests = [] if mock is None else list(mock.requests)
        if mock:
            mock.close()
        surfaces.append((code, out, err, requests))
    (s_code, s_out, s_err, s_req), (r_code, r_out, r_err, r_req) = surfaces
    detail = (
        f"    exit: script={s_code} rust={r_code}\n"
        f"    stdout: script={s_out!r}\n            rust={r_out!r}\n"
        f"    stderr: script={s_err!r}\n            rust={r_err!r}\n"
        f"    requests: script={s_req!r}\n              rust={r_req!r}"
    )
    check(
        name,
        (s_code, s_out, s_req) == (r_code, r_out, r_req),
        detail,
    )


def rejects(name, args, env_extra=None):
    """The Rust client refuses this itself: non-zero exit, nothing on the wire.

    The exact code and wording are clap's, not the shell client's; what the
    contract needs is that a malformed command never reaches the app.
    """
    mock = MockApp([b'{"ok":true}'])
    code, out, err = run(RUST, args, env_extra)
    requests = list(mock.requests)
    mock.close()
    check(
        name,
        code != 0 and out == "" and requests == [],
        f"    exit={code} stdout={out!r} stderr={err!r} requests={requests!r}",
    )


def diagnoses(name, args, needle):
    """With no app running at all, argv is still diagnosed first.

    The socket check happens only once the command is known to be well formed,
    so a malformed one reports itself rather than reporting that the app is
    down.
    """
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    code, out, err = run(RUST, args)
    check(
        name,
        code != 0 and needle in err,
        f"    exit={code} needle={needle!r} stderr={err!r}",
    )


def helps(name, args, needle, usage=None):
    """`--help` reaches stdout, exits 0, and still carries the verb's prose.

    `usage` additionally pins the rendered usage line. The prose alone is too
    weak a check on its own: it would still pass if the verb lost its arguments
    or its name, which is the one part of help a caller actually copies.
    """
    code, out, err = run(RUST, args)
    ok = code == 0 and needle in out and err == ""
    if usage is not None:
        ok = ok and usage in out
    check(
        name,
        ok,
        f"    exit={code} needle={needle!r} usage={usage!r} stdout={out!r} stderr={err!r}",
    )


def main():
    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(SOCK_DIR)
    if not os.path.exists(RUST):
        print(f"missing rust client at {RUST}; cargo build first", file=sys.stderr)
        return 2

    ok = b'{"ok":true,"schema_version":1,"sessions":[]}'
    err = b'{"error":"no_scope","message":"Couldn\xe2\x80\x99t tell.","ok":false,"schema_version":1}'

    print("== requests and replies ==")
    compare("list text", ["sessions", "list"], [ok])
    compare("list json", ["sessions", "list", "--json"], [ok])
    compare("list default op", ["sessions"], [ok])
    compare("error reply exits 1", ["sessions", "list", "--json"], [err])
    compare("text error prefix exits 1", ["sessions", "list"], [b"error: nope\n"])
    compare("send to target", ["sessions", "send", "8de0b387", "hello", "world"], [ok])
    compare("send full link", ["sessions", "send", "termio://session/8de0b387-485a-4016-8990-cbcbfff03199", "hi"], [ok])
    compare("send no-enter with key", ["sessions", "send", "8de0b387", "t", "--no-enter", "--key", "escape", "--key", "enter"], [ok])
    compare("send no target aliases spawn", ["sessions", "send", "fix", "the", "build"], [ok])
    compare("send 7-hex token is text", ["sessions", "send", "deadbee", "tail"], [ok])
    compare("answer", ["sessions", "answer", "8de0b387", "yes"], [ok])
    compare("spawn with placement", ["sessions", "spawn", "fix it", "--agent", "codex", "--direction", "down", "--ratio", "0.25"], [ok])
    compare("run", ["sessions", "run", "pnpm dev", "--direction", "right"], [ok])
    compare("read with lines", ["sessions", "read", "8de0b387", "--lines", "12"], [ok])
    compare("focus", ["sessions", "focus", "8de0b387"], [ok])
    compare("close two targets", ["sessions", "close", "8de0b387", "deadbeef"], [ok, ok])
    compare("close second fails", ["sessions", "close", "8de0b387", "deadbeef"], [ok, err])
    compare("notify", ["notify", "tests", "passed"], [ok])
    compare("trailing newline eaten", ["sessions", "spawn", "hello\n"], [ok])
    compare("interior newline survives", ["sessions", "spawn", "a\nb"], [ok])
    compare("two trailing newlines keep one", ["sessions", "spawn", "a\n\n"], [ok])
    compare("close splits one argument", ["sessions", "close", "one two"], [ok, ok])
    compare("close whitespace-only argument", ["sessions", "close", "  "], [ok])
    compare("send text then address is all text", ["sessions", "send", "fix", "8de0b387aa", "please"], [ok])
    compare("json after positionals", ["sessions", "send", "8de0b387", "hi", "--json"], [ok])
    compare("ok-false inside text reply", ["sessions", "list"], [b'something "ok":false something\n'])
    compare("notify with title", ["notify", "--title", "ci", "done", "--json"], [ok])

    print("== --wait ==")
    waited = b'{"ok":true,"status":"done","timed_out":false}'
    timed = b'{"ok":true,"status":"working","timed_out":true}'
    compare("wait settled", ["sessions", "send", "8de0b387", "go", "--wait", "--timeout", "5000", "--json"], [waited])
    compare("wait timeout exits 3 json", ["sessions", "send", "8de0b387", "go", "--wait", "--timeout", "5000", "--json"], [timed])
    compare("wait timeout exits 3 text", ["sessions", "spawn", "go", "--wait"], [b"working \xe2\x80\x94 timed out after 300s\ndetail\n"])
    compare("wait timeout marker on later line", ["sessions", "spawn", "go", "--wait"], [b"working\nlater \xe2\x80\x94 timed out\n"])

    print("== watch ==")
    stream = b'{"snapshot":true,"session":"a"}\n{"session":"a","status":"done"}\n'
    compare("watch stream then eof", ["sessions", "watch", "--json"], [stream])
    compare("watch error first line", ["sessions", "watch"], [b'error: control disabled\n'])
    compare("watch no-snapshot state filter", ["sessions", "watch", "--state", "done,stalled", "--no-snapshot", "--json"], [stream])
    compare("watch unterminated final line", ["sessions", "watch", "--json"], [b'{"snapshot":true}\n{"session":"a","status":"done"}'])
    compare("watch unterminated first line", ["sessions", "watch", "--json"], [b'{"snapshot":true}'])

    print("== validation: refused before the app hears about it ==")
    for name, args in [
        ("spawn empty", ["sessions", "spawn"]),
        ("spawn terminal refused", ["sessions", "spawn", "x", "--agent", "terminal"]),
        ("spawn Shell refused", ["sessions", "spawn", "x", "--agent", "Shell"]),
        ("run empty", ["sessions", "run"]),
        ("send empty", ["sessions", "send"]),
        ("read no target", ["sessions", "read"]),
        ("answer no target", ["sessions", "answer"]),
        ("focus no target", ["sessions", "focus"]),
        ("close no target", ["sessions", "close"]),
        ("ratio bare5", ["sessions", "spawn", "x", "--ratio", ".5"]),
        ("ratio trailing dot", ["sessions", "spawn", "x", "--ratio", "0."]),
        ("ratio percent", ["sessions", "spawn", "x", "--ratio", "50%"]),
        ("direction bad", ["sessions", "spawn", "x", "--direction", "left"]),
        ("timeout not ms", ["sessions", "send", "8de0b387", "x", "--timeout", "5s"]),
        ("timeout leading plus", ["sessions", "send", "8de0b387", "x", "--timeout", "+5"]),
        ("timeout negative", ["sessions", "send", "8de0b387", "x", "--timeout", "-5"]),
        ("lines not number", ["sessions", "read", "8de0b387", "--lines", "two"]),
        ("wait on list", ["sessions", "list", "--wait"]),
        ("placement on send", ["sessions", "send", "8de0b387", "x", "--direction", "down"]),
        ("no-enter on spawn", ["sessions", "spawn", "x", "--no-enter"]),
        ("no-enter without target", ["sessions", "send", "x", "--no-enter"]),
        ("key without target", ["sessions", "send", "x", "--key", "escape"]),
        ("key missing value", ["sessions", "send", "8de0b387", "--key"]),
        ("agent missing value", ["sessions", "spawn", "x", "--agent"]),
        ("state missing value", ["sessions", "watch", "--state"]),
        ("title missing value", ["notify", "--title"]),
        ("notify empty", ["notify"]),
        ("unknown sessions cmd", ["sessions", "bogus"]),
        # The two defects this port exists to close: the shell client swallowed
        # both into the payload and exited 0.
        ("unknown flag refused", ["sessions", "spawn", "hi", "--agnet", "codex"]),
        ("unknown flag on notify", ["notify", "hi", "--bogus"]),
        ("unknown flag on read", ["sessions", "read", "8de0b387", "--bogus"]),
    ]:
        rejects(name, args)

    print("== parsing shapes the shell client never had ==")
    compare("eq-form flag", ["sessions", "read", "8de0b387", "--lines=12"], [ok],
            expect_script=["sessions", "read", "8de0b387", "--lines", "12"])
    compare("eq-form on spawn", ["sessions", "spawn", "x", "--agent=codex"], [ok],
            expect_script=["sessions", "spawn", "x", "--agent", "codex"])
    # A payload that genuinely starts with `--` stays expressible after `--`.
    compare("dash-dash payload", ["sessions", "send", "8de0b387", "--", "--force"], [ok],
            expect_script=["sessions", "send", "8de0b387", "--force"])

    print("== error taxonomy ==")
    compare("no socket at all", ["sessions", "list"], no_server=True)
    # Reversed from the shell client on purpose: argv is now diagnosed before
    # the app is contacted, so a malformed flag reports itself rather than
    # reporting that the app is down.
    rejects("flag validation before socket error", ["sessions", "spawn", "x", "--ratio", "bad"])
    diagnoses("parse error beats socket error", ["sessions", "spawn", "x", "--ratio", "bad"],
              "invalid value")
    diagnoses("spawn/run split beats socket error", ["sessions", "spawn", "x", "--agent", "terminal"],
              "spawn starts agents")
    diagnoses("no-enter target beats socket error", ["sessions", "send", "x", "--no-enter"],
              "needs a session to send to")
    diagnoses("key target beats socket error", ["sessions", "send", "x", "--key", "escape"],
              "needs a session to press it in")
    compare("notify no socket", ["notify", "hi"], no_server=True)
    # A plain file where the socket should be: the -S pre-check refuses.
    with open(SOCK, "w") as handle:
        handle.write("")
    compare("socket is a plain file", ["sessions", "list"], no_server=True)
    os.unlink(SOCK)
    # An app older than the socket rename: both clients fall back to the name it
    # binds, and both must name the same path when what sits there is not a socket.
    legacy = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    legacy.bind(LEGACY_SOCK)
    legacy.close()
    compare("falls back to the pre-rename socket", ["sessions", "list"], no_server=True)
    os.unlink(LEGACY_SOCK)
    with open(LEGACY_SOCK, "w") as handle:
        handle.write("")
    compare("pre-rename plain file is not an older app", ["sessions", "list"], no_server=True)
    os.unlink(LEGACY_SOCK)
    # A socket file whose listener is gone: connect refused.
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(SOCK)
    stale.close()
    compare("stale socket refused", ["sessions", "list"], no_server=True)
    os.unlink(SOCK)
    compare(
        "silent app times out",
        ["sessions", "list"],
        hold=True,
        env_extra={"TERMIO_CLI_TIMEOUT": "1"},
    )

    print("== agent report ==")
    compare("report outside session", ["agent", "report", "done"], no_server=True)
    compare("report outside session reply", ["agent", "report", "done", "--reply"], no_server=True)
    rejects("report no state", ["agent", "report"])
    rejects("report unknown flag", ["agent", "report", "done", "--bogus"])
    rejects("report unknown state", ["agent", "report", "sleeping"])
    rejects("unknown agent cmd", ["agent", "bogus"])
    # With a session id and a recorder daemon, the exec'd argv is the contract
    # the daemon parses. It is asserted directly rather than against the shell
    # client: the script expanded its accumulated flag string unquoted, so
    # `--tool-from "tool name"` reached `set-status` as two arguments and was
    # rejected there as an unexpected positional. The Rust client forwards the
    # value as one argv item.
    recorder = os.path.join(HOME, "record-termiod")
    argv_log = os.path.join(HOME, "argv")
    with open(recorder, "w") as handle:
        handle.write(f'#!/bin/sh\nprintf \'%s\\n\' "$@" > "{argv_log}"\n')
    os.chmod(recorder, 0o755)
    if os.path.exists(argv_log):
        os.unlink(argv_log)
    code, out, err = run(
        RUST,
        ["agent", "report", "working", "--transcript", "--tool-from", "tool name", "--reply"],
        {"TERMIOD_SESSION_ID": "S1", "TERMIOD_BIN": recorder},
    )
    argv = open(argv_log).read().splitlines() if os.path.exists(argv_log) else []
    check(
        "report execs set-status with the value intact",
        argv == ["set-status", "S1", "working", "--transcript", "--tool-from", "tool name", "--reply"],
        f"    exit={code} argv={argv!r} stderr={err!r}",
    )

    print("== remote passthrough ==")
    # `remote` is an argv passthrough: its help belongs to the daemon, so
    # `--help` must reach the exec'd binary rather than being claimed by the
    # client's own parser.
    for name, args, expected in [
        ("remote help reaches the daemon", ["remote", "--help"], ["remote", "--help"]),
        ("remote -h reaches the daemon", ["remote", "-h"], ["remote", "-h"]),
        ("remote flags pass through", ["remote", "deploy", "--host", "box"],
         ["remote", "deploy", "--host", "box"]),
        # clap claims the first `--` after a subcommand as its own
        # end-of-options marker. For a passthrough that marker is the daemon's
        # argument, not ours.
        ("remote keeps a leading separator", ["remote", "--", "deploy"],
         ["remote", "--", "deploy"]),
        ("remote keeps a later separator", ["remote", "deploy", "--", "--host", "box"],
         ["remote", "deploy", "--", "--host", "box"]),
    ]:
        if os.path.exists(argv_log):
            os.unlink(argv_log)
        code, out, err = run(RUST, args, {"TERMIOD_BIN": recorder})
        argv = open(argv_log).read().splitlines() if os.path.exists(argv_log) else []
        check(name, argv == expected, f"    argv={argv!r} want={expected!r} stderr={err!r}")

    print("== help ==")
    # The per-verb prose is the shell client's, carried as clap `long_about`;
    # the frame around it (Usage, Options) is clap's. Assert the prose, not the
    # frame.
    for name, args, needle, usage in [
        ("usage", ["--help"], "sessions", "Usage: termio"),
        ("usage via help", ["help"], "sessions", "Usage: termio"),
        ("sessions usage", ["sessions", "--help"], "spawn", "Usage: termio sessions"),
        ("list help", ["sessions", "list", "--help"], "live status",
         "Usage: termio sessions list"),
        ("watch help", ["sessions", "watch", "--help"], "unattended-runaway pattern",
         "Usage: termio sessions watch"),
        ("spawn help", ["sessions", "spawn", "--help"], "prompt_undelivered",
         "Usage: termio sessions spawn"),
        ("run help", ["sessions", "run", "--help"], "no LLM involved",
         "Usage: termio sessions run"),
        ("send help", ["sessions", "send", "--help"], "application mode",
         "Usage: termio sessions send"),
        ("answer help", ["sessions", "answer", "--help"], "application mode",
         "Usage: termio sessions answer"),
        ("read help", ["sessions", "read", "--help"], "Scrollback is not included",
         "Usage: termio sessions read [OPTIONS] <SESSION>"),
        ("close help", ["sessions", "close", "--help"], "its own attempt and reply",
         "Usage: termio sessions close [OPTIONS] <SESSION>..."),
        ("focus help", ["sessions", "focus", "--help"], "bring termio to the front",
         "Usage: termio sessions focus [OPTIONS] <SESSION>"),
        ("notify help", ["notify", "--help"], "need a decision",
         "Usage: termio notify"),
        ("version flag names the channel", ["--version"], "(release)", None),
    ]:
        helps(name, args, needle, usage)

    print("== open ==")
    compare("not a directory", ["/nonexistent-dir"], no_server=True)
    compare("open not a directory", ["open", "/nonexistent-dir"], no_server=True)

    shutil.rmtree(HOME, ignore_errors=True)
    print()
    if failures:
        print(f"{passes} passed, {len(failures)} FAILED: {failures}")
        return 1
    print(f"ALL {passes} CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
