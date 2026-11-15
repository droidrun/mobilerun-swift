#!/usr/bin/env python3
"""Validate a stable release tag and print its committed changelog entry."""
import re
import sys
from pathlib import Path

changelog = Path("CHANGELOG.md").read_text()
if len(sys.argv) == 2 and sys.argv[1] == "--latest":
    latest = re.search(r"^## \[([0-9]+\.[0-9]+\.[0-9]+)\]", changelog, re.M)
    if not latest:
        sys.exit("::error::CHANGELOG must contain a stable X.Y.Z heading.")
    tag = "v" + latest[1]
else:
    tag = sys.argv[1] if len(sys.argv) == 2 else ""

if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
    sys.exit("::error::Release tag must be vX.Y.Z without a prerelease suffix.")
version = tag[1:]
entry = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |\Z)", changelog, re.M | re.S)
if not entry or not entry[1].strip():
    sys.exit("::error::Release tag must have a nonempty CHANGELOG entry.")
print(entry[1].strip())
