#!/usr/bin/env python3
"""End-to-end check and release gate for the Token Saver PostToolUse fold (ADR-035). Run BY HAND.

Without --run / --gate it only prints the plan and calls no model. --run and --gate call `claude -p` (SPENDS MODEL USAGE)
and ask you to type SPEND first. Everything happens in fresh temporary work dirs with synthetic files; the hook is passed
with a per-run `--settings` (no allow rule, nothing written to any settings file); the only tool permission is a per-run
`--allowedTools` for the exact synthetic commands. Global settings and RTK are untouched.

  python3 hookcheck.py                         # plan: integration cases, no model call
  python3 hookcheck.py --self-test             # offline: wrapper + helper + expansion on synthetic payloads
  python3 hookcheck.py --run --model claude-haiku-5-5                 # integration cases (7 calls)
  python3 hookcheck.py --gate --model claude-haiku-5-5 --reps 3      # release gate (tasks x {baseline, fold} x reps)
  python3 hookcheck.py --evaluate <run dir>    # re-evaluate a finished run, no model call

What is measured and how:
  delivered      hook log: the stdout the CLI handed the hook, and the replacement it accepted (fold arm)
  model saw      the model quotes the first line of the tool result; transcript tool_result checked too
  usage          provider-reported, from Claude Code's transcript of the row's private work dir (paired_experiment rules)
  hook latency   wall clock of the hook command, measured inside the wrapper (excludes the CLI's own spawn cost)
  success        the task's check; nothing else about the answer is judged
"""
import argparse, json, os, random, re, shutil, statistics, subprocess, sys, tempfile, time, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "Tools" / "experiment"))
from paired_experiment import Unavailable, claude_home, usage_for_workdir, USAGE_KEYS  # noqa: E402

HEADER = '[c2d: lossless fold; under a "path:" line, "  N:…" means "path:N:…"; repeat counts are exact]'
DEFAULT_HELPER = ROOT / "Packages/C2DCore/.build/release/c2d-token-helper"
GEN = """#!/bin/sh
# Synthetic grep -n style rows: gen.sh <rows> <exit status>
i=1
while [ "$i" -le "$1" ]; do printf 'src/mod%d.swift:%d:    let value%d = compute(%d)\\n' $((i / 500)) "$i" "$i" "$i"; i=$((i + 1)); done
exit "${2:-0}"
"""
RAW_FIRST = "src/mod0.swift:1:    let value1 = compute(1)"

# id, command, mode, rows (for the expected output), what it shows
CASES = [
    ("fold", "sh gen.sh 40 0", "fold", 40, "replacement reaches the model; every other field intact"),
    ("large", "sh gen.sh 4000 0", "fold", 4000, "full stdout or a persisted preview in the payload (~180 KB)"),
    ("failure", "sh gen.sh 40 3", "fold", 40, "non-zero exit: PostToolUseFailure, original output reaches the model"),
    ("garbage", "sh gen.sh 40 0", "garbage", 40, "invalid hook JSON: original output reaches the model"),
    ("badshape", "sh gen.sh 40 0", "badshape", 40, "replacement with the wrong shape: original output reaches the model"),
    ("rtk-1", "grep -rn value data.txt", "fold", 40, "with the user's RTK hook: who owns the output"),
    ("rtk-2", "grep -rn value data.txt", "fold", 40, "same again: is the outcome deterministic"),
]
PROMPT = ("Use the Bash tool to run exactly this command, once, and nothing else: {cmd}\n"
          "Then answer with exactly two lines and nothing else:\n"
          "FIRST: <the first line of the tool result, exactly as you received it>\n"
          "LINES: <the number of lines in the tool result as you received it>")


