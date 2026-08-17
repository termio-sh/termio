#!/bin/zsh
# Measures how many git subprocesses the running termio-dev app spawns while a
# synthetic agent workload (file appends + `git status` index rewrites + periodic
# commits) hammers a scratch repo the app watches. The regression harness for the
# git-spawn-storm fix: run it against two builds and compare the exact counts.
#
# Exact counting works via GIT_TRACE2_EVENT: set it in the launchd GUI domain
# BEFORE launching the app, so every git the app spawns appends a "start" event
# (with argv) to the trace file. Remember to unset it afterwards:
#
#   launchctl setenv GIT_TRACE2_EVENT /tmp/git-trace.jsonl
#   open <bundle>/termio-dev.app
#   scripts/bench-git-spawns.sh /path/to/scratch-repo 45
#   launchctl unsetenv GIT_TRACE2_EVENT
#   python3 -c 'import json,collections,sys; c=collections.Counter(
#       " ".join(e["argv"][1:4]) for e in map(json.loads, open("/tmp/git-trace.jsonl"))
#       if e.get("event")=="start"); [print(v,k) for k,v in c.most_common(12)]'
#
# The scratch repo must already be one of the app's projects (open it once via
# `open -b sh.termio.app.dev <repo>`), or nothing will be watching it.
zmodload zsh/datetime
set -u
REPO=${1:?usage: bench-git-spawns.sh <scratch-repo> [seconds]}
DURATION=${2:-45}

APP_PID=$(pgrep -f "termio-dev.app/Contents/MacOS/termio" | head -1)
[[ -z "$APP_PID" ]] && { echo "dev app not running"; exit 1; }
echo "app: $(ps -o args= -p "$APP_PID")"

# The trace file counts every traced git, not just the app's — so start each run
# from the current line offset and report the delta, and keep this script's own
# workload out of the trace even when run from a traced shell.
TRACE_FILE=$(launchctl getenv GIT_TRACE2_EVENT 2>/dev/null || true)
trace_start=0
[[ -n "$TRACE_FILE" && -f "$TRACE_FILE" ]] && trace_start=$(wc -l < "$TRACE_FILE")

( # workload: appends + index rewrites + a real commit every ~4s
  unset GIT_TRACE2_EVENT
  cd "$REPO" || exit 1
  i=0
  end=$((EPOCHSECONDS + DURATION))
  while (( EPOCHSECONDS < end )); do
    i=$((i + 1))
    echo "tick $i" >> "$(( i % 5 )).work.txt"
    (( i % 3 == 0 )) && git status --porcelain >/dev/null 2>&1
    (( i % 15 == 0 )) && { git add -A >/dev/null 2>&1; git commit -qm "bench $i" >/dev/null 2>&1; }
    sleep 0.25
  done
) &
WORKLOAD=$!

# coarse sampler alongside the exact trace: git-child sightings + app CPU
ticks=0; hits=0; cpu_total=0
end=$((EPOCHSECONDS + DURATION))
while (( EPOCHSECONDS < end )); do
  n=$(ps -axo ppid=,comm= 2>/dev/null | awk -v p="$APP_PID" '$1==p && $2 ~ /git/' | wc -l)
  hits=$((hits + n))
  cpu=$(ps -o pcpu= -p "$APP_PID" 2>/dev/null | tr -d ' ')
  cpu_total=$(( cpu_total + ${cpu:-0} ))
  ticks=$((ticks + 1))
  sleep 0.06
done
wait $WORKLOAD 2>/dev/null

echo "samples=$ticks git-child-sightings=$hits avg-app-cpu=$(( cpu_total / (ticks > 0 ? ticks : 1) ))%"
if [[ -n "$TRACE_FILE" && -f "$TRACE_FILE" ]]; then
  trace_end=$(wc -l < "$TRACE_FILE")
  echo "trace-lines-this-run=$(( trace_end - trace_start ))  (analyze from line $(( trace_start + 1 )) of $TRACE_FILE)"
fi
