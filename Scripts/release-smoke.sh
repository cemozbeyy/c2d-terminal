#!/bin/zsh
# Safe runtime smoke test for a built Release app (ADR-039 audit, 2026-11-02).
#
#   ./Scripts/release-smoke.sh [path/to/C2DTerminal.app]     (default build/release/C2DTerminal.app)
#
# What it proves: the hardened-runtime Release app launches, opens a never-seen project, spawns a real shell on a
# PTY (posix_openpt + posix_spawn, no entitlements), and leaves no orphan shell behind when quit.
# How it stays safe next to a running C2D Terminal: the test instance is launched with `open -n`, its PID is resolved
# from LaunchServices by the EXACT bundle path, the executable path is re-checked before every kill, and only that PID
# is ever signalled. Nothing is matched by name or pattern. The instance shares ~/Library/Application Support with the
# real app (no override exists), so the scratch project appears in Projects afterwards — remove it there.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-build/release/C2DTerminal.app}; APP=$(cd "$APP" && pwd)
EXE="$APP/Contents/MacOS/C2DTerminal"
[[ -x $EXE ]] || { echo "no app at $APP" >&2; exit 1; }
SCRATCH=$(mktemp -d); PROJ="$SCRATCH/c2d-smoke-project"; mkdir -p "$PROJ"; echo "# smoke" > "$PROJ/README.md"

pid_by_path() {   # LaunchServices → pid of the instance whose bundle is exactly $APP
  lsappinfo list | grep -B2 -A8 "\"$APP/" | grep -oE 'pid = *[0-9]+' | grep -oE '[0-9]+' | head -1
}
verified_kill() {  # kill $1 only if its executable path is our test app
  local p=$1
  [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == "$EXE" ]] || { echo "refusing to kill $p: not $EXE" >&2; return 1; }
  kill "$p"
}

echo "== launching $APP with project $PROJ"
open -n "$APP" --args -c2dOpenProject "$PROJ"
PID=""; for i in {1..30}; do PID=$(pid_by_path); [[ -n $PID ]] && break; sleep 1; done
[[ -n $PID ]] || { echo "FAIL: app did not register with LaunchServices" >&2; exit 1; }
echo "   pid $PID ($(ps -o comm= -p "$PID"))"
trap 'verified_kill "$PID" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

SHELL_PID=""; for i in {1..20}; do SHELL_PID=$(pgrep -P "$PID" -x zsh | head -1 || true); [[ -n $SHELL_PID ]] && break; sleep 1; done
PTYS=$(lsof -p "$PID" 2>/dev/null | grep -cE '/dev/ptmx' || true)
FLAGS=$(codesign -dv "$APP" 2>&1 | grep -o 'flags=[^ ]*')
echo "   signature $FLAGS"
if [[ -n $SHELL_PID && $PTYS -gt 0 ]]; then
  echo "   PASS: zsh $SHELL_PID is a child of $PID on $(ps -o tty= -p "$SHELL_PID"), $PTYS PTY master fd(s) open"
else
  echo "   FAIL: no shell child (zsh='$SHELL_PID') or no PTY ($PTYS)"; exit 1
fi

echo "== quitting $PID (path verified)"
verified_kill "$PID"; trap 'rm -rf "$SCRATCH"' EXIT
for i in {1..10}; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$SHELL_PID" 2>/dev/null; then echo "   FAIL: shell $SHELL_PID survived the app" >&2; exit 1; fi
echo "   PASS: app exited, shell gone, no orphans"
echo "== manual follow-up (owner): open the app, type a command in the shell, start an agent — see docs/RELEASE_RUNBOOK.md"