def expand(text):
    """Python mirror of OutputCondenser.expandExact (groups, then repeat markers)."""
    if not text.startswith(HEADER + "\n"):
        return text
    out, path = [], None
    for line in text[len(HEADER) + 1:].split("\n"):
        if line.startswith("  ") and path is not None and line[2:3].isdigit():
            out.append(path + ":" + line[2:]); continue
        if line.endswith(":") and not line.startswith(" ") and " " not in line and len(line) > 1:
            path = line[:-1]; continue
        path = None
        out.append(line)
    final = []
    for line in out:
        m = re.fullmatch(r"\[c2d: previous line repeated (\d+) more times\]", line)
        if m and final:
            final += [final[-1]] * int(m.group(1))
        else:
            final.append(line)
    return "\n".join(final)


def write_workdir(base, rows=40):
    wd = Path(tempfile.mkdtemp(prefix="c2d-hookcheck-", dir=base))
    (wd / "gen.sh").write_text(GEN)
    data = subprocess.run(["sh", "gen.sh", str(rows), "0"], cwd=wd, capture_output=True, text=True).stdout
    (wd / "data.txt").write_text(data)
    (wd / "hooklog").mkdir()
    return wd


def settings_json(mode, wd, helper):
    cmd = f"python3 -I '{HERE / 'hook_wrapper.py'}' {{m}} '{wd / 'hooklog'}' '{helper}'"
    return json.dumps({"hooks": {
        "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": cmd.format(m=mode)}]}],
        "PostToolUseFailure": [{"matcher": "Bash", "hooks": [{"type": "command", "command": cmd.format(m="log")}]}]}})


def hook_entries(wd):
    out = []
    for f in sorted((wd / "hooklog").glob("*.json")):
        try:
            out.append(json.loads(f.read_text()))
        except ValueError:
            out.append({"unreadable": f.name})
    return out


def transcript_records(wd, sid):
    names = {re.sub(r"[^A-Za-z0-9]", "-", p) for p in (str(wd), os.path.realpath(wd))}
    for n in names:
        f = claude_home() / "projects" / n / f"{sid}.jsonl"
        if f.exists():
            return [json.loads(l) for l in f.read_text(errors="replace").splitlines() if l.strip()]
    return []


def transcript_tool_results(records):
    """What the transcript stored for each Bash result: the tool_result text and toolUseResult.stdout (first lines)."""
    out = []
    for r in records:
        content = (r.get("message") or {}).get("content")
        if r.get("type") != "user" or not isinstance(content, list):
            continue
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                c = b.get("content")
                text = c if isinstance(c, str) else "\n".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
                tur = r.get("toolUseResult") if isinstance(r.get("toolUseResult"), dict) else {}
                out.append({"isError": bool(b.get("is_error")), "resultFirst": text.split("\n", 1)[0][:200], "resultBytes": len(text.encode()),
                            "toolUseResultStdoutFirst": str(tur.get("stdout", ""))[:200].split("\n", 1)[0], "toolUseResultStdoutBytes": len(str(tur.get("stdout", "")).encode())})
    return out


def run_claude(args, wd, prompt, settings, allowed, sid):
    cmd = [args.claude, "-p", prompt, "--output-format", "text", "--session-id", sid, "--settings", settings,
           "--allowedTools", allowed] + (["--model", args.model] if args.model else []) + (["--setting-sources", "project,local"] if args.without_user_settings else [])
    start = time.monotonic()
    p = subprocess.run(cmd, cwd=wd, capture_output=True, text=True, timeout=args.timeout)
    return p.returncode, p.stdout, p.stderr[-2000:], round(time.monotonic() - start, 2)


def answer_first(answer):
    m = re.search(r"^FIRST:\s?(.*)$", answer or "", re.M)
    return m.group(1).strip().strip("`") if m else None


