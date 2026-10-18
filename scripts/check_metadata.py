#!/usr/bin/env python3 -I
"""Checks docs/appstore/metadata.md fields against App Store Connect character limits."""
import re, sys, pathlib
text = pathlib.Path(__file__).resolve().parent.parent.joinpath("docs/appstore/metadata.md").read_text()
limits = {"Name": 30, "Subtitle": 30, "Promotional text": 170, "Keywords": 100, "Description": 4000}
ok = True
for name, limit in limits.items():
    m = re.search(rf"^## {re.escape(name)}[^\n]*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    value = m.group(1).strip() if m else ""
    n = len(value)
    status = "OK " if 0 < n <= limit else "BAD"
    ok &= status == "OK "
    print(f"{status} {name:17} {n:5}/{limit}")
    if name == "Keywords" and (" ," in value or ", " in value):
        print("BAD Keywords contain spaces around commas"); ok = False
root = pathlib.Path(__file__).resolve().parent.parent
placeholders = []
for rel in ["Resources/Info.plist", "Resources/Info-Direct.plist", "release.config", "docs/appstore/metadata.md",
            "docs/site/support.html", "docs/site/privacy.html", "docs/site/terms.html"]:
    for n, line in enumerate(root.joinpath(rel).read_text().splitlines(), 1):
        if "example.com" in line:
            placeholders.append(f"{rel}:{n}")
for rel in ["Resources/Info-Direct.plist"]:
    if "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY" in root.joinpath(rel).read_text():
        placeholders.append(f"{rel}: SUPublicEDKey placeholder")
if placeholders:
    ok = False
    print("BAD placeholder URLs/emails (replace before submitting):")
    for p in placeholders: print("    " + p)
sys.exit(0 if ok else 1)
