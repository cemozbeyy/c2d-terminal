#!/usr/bin/env python3
"""End-to-end check and release gate for the Token Saver PostToolUse fold (ADR-035). Run BY HAND.

Without --run / --gate it only prints the plan and calls no model. --run and --gate call `claude -p` (SPENDS MODEL USAGE)
and ask you to type SPEND first. Everything happens in fresh temporary work dirs with synthetic files; the hook is passed
with a per-run `--settings` (no allow rule, nothing written to any settings file); the only tool permission is a per-run
`--allowedTools` for the exact synthetic commands. Global settings and RTK are untouched.

  python3 hookcheck.py                         # plan: integration cases, no model call
  python3 hookcheck.py --self-test             # offline: wrapper + helper + expansion on synthetic payloads
  python3 hookcheck.py --run --model claude-haiku-5-5                 # integration cases (7 calls)
  python3 hookcheck.py --gate --model claude-haiku-5-5 --reps 3      # release gate: tasks x {baseline, rtk, c2d, combined} x reps (36 calls)
  python3 hookcheck.py --preflight / --rtk-offline / --report <dir>   # offline: env checks, bytes vs RTK, re-render a report
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

sys.dont_write_bytecode = True   # no __pycache__ residue in the repository

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
    ("large", "sh gen.sh 4000 0", "fold", 4000, "full stdout or a persisted preview in the payload (~213 KB)"),
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


def allowed_rules(command):
    """Permission rules for one synthetic command. Claude Code evaluates rules against the input a PreToolUse hook
    returns (ADR-034), and RTK's user hook rewrites e.g. `grep -rn x f` to `rtk grep -rn x f`, so with user settings on
    the exact rule alone would deny the call and the case would observe nothing. Both forms are allowed, plus whatever
    the installed rtk actually rewrites to (`cat x` becomes `rtk read x`); the extra rules are inert when nothing rewrites."""
    rules = [f"Bash({command})", f"Bash(rtk {command})"]
    rewritten = rtk_rewrite(command)
    if rewritten and f"Bash({rewritten})" not in rules:
        rules.append(f"Bash({rewritten})")
    return rules


def rtk_rewrite(command):
    """What the user's RTK PreToolUse hook would turn `command` into (None when rtk is absent or leaves it alone)."""
    if not shutil.which("rtk"):
        return None
    payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": command}, "cwd": "/tmp"})
    out = subprocess.run(["rtk", "hook", "claude"], input=payload, capture_output=True, text=True).stdout
    try:
        return json.loads(out)["hookSpecificOutput"]["updatedInput"]["command"]
    except (ValueError, KeyError, TypeError):
        return None


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


def run_claude(args, wd, prompt, settings, allowed, sid, user_settings=None, disallow=()):
    """One `claude -p` call (SPENDS MODEL USAGE). `user_settings=False` passes `--setting-sources project,local`, so the
    user's own hooks (RTK) are not loaded; the per-run `--settings` still applies either way (CLI help: "--settings
    still apply"). `disallow` removes tools so the prompt cannot be satisfied without the Bash tool."""
    if user_settings is None:
        user_settings = not args.without_user_settings
    cmd = [args.claude, "-p", prompt, "--output-format", "text", "--session-id", sid, "--settings", settings,
           "--allowedTools", *allowed] + (["--model", args.model] if args.model else []) + ([] if user_settings else ["--setting-sources", "project,local"]) \
          + (["--disallowedTools", *disallow] if disallow else [])
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
        code, answer, err, secs = run_claude(args, wd, PROMPT.format(cmd=command), settings_json(mode, wd, args.helper), allowed_rules(command), sid)
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


# MARK: Release gate (four arms)

# arm → whether the user's own settings (RTK's PreToolUse hook on this Mac) are loaded, and what the per-run hook does
ARMS = {"baseline": (False, "log"), "rtk": (True, "log"), "c2d": (False, "fold"), "combined": (True, "fold"), "c2d-lossy": (False, "lossy:all")}
DEFAULT_ARMS = "baseline,rtk,c2d,combined"   # c2d-lossy is opt-in (--arms … or --tasks body); its variant comes from --lossy-variant
GATE_DISALLOW = ("Grep", "Glob", "Read")   # otherwise the model can answer with the built-in Grep tool: no Bash call, no hook, nothing measured
GATE_COMMAND = 'grep -rn "compute(" src'


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
    # A 400-line file whose answers sit in the middle (lines 41–320 are what head/tail truncation drops): the body tasks.
    body = [f"    let field{i} = compute({i})" for i in range(1, 401)]
    body[249] = "    let secret = compute(7331)"   # line 250: inside the omitted 41–320, so a truncating arm must re-read or fail
    body[214] = "    func checksum() -> Int { return 4242 }"
    (wd / "src" / "long.swift").write_text("\n".join(body) + "\n")
    (wd / "hooklog").mkdir()
    return wd


