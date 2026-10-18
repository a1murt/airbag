#!/usr/bin/env python3 -I
"""Replays the shell commands real agent sessions ran on this Mac through two `airbag` binaries and compares the
circuit breaker's verdicts. Analysis only: `airbag check` never runs a command. The commands stay on this machine;
nothing is written to the repository.

usage: Scripts/breaker-corpus.py OLD_AIRBAG NEW_AIRBAG [--show N]
"""
import glob, json, os, subprocess, sys
from collections import Counter

HOME = os.path.expanduser("~")

def commands():
    seen = {}
    for f in glob.glob(os.path.join(HOME, ".claude/projects/*/*.jsonl")):
        if os.path.basename(os.path.dirname(f)).startswith("ssh-"):  # remote sessions: remote paths
            continue
        for line in open(f, errors="replace"):
            if '"Bash"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            content = (o.get("message") or {}).get("content")
            for part in content if isinstance(content, list) else []:
                if isinstance(part, dict) and part.get("type") == "tool_use" and part.get("name") == "Bash":
                    cmd = (part.get("input") or {}).get("command")
                    if cmd and o.get("cwd"):
                        seen[(cmd, o["cwd"])] = True
    return list(seen)

def root_for(cwd):
    d = cwd
    while d and d != "/" and d != HOME:
        if os.path.lexists(os.path.join(d, ".git")):
            return d
        d = os.path.dirname(d)
    return cwd if cwd != HOME else "/nonexistent-airbag-root"

def verdict(binary, cmd, cwd):
    p = subprocess.run([binary, "check", "--json", "--cwd", cwd, "--root", root_for(cwd), cmd], capture_output=True, text=True, timeout=20)
    try:
        v = json.loads(p.stdout)
    except ValueError:
        return ("error", ())
    return (v["decision"], tuple(sorted({f["ruleId"] for f in v.get("findings", []) if f["decision"] == v["decision"]})))

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    old, new = sys.argv[1], sys.argv[2]
    show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 5
    rows = commands()
    rank = {"allow": 0, "ask": 1, "block": 2, "error": 3}
    stats = {"old": Counter(), "new": Counter()}
    changed = []
    for cmd, cwd in rows:
        a, b = verdict(old, cmd, cwd), verdict(new, cmd, cwd)
        stats["old"][a[0]] += 1
        stats["new"][b[0]] += 1
        if a[0] != b[0]:
            changed.append(("stricter" if rank[b[0]] > rank[a[0]] else "looser", a, b, cmd))
    n = len(rows)
    for k in ("old", "new"):
        s = stats[k]
        print(f"{k}: {n} commands  allow {s['allow']}  ask {s['ask']} ({100 * s['ask'] / max(n, 1):.1f} %)  block {s['block']}  error {s['error']}")
    print(f"decision changed: {len(changed)}  {Counter(c[0] for c in changed)}")
    for direction in ("stricter", "looser"):
        group = [c for c in changed if c[0] == direction]
        if group:
            print(f"\n{direction}:")
            for _, a, b, cmd in group[:show]:
                print(f"  {a[0]} {list(a[1])} -> {b[0]} {list(b[1])}\n    {cmd[:160]!r}")

if __name__ == "__main__":
    main()
