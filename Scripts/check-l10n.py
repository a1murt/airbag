#!/usr/bin/env python3 -I
"""Checks the interface translations.

1. Every user-facing string in Sources/AirbagApp has an entry in the reference translation (ru.lproj).
2. Every other language has exactly the reference keys, the same format specifiers (reordered only with positional
   specifiers such as %1$@), and every plural form its language needs (CLDR categories).

usage: check-l10n.py [--lang CODE]      (default: all languages)
"""
import glob, json, os, plistlib, re, subprocess, sys

RES = 'Sources/AirbagApp/Resources'
REFERENCE = 'ru'
# CLDR plural categories a translation must provide; English and other one/other languages need both.
PLURALS = {
    'ru': {'one', 'few', 'many', 'other'}, 'uk': {'one', 'few', 'many', 'other'}, 'pl': {'one', 'few', 'many', 'other'},
    'ja': {'other'}, 'ko': {'other'}, 'zh-Hans': {'other'}, 'zh-Hant': {'other'}, 'id': {'other'}, 'vi': {'other'},
}
ONE_OTHER = {'one', 'other'}

# Interpolations Swift formats as %lld. Name integer values …Count / …count (or use .count) so they are recognised.
INT = re.compile(r'(\.count\b|[cC]ount\b|\bn\b|liveSessions|commandsToday|unprotectedDuringPause|\bport\b|\$0\b|[+-]\s*\d)')
SPEC = re.compile(r'%(?:(\d+)\$)?(lld|ld|d|@)')
VARIABLE = re.compile(r'%#@(\w+)@')


def key(lit):
    out, i = '', 0
    while i < len(lit):
        if lit.startswith('\\(', i):
            depth, j = 1, i + 2
            while j < len(lit) and depth:
                depth += {'(': 1, ')': -1}.get(lit[j], 0); j += 1
            out += '%lld' if INT.search(lit[i + 2:j - 1]) else '%@'; i = j; continue
        out += lit[i]; i += 1
    return out.replace('\\"', '"')


def load_strings(path):
    out = subprocess.run(['plutil', '-convert', 'json', '-o', '-', path], capture_output=True, text=True)
    if out.returncode != 0:
        raise ValueError(out.stderr.strip() or out.stdout.strip())
    return json.loads(out.stdout) if out.stdout.strip() else {}


def specs(s):
    """Specifier types in argument order; None when positional and plain specifiers are mixed."""
    found = SPEC.findall(s)
    if not found:
        return []
    positional = [p for p, _ in found if p]
    if positional and len(positional) != len(found):
        return None
    if positional:
        return [t for _, t in sorted(found, key=lambda x: int(x[0]))]
    return [t for _, t in found]


def same_specs(reference, translated):
    a, b = specs(reference), specs(translated)
    norm = lambda xs: None if xs is None else ['lld' if x in ('ld', 'd') else x for x in xs]
    return norm(b) is not None and norm(a) == norm(b)


def source_keys():
    pat = re.compile(r'(?:bullet\("[^"]*",\s*|\bTextField|\bText|\bButton|\bLabel|\bToggle|\bPicker|\bSection|\bMenu|\bLink|\bTableColumn|\bContentUnavailableView|\bLocalizedStringKey|\bLocalizedStringResource|\.navigationTitle|\.navigationSubtitle|\.confirmationDialog|\.alert|\.help|prompt:|String\(localized:|Pill\(text:|StatusDot\(text:|Callout\(\.\w+,|SectionHeader\(title:|EmptyState\(symbol: "[^"]*", title:|, message:|case \.\w+: return|resolutionText.*return|title = )\s*\(?\s*"((?:[^"\\]|\\.)*)"')
    symbols = re.compile(r'^[a-z]+(\.[a-z.]+)*$')
    sf = {'airplane', 'camera', 'diamond', 'gearshape', 'shield', 'sparkle', 'terminal', 'folder', 'pin', 'lock'}
    out = {}
    for f in glob.glob('Sources/AirbagApp/**/*.swift', recursive=True):
        for m in pat.finditer(open(f, encoding='utf-8').read()):
            k = key(m.group(1))
            if not k or k == 'Airbag' or k.startswith('http') or re.fullmatch(r'[\W\d_%@lA-Z]{0,3}', k) or symbols.match(k) and ('.' in k or k in sf):
                continue
            out.setdefault(k, os.path.basename(f))
    return out


