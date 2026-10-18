#!/usr/bin/env python3
"""Builds Resources/Localizable.xcstrings (String Catalog) from the SwiftUI string literals in
Sources/DiskLensApp. Xcode refreshes the catalog itself on every build (SWIFT_EMIT_LOC_STRINGS);
this script exists so the catalog is complete for translators even before Xcode is installed.
Existing translations in the catalog are preserved."""
import json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = os.path.join(root, "Sources", "DiskLensApp")
out = os.path.join(root, "Resources", "Localizable.xcstrings")
calls = r'(?:Text|Button|Label|Toggle|Picker|Section|Link|LabeledContent|TextField|GroupBox|Menu|Window|navigationTitle|help|String\(localized:)'
pat = re.compile(calls + r'\(\s*"((?:[^"\\]|\\.)*)"')
def interpolations_to_format(k):
    out, i = [], 0
    while i < len(k):
        if k.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(k) and depth:
                depth += {"(": 1, ")": -1}.get(k[j], 0)
                j += 1
            out.append("%@"); i = j
        else:
            out.append(k[i]); i += 1
    return "".join(out)

keys = set()
for dirpath, _, files in os.walk(src):
    for f in files:
        if f.endswith(".swift"):
            text = open(os.path.join(dirpath, f), encoding="utf-8").read()
            for m in pat.finditer(text):
                k = m.group(1)
                # String interpolation becomes a format specifier in the catalog key.
                k = interpolations_to_format(k)
                k = k.replace('\\"', '"').replace('\\n', '\n')
                if k.strip() and not k.startswith("http"):
                    keys.add(k)
catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
if os.path.exists(out):
    try:
        catalog = json.load(open(out, encoding="utf-8"))
    except Exception:
        pass
strings = catalog.setdefault("strings", {})
for k in sorted(keys):
    strings.setdefault(k, {})
json.dump(catalog, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(keys)} strings in {os.path.relpath(out, root)}")
