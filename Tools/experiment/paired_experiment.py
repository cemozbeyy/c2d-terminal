#!/usr/bin/env python3
"""Paired Token Saver experiment (TSD-03): the same task, once per arm (e.g. raw vs condensed hand-off).

Run BY HAND. Without --run it only prints the plan and calls no model. With --run it calls `claude -p` once per
task x arm x repetition (plus retries), which SPENDS MODEL USAGE on your account, so it asks you to type SPEND first.

What each row records, and how it was obtained:
  success        measured  - the task's `check` command exited 0 after the last attempt
  retries        measured  - re-prompts after a failed check (0..--max-retries)
  elapsed_s      measured  - wall clock of all `claude -p` calls for the row
  input/output/cache_read/cache_creation tokens
                 provider-reported - read from Claude Code's own transcript(s) for the row's private work dir, with
                 C2D's ledger rules: last record per message id, records of one message must agree, else unavailable
  context_bytes  measured  - size of the context file handed over (a fixture-level number, not a token count)
  models_actual  provider-reported - distinct `message.model` values in the row's transcript(s) (`<synthetic>` skipped)
  model_match    exact (only the requested model) | mixed (requested plus others, e.g. CLI side calls) | mismatch |
                 unavailable (no transcript, or no --model given). Two rows are comparable only when both carry the
                 identical models_actual set and it contains the requested model; the summary counts the rest.
  answer_quality unmeasured - only the check is evaluated; nothing else about the answer is judged

Confounds to report with any result: RTK's Claude Code hook (if installed) is active in every arm; one model and
CLI version per run only; small n says nothing about significance. Never present a difference as "saved".

  python3 paired_experiment.py --tasks tasks.example.json                     # plan only, no model call
  python3 paired_experiment.py --tasks tasks.example.json --json              # same plan as JSON (C2D's preview)
  python3 paired_experiment.py --tasks tasks.example.json --run --model sonnet --reps 3
  python3 paired_experiment.py --usage <transcript.jsonl>                     # read usage from one transcript
  python3 paired_experiment.py --self-test                                    # checks the usage reader
"""
import argparse, csv, hashlib, json, os, platform, random, re, signal, statistics, subprocess, sys, tempfile, time, uuid
from pathlib import Path

USAGE_KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")


class Unavailable(Exception):
    pass


def read_usage(lines):
    """Provider-reported usage from transcript lines. Fails closed (raises Unavailable) instead of guessing."""
    messages, versions, models = {}, set(), set()
    for n, line in enumerate(lines, 1):
        if not line.strip() or '"assistant"' not in line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            raise Unavailable(f"malformed JSON on line {n}")
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        u, mid = msg.get("usage"), msg.get("id") or rec.get("requestId")
        if not isinstance(u, dict) or not mid or "version" not in rec:
            raise Unavailable(f"unrecognised assistant record on line {n}")
        vals = {}
        for k in USAGE_KEYS:
            v = u.get(k, None if k in ("input_tokens", "output_tokens") else 0)
            if type(v) is not int or v < 0:
                raise Unavailable(f"usage field {k} on line {n} is not a non-negative integer")
            vals[k] = v
        prev = messages.get(mid)
        if prev and (any(prev[k] != vals[k] for k in USAGE_KEYS if k != "output_tokens") or vals["output_tokens"] < prev["output_tokens"]):
            raise Unavailable(f"records of message {mid} disagree (line {n})")
        messages[mid] = vals
        versions.add(rec["version"])
        if isinstance(msg.get("model"), str) and msg["model"] != "<synthetic>":   # CLI placeholder records, as in the app reader
            models.add(msg["model"])
    if not messages:
        raise Unavailable("no assistant messages with usage")
    total = {k: sum(m[k] for m in messages.values()) for k in USAGE_KEYS}
    return total, sorted(versions), sorted(models)


def claude_home():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def usage_for_workdir(workdir):
    """Sums every top-level transcript in the work dir's project folder; the dir is private to one row."""
    names = {re.sub(r"[^A-Za-z0-9]", "-", p) for p in (workdir, os.path.realpath(workdir))}
    files = [f for n in names for f in (claude_home() / "projects" / n).glob("*.jsonl")]
    if not files:
        raise Unavailable("no transcript found for the work dir")
    total, versions, models = dict.fromkeys(USAGE_KEYS, 0), set(), set()
    for f in files:
        t, v, m = read_usage(f.read_text(errors="replace").splitlines())
        total = {k: total[k] + t[k] for k in USAGE_KEYS}
        versions.update(v)
        models.update(m)
    return total, sorted(versions), sorted(models), len(files)


