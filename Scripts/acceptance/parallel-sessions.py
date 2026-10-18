#!/usr/bin/env python3 -I
"""MVP readiness check from the market report: 3–5 parallel agent sessions in worktrees; every dev server is
attributed to its session, including servers that survive their session. Uses fake agent binaries named
`claude`/`codex`, the real hook binary and the real radar, all in a temporary sandbox."""
import json, os, shutil, signal, subprocess, sys, tempfile, time
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True).stdout.strip() + "/airbag"
work = os.path.realpath(tempfile.mkdtemp(prefix="airbag-accept-"))
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CODEX"))}
env["AIRBAG_HOME"] = os.path.join(work, "home")
agents_dir = os.path.join(work, "bin"); os.makedirs(agents_dir)
subprocess.run(["swiftc", "-O", "-o", os.path.join(agents_dir, "claude"), os.path.join(ROOT, "Scripts/acceptance/fake-agent.swift")], check=True, capture_output=True)
shutil.copy(os.path.join(agents_dir, "claude"), os.path.join(agents_dir, "codex"))
repo = os.path.join(work, "shop")
os.makedirs(repo)
sh = lambda c, cwd=repo: subprocess.run(c, shell=True, cwd=cwd, check=True, capture_output=True)
sh("git init -q && echo hi > a.txt && git add -A && git -c user.email=a@a -c user.name=a commit -qm init")
trees = {"main": repo}
for name, path in [("claude-1", ".claude/worktrees/agent-1"), ("claude-2", ".claude/worktrees/agent-2"), ("codex-1", "../codex-wt/shop")]:
    sh(f"git worktree add -q --detach {path}")
    trees[name] = os.path.realpath(os.path.join(repo, path))
sessions = [("claude", "sess-main", trees["main"]), ("claude", "sess-wt1", trees["claude-1"]), ("claude", "sess-wt2", trees["claude-2"]),
            ("codex", "thread-wt3", trees["codex-1"]), ("codex", "thread-main", trees["main"])]
procs = {}
for kind, sid, cwd in sessions:
    p = subprocess.Popen([os.path.join(agents_dir, kind), BIN, sid, cwd], stdout=subprocess.PIPE, text=True, env=env)
    line = p.stdout.readline().split()
    procs[sid] = (p, int(line[1]), kind, cwd)
time.sleep(0.5)
# Two agents end: one gracefully with a SessionEnd hook, one crashes. Their servers keep running.
def session_end(kind, sid, cwd):
    payload = json.dumps({"session_id": sid, "cwd": cwd, "hook_event_name": "SessionEnd", "reason": "other"})
    subprocess.run([BIN, "hook", "claude-code" if kind == "claude" else "codex"] + (["session-end"] if kind == "codex" else []),
                   input=payload, text=True, env=env, capture_output=True)
p, _, kind, cwd = procs["sess-wt2"]; session_end(kind, "sess-wt2", cwd); p.kill()
p, _, kind, cwd = procs["thread-wt3"]; p.kill()            # crash: no SessionEnd
time.sleep(0.5)
rows = json.loads(subprocess.run([BIN, "ports", "--json"], capture_output=True, text=True, env=env).stdout)
by_port = {r["listeners"][0]["port"]: r for r in rows}
failures = []
expect = {"sess-main": "attached", "sess-wt1": "attached", "sess-wt2": "orphan", "thread-wt3": "orphan", "thread-main": "attached"}
print(f"{'session':12s} {'port':>6s}  {'state':9s} {'attributed to':16s} project/worktree")
for sid, (p, port, kind, cwd) in procs.items():
    r = by_port.get(port)
    if not r: failures.append(f"{sid}: server on :{port} not found"); print(f"{sid:12s} {port:6d}  MISSING"); continue
    a = r.get("attribution") or {}
    print(f"{sid:12s} {port:6d}  {r['linkState']:9s} {str(a.get('agentSessionID')):16s} {a.get('projectRoot')}")
    if a.get("agentSessionID") != sid: failures.append(f"{sid}: attributed to {a.get('agentSessionID')}")
    if r["linkState"] != expect[sid]: failures.append(f"{sid}: state {r['linkState']}, expected {expect[sid]}")
    if a.get("projectRoot") != os.path.realpath(cwd): failures.append(f"{sid}: project {a.get('projectRoot')}, expected {cwd}")
# Stop an orphan through the CLI: SIGTERM path, the agent processes stay untouched.
orphan_port = procs["sess-wt2"][1]
r = subprocess.run([BIN, "stop", str(by_port[orphan_port]["identity"]["pid"])], capture_output=True, text=True, env=env)
print(r.stdout.strip())
alive_after = json.loads(subprocess.run([BIN, "ports", "--json"], capture_output=True, text=True, env=env).stdout)
if any(x["listeners"][0]["port"] == orphan_port for x in alive_after): failures.append("orphan still listening after stop")
for sid, (p, port, kind, cwd) in procs.items():
    try: p.kill()
    except Exception: pass
subprocess.run(f"pkill -f 'time.sleep\\(600\\)' -U {os.getuid()}", shell=True)
shutil.rmtree(work, ignore_errors=True)
print("RESULT:", "PASS" if not failures else "FAIL\n  " + "\n  ".join(failures))
sys.exit(1 if failures else 0)
