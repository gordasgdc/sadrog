#!/usr/bin/env python3
"""One-shot helper: wraps the app's remaining Romanian UI literals. Plain → T("…"); with \\(…) → L10n.f("…%@…", "\\(…)").
Skips: log lines, comparisons/case patterns, enum raw values, strings already wrapped, comments, probe/dev files.
Usage: l10n_convert.py <file.swift>…   (prints what it changed; review the diff)."""
import re, sys, pathlib
DIAC = re.compile(r"[ăâîșțĂÂÎȘȚ]")
LOGLINE = re.compile(r'log\.(info|warning|error)\(|\bLog\(|Logger|print\(|fxLog\.|overlayLog\.|NSLog\(')

def scan_string(s, i):
    """s[i] == '"'; returns (end_index_exclusive, parts) where parts = list of ('t', text) / ('i', expr)."""
    assert s[i] == '"'
    j = i + 1; parts = []; buf = ""
    while j < len(s):
        c = s[j]
        if c == '\\' and j + 1 < len(s) and s[j+1] == '(':
            if buf: parts.append(('t', buf)); buf = ""
            k = j + 2; depth = 1; expr_start = k
            while k < len(s) and depth:
                if s[k] == '"': k = scan_string(s, k)[0]; continue
                if s[k] == '(': depth += 1
                elif s[k] == ')': depth -= 1
                k += 1
            parts.append(('i', s[expr_start:k-1])); j = k; continue
        if c == '\\': buf += s[j:j+2]; j += 2; continue
        if c == '"': 
            if buf: parts.append(('t', buf))
            return j + 1, parts
        buf += c; j += 1
    raise ValueError("unterminated")

def convert_line(line):
    if LOGLINE.search(line) or line.strip().startswith("//"): return line
    out = ""; i = 0; changed = False
    code_end = len(line)
    while i < len(line):
        if line.startswith("//", i) : out += line[i:]; break
        if line[i] == '"' and not line.startswith('"""', i):
            end, parts = scan_string(line, i)
            lit = line[i:end]
            text = "".join(p[1] if p[0] == 't' else "\\(" + p[1] + ")" for p in parts)
            pre = out.rstrip()
            skip = (not DIAC.search("".join(p[1] for p in parts if p[0] == 't'))
                    or re.search(r'(\bT|L10n\.t|L10n\.f|verbatim:)\(\s*$', out) is not None and False
                    or re.search(r'(\bT|L10n\.t|L10n\.f)\(\s*$', out)
                    or re.search(r'(==|!=)\s*$', pre) or re.search(r'\bcase\s+\w*\s*=\s*$', pre) or re.search(r'\bcase\s*$', pre))
            if skip: out += lit; i = end; continue
            if re.search(r'String\(format:\s*$', out):
                out += f'T({lit})'; changed = True
            elif all(p[0] == 't' for p in parts):
                out += f'T({lit})'; changed = True
            else:
                fmt = "".join(p[1].replace("%", "%%") if p[0] == 't' else "%@" for p in parts)
                args = ", ".join('"\\(' + p[1] + ')"' for p in parts if p[0] == 'i')
                out += f'L10n.f("{fmt}", {args})'; changed = True
            i = end; continue
        out += line[i]; i += 1
    return out

for f in sys.argv[1:]:
    p = pathlib.Path(f); lines = p.read_text().split("\n"); n = 0
    for k, l in enumerate(lines):
        c = convert_line(l)
        if c != l: lines[k] = c; n += 1
    p.write_text("\n".join(lines))
    print(f"{n:4d} rânduri  {f}")
