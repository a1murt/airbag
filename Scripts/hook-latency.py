#!/usr/bin/env python3 -I
"""Hook latency without running anything: feeds `airbag hook claude-code` PreToolUse payloads, as Claude Code does,
and times process start to reply. The commands are only decided on, never executed. Sandbox project and AIRBAG_HOME
live in a temp folder under /private/tmp, removed at the end.

Every call gets its own tool_use_id: a repeated id is the same call arriving twice, which the hook answers from its
first decision without a snapshot.

usage: Scripts/hook-latency.py AIRBAG_BIN [FILES] [RUNS]
"""
import itertools, json, os, shutil, statistics, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1])
FILES = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
RUNS = int(sys.argv[3]) if len(sys.argv) > 3 else 60
ids = itertools.count()
work = os.path.realpath(tempfile.mkdtemp(prefix="airbag-latency-", dir="/private/tmp"))  # not below /private/var (ADR-032)
try:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CODEX"))}
    env["AIRBAG_HOME"] = os.path.join(work, "home")
    proj = os.path.join(work, "proj")
    blob = os.urandom(5000).hex()  # ~10 KB per file
    for i in range(FILES):
        d = os.path.join(proj, "src", f"m{i // 100:03d}")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"f{i:05d}.ts"), "w") as f:
            f.write(f"// {i}\n{blob}\n")
    subprocess.run("git init -q && git add -A && git -c user.email=e@e -c user.name=e -c commit.gpgsign=false commit -qm init",
                   shell=True, cwd=proj, check=True)

    def hook(cmd):
        payload = {"session_id": "latency", "transcript_path": "/tmp/t.jsonl", "cwd": proj, "permission_mode": "default",
                   "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": cmd, "description": "x"},
                   "tool_use_id": f"toolu_{next(ids)}"}
        t = time.perf_counter()
        p = subprocess.run([BIN, "hook", "claude-code"], input=json.dumps(payload), capture_output=True, text=True, env=env, cwd=proj)
        ms = (time.perf_counter() - t) * 1000
        assert p.returncode == 0, p.stderr
        assert p.stdout.strip() == "{}", f"expected a plain allow for {cmd!r}, got {p.stdout.strip()[:200]}"
        return ms

    # The first command that changes files creates the store and takes the initial snapshot; then steady state.
    first = hook("rm -rf src/m000")
    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(os.path.join(proj, "src")) for f in fs)
    print(f"project: {FILES} files, {size / 1e6:.0f} MB; first file-changing command, initial snapshot included: {first:.0f} ms")
    for label, cmd in [("read-only command (no snapshot)", "ls src"),
                       ("file-changing command, project unchanged since the last snapshot", "rm -rf src/m000")]:
        for _ in range(3):
            hook(cmd)  # warm-up
        times = sorted(hook(cmd) for _ in range(RUNS))
        print(f"{label}: p50 {statistics.median(times):.1f} ms, p90 {times[int(len(times) * 0.9)]:.1f} ms, max {times[-1]:.1f} ms ({RUNS} runs)")
finally:
    shutil.rmtree(work, ignore_errors=True)