def model_match(requested, actual):
    """How the row's transcript models relate to the requested one. Never inferred: an alias such as `sonnet` is
    not resolved, so it can only give `mismatch`; pass the full model id to be able to get `exact`."""
    if not requested or not actual:
        return "unavailable"
    if requested not in actual:
        return "mismatch"
    return "exact" if actual == [requested] else "mixed"


def load_tasks(path):
    spec = json.loads(Path(path).read_text())
    base = Path(path).resolve().parent
    template = spec.get("prompt_template", "{context}\n\n{question}")
    for t in spec["tasks"]:
        for arm, ctx in t["arms"].items():
            f = base / ctx
            if not f.is_file():
                sys.exit(f"task {t['id']} arm {arm}: context file missing: {f}")
    return spec["tasks"], template, base


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()[:16]


def same_context(task, arm, base):
    """Other arms of the task whose context file is byte-identical: those pairs are A/A controls, not treatments."""
    ctx = (base / task["arms"][arm]).read_bytes()
    return [a for a in task["arms"] if a != arm and (base / task["arms"][a]).read_bytes() == ctx]


def plan(tasks, reps, seed):
    """One block per task x rep holding every arm back to back (the pair is compared under the same conditions).
    Block order is shuffled; inside a block the arm order is rotated by rep, so with reps = a multiple of the arm
    count every arm runs first, second, ... equally often per task (order effects cancel instead of being random)."""
    blocks = [(t, r) for t in tasks for r in range(reps)]
    random.Random(seed).shuffle(blocks)
    rows = []
    for t, r in blocks:
        arms = list(t["arms"])
        k = r % len(arms)
        rows += [(t, arm, r) for arm in arms[k:] + arms[:k]]
    return rows


def call(cmd, cwd, timeout, env=None):
    """(returncode, stdout, error). A timeout or a missing binary becomes a recorded error, never a lost row."""
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return None, "", f"timed out after {timeout} s"
    except OSError as e:
        return None, "", f"could not start {cmd[0]}: {e}"
    return p.returncode, p.stdout, "" if p.returncode == 0 else f"exited {p.returncode}: {p.stderr.strip()[-300:]}"


def manifest(args, tasks_path):
    """Environment of a run; `claude --version` is a local CLI call (no model request)."""
    repo = Path(__file__).resolve().parents[2]
    git = lambda *a: call(["git", "-C", str(repo), *a], None, 30)
    rev = git("rev-parse", "HEAD")   # None when the script runs outside a Git checkout (e.g. bundled in the app)
    return {"started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "git_revision": rev[1].strip() if rev[0] == 0 else None,
            "git_dirty": bool(git("status", "--porcelain")[1].strip()) if rev[0] == 0 else None,
            "script_sha256": sha256(Path(__file__).read_bytes()),
            "tasks_file": str(tasks_path), "tasks_sha256": sha256(Path(tasks_path).read_bytes()),
            "claude": args.claude, "claude_version": (call([args.claude, "--version"], None, 30)[1] or "unknown").strip(),
            "model": args.model or "(CLI default)", "reps": args.reps, "max_retries": args.max_retries, "seed": args.seed,
            "timeout_s": args.timeout, "python": platform.python_version(), "os": platform.platform(),
            "confounds": "user-level Claude Code config (CLAUDE.md, hooks such as RTK, plugins) is active in every arm"}


