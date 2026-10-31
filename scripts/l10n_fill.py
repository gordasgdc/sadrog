#!/usr/bin/env python3
"""Fill EN/ES for catalog keys from a TSV on stdin: ro<TAB>en<TAB>es. Only rows whose EN/ES are still empty are changed."""
import sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent; p = root / "Localization" / "catalog.tsv"
new = {}
for l in sys.stdin.read().splitlines():
    if l.strip():
        a = l.split("\t"); new[a[0]] = (a[1], a[2])
out = []
for l in p.read_text().split("\n"):
    ro = l.split("\t")[0]
    parts = (l.split("\t") + ["", ""])[:3]
    out.append(f"{ro}\t{new[ro][0]}\t{new[ro][1]}" if ro in new and (not parts[1] or not parts[2]) else l)
p.write_text("\n".join(out))