BODY_COMMAND = "cat src/long.swift"


def body_tasks():
    """Tasks whose answer is inside the part a lossy truncation omits. The model may recover with a ranged read
    (`sed -n 'A,Bp' src/long.swift` is allowed as a prefix rule), so the row measures re-work (extra Bash calls, context),
    not a forced failure."""
    q = (f"Use the Bash tool to run exactly `{BODY_COMMAND}` once. If the result tells you lines were omitted, you may read a line range "
         "with `sed -n 'A,Bp' src/long.swift`. Use no other tool or command. ")
    return [
        ("secret", q + "What number is passed to compute() on the line that defines `secret`? Answer with one line: ANSWER: <number>", "ANSWER: 7331"),
        ("checksum", q + "What does the function `checksum()` return? Answer with one line: ANSWER: <number>", "ANSWER: 4242"),
    ]


def gate_tasks(wd):
    counts = {p.name: sum("compute(" in l for l in p.read_text().splitlines()) for p in sorted((wd / "src").glob("*.swift"))}
    best = max(counts, key=counts.get)
    total = sum(counts.values())
    lines3 = [i for i, l in enumerate((wd / "src" / "mod3.swift").read_text().splitlines(), 1) if "compute(" in l]
    q = f"Use the Bash tool to run exactly `{GATE_COMMAND}` once (no other tool, no other command). "
    return [
        ("most", q + "Which file in src has the most lines containing `compute(`, and how many? Answer with one line: ANSWER: <file name> <count>",
                 f"ANSWER: {best} {counts[best]}"),
        ("total", q + "How many lines in total contain `compute(`? Answer with one line: ANSWER: <number>", f"ANSWER: {total}"),
        ("lines", q + "List the line numbers in src/mod3.swift that contain `compute(`, ascending, comma-separated. Answer with one line: ANSWER: <numbers>",
                  "ANSWER: " + ",".join(map(str, lines3))),
    ]


def gate_plan(arms, reps, seed, task_count=3):
    """One block per task x rep holding every arm; the arm order rotates by rep (each arm runs first equally often when
    reps is a multiple of the arm count); block order shuffled by seed. Mirrors paired_experiment.plan."""
    blocks = [(t, r) for t in range(task_count) for r in range(reps)]
    random.Random(seed).shuffle(blocks)
    return [(t, arms[(i + r) % len(arms)], r) for t, r in blocks for i in range(len(arms))]


def classify_hooks(hooks, mode):
    """Facts from the hook log of one row: bytes the model got, replacements, declines, RTK rewrites, latencies."""
    delivered = replaced = declined = rtk_rewrites = 0
    latencies, commands, exact = [], [], True
    for h in hooks:
        p = h.get("payload") or {}
        cmd = (p.get("tool_input") or {}).get("command") or ""
        commands.append(cmd[:80])
        if cmd.lstrip().startswith("rtk "):
            rtk_rewrites += 1
        resp = (p.get("tool_response") or {})
        stdout = resp.get("stdout", "") if isinstance(resp.get("stdout"), str) else ""
        try:
            r = json.loads(h["response"]) if h.get("response") else None
        except ValueError:
            r = None
        transforming = mode == "fold" or mode.startswith("lossy:")
        if isinstance(r, dict):
            new = r["hookSpecificOutput"]["updatedToolOutput"]["stdout"]
            delivered += len(new.encode()); replaced += 1
            exact = exact and (expand(new) == stdout if mode == "fold" else new.startswith("[c2d: condensed "))   # lossy: marked, not restorable
        else:
            delivered += len(stdout.encode()); declined += transforming
        if transforming and h.get("hookMs") is not None:
            latencies.append(h["hookMs"])
    return {"bashResults": len(hooks), "deliveredBytes": delivered, "replaced": replaced, "declined": declined, "rtkRewrites": rtk_rewrites,
            "replacementsExact": exact, "hookMs": latencies, "commands": commands}


def task_table(wd, which):
    """(task id, prompt, expected, allow rules) for the chosen task family."""
    grep = [(i, p, e, allowed_rules(GATE_COMMAND)) for i, p, e in gate_tasks(wd)]
    body = [(i, p, e, allowed_rules(BODY_COMMAND) + ["Bash(sed -n:*)", "Bash(rtk sed -n:*)"]) for i, p, e in body_tasks()]
    return {"grep": grep, "body": body, "all": grep + body}[which]