def run_row(task, arm, rep, order, template, base, args, out_dir):
    context = (base / task["arms"][arm]).read_text(errors="replace")
    prompt = template.format(context=context, question=task["question"])
    workdir = tempfile.mkdtemp(prefix=f"c2d-exp-{task['id']}-{arm}-")
    sid = str(uuid.uuid4())
    answer_file = Path(out_dir) / f"{task['id']}.{arm}.{rep}.answer.txt"
    base_cmd = [args.claude, "-p", "--output-format", "text"] + (["--model", args.model] if args.model else [])
    elapsed, retries, success, check_out, err = 0.0, 0, False, "", ""
    message = prompt
    for attempt in range(args.max_retries + 1):
        cmd = base_cmd + (["--session-id", sid] if attempt == 0 else ["--resume", sid]) + [message]
        t0 = time.monotonic()
        rc, out, err = call(cmd, workdir, args.timeout)
        elapsed += time.monotonic() - t0
        if rc != 0:
            err = f"claude {err}"
            break
        answer_file.write_text(out)
        crc, check_out, check_err = call(["/bin/sh", "-c", task["check"]], workdir, 60, {**os.environ, "ANSWER_FILE": str(answer_file)})
        check_out = (check_out + check_err).strip()[-500:]
        if crc == 0:
            success = True
            break
        if attempt < args.max_retries:
            retries += 1
            message = f"That answer did not pass the check. Check output:\n{check_out or '(none)'}\nPlease answer again."
    row = {"task": task["id"], "arm": arm, "rep": rep, "order": order, "model": args.model or "(CLI default)", "success": success,
           "retries": retries, "elapsed_s": round(elapsed, 2), "context_bytes": len(context.encode()),
           "context_sha256": sha256(context), "prompt_sha256": sha256(prompt),
           "error": err, "answer_quality": "unmeasured", "session_id": sid}
    try:
        usage, versions, models, nfiles = usage_for_workdir(workdir)
        row.update(usage, usage_source="provider-reported", cli_versions=",".join(versions), transcripts=nfiles,
                   models_actual=",".join(models), model_match=model_match(args.model, models))
    except Unavailable as e:
        row.update(dict.fromkeys(USAGE_KEYS, None), usage_source=f"unavailable: {e}", cli_versions="", transcripts=0,
                   models_actual="", model_match="unavailable")
    return row


def summarize(rows):
    print("\nPer arm (medians; n = rows; usage only from rows where it was provider-reported):")
    for key in sorted({(r["task"], r["arm"]) for r in rows}):
        rs = [r for r in rows if (r["task"], r["arm"]) == key]
        ok = [r for r in rs if r["usage_source"] == "provider-reported"]
        med = lambda k, xs: statistics.median(x[k] for x in xs) if xs else "n/a"
        print(f"  {key[0]:<22} {key[1]:<18} n={len(rs)} success={sum(r['success'] for r in rs)}/{len(rs)} errors={sum(bool(r['error']) for r in rs)} "
              f"retries={med('retries', rs)} elapsed_s={med('elapsed_s', rs)} "
              f"input+cache={med('ctx', [dict(r, ctx=r['input_tokens'] + r['cache_read_input_tokens'] + r['cache_creation_input_tokens']) for r in ok])} "
              f"output={med('output_tokens', ok)} (usage rows {len(ok)}/{len(rs)})")
    sets = {r["models_actual"] for r in rows if r["model_match"] in ("exact", "mixed")}
    off = [r for r in rows if r["model_match"] not in ("exact", "mixed")]
    if off or len(sets) > 1:
        print(f"  WARNING: not a same-model comparison: {len(off)} row(s) without the requested model"
              f" ({', '.join(sorted({r['model_match'] for r in off})) or 'none'}), {len(sets)} distinct model set(s): {sorted(sets)}")
    if len(rows) < 10:
        print("  Note: too few rows for any conclusion; differences may be noise.")
    print("  Exploratory: single-response fixture tasks; says nothing about long-session productivity.")


