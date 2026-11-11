#!/usr/bin/env python3
"""Feeds generated hostile shell commands to `airbag check` and fails if one crashes it or hangs.

A crashed hook lets the command run unchecked in Claude Code, Codex and Cursor (they fail open), so the command
parser must survive anything an agent can type: brace sequences at the ends of Int, deep `$(…)` nesting, unbalanced
quotes and braces, very long words, control characters. Nothing is executed; `airbag check` only analyses.

    python3 -I Scripts/guard-fuzz.py [--bin PATH] [--count N] [--seed S] [--jobs J]

Same seed, same commands. Exit status 1 lists the commands that crashed (exit status 128 or more) or took longer than
2 s: the hook answers within 4 s, and a verdict that comes too late must never become the answer.
"""

import argparse
import concurrent.futures
import os
import random
import subprocess
import sys

NUMBERS = ["0", "1", "-1", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "-9223372036854775809",
           "18446744073709551615", "00", "-0", "007", "99999999999999999999999", "1e9", "0x10", ""]
ATOMS = ["rm", "-rf", "~", "/", ".", "..", "src", "x", '"a b"', "'q'", "$HOME", "${HOME}", "$(pwd)", "`ls`", "*", "**/*",
         ".env", ".git", "|", "&&", "||", ";", ">", ">>", "2>&1", "<", "<<<", "&", "!", "{", "}", "{a,b}", "{1..3}", "\\",
         "$((1+2))", "${x:-y}", "${x:0:-1}", "${#x}", "$?", "$$", "$@", "$'\\x41'", "~root", "~+", "-", "--", "=", "a=b",
         "sudo", "env", "-S", "bash", "-c", "sh", "eval", "xargs", "find", "-exec", "-delete", "git", "reset", "--hard",
         "clean", "-fdx", "mv", "cp", "sed", "-i", "dd", "of=/dev/disk0", "mkfs", "chmod", "777", "airbag", "allow",
         "hooks", "uninstall", "python3", "-c", "node", "-e", "(", ")", "((", "))", "[[", "]]", "#", "\n", "\t", "é", "💥",
         "\x01", "<<EOF", "EOF", "<(ls)", ">(cat)", "$[1]", "{,}", "{..}", "{a..}", "{1..2..}"]


def sequence(rng):
    a, b = rng.choice(NUMBERS), rng.choice(NUMBERS)
    if rng.random() < 0.2:
        a, b = rng.choice("aZz@[0"), rng.choice("aZz@[0")
    if rng.random() < 0.5:
        return "{%s..%s..%s}" % (a, b, rng.choice(NUMBERS))
    return "{%s..%s}" % (a, b)


def word(rng):
    r = rng.random()
    if r < 0.25:
        return sequence(rng)
    if r < 0.30:
        return "{" + ",".join(rng.choice(ATOMS) for _ in range(rng.randint(0, 4))) + "}"
    if r < 0.35:
        return "$(" * rng.randint(1, 40) + "x" + ")" * rng.randint(0, 40)
    if r < 0.38:
        return '"' + '$("' * rng.randint(1, 20)
    if r < 0.40:
        return "a" * rng.randint(1000, 20000)
    if r < 0.42:
        return "{" * rng.randint(1, 300) + "a,b" + "}" * rng.randint(0, 300)
    return rng.choice(ATOMS)


def commands(count, seed):
    rng = random.Random(seed)
    out = [" ".join(word(rng) for _ in range(rng.randint(1, 12))) for _ in range(count)]
    # The cases that crashed 0.1.4 (abs() of Int.min in a brace sequence).
    out += ["echo {1..-9223372036854775808}", "rm -rf ~ ; echo {0..1..-9223372036854775808}",
            "echo {9223372036854775807..-9223372036854775808..1}"]
    # Padding that made the verdict slow in 0.1.5 (each `cd` made later paths costlier to resolve).
    out += ["rm -rf ~; " + "cd a; " * 2000, "rm -rf ~; " + "pushd a; " * 2000, "cd a; " * 2000 + "rm -rf *",
            "rm -rf ~; echo " + "eyJaaaaaa-" * 20000, "rm -rf ~; " + "x=" + "a" * 200000]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bin", default=os.path.join(".build", "release", "airbag"))
    ap.add_argument("--count", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()
    if not os.access(a.bin, os.X_OK):
        sys.exit("no airbag binary at %s (swift build -c release --product airbag)" % a.bin)

    def run(cmd):
        try:
            p = subprocess.run([a.bin, "check", "--cwd", "/private/tmp", "--root", "/private/tmp", cmd],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=2)
            return p.returncode, cmd
        except subprocess.TimeoutExpired:
            return "timeout", cmd

    cmds = commands(a.count, a.seed)
    bad = []
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool:
        for status, cmd in pool.map(run, cmds):
            if status == "timeout" or status < 0 or status >= 128:
                bad.append((status, cmd))
    print("%d commands, %d crashed or hung (seed %d)" % (len(cmds), len(bad), a.seed))
    for status, cmd in bad[:20]:
        print("  %s: %r" % (status, cmd[:200]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