def evaluate_case(case_id, mode, rows, wd, answer, records):
    """Facts first, verdicts after. A verdict is only 'pass'/'fail' when the facts decide it; else 'unknown'."""
    expected = subprocess.run(["sh", "gen.sh", str(rows), "0"], cwd=wd, capture_output=True, text=True).stdout
    hooks = hook_entries(wd)
    post = [h for h in hooks if (h.get("payload") or {}).get("hook_event_name", "PostToolUse") == "PostToolUse" and h.get("mode") != "log"]
    fail = [h for h in hooks if (h.get("payload") or {}).get("hook_event_name") == "PostToolUseFailure"]
    facts = {"hookCalls": len(hooks), "postToolUse": len(post), "postToolUseFailure": len(fail), "answerFirst": answer_first(answer),
             "transcript": transcript_tool_results(records)}
    if post:
        p = post[0]["payload"] or {}
        resp = (p.get("tool_response") or {})
        stdout = resp.get("stdout", "")
        facts.update({"payloadCommand": (p.get("tool_input") or {}).get("command"), "payloadStdoutBytes": len(stdout.encode()),
                      "expectedStdoutBytes": len(expected.encode()), "payloadIsFullOutput": stdout == expected,
                      "payloadResponseKeys": sorted(resp), "hookMs": post[0].get("hookMs")})
        try:
            r = json.loads(post[0]["response"]) if post[0]["response"] else None
        except ValueError:
            r = "invalid"
        if isinstance(r, dict):
            upd = r["hookSpecificOutput"]["updatedToolOutput"]
            facts.update({"replaced": True, "replacementBytes": len(str(upd.get("stdout", "")).encode()),
                          "replacementExpandsToPayload": isinstance(upd.get("stdout"), str) and expand(upd["stdout"]) == stdout,
                          "otherFieldsIntact": {k: v for k, v in upd.items() if k != "stdout"} == {k: v for k, v in resp.items() if k != "stdout"}})
        else:
            facts["replaced"] = False if r is None else "invalid"
    first = facts["answerFirst"] or ""
    saw_fold, saw_raw = first.startswith("[c2d: lossless fold"), first == RAW_FIRST
    verdict = {"modelSawFold": saw_fold, "modelSawOriginal": saw_raw}
    if case_id in ("fold", "large"):
        verdict["pass"] = bool(facts.get("replaced") is True and facts.get("replacementExpandsToPayload") and facts.get("otherFieldsIntact") and saw_fold)
    elif case_id in ("failure", "garbage", "badshape"):
        verdict["pass"] = saw_raw
    else:
        verdict["pass"] = None   # rtk cases are observations; compared across rtk-1/rtk-2
    return {"facts": facts, "verdict": verdict}


def confirm():
    if input("This calls `claude -p` and spends model usage on your account. Type SPEND to continue: ").strip() != "SPEND":
        sys.exit("Not confirmed; nothing was run.")


def run_cases(args):
    base = Path(tempfile.mkdtemp(prefix="c2d-hookcheck-run-"))
    print(f"Run dir: {base}")
    results = []
    for case_id, command, mode, rows, why in CASES:
        wd = write_workdir(base)
        sid = str(uuid.uuid4())
        allowed = f"Bash({command})"
        code, answer, err, secs = run_claude(args, wd, PROMPT.format(cmd=command), settings_json(mode, wd, args.helper), allowed, sid)
        row = {"case": case_id, "why": why, "workdir": str(wd), "sessionId": sid, "exit": code, "seconds": secs, "answer": answer[-500:], "stderrTail": err}
        row.update(evaluate_case(case_id, mode, rows, wd, answer, transcript_records(wd, sid)))
        results.append(row)
        print(f"  {case_id:9s} exit {code}  pass={row['verdict']['pass']}  sawFold={row['verdict']['modelSawFold']}  sawOriginal={row['verdict']['modelSawOriginal']}")
    r1, r2 = [r for r in results if r["case"] in ("rtk-1", "rtk-2")]
    summary = {"rtkDeterministic": (r1["facts"].get("payloadCommand"), r1["facts"].get("replaced"), r1["verdict"]["modelSawFold"])
               == (r2["facts"].get("payloadCommand"), r2["facts"].get("replaced"), r2["verdict"]["modelSawFold"])}
    out = {"kind": "hookcheck integration", "model": args.model, "claude": subprocess.run([args.claude, "--version"], capture_output=True, text=True).stdout.strip(),
           "results": results, "summary": summary}
    (base / "hookcheck.json").write_text(json.dumps(out, indent=2))
    print(f"Wrote {base / 'hookcheck.json'}")