def self_test():
    rec = lambda mid, i, o, v="9.9.9": json.dumps({"type": "assistant", "version": v, "message": {"id": mid, "usage": {
        "input_tokens": i, "output_tokens": o, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 5}}})
    total, versions, models = read_usage([rec("a", 1, 2), rec("a", 1, 7), json.dumps({"type": "user"}), rec("b", 3, 4)])
    assert total == {"input_tokens": 4, "output_tokens": 11, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 10}, total
    assert versions == ["9.9.9"] and models == []
    with_model = lambda mid, m: rec(mid, 1, 1).replace('"message": {', f'"message": {{"model": "{m}", ')
    assert read_usage([with_model("a", "m-2"), with_model("b", "m-1"), with_model("c", "<synthetic>")])[2] == ["m-1", "m-2"]
    assert [model_match(r, a) for r, a in [("m-1", ["m-1"]), ("m-1", ["m-1", "side"]), ("m-1", ["m-2"]), ("m-1", []), (None, ["m-1"]), ("opus", ["claude-opus-x"])]] \
        == ["exact", "mixed", "mismatch", "unavailable", "unavailable", "mismatch"]
    # Order: every task x rep block holds all arms; with reps = arm count each arm takes each position once per task.
    tasks = [{"id": "t1", "arms": {"a": "", "b": "", "c": ""}}, {"id": "t2", "arms": {"a": "", "b": ""}}]
    rows = plan(tasks, 6, 7)
    for t in tasks:
        n = len(t["arms"])
        blocks = [[a for tt, a, r in rows if tt is t and r == rep] for rep in range(6)]
        assert all(sorted(b) == sorted(t["arms"]) for b in blocks), blocks
        assert all(sum(b[pos] == arm for b in blocks) == 6 // n for arm in t["arms"] for pos in range(n)), blocks
    assert plan(tasks, 6, 7) == rows                                 # same seed, same order
    # A hung or missing command is a recorded error, not an exception that loses the row.
    assert call(["/bin/sleep", "3"], None, 1)[2].startswith("timed out")
    assert call(["/nonexistent/claude"], None, 5)[2].startswith("could not start")
    assert call(["/bin/sh", "-c", "exit 3"], None, 5)[0] == 3
    for bad in ([rec("a", 1, 2), rec("a", 2, 2)], [rec("a", 1, 5), rec("a", 1, 4)], [rec("a", 1, 2).replace('"input_tokens": 1', '"input_tokens": true')],
                [rec("a", 1, 2).replace('"input_tokens": 1', '"input_tokens": 1.5')], ['{"type": "assistant", BROKEN'], []):
        try:
            read_usage(bad)
        except Unavailable:
            continue
        raise AssertionError(f"accepted {bad}")
    end_to_end_with_fake_cli()
    print("self-test ok")


def end_to_end_with_fake_cli():
    """Runs this script as a child against a fake `claude` that only logs its calls and writes a transcript.
    No real CLI, no model call. Checks the consent gate, per-row model readback, timeouts and the manifest."""
    tmp = Path(tempfile.mkdtemp(prefix="c2d-exp-selftest-"))
    calls, home = tmp / "calls.log", tmp / "home"
    fake = tmp / "claude"
    fake.write_text(f"""#!{sys.executable}
import json, os, re, sys, time
open({str(calls)!r}, "a").write(" ".join(sys.argv[1:2]) + "\\n")
if sys.argv[1:] == ["--version"]:
    print("0.0.0 (fake)"); sys.exit(0)
a = sys.argv
model = os.environ.get("FAKE_MODEL") or (a[a.index("--model") + 1] if "--model" in a else "default")
sid = a[a.index("--session-id") + 1] if "--session-id" in a else a[a.index("--resume") + 1]
time.sleep(float(os.environ.get("FAKE_SLEEP", "0")))
d = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", re.sub(r"[^A-Za-z0-9]", "-", os.getcwd()))
os.makedirs(d, exist_ok=True)
open(os.path.join(d, sid + ".jsonl"), "a").write(json.dumps({{"type": "assistant", "version": "0.0.0", "message": {{
    "id": "m" + str(time.time()), "model": model, "usage": {{"input_tokens": 3, "output_tokens": 1}}}}}}) + "\\n")
print("ok")
""")
    fake.chmod(0o755)
    (tmp / "ctx.txt").write_text("ctx")
    (tmp / "tasks.json").write_text(json.dumps({"tasks": [{"id": "t", "question": "q", "check": "grep -q ok \"$ANSWER_FILE\"",
                                                           "arms": {"a": "ctx.txt", "b": "ctx.txt"}}]}))

    def run(*extra, stdin="", **env):
        out = tmp / f"out{len(list(tmp.glob('out*')))}"
        p = subprocess.run([sys.executable, "-I", __file__, "--tasks", str(tmp / "tasks.json"), "--claude", str(fake), "--model", "m-1",
                            "--reps", "2", "--out", str(out), *extra], input=stdin, capture_output=True, text=True, timeout=120,
                           env={**os.environ, "CLAUDE_CONFIG_DIR": str(home), **env})
        rows = [json.loads(l) for l in (out / "results.jsonl").read_text().splitlines()] if (out / "results.jsonl").exists() else []
        return p, rows, out

    p, rows, _ = run()                                                    # plan only
    assert p.returncode == 0 and "no model was called" in p.stdout and not calls.exists(), p.stdout
    p, _, _ = run("--json")
    plan_json = json.loads(p.stdout)
    assert plan_json["runs"] == 4 and plan_json["model"] == "m-1" and not calls.exists(), p.stdout
    p, rows, _ = run("--run", stdin="spend\n")                           # anything but SPEND cancels before any call
    assert p.returncode != 0 and not rows and not calls.exists(), p.stdout
    p, rows, _ = run("--run")                                             # no input at all (EOF) also cancels
    assert p.returncode != 0 and not rows and not calls.exists()
    p, rows, out = run("--run", stdin="SPEND\n")
    assert p.returncode == 0 and [r["model_match"] for r in rows] == ["exact"] * 4 and all(r["success"] for r in rows), p.stdout + p.stderr
    assert [r["order"] for r in rows] == [0, 1, 2, 3] and "WARNING" not in p.stdout
    m = json.loads((out / "manifest.json").read_text())
    assert m["model"] == "m-1" and m["claude_version"] == "0.0.0 (fake)" and m["seed"] == 1 and m["script_sha256"] and m["tasks_sha256"]
    p, rows, _ = run("--run", stdin="SPEND\n", FAKE_MODEL="m-2")         # CLI used another model: flagged, never hidden
    assert [r["model_match"] for r in rows] == ["mismatch"] * 4 and "WARNING: not a same-model comparison" in p.stdout, p.stdout
    p, rows, _ = run("--run", "--timeout", "1", "--max-retries", "0", stdin="SPEND\n", FAKE_SLEEP="3")
    assert len(rows) == 4 and all(r["error"].startswith("claude timed out") and not r["success"] for r in rows), rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tasks")
    ap.add_argument("--run", action="store_true", help="actually call `claude -p` (spends model usage)")
    ap.add_argument("--model", help="passed to `claude --model`; the same for every arm (give the full model id)")
    ap.add_argument("--claude", default="claude", help="Claude Code executable (C2D passes the path it discovered)")
    ap.add_argument("--json", action="store_true", help="print the plan as JSON and exit (never runs anything)")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--max-retries", type=int, default=1)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=600, help="seconds per claude call")
    ap.add_argument("--out", help="results folder (default: a new temp folder)")
    ap.add_argument("--usage", help="print provider-reported usage of one transcript .jsonl and exit")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if args.usage:
        try:
            total, versions, models = read_usage(Path(args.usage).read_text(errors="replace").splitlines())
            print(json.dumps({**total, "cli_versions": versions, "models": models, "source": "provider-reported"}, indent=1))
        except Unavailable as e:
            print(f"unavailable: {e}")
        return
    if not args.tasks:
        ap.error("--tasks is required")
    tasks, template, base = load_tasks(args.tasks)
    rows = plan(tasks, args.reps, args.seed)
    if args.json:
        print(json.dumps({"runs": len(rows), "reps": args.reps, "seed": args.seed, "max_retries": args.max_retries,
                          "model": args.model, "tasks": [t["id"] for t in tasks], "arms": sorted({a for t in tasks for a in t["arms"]}),
                          "rows": [{"task": t["id"], "arm": a, "rep": r, "same_context_as": same_context(t, a, base)} for t, a, r in rows]}))
        return
    print(f"{len(rows)} run(s), model {args.model or '(CLI default)'}, up to {args.max_retries} retry each, order seed {args.seed}:")
    for t, arm, r in rows:
        ctx = (base / t["arms"][arm]).read_bytes()
        same = same_context(t, arm, base)
        print(f"  {t['id']:<22} {arm:<18} rep {r}  context {len(ctx)} bytes  sha256 {sha256(ctx)}"
              + (f"  (same context as {', '.join(same)}: A/A control, not a treatment)" if same else ""))
    if not args.run:
        print("\nPlan only: no model was called. Add --run to execute (spends model usage).")
        return
    try:
        answer = input("\nThis calls Claude Code and spends model usage on your account. Type SPEND to continue: ")
    except EOFError:
        answer = ""
    if answer.strip() != "SPEND":
        sys.exit("Cancelled; nothing was run.")
    # Closing C2D's pane (SIGTERM/SIGHUP) stops the run: SystemExit inside subprocess.run kills the running claude
    # child, and the rows already appended to results.jsonl stay as they are (an incomplete run, never retried).
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit("Stopped; results.jsonl holds the completed rows only."))
    out_dir = args.out or tempfile.mkdtemp(prefix="c2d-experiment-")
    os.makedirs(out_dir, exist_ok=True)
    (Path(out_dir) / "manifest.json").write_text(json.dumps(manifest(args, args.tasks), indent=1))
    results = []
    for i, (t, arm, r) in enumerate(rows):
        print(f"running {t['id']} / {arm} / rep {r} …", flush=True)
        results.append(run_row(t, arm, r, i, template, base, args, out_dir))
        with open(Path(out_dir) / "results.jsonl", "a") as fh:
            fh.write(json.dumps(results[-1]) + "\n")
    with open(Path(out_dir) / "results.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(results[0].keys()))
        w.writeheader()
        w.writerows(results)
    summarize(results)
    print(f"\nResults: {out_dir}/results.csv (answers saved next to it)")


if __name__ == "__main__":
    main()
