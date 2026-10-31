#!/usr/bin/env python3
"""Lists the Romanian texts of the app still outside the catalog (literals with diacritics or common Romanian words, not wrapped in T/L10n)."""
import re, pathlib, collections
root = pathlib.Path(__file__).resolve().parent.parent
rx = re.compile(r'"((?:[^"\\]|\\.)*[ăâîșțĂÂÎȘȚ](?:[^"\\]|\\.)*)"')
per = collections.Counter(); samples = {}
for f in sorted((root / "Sources").rglob("*.swift")):
    if f.name == "L10nCatalog.swift": continue
    for line in f.read_text().splitlines():
        s = line.strip()
        if s.startswith("//") or s.startswith("///"): continue
        for m in rx.finditer(line):
            pre = line[:m.start()]
            if re.search(r'(\bT|L10n\.t|L10n\.f)\(\s*$', pre): continue
            per[f.name] += 1; samples.setdefault(f.name, m.group(1)[:70])
for k, v in per.most_common(): print(f"{v:4d}  {k}  ex: {samples[k]}")
print("total:", sum(per.values()))
