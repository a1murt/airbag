#!/usr/bin/env python3 -I
"""Simulated agent: calls the real `airbag hook <agent>` binary exactly like the agents do (JSON on stdin, reply on
stdout), runs the shell command only when the reply allows it, and checks the outcome. Everything happens inside a
temporary sandbox; the "dangerous" targets are sacrificial directories in that sandbox."""
import json, os, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True).stdout.strip() + "/airbag"
work = os.path.realpath(tempfile.mkdtemp(prefix="airbag-e2e-"))
env = dict(os.environ, AIRBAG_HOME=os.path.join(work, "home"))
for k in list(env):
    if k.startswith("CLAUDE") or k.startswith("CODEX"): env.pop(k)
parent = os.path.join(work, "parent"); proj = os.path.join(parent, "proj")
os.makedirs(os.path.join(proj, "src/legacy"))
open(os.path.join(proj, "src/index.ts"), "w").write("export const a = 1;\n")
open(os.path.join(proj, "src/legacy/old.ts"), "w").write("old\n")
open(os.path.join(proj, ".env"), "w").write("SECRET=1\n")
subprocess.run("git init -q && git add -A && git -c user.email=e@e -c user.name=e commit -qm init", shell=True, cwd=proj, check=True)
failures = []; timings = []

def hook(agent, payload, hint=None):
    args = [BIN, "hook", agent] + ([hint] if hint else [])
    t = time.perf_counter()
    p = subprocess.run(args, input=json.dumps(payload), capture_output=True, text=True, env=env, cwd=proj)
    timings.append((agent, payload.get("tool_input", {}).get("command") or payload.get("command") or payload.get("hook_event_name"), (time.perf_counter() - t) * 1000))
    assert p.returncode == 0, f"hook exit {p.returncode}: {p.stderr}"
    return json.loads(p.stdout) if p.stdout.strip() else None

def claude(cmd, tid):
    return {"session_id": "e2e-claude", "cwd": proj, "hook_event_name": "PreToolUse", "permission_mode": "default",
            "tool_name": "Bash", "tool_input": {"command": cmd}, "tool_use_id": tid, "transcript_path": "/dev/null"}

def decision_claude(r):
    return (r or {}).get("hookSpecificOutput", {}).get("permissionDecision", "allow")

def agent_runs(cmd, tid):
    """What Claude Code does: PreToolUse → run if allowed → PostToolUse."""
    r = hook("claude-code", claude(cmd, tid))
    d = decision_claude(r)
    if d == "allow":
        subprocess.run(cmd, shell=True, cwd=proj)
        post = claude(cmd, tid); post["hook_event_name"] = "PostToolUse"; post["tool_response"] = {"stdout": "", "stderr": "", "interrupted": False}
        hook("claude-code", post)
    return d, r

def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond: failures.append(msg)

print("== session start"); hook("claude-code", {"session_id": "e2e-claude", "cwd": proj, "hook_event_name": "SessionStart", "source": "startup"})
print("== 1. rm -rf src (recoverable)")
d, _ = agent_runs("rm -rf src", "t1")
check(d == "allow" and not os.path.exists(os.path.join(proj, "src")), "allowed after a snapshot, src deleted")
print("== 2. rm -rf <parent of project> (catastrophic)")
d, r = agent_runs(f"rm -rf {parent}", "t2")
check(d == "deny" and os.path.isdir(parent), "denied, parent directory survived")
check("Airbag blocked" in json.dumps(r), "agent sees an explanation")
print("== 3. git reset --hard after uncommitted work")
os.makedirs(os.path.join(proj, "src"), exist_ok=True)
open(os.path.join(proj, "src/wip.ts"), "w").write("work in progress\n")
subprocess.run("git add -A", shell=True, cwd=proj)
d, _ = agent_runs("git reset --hard HEAD", "t3")
check(d == "allow", "git reset --hard allowed with snapshot")
print("== 4. git push --force (ask)")
d, r = agent_runs("git push --force origin main", "t4")
check(d == "ask", "native ask for Claude")
print("== 5. Codex ask → deny with allowance → allow once")
cx = {"session_id": "e2e-codex", "turn_id": "u1", "cwd": proj, "hook_event_name": "PreToolUse", "tool_name": "Bash",
      "tool_input": {"command": "terraform destroy"}, "tool_use_id": "c1"}
r = hook("codex", cx, "pre-bash")
check(r and r["hookSpecificOutput"]["permissionDecision"] == "deny", "Codex gets deny with allowance hint")
gid = json.loads(subprocess.run([BIN, "guard", "--json"], capture_output=True, text=True, env=env).stdout)[0]["id"]
subprocess.run([BIN, "allow", gid], env=env, check=True, capture_output=True)
cx["tool_use_id"] = "c2"
check(hook("codex", cx, "pre-bash") is None, "after `airbag allow`, the retried command passes (Codex: empty reply)")
print("== 6. restore what the agent destroyed")
log = json.loads(subprocess.run([BIN, "log", "--json"], capture_output=True, text=True, env=env).stdout)
snap_for = lambda c: next(e["snapshot"] for e in log if e["command"].startswith(c))
check(all(e["snapshot"] for e in log if e["decision"] in ("allow", "allow_once")), "every allowed command points at a snapshot")
subprocess.run([BIN, "restore", snap_for("rm -rf src"), "--root", proj, "--path", "src"], env=env, check=True, capture_output=True)
check(open(os.path.join(proj, "src/legacy/old.ts")).read() == "old\n", "src/legacy restored from the pre-command snapshot")
subprocess.run([BIN, "restore", snap_for("git reset --hard"), "--root", proj, "--path", "src/wip.ts"], env=env, check=True, capture_output=True)
check(os.path.exists(os.path.join(proj, "src/wip.ts")), "work in progress restored after git reset --hard")
print("== 7. session end")
hook("claude-code", {"session_id": "e2e-claude", "cwd": proj, "hook_event_name": "SessionEnd", "reason": "other"})
sessions = json.loads(subprocess.run([BIN, "sessions", "--all", "--json"], capture_output=True, text=True, env=env).stdout)
check(any(s["session"] == "e2e-claude" and s["ended"] > 0 for s in sessions), "session recorded and ended")
print("\nhook latency (process start → reply), ms:")
for a, c, ms in timings: print(f"  {ms:7.1f}  {a:12s} {str(c)[:60]}")
lat = sorted(ms for _, _, ms in timings)
print(f"  p50 {lat[len(lat)//2]:.1f} ms, max {lat[-1]:.1f} ms")
shutil.rmtree(work, ignore_errors=True)
print("\nRESULT:", "PASS" if not failures else f"FAIL ({len(failures)})")
sys.exit(1 if failures else 0)
