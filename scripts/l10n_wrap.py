#!/usr/bin/env python3
"""Wraps the app's own static UI texts with T("…") in the given Swift files (idempotent), then lists every T() key.
Only plain literals (no \\( interpolation) in UI positions are wrapped; identifiers and file names are left alone."""
import re, sys, pathlib
POS = r'(Text|Button|Label|Toggle|Picker|Menu|Section|InspectorGroup|section|row|SectionLabel|InfoRow\(label:|NumberRow\(label:|Chip\(text:|\.help|\.accessibilityLabel|\.accessibilityHint|\.navigationTitle|field|permRow|EmptyState\(symbol: "[^"]*", title:)'
pat = re.compile(POS + r'\(\s*"((?:[^"\\]|\\.)*)"')
pat2 = re.compile(r'(InfoRow\(label:|NumberRow\(label:|Chip\(text:|title:|detail:|placeholder:|label:) "((?:[^"\\]|\\.)*)"')
def wrap(m, prefix_len):
    text = m.group(2)
    if "\\(" in text or not re.search(r"[A-Za-zĂÂÎȘȚăâîșț]", text) or len(text) < 2: return m.group(0)
    return m.group(0)[:prefix_len] + f'T("{text}")'
for f in sys.argv[1:]:
    p = pathlib.Path(f); s = p.read_text()
    s = pat.sub(lambda m: wrap(m, m.group(0).index('"')), s)
    s = pat2.sub(lambda m: wrap(m, m.group(0).index('"')), s)
    p.write_text(s)