def main():
    only = sys.argv[sys.argv.index('--lang') + 1] if '--lang' in sys.argv else None
    problems = []
    ref = load_strings(f'{RES}/{REFERENCE}.lproj/Localizable.strings')
    ref_plural = plistlib.load(open(f'{RES}/en.lproj/Localizable.stringsdict', 'rb'))
    if only in (None, REFERENCE):
        ru_plural = plistlib.load(open(f'{RES}/{REFERENCE}.lproj/Localizable.stringsdict', 'rb'))
        for k, f in sorted(source_keys().items()):
            if k not in ref and k not in ru_plural:
                problems.append(f'{REFERENCE}: missing {k!r} ({f})')
    langs = sorted(os.path.basename(d)[:-6] for d in glob.glob(f'{RES}/*.lproj'))
    for lang in langs:
        if lang == 'en' or (only and lang != only):
            continue
        base = f'{RES}/{lang}.lproj'
        try:
            tr = load_strings(f'{base}/Localizable.strings')
        except (ValueError, FileNotFoundError) as e:
            problems.append(f'{lang}: Localizable.strings does not parse: {e}'); continue
        for k in sorted(set(ref) - set(tr)):
            problems.append(f'{lang}: missing {k!r}')
        for k in sorted(set(tr) - set(ref)):
            problems.append(f'{lang}: unknown key {k!r}')
        for k, v in tr.items():
            if k in ref:
                if not v.strip():
                    problems.append(f'{lang}: empty translation for {k!r}')
                elif not same_specs(k, v):
                    problems.append(f'{lang}: format specifiers differ in {k!r} -> {v!r}')
        try:
            pl = plistlib.load(open(f'{base}/Localizable.stringsdict', 'rb'))
        except Exception as e:
            problems.append(f'{lang}: Localizable.stringsdict does not parse: {e}'); continue
        need = PLURALS.get(lang, ONE_OTHER)
        for k in sorted(set(ref_plural) - set(pl)):
            problems.append(f'{lang}: plural missing {k!r}')
        for k, entry in pl.items():
            if k not in ref_plural:
                problems.append(f'{lang}: unknown plural {k!r}'); continue
            r = ref_plural[k]
            fmt = entry.get('NSStringLocalizedFormatKey', '')
            if sorted(VARIABLE.findall(fmt)) != sorted(VARIABLE.findall(r['NSStringLocalizedFormatKey'])):
                problems.append(f'{lang}: plural {k!r}: format key must use the variables of {r["NSStringLocalizedFormatKey"]!r}, got {fmt!r}')
            for var in VARIABLE.findall(r['NSStringLocalizedFormatKey']):
                rv, tv = r[var], entry.get(var)
                if not isinstance(tv, dict):
                    problems.append(f'{lang}: plural {k!r}: variable {var!r} missing'); continue
                for meta in ('NSStringFormatSpecTypeKey', 'NSStringFormatValueTypeKey'):
                    if tv.get(meta) != rv.get(meta):
                        problems.append(f'{lang}: plural {k!r}.{var}: {meta} must be {rv.get(meta)!r}')
                forms = {c for c in tv if not c.startswith('NSString')}
                for c in sorted(need - forms):
                    problems.append(f'{lang}: plural {k!r}.{var}: needs the {c!r} form')
                for c in forms:
                    if not same_specs(rv['other'], tv[c]):  # 'one' covers 21, 31… in ru/uk and 0 in fr: keep the number
                        problems.append(f'{lang}: plural {k!r}.{var}.{c}: format specifiers differ from {rv["other"]!r}: {tv[c]!r}')
    for p in problems:
        print(p)
    if not problems:
        print(f'ok: {len(langs)} languages, {len(ref)} strings, {len(ref_plural)} plurals')
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
