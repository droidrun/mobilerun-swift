#!/usr/bin/env python3
"""Validate a stable release tag and print its committed changelog entry."""
import re
import sys
from pathlib import Path

if len(sys.argv) != 2 or not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", sys.argv[1]):
    sys.exit("::error::Release tag must be vX.Y.Z without a prerelease suffix.")
version = sys.argv[1][1:]
changelog = Path("CHANGELOG.md").read_text()
entry = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |\Z)", changelog, re.M | re.S)
if not entry or not entry[1].strip():
    sys.exit("::error::Release tag must have a nonempty CHANGELOG entry.")
print(entry[1].strip())