# MARK: Release gate

def gate_repo(base):
    """A synthetic repo where the honest way to answer is grep -rn (output the fold applies to)."""
    wd = Path(tempfile.mkdtemp(prefix="c2d-gate-", dir=base))
    rng = random.Random(7)
    for f in range(6):
        lines = []
        for i in range(1, 301):
            lines.append(f"    let value{i} = compute({i})" if rng.random() < (0.1 + f * 0.05) else f"    // line {i}")
        (wd / "src").mkdir(exist_ok=True)
        (wd / "src" / f"mod{f}.swift").write_text("\n".join(lines) + "\n")
    (wd / "hooklog").mkdir()
    return wd


def gate_tasks(wd):
    counts = {p.name: sum("compute(" in l for l in p.read_text().splitlines()) for p in sorted((wd / "src").glob("*.swift"))}
    best = max(counts, key=counts.get)
    total = sum(counts.values())
    lines3 = [i for i, l in enumerate((wd / "src" / "mod3.swift").read_text().splitlines(), 1) if "compute(" in l]
    return [
        ("most", "Using `grep -rn \"compute(\" src` (run it once), which file in src has the most lines containing `compute(`, and how many? "
                 "Answer with one line: ANSWER: <file name> <count>", f"ANSWER: {best} {counts[best]}"),
        ("total", "Using `grep -rn \"compute(\" src` (run it once), how many lines in total contain `compute(`? Answer with one line: ANSWER: <number>",
                  f"ANSWER: {total}"),
        ("lines", "Using `grep -rn \"compute(\" src` (run it once), list the line numbers in src/mod3.swift that contain `compute(`, ascending, "
                  "comma-separated. Answer with one line: ANSWER: <numbers>", "ANSWER: " + ",".join(map(str, lines3))),
    ]


def run_gate(args):
    base = Path(tempfile.mkdtemp(prefix="c2d-gate-run-"))
    print(f"Run dir: {base}")
    plan = [(t, arm, rep) for t in range(3) for arm in ("baseline", "fold") for rep in range(args.reps)]
    random.Random(args.seed).shuffle(plan)
    rows = []
    for t, arm, rep in plan:
        wd = gate_repo(base)
        task_id, prompt, expected = gate_tasks(wd)[t]
        sid = str(uuid.uuid4())
        code, answer, err, secs = run_claude(args, wd, prompt, settings_json("fold" if arm == "fold" else "log", wd, args.helper),
                                             'Bash(grep -rn "compute(" src)', sid)
        got = re.search(r"^ANSWER:.*$", answer or "", re.M)
        hooks = [h for h in hook_entries(wd) if h.get("mode") != "log" or arm == "baseline"]
        delivered = replaced = declined = 0
        latencies, exact = [], True
        for h in hooks:
            resp = ((h.get("payload") or {}).get("tool_response") or {})
            stdout = resp.get("stdout", "") if isinstance(resp.get("stdout"), str) else ""
            try:
                r = json.loads(h["response"]) if h.get("response") else None
            except ValueError:
                r = None
            if isinstance(r, dict):
                new = r["hookSpecificOutput"]["updatedToolOutput"]["stdout"]
                delivered += len(new.encode()); replaced += 1; exact = exact and expand(new) == stdout
            else:
                delivered += len(stdout.encode()); declined += arm == "fold"
            if arm == "fold" and h.get("hookMs") is not None:
                latencies.append(h["hookMs"])
        try:
            usage, versions, models, files = usage_for_workdir(str(wd))
            usage_err = None
        except Unavailable as e:
            usage, versions, models, usage_err = None, [], [], str(e)
        rows.append({"task": task_id, "arm": arm, "rep": rep, "exit": code, "seconds": secs, "success": bool(got and got.group(0).strip() == expected),
                     "bashResults": len(hooks), "deliveredBytes": delivered, "replaced": replaced, "declined": declined, "replacementsExact": exact,
                     "hookMs": latencies, "usage": usage, "usageUnavailable": usage_err, "models": models, "versions": versions})
        print(f"  {task_id:6s} {arm:8s} rep {rep}  success={rows[-1]['success']}  delivered={delivered}  replaced={replaced}")
    verdict = gate_verdict(rows)
    out = {"kind": "hookcheck release gate", "model": args.model, "reps": args.reps, "seed": args.seed, "withUserSettings": not args.without_user_settings,
           "rows": rows, "verdict": verdict}
    (base / "gate.json").write_text(json.dumps(out, indent=2))
    print(json.dumps(verdict, indent=2))
    print(f"Wrote {base / 'gate.json'}")


