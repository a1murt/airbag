#!/usr/bin/env python3 -I
"""Removes translations whose English key no longer appears anywhere in Sources/AirbagApp.

A key counts as used when its text, with %@ / %lld turned into "any interpolation", occurs as a string literal in a
Swift file (a looser test than check-l10n's, so keys used through LocalizedStringKey variables are kept).

usage: prune-l10n.py [--dry-run]
"""
import glob, os, plistlib, re, subprocess, sys

RES = 'Sources/AirbagApp/Resources'


def load(path):
    out = subprocess.run(['plutil', '-convert', 'json', '-o', '-', path], capture_output=True, text=True, check=True)
    import json
    return json.loads(out.stdout) if out.stdout.strip() else {}


def used(key, source):
    parts = re.split(r'%(?:\d+\$)?(?:lld|ld|d|@)', key)
    pattern = r'\\\([^"]*?\)'.join(re.escape(p.replace('"', '\\"')) for p in parts)
    return re.search('"' + pattern + '"', source) is not None


def write_strings(path, header, entries):
    def esc(s):
        return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    lines = [header] + [f'"{esc(k)}" = "{esc(v)}";' for k, v in sorted(entries.items(), key=lambda kv: kv[0].lower())]
    open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')


def main():
    dry = '--dry-run' in sys.argv
    source = ''.join(open(f, encoding='utf-8').read() for f in glob.glob('Sources/AirbagApp/**/*.swift', recursive=True))
    removed = set()
    for d in sorted(glob.glob(f'{RES}/*.lproj')):
        sp = f'{d}/Localizable.strings'
        if os.path.exists(sp):
            text = open(sp, encoding='utf-8').read()
            header = text.split('\n', 1)[0] if text.startswith('/*') else ''
            entries = load(sp)
            keep = {k: v for k, v in entries.items() if used(k, source)}
            removed |= set(entries) - set(keep)
            if not dry and len(keep) != len(entries):
                write_strings(sp, header, keep)
        pp = f'{d}/Localizable.stringsdict'
        if os.path.exists(pp):
            plural = plistlib.load(open(pp, 'rb'))
            keep = {k: v for k, v in plural.items() if used(k, source)}
            removed |= set(plural) - set(keep)
            if not dry and len(keep) != len(plural):
                plistlib.dump(keep, open(pp, 'wb'), sort_keys=True)
    for k in sorted(removed):
        print(('would remove ' if dry else 'removed ') + repr(k))


if __name__ == '__main__':
    main()
