#!/usr/bin/env python3 -I
"""Fails when a user-facing string in Sources/AirbagApp has no Russian translation (Localizable.strings or .stringsdict)."""
import glob, plistlib, re, sys
INT = re.compile(r'(\.count\b|\bn\b|liveSessions|pinnedCount|snapshotCount|changedCount|\bport\b|\$0\b|[+-]\s*\d)')
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
pat = re.compile(r'(?:bullet\("[^"]*",\s*|\bTextField|\bText|\bButton|\bLabel|\bToggle|\bPicker|\bSection|\bMenu|String\(localized:|Pill\(text:|SectionHeader\(title:|EmptyState\(symbol: "[^"]*", title:|, message:|case \.\w+: return|resolutionText.*return)\s*\(?\s*"((?:[^"\\]|\\.)*)"')
ru = {}
for line in open('Sources/AirbagApp/Resources/ru.lproj/Localizable.strings', encoding='utf-8'):
    m = re.match(r'"((?:[^"\\]|\\.)*)"\s*=', line)
    if m: ru[m.group(1).replace('\\"', '"').replace('\\\\', '\\')] = 1
plural = plistlib.load(open('Sources/AirbagApp/Resources/ru.lproj/Localizable.stringsdict', 'rb'))
symbols = re.compile(r'^[a-z]+(\.[a-z.]+)*$')
SF = {'airplane', 'camera', 'diamond', 'gearshape', 'shield', 'sparkle', 'terminal', 'folder', 'pin', 'lock'}
missing = set()
for f in glob.glob('Sources/AirbagApp/**/*.swift', recursive=True):
    for m in pat.finditer(open(f, encoding='utf-8').read()):
        k = key(m.group(1))
        if not k or k == 'Airbag' or k.startswith('http') or re.fullmatch(r'[\W\d_%@lA-Z]{0,3}', k) or symbols.match(k) and ('.' in k or k in SF): continue
        if k not in ru and k not in plural: missing.add((k, f.split('/')[-1]))
for k, f in sorted(missing): print(f'missing ru: {k!r}  ({f})')
sys.exit(1 if missing else 0)