def run_gate(args):
    arms = [a for a in args.arms.split(",") if a]
    unknown = [a for a in arms if a not in ARMS]
    if unknown:
        sys.exit(f"unknown arm(s): {unknown}; choose from {list(ARMS)}")
    base = Path(tempfile.mkdtemp(prefix="c2d-gate-run-"))
    print(f"Run dir: {base}")
    rtk_version = subprocess.run(["rtk", "--version"], capture_output=True, text=True).stdout.strip() if shutil.which("rtk") else None
    rows = []
    task_count = len(task_table(gate_repo(base), args.tasks))
    for t, arm, rep in gate_plan(arms, args.reps, args.seed, task_count):
        user_settings, mode = ARMS[arm]
        if mode.startswith("lossy:"):
            mode = "lossy:" + args.lossy_variant
        wd = gate_repo(base)
        task_id, prompt, expected, allowed = task_table(wd, args.tasks)[t]
        sid = str(uuid.uuid4())
        code, answer, err, secs = run_claude(args, wd, prompt, settings_json(mode, wd, args.helper), allowed, sid,
                                             user_settings=user_settings, disallow=GATE_DISALLOW)
        got = re.search(r"^ANSWER:.*$", answer or "", re.M)
        hooks = [h for h in hook_entries(wd) if (h.get("payload") or {}).get("hook_event_name", "PostToolUse") == "PostToolUse"]
        facts = classify_hooks(hooks, mode)
        try:
            usage, versions, models, files = usage_for_workdir(str(wd))
            usage_err = None
        except Unavailable as e:
            usage, versions, models, usage_err = None, [], [], str(e)
        rows.append({"task": task_id, "arm": arm, "rep": rep, "userSettings": user_settings, "mode": mode, "exit": code, "seconds": secs,
                     "success": bool(got and got.group(0).strip() == expected), "answer": (got.group(0) if got else (answer or "")[-200:]),
                     "stderrTail": err[-300:], "sessionId": sid, "workdir": str(wd), **facts,
                     "usage": usage, "usageUnavailable": usage_err, "models": models, "versions": versions})
        print(f"  {task_id:6s} {arm:9s} rep {rep}  success={rows[-1]['success']}  bash={facts['bashResults']}  delivered={facts['deliveredBytes']}  "
              f"replaced={facts['replaced']}  declined={facts['declined']}  rtk={facts['rtkRewrites']}")
    verdict = gate_verdict(rows)
    out = {"kind": f"hookcheck release gate (arms {','.join(arms)}; tasks {args.tasks}; lossy variant {args.lossy_variant})", "model": args.model,
           "reps": args.reps, "seed": args.seed, "arms": arms, "tasks": args.tasks, "lossyVariant": args.lossy_variant,
           "claude": subprocess.run([args.claude, "--version"], capture_output=True, text=True).stdout.strip(), "rtk": rtk_version,
           "helper": str(args.helper), "rows": rows, "verdict": verdict}
    (base / "gate.json").write_text(json.dumps(out, indent=2))
    (base / "report.md").write_text(render_report(out))
    print(json.dumps({"checks": verdict["checks"], "validity": verdict["validity"], "pass": verdict["pass"]}, indent=2))
    print(f"Wrote {base / 'gate.json'} and {base / 'report.md'}")


def _ctx(r):
    u = r.get("usage")
    return u["input_tokens"] + u["cache_read_input_tokens"] + u["cache_creation_input_tokens"] if u else None