def gate_verdict(rows):
    """The release gate (docs/token-saver/RELEASE_GATE.md). Savings are reported, never required: the gate is about
    correctness, delivery and cost of the hook; a saving is only claimed from provider-reported usage, separately."""
    def arm(a, t=None): return [r for r in rows if r["arm"] == a and (t is None or r["task"] == t)]
    tasks = sorted({r["task"] for r in rows})
    lat = [x for r in arm("fold") for x in r["hookMs"]]
    ctx = lambda rs: [r["usage"]["input_tokens"] + r["usage"]["cache_read_input_tokens"] + r["usage"]["cache_creation_input_tokens"] for r in rs if r["usage"]]
    checks = {
        "G1 every fold row had its Bash output replaced": all(r["replaced"] >= 1 for r in arm("fold")),
        "G2 every replacement expands to the original byte for byte": all(r["replacementsExact"] for r in arm("fold")),
        "G3 no task less successful with the fold": all(sum(r["success"] for r in arm("fold", t)) >= sum(r["success"] for r in arm("baseline", t)) for t in tasks),
        "G4 fold success rate >= 90 %": bool(arm("fold")) and sum(r["success"] for r in arm("fold")) / len(arm("fold")) >= 0.9,
        "G5 hook latency median <= 20 ms and p90 <= 50 ms": bool(lat) and statistics.median(lat) <= 20 and sorted(lat)[max(0, int(len(lat) * 0.9) - 1)] <= 50,
        "G6 provider-reported usage available for every row": all(r["usage"] for r in rows),
    }
    b, f = ctx(arm("baseline")), ctx(arm("fold"))
    report = {
        "deliveredBytes (measured)": {"baselineMedian": statistics.median([r["deliveredBytes"] for r in arm("baseline")]) if arm("baseline") else None,
                                      "foldMedian": statistics.median([r["deliveredBytes"] for r in arm("fold")]) if arm("fold") else None},
        "providerContextTokens (provider-reported, all calls of a row)": {"baseline": sorted(b), "fold": sorted(f)},
        "estimatedTokens (bytes/4, heuristic)": {"baselineMedian": statistics.median([r["deliveredBytes"] / 4 for r in arm("baseline")]) if arm("baseline") else None,
                                                 "foldMedian": statistics.median([r["deliveredBytes"] / 4 for r in arm("fold")]) if arm("fold") else None},
        "hookMs (fold arm)": {"median": statistics.median(lat) if lat else None, "max": max(lat) if lat else None},
        "savingClaimable": bool(b and f) and max(f) < min(b),   # only when every fold row used less than every baseline row
    }
    return {"checks": checks, "pass": all(checks.values()), "report": report}


# MARK: Offline self-test

