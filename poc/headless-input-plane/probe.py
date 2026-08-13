#!/usr/bin/env python3
"""Proof of concept: a structured input plane, and the handoff back to a TUI.

The question this answers is not "can Claude run headless" — it can. It is
whether termio could take a Happy-shaped route without giving up the terminal:

  1. drive a session with **structured input** (stream-json in and out), so a
     prompt is a message with an acknowledgement instead of keystrokes typed at
     a screen that may not be listening;
  2. hand that same session to a real TUI on the Mac with `--resume`, so the
     terminal stays the interface whenever the user wants it;
  3. leave behind a transcript the existing content plane can already read,
     which decides whether the chat lens works over headless for free.

Run:  python3 probe.py            (adds ~1 cheap Claude turn)
      python3 probe.py --keep     (leave the scratch dir for inspection)

Everything happens in a scratch directory, never in a real repo: the point is
the runtime's behaviour, and an agent with tool access pointed at your worktree
is not a controlled experiment.
"""
import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

PROMPT = "Reply with exactly the word: pong"
RESUME_SETTLE_SECONDS = 8


def claude_project_dir(cwd: str) -> str:
    """Where Claude Code keeps a directory's transcripts.

    Note for whoever wires this up: Claude flattens `_` to `-` as well as `/`,
    so `/tmp/my_project` lands in `-tmp-my-project`. Constructing this path by
    hand is how you end up reporting "no transcript" for a session that has
    one — which is why termio discovers transcripts by scanning rather than by
    building the path.
    """
    encoded = os.path.realpath(cwd).replace("/", "-").replace("_", "-")
    return os.path.expanduser(f"~/.claude/projects/{encoded}")


def step_headless(cwd: str, session_id: str) -> dict:
    """Drive one turn over stream-json and report what came back."""
    process = subprocess.Popen(
        ["claude", "--print", "--input-format", "stream-json",
         "--output-format", "stream-json", "--verbose",
         "--session-id", session_id],
        cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, bufsize=1)

    request = {
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": PROMPT}]},
    }
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    process.stdin.close()

    events, reply = [], ""
    for line in process.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        events.append(event)
        kind = event.get("type")
        print(f"    event: {kind}"
              + (f"/{event.get('subtype')}" if event.get("subtype") else ""))
        if kind == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "text":
                    reply += block.get("text", "")
        if kind == "result":
            reply = reply or event.get("result", "")

    process.wait(timeout=120)
    stderr = process.stderr.read()
    return {"events": events, "reply": reply.strip(), "stderr": stderr.strip(),
            "exit": process.returncode}


def step_resume_in_tui(cwd: str, session_id: str) -> str:
    """Reopen the same conversation as a real TUI on a PTY, the way termio
    spawns every agent, and capture what it paints."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ["TERM"] = "xterm-256color"
        os.execvp("claude", ["claude", "--resume", session_id])
        os._exit(1)

    screen = b""
    deadline = time.time() + RESUME_SETTLE_SECONDS
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        screen += chunk

    os.close(fd)
    try:
        os.kill(pid, 15)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
    return screen.decode("utf8", "replace")


def main() -> int:
    keep = "--keep" in sys.argv
    if not shutil.which("claude"):
        print("claude is not on PATH")
        return 1

    cwd = tempfile.mkdtemp(prefix="termio-headless-poc-")
    session_id = str(uuid.uuid4())
    print(f"scratch dir : {cwd}")
    print(f"session id  : {session_id}\n")

    print("1. headless turn over stream-json")
    headless = step_headless(cwd, session_id)
    if headless["exit"] != 0:
        print(f"   FAILED (exit {headless['exit']}): {headless['stderr'][:400]}")
        return 1
    print(f"   reply: {headless['reply']!r}")
    print(f"   {len(headless['events'])} structured events, no PTY involved\n")

    print("2. transcript left on disk")
    path = os.path.join(claude_project_dir(cwd), f"{session_id}.jsonl")
    transcript_exists = os.path.exists(path)
    print(f"   {path}")
    print(f"   exists: {transcript_exists}"
          + (f", {os.path.getsize(path)} bytes" if transcript_exists else ""))
    if transcript_exists:
        fixture = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "headless-transcript.jsonl")
        shutil.copyfile(path, fixture)
        print(f"   copied to {os.path.basename(fixture)} (normalizer fixture)\n")

    print("3. handoff: same session id, reopened as a TUI on a PTY")
    screen = step_resume_in_tui(cwd, session_id)
    carried = "pong" in screen.lower()
    alt_screen = "\x1b[?1049h" in screen
    print(f"   TUI painted: {alt_screen} ({len(screen)} bytes)")
    print(f"   prior turn visible in the resumed TUI: {carried}\n")

    print("verdict")
    print(f"  structured input answered      : {bool(headless['reply'])}")
    print(f"  transcript readable afterwards : {transcript_exists}")
    print(f"  conversation survived handoff  : {carried}")

    if keep:
        print(f"\nscratch dir kept: {cwd}")
    else:
        shutil.rmtree(cwd, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