def gate_verdict(rows):
    """The release gate (docs/token-saver/RELEASE_GATE.md). G1–G6 judge C2D's own delivery, correctness and cost; the
    validity block says whether the run measured what it claims (every row used Bash; baseline/c2d rows free of RTK;
    one model set, one CLI version). Savings are reported, never required, and only from provider-reported usage."""
    def arm(a, t=None): return [r for r in rows if r["arm"] == a and (t is None or r["task"] == t)]
    tasks = sorted({r["task"] for r in rows})
    present = [a for a in ARMS if arm(a)]
    fold_rows = [r for r in rows if r["mode"] == "fold"]                     # G2 applies to byte-exact arms only
    lat = [x for r in fold_rows for x in r["hookMs"]]                       # G5 judges the exact fold; lossy latency is reported per arm
    med = lambda xs: statistics.median(xs) if xs else None
    body_task = lambda r: r["task"] in ("secret", "checksum")   # file-body tasks: the exact fold declines a plain file body by design
    checks = {
        "G1 every c2d row replaced its Bash output on grep tasks (and left file bodies alone on body tasks)": bool(arm("c2d")) and all(
            (r["replaced"] == 0) if body_task(r) else (r["replaced"] >= 1) for r in arm("c2d")),
        "G2 every replacement expands to the original byte for byte (exact arms; lossy arms only checked for the marker)": all(r["replacementsExact"] for r in fold_rows)
            and all(r["replacementsExact"] for r in rows if r["mode"].startswith("lossy:")),
        "G3 no task less successful in c2d than in baseline": bool(arm("c2d")) and bool(arm("baseline")) and all(
            sum(r["success"] for r in arm("c2d", t)) >= sum(r["success"] for r in arm("baseline", t)) for t in tasks),
        "G4 c2d success rate >= 90 %": bool(arm("c2d")) and sum(r["success"] for r in arm("c2d")) / len(arm("c2d")) >= 0.9,
        "G5 exact-fold hook latency median <= 20 ms and p90 <= 50 ms": bool(lat) and statistics.median(lat) <= 20 and sorted(lat)[max(0, int(len(lat) * 0.9) - 1)] <= 50,
        "G6 provider-reported usage available for every row": bool(rows) and all(r["usage"] for r in rows),
    }
    validity = {
        "V1 every row ran the Bash command at least once": bool(rows) and all(r["bashResults"] >= 1 for r in rows),
        "V2 no RTK rewrite in baseline/c2d rows (user settings really excluded)": all(r["rtkRewrites"] == 0 for r in arm("baseline") + arm("c2d")),
        "V3 every rtk/combined row saw an RTK rewrite (RTK really active)": all(r["rtkRewrites"] >= 1 for r in arm("rtk") + arm("combined")),
        "V4 one model set across all rows": len({tuple(r["models"]) for r in rows}) == 1,
        "V5 one CLI version across all rows": len({tuple(r["versions"]) for r in rows}) == 1,
    }
    if not arm("rtk") + arm("combined"):
        validity.pop("V3 every rtk/combined row saw an RTK rewrite (RTK really active)")
    per_arm = {}
    base_ctx, base_bytes = [c for c in map(_ctx, arm("baseline")) if c is not None], [r["deliveredBytes"] for r in arm("baseline")]
    for a in present:
        rs = arm(a)
        ctx = [c for c in map(_ctx, rs) if c is not None]
        per_arm[a] = {
            "rows": len(rs), "success": sum(r["success"] for r in rs), "bashResults": sum(r["bashResults"] for r in rs),
            "deliveredBytes (measured, hook log)": {"median": med([r["deliveredBytes"] for r in rs]), "values": sorted(r["deliveredBytes"] for r in rs)},
            "estimatedTokens (bytes/4, heuristic)": {"median": med([r["deliveredBytes"] / 4 for r in rs])},
            "contextTokens (provider-reported, all calls of a row)": {"median": med(ctx), "values": sorted(ctx)},
            "outputTokens (provider-reported)": {"median": med([r["usage"]["output_tokens"] for r in rs if r["usage"]])},
            "elapsedSeconds (measured)": {"median": med([r["seconds"] for r in rs])},
            "hookMs (measured inside the hook)": {"median": med([x for r in rs for x in r["hookMs"]]), "max": max([x for r in rs for x in r["hookMs"]], default=None)},
            "replaced": sum(r["replaced"] for r in rs), "declined": sum(r["declined"] for r in rs), "rtkRewrites": sum(r["rtkRewrites"] for r in rs),
            "vsBaseline": None if a == "baseline" or not base_ctx else {
                "deliveredBytesMedianChange": _change(med(base_bytes), med([r["deliveredBytes"] for r in rs])),
                "contextTokensMedianChange": _change(med(base_ctx), med(ctx)),
                # only when every row of this arm used fewer provider-reported context tokens than every baseline row
                "contextLowerInEveryRow": bool(ctx) and max(ctx) < min(base_ctx),
            },
        }
    return {"checks": checks, "validity": validity, "pass": all(checks.values()) and all(validity.values()), "perArm": per_arm}


def _change(before, after):
    return None if not before or after is None else round((after - before) / before, 4)


