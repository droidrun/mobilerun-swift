#!/usr/bin/env python3
"""Keep signatures, availability and relationships; discard docs and machine metadata."""
import json
import sys
from pathlib import Path

platform, directory = sys.argv[1:]
modules = ("MobilerunProtocol", "MobilerunStream", "MobilerunStreamCore")
lines = set()
for module in modules:
    paths = [Path(directory) / (module + ".symbols.json")]
    paths += sorted(Path(directory).glob(module + "@*.symbols.json"))
    if not paths[0].is_file():
        sys.exit(f"Missing symbol graph for {module}")
    for path in paths:
        graph = json.loads(path.read_text())
        symbols = {
            s["identifier"]["precise"]: s
            for s in graph["symbols"]
            if s["accessLevel"] in ("public", "open") and not s.get("spi")
        }
        for identifier, symbol in symbols.items():
            declaration = "".join(f["spelling"] for f in symbol["declarationFragments"])
            record = {
                "path": ".".join(symbol["pathComponents"]),
                "declaration": " ".join(declaration.split()),
                "access": symbol["accessLevel"],
            }
            for key in ("availability", "swiftGenerics"):
                if key in symbol:
                    record[key] = symbol[key]
            lines.add(f"{module} " + json.dumps(record, sort_keys=True, ensure_ascii=False))
        for relation in graph["relationships"]:
            if relation["source"] not in symbols:
                continue
            # Exclude inherited SDK conformances and compiler-only marker protocols.
            if relation.get("sourceOrigin") or relation.get("targetFallback") == "Swift.SendableMetatype":
                continue
            if relation["kind"] not in ("conformsTo", "inheritsFrom"):
                continue
            record = {k: v for k, v in relation.items() if k != "sourceOrigin"}
            lines.add(f"{module} relationship " + json.dumps(record, sort_keys=True))
print(f"# {platform}")
print("\n".join(sorted(lines)))