def self_test(args):
    helper = Path(args.helper)
    if not helper.exists():
        sys.exit(f"helper not built: {helper} (swift build -c release --package-path Packages/C2DCore --product c2d-token-helper)")
    base = Path(tempfile.mkdtemp(prefix="c2d-hookcheck-self-"))
    try:
        wd = write_workdir(base)
        stdout = (wd / "data.txt").read_text()
        payload = json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "sh gen.sh 40 0"},
                              "tool_response": {"stdout": stdout, "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False}})
        for mode in ("fold", "log", "garbage", "badshape"):
            subprocess.run(["python3", "-I", str(HERE / "hook_wrapper.py"), mode, str(wd / "hooklog"), str(helper)], input=payload, text=True, check=True, capture_output=True)
        entries = {e["mode"]: e for e in hook_entries(wd)}
        fold = json.loads(entries["fold"]["response"])["hookSpecificOutput"]["updatedToolOutput"]
        assert expand(fold["stdout"]) == stdout, "fold must expand to the original"
        assert len(fold["stdout"]) < len(stdout) and fold["stdout"].startswith(HEADER)
        assert {k: v for k, v in fold.items() if k != "stdout"} == {"stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False}
        assert entries["log"]["response"] == "" and entries["garbage"]["response"] == "{not json"
        assert json.loads(entries["badshape"]["response"])["hookSpecificOutput"]["updatedToolOutput"]["stdout"] == 42
        assert expand("no header\n") == "no header\n"
        # The evaluator on a fabricated answer (no transcript): fold case passes only when the model quotes the fold.
        ev = evaluate_case("fold", "fold", 40, wd, f"FIRST: {HEADER}\nLINES: 9", [])
        assert ev["facts"]["payloadIsFullOutput"] and ev["facts"]["replaced"] is True and ev["facts"]["otherFieldsIntact"] and ev["verdict"]["pass"]
        assert evaluate_case("fold", "fold", 40, wd, f"FIRST: {RAW_FIRST}\nLINES: 40", [])["verdict"]["pass"] is False
        rows = [{"task": "t", "arm": a, "replaced": a == "fold", "replacementsExact": True, "success": True, "hookMs": [10.0] if a == "fold" else [],
                 "deliveredBytes": 100 if a == "fold" else 200, "usage": dict.fromkeys(USAGE_KEYS, 1)} for a in ("baseline", "fold")]
        v = gate_verdict(rows)
        assert v["pass"] and not v["report"]["savingClaimable"], "equal usage is no saving"
        print("self-test OK (wrapper modes, helper fold, byte-exact expansion, evaluator, gate verdict)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", action="store_true"); ap.add_argument("--gate", action="store_true")
    ap.add_argument("--self-test", action="store_true"); ap.add_argument("--evaluate")
    ap.add_argument("--model"); ap.add_argument("--reps", type=int, default=3); ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--claude", default="claude"); ap.add_argument("--helper", default=str(DEFAULT_HELPER)); ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--without-user-settings", action="store_true", help="--setting-sources project,local: no user hooks (RTK) in either arm")
    args = ap.parse_args()
    if args.self_test:
        return self_test(args)
    if args.evaluate:
        d = json.loads((Path(args.evaluate) / "hookcheck.json").read_text())
        for r in d["results"]:
            wd = Path(r["workdir"])
            mode = next(c[2] for c in CASES if c[0] == r["case"]); rows = next(c[3] for c in CASES if c[0] == r["case"])
            print(r["case"], json.dumps(evaluate_case(r["case"], mode, rows, wd, r["answer"], transcript_records(wd, r["sessionId"]))["verdict"]))
        return
    if args.run or args.gate:
        if not args.model:
            sys.exit("--model is required for a run (pass the full model id so the transcript can confirm it)")
        if not Path(args.helper).exists():
            sys.exit(f"helper not built: {args.helper}")
        confirm()
        return run_gate(args) if args.gate else run_cases(args)
    print("Plan (no model call). Integration cases, one `claude -p` each:")
    for case_id, command, mode, _, why in CASES:
        print(f"  {case_id:9s} mode={mode:8s} `{command}` — {why}")
    print(f"Release gate: 3 tasks x {{baseline, fold}} x --reps (default 3) = 18 calls; see docs/token-saver/RELEASE_GATE.md")


if __name__ == "__main__":
    main()