def render_report(out):
    """Markdown: absolute values, % change vs baseline, the source of every number, pass/fail, validity, limitations."""
    v = out["verdict"]
    L = [f"# Token Saver gate — {out.get('kind', 'gate')}", "",
         f"Model requested: `{out.get('model')}` · CLI: `{out.get('claude')}` · RTK: `{out.get('rtk') or 'not installed'}` · reps {out.get('reps')} · seed {out.get('seed')}", "",
         "Arms: baseline = no user settings, hook observes · rtk = user settings (RTK PreToolUse) · c2d = no user settings, exact fold · combined = user settings + exact fold · c2d-lossy = no user settings, opt-in lossy condenser (not restorable; re-work shows as extra Bash results and context).", "",
         "| arm | rows | success | Bash results | delivered bytes (median, measured) | Δ vs baseline | context tokens (median, provider-reported) | Δ vs baseline | lower in every row | output tokens (median, provider-reported) | hook ms (median/max, measured) | replaced / declined / rtk rewrites |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    def pc(x): return "—" if x is None else f"{x * 100:+.1f} %"
    for a, m in v["perArm"].items():
        vb = m["vsBaseline"] or {}
        hm = m["hookMs (measured inside the hook)"]
        L.append(f"| {a} | {m['rows']} | {m['success']}/{m['rows']} | {m['bashResults']} | {m['deliveredBytes (measured, hook log)']['median']} | {pc(vb.get('deliveredBytesMedianChange'))} | "
                 f"{m['contextTokens (provider-reported, all calls of a row)']['median']} | {pc(vb.get('contextTokensMedianChange'))} | {vb.get('contextLowerInEveryRow', '—')} | "
                 f"{m['outputTokens (provider-reported)']['median']} | {hm['median']} / {hm['max']} | {m['replaced']} / {m['declined']} / {m['rtkRewrites']} |")
    L += ["", "Per-row context tokens (provider-reported, sorted):", ""]
    for a, m in v["perArm"].items():
        L.append(f"- {a}: {m['contextTokens (provider-reported, all calls of a row)']['values']}")
    L += ["", "## Checks (C2D delivery, correctness, cost)", ""] + [f"- {'PASS' if ok else 'FAIL'} — {k}" for k, ok in v["checks"].items()]
    L += ["", "## Validity (did the run measure what it claims)", ""] + [f"- {'OK' if ok else 'INVALID'} — {k}" for k, ok in v["validity"].items()]
    L += ["", f"**Result: {'PASS' if v['pass'] else 'FAIL'}** (all checks and all validity conditions).", "",
          "## Limitations", "",
          "- Context tokens are the sum over every API call of a row (Claude Code's system prompt and side calls included); cache reads dominate, so a byte reduction in one tool result moves them little.",
          "- `delivered bytes` and `bytes/4` are measurements of what the hook handed back, not of what the model billed; `bytes/4` is a heuristic.",
          "- n is small (reps per arm); medians and `lower in every row` are descriptive, not significance.",
          "- `combined` cannot replace RTK-owned output by design (one owner per output), so its replaced count is expected to be 0 on grep.",
          "- Subscription accounts are metered by plan quota; nothing here is a currency figure.",
          "- Byte reductions are never presented as token or quota reductions."]
    return "\n".join(L) + "\n"


# MARK: Offline RTK comparison (equivalent inputs, bytes only)

RTK_COMMANDS = ['grep -rn "compute(" src', "ls -la src", "git status", "git log --oneline -n 20", "find src -name '*.swift'", "cat src/mod0.swift"]


def rtk_offline(args):
    """Same command in the same synthetic repo: raw bytes, C2D exact fold (verified restorable), and — only with
    --invoke-rtk — RTK's output for `rtk <cmd>` (lossy by design, not restorable; writes a row into the owner's
    `rtk gain --history`, hence the flag). No model call anywhere."""
    base = Path(tempfile.mkdtemp(prefix="c2d-rtkcmp-"))
    wd = gate_repo(base)
    subprocess.run(["git", "init", "-q"], cwd=wd, check=True); subprocess.run(["git", "add", "."], cwd=wd, check=True)
    subprocess.run(["git", "-c", "user.email=x@y", "-c", "user.name=x", "commit", "-qm", "init"], cwd=wd, check=True)
    (wd / "src" / "mod0.swift").write_text((wd / "src" / "mod0.swift").read_text() + "    // dirty\n")
    rows = []
    for cmd in RTK_COMMANDS:
        raw = subprocess.run(["sh", "-c", cmd], cwd=wd, capture_output=True, text=True).stdout
        payload = json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": cmd},
                              "tool_response": {"stdout": raw, "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False}})
        out = subprocess.run([str(args.helper)], input=payload, capture_output=True, text=True).stdout
        fold = json.loads(out)["hookSpecificOutput"]["updatedToolOutput"]["stdout"] if out.strip() else None
        row = {"command": cmd, "rawBytes": len(raw.encode()), "c2dBytes": len(fold.encode()) if fold is not None else len(raw.encode()),
               "c2dChanged": fold is not None, "c2dRestorable": fold is None or expand(fold) == raw, "rtkBytes": None, "rtkNote": "not invoked (pass --invoke-rtk)"}
        if args.invoke_rtk and shutil.which("rtk"):
            r = subprocess.run(["sh", "-c", "rtk " + cmd], cwd=wd, capture_output=True, text=True)
            row["rtkBytes"], row["rtkNote"] = len(r.stdout.encode()), f"exit {r.returncode}; lossy by design, not restorable"
        elif args.invoke_rtk:
            row["rtkNote"] = "rtk not installed"
        rows.append(row)
    print("Offline comparison on one synthetic repo (bytes measured; no model call; tokens not estimated here)")
    print(f"{'command':34s} {'raw':>8s} {'c2d fold':>9s} {'restorable':>10s} {'rtk':>8s}  note")
    for r in rows:
        print(f"{r['command']:34s} {r['rawBytes']:8d} {r['c2dBytes']:9d} {str(r['c2dRestorable']):>10s} {str(r['rtkBytes'] if r['rtkBytes'] is not None else '—'):>8s}  {r['rtkNote']}")
    print("C2D is byte-exact (expand == raw) or declines; RTK output is a different, lossy rendering — comparable in bytes only, not in content.")
    return rows


# MARK: Preflight (offline) and self-test

def preflight(args):
    """Environment checks without a model call, then the exact commands that do call one, each labelled."""
    ok = True
    def line(good, text): 
        nonlocal ok; ok = ok and bool(good); print(f"  [{'ok' if good else 'MISSING'}] {text}")
    claude = shutil.which(args.claude)
    ver = subprocess.run([args.claude, "--version"], capture_output=True, text=True).stdout.strip() if claude else ""
    help_text = subprocess.run([args.claude, "--help"], capture_output=True, text=True).stdout if claude else ""
    print("Preflight (offline):")
    line(claude, f"claude executable: {claude or 'not found'} {ver}")
    for flag in ("--settings", "--setting-sources", "--allowedTools", "--disallowedTools", "--session-id", "--model"):
        line(flag in help_text, f"CLI supports {flag}")
    line(Path(args.helper).exists(), f"helper built: {args.helper}")
    rtk = shutil.which("rtk")
    print(f"  [info] rtk: {rtk or 'not installed'} {subprocess.run(['rtk', '--version'], capture_output=True, text=True).stdout.strip() if rtk else ''}")
    try:
        hooks = json.loads((claude_home() / "settings.json").read_text()).get("hooks", {})
        pre = [h.get("command") for m in hooks.get("PreToolUse", []) for h in m.get("hooks", [])]
        print(f"  [info] user PreToolUse hooks (read-only): {pre or 'none'} → arms rtk/combined {'will' if any('rtk' in (c or '') for c in pre) else 'will NOT'} see RTK rewrites")
    except (OSError, ValueError):
        print("  [info] user settings.json not readable: arms rtk/combined will not see RTK")
    for c in [c[1] for c in CASES] + [GATE_COMMAND, BODY_COMMAND, "sed -n '1,10p' src/long.swift"]:
        rw = rtk_rewrite(c)
        print(f"  [info] rtk rewrite of `{c}`: {rw or 'none'}")
    folders = sorted(p.name for p in (claude_home() / "projects").glob("*c2d-gate*")) + sorted(p.name for p in (claude_home() / "projects").glob("*c2d-hookcheck*"))
    print(f"  [info] transcript folders from earlier runs (never deleted by this tool): {len(folders)}")
    try:
        self_test(args); line(True, "self-test")
    except (AssertionError, SystemExit) as e:
        line(False, f"self-test: {e}")
    print(f"\nPreflight {'OK' if ok else 'FAILED'}. Commands below SPEND SUBSCRIPTION QUOTA; run them yourself, each asks you to type SPEND:")
    print(f"  python3 -I Tools/hookcheck/hookcheck.py --run --model <full model id>                     # 7 calls, integration cases")
    print(f"  python3 -I Tools/hookcheck/hookcheck.py --gate --model <full model id> --reps 3            # 36 calls: 3 tasks x 4 arms x 3 reps")
    print(f"  python3 -I Tools/hookcheck/hookcheck.py --gate --model <full model id> --reps 3 --arms baseline,c2d   # 18 calls, C2D only")
    print(f"  python3 -I Tools/hookcheck/hookcheck.py --gate --model <full model id> --reps 3 --tasks body --arms baseline,c2d,c2d-lossy --lossy-variant truncate   # 18 calls, lossy quality (D5)")
    print(f"  python3 -I Tools/hookcheck/hookcheck.py --report <run dir>                                 # offline, re-renders report.md")


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
        # classify_hooks on the real wrapper entries: fold replaced, log delivered the raw bytes.
        fold_facts = classify_hooks([entries["fold"]], "fold"); log_facts = classify_hooks([entries["log"]], "log")
        assert fold_facts["replaced"] == 1 and fold_facts["replacementsExact"] and fold_facts["declined"] == 0 and fold_facts["rtkRewrites"] == 0
        assert log_facts["deliveredBytes"] == len(stdout.encode()) and log_facts["replaced"] == 0
        assert classify_hooks([{"payload": {"tool_input": {"command": "rtk grep x"}, "tool_response": {"stdout": "a"}}, "response": ""}], "fold")["rtkRewrites"] == 1
        # Four-arm verdict on fabricated rows: c2d replaces and is cheaper; combined cannot replace (RTK owns the output); equal usage is no saving.
        def row(arm, ctx, replaced, rtk, success=True):
            return {"task": "t", "arm": arm, "mode": ARMS[arm][1], "replaced": replaced, "declined": 0 if replaced else int(ARMS[arm][1] == "fold"),
                    "rtkRewrites": rtk, "replacementsExact": True, "success": success, "hookMs": [10.0] if ARMS[arm][1] == "fold" else [],
                    "bashResults": 1, "deliveredBytes": 100 if replaced else 200, "seconds": 1.0, "usage": dict(dict.fromkeys(USAGE_KEYS, 1), input_tokens=ctx),
                    "models": ["m"], "versions": ["1"]}
        rows = [row("baseline", 300, 0, 0), row("rtk", 250, 0, 1), row("c2d", 200, 1, 0), row("combined", 240, 0, 1)]
        v = gate_verdict(rows)
        assert v["pass"], v
        assert v["perArm"]["c2d"]["vsBaseline"]["contextLowerInEveryRow"] and v["perArm"]["c2d"]["vsBaseline"]["contextTokensMedianChange"] < 0
        assert v["perArm"]["combined"]["replaced"] == 0 and "V3" in " ".join(v["validity"])
        bad = gate_verdict([row("baseline", 300, 0, 1), row("c2d", 300, 1, 0)])
        assert not bad["pass"] and not bad["validity"]["V2 no RTK rewrite in baseline/c2d rows (user settings really excluded)"]
        assert not bad["perArm"]["c2d"]["vsBaseline"]["contextLowerInEveryRow"], "equal usage is no saving"
        assert not gate_verdict([row("baseline", 300, 0, 0), row("c2d", 200, 1, 0, success=False)])["checks"]["G4 c2d success rate >= 90 %"]
        four = DEFAULT_ARMS.split(",")
        plan = gate_plan(four, 4, 1)
        assert len(plan) == 3 * 4 * 4 and all(sum(1 for t, a, r in plan if a == arm and r == 0) == 3 for arm in four)
        firsts = [plan[i][1] for i in range(0, len(plan), 4)]
        assert all(firsts.count(a) == 3 for a in four), "every arm runs first equally often"
        assert len(gate_plan(["baseline", "c2d", "c2d-lossy"], 3, 1, task_count=2)) == 18
        # Lossy helper mode: a 400-line body is truncated with an explicit marker, every other field intact, same two response keys.
        long = "\n".join(f"    let field{i} = compute({i})" for i in range(1, 401)) + "\n"
        lp = json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "cat src/long.swift"},
                         "tool_response": {"stdout": long, "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False}})
        wd2 = write_workdir(base)
        subprocess.run(["python3", "-I", str(HERE / "hook_wrapper.py"), "lossy:truncate", str(wd2 / "hooklog"), str(helper)], input=lp, text=True, check=True, capture_output=True)
        le = hook_entries(wd2)[0]
        lr = json.loads(le["response"])
        assert set(lr) == {"hookSpecificOutput"} and set(lr["hookSpecificOutput"]) == {"hookEventName", "updatedToolOutput"}
        lt = lr["hookSpecificOutput"]["updatedToolOutput"]["stdout"]
        assert lt.startswith("[c2d: condensed 400→") and "lines omitted: 41–320 of this output]" in lt and len(lt) < len(long) and "field400" in lt and "field1 " in lt
        assert classify_hooks([le], "lossy:truncate")["replaced"] == 1 and classify_hooks([le], "lossy:truncate")["replacementsExact"]
        subprocess.run(["python3", "-I", str(HERE / "hook_wrapper.py"), "fold", str(wd2 / "hooklog"), str(helper)], input=lp, text=True, check=True, capture_output=True)
        assert [e for e in hook_entries(wd2) if e["mode"] == "fold"][0]["response"] == "", "the exact fold declines a plain file body"
        repo = gate_repo(base)
        assert len(task_table(repo, "all")) == 5 and task_table(repo, "body")[0][3][-2:] == ["Bash(sed -n:*)", "Bash(rtk sed -n:*)"]
        assert (repo / "src" / "long.swift").read_text().splitlines()[249] == "    let secret = compute(7331)", "answer sits inside the omitted 41–320"
        lossy_rows = [row("baseline", 300, 0, 0), row("c2d", 200, 1, 0), dict(row("c2d-lossy", 150, 1, 0), mode="lossy:all")]
        lv = gate_verdict(lossy_rows)
        assert lv["pass"] and lv["perArm"]["c2d-lossy"]["vsBaseline"]["contextLowerInEveryRow"]
        # A body run: c2d declines the file body (replaced 0) and still passes G1; a slow lossy hook does not fail G5; a grep-task c2d row with 0 replacements fails G1.
        body = [dict(row("baseline", 300, 0, 0), task="secret"), dict(row("c2d", 300, 0, 0), task="secret", declined=1),
                dict(row("c2d-lossy", 150, 1, 0), task="secret", mode="lossy:truncate", hookMs=[40.0])]
        bv = gate_verdict(body)
        assert bv["pass"], bv
        assert not gate_verdict([row("baseline", 300, 0, 0), row("c2d", 300, 0, 0)])["checks"][next(k for k in bv["checks"] if k.startswith("G1"))]
        md = render_report({"kind": "self-test", "model": "m", "claude": "c", "rtk": "r", "reps": 1, "seed": 1, "verdict": v})
        assert "| c2d |" in md and "PASS" in md and "Limitations" in md
        # Every synthetic command stays allowed after RTK's rewrite (or rtk leaves it alone / is not installed).
        for command in [c[1] for c in CASES] + [GATE_COMMAND, BODY_COMMAND, "sed -n '1,10p' src/long.swift"]:
            rewritten = rtk_rewrite(command)
            assert rewritten is None or f"Bash({rewritten})" in allowed_rules(command), (command, rewritten)
        print("self-test OK (wrapper modes, helper fold, byte-exact expansion, evaluator, four-arm verdict, plan rotation, report, lossy helper mode, body tasks, allow rules vs rtk rewrite)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", action="store_true"); ap.add_argument("--gate", action="store_true")
    ap.add_argument("--self-test", action="store_true"); ap.add_argument("--evaluate"); ap.add_argument("--report", help="run dir with gate.json: re-render report.md offline")
    ap.add_argument("--preflight", action="store_true", help="offline environment checks + the exact (spending) commands")
    ap.add_argument("--rtk-offline", action="store_true", help="offline bytes: raw vs C2D fold (vs RTK only with --invoke-rtk)")
    ap.add_argument("--invoke-rtk", action="store_true", help="with --rtk-offline: also run `rtk <cmd>` (writes rows into your `rtk gain --history`)")
    ap.add_argument("--model"); ap.add_argument("--reps", type=int, default=3); ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--arms", default=DEFAULT_ARMS, help=f"gate arms, comma-separated, from {list(ARMS)}")
    ap.add_argument("--tasks", default="grep", choices=["grep", "body", "all"], help="grep: 3 grep tasks (default); body: 2 file-body tasks for the lossy arm; all: both")
    ap.add_argument("--lossy-variant", default="truncate", choices=["similar", "longline", "truncate", "all"], help="helper --lossy variant for the c2d-lossy arm")
    ap.add_argument("--claude", default="claude"); ap.add_argument("--helper", default=str(DEFAULT_HELPER)); ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--without-user-settings", action="store_true", help="--run only: --setting-sources project,local (no user hooks such as RTK)")
    args = ap.parse_args()
    if args.self_test:
        return self_test(args)
    if args.preflight:
        return preflight(args)
    if args.rtk_offline:
        return rtk_offline(args)
    if args.report:
        d = json.loads((Path(args.report) / "gate.json").read_text())
        d["verdict"] = gate_verdict(d["rows"])
        md = render_report(d)
        (Path(args.report) / "report.md").write_text(md)
        print(md)
        return
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
    print(f"Release gate: 3 grep tasks x arms {DEFAULT_ARMS} x --reps 3 = 36 calls; lossy experiment: --tasks body --arms baseline,c2d,c2d-lossy = 18 calls; see docs/token-saver/RELEASE_GATE.md")


if __name__ == "__main__":
    main()
