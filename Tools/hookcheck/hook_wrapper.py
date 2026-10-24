#!/usr/bin/env python3
"""Test-only PostToolUse / PostToolUseFailure hook for hookcheck.py (ADR-035). Logs the payload Claude Code handed the
hook and the exact answer, so a run shows what the CLI passed in and what came back. Only ever configured through a
per-run `--settings` for a synthetic work dir; never installed anywhere.

  hook_wrapper.py <mode> <log dir> <helper>
  mode: fold (answer with c2d-token-helper) | lossy:<similar|longline|truncate|all> (helper --lossy) | log (observe, answer nothing)
        | garbage (invalid JSON) | badshape (stdout: 42)
"""
import json, os, subprocess, sys, time

mode, logdir, helper = sys.argv[1:4]
payload = sys.stdin.buffer.read()
start = time.perf_counter()
if mode == "fold":
    out = subprocess.run([helper], input=payload, capture_output=True).stdout
elif mode.startswith("lossy:"):
    out = subprocess.run([helper, "--lossy", mode.split(":", 1)[1]], input=payload, capture_output=True).stdout
elif mode == "garbage":
    out = b"{not json"
elif mode == "badshape":
    out = json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": {"stdout": 42}}}).encode()
else:
    out = b""
elapsed_ms = (time.perf_counter() - start) * 1000
try:
    parsed = json.loads(payload)
except ValueError:
    parsed = None
os.makedirs(logdir, exist_ok=True)
entry = {"mode": mode, "payload": parsed, "payloadBytes": len(payload), "response": out.decode("utf-8", "replace"), "hookMs": round(elapsed_ms, 2)}
name = os.path.join(logdir, f"{time.time_ns()}-{os.getpid()}.json")
with open(name + ".tmp", "w") as f:
    json.dump(entry, f)
os.replace(name + ".tmp", name)   # atomic: a reader never sees half an entry
sys.stdout.buffer.write(out)
