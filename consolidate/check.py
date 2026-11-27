#!/usr/bin/env python3
"""Proof that a consolidation lost nothing (consolidate/CONSOLIDATE.md). No model.
Usage: check.py BEFORE AFTER [ARCHIVE ...]
BEFORE is the file as it was, AFTER as it is now, each ARCHIVE a file the moved text went to. Passes when every
non-blank line of BEFORE is still in AFTER or in an archive, word for word; every `mission` block is unchanged; and
AFTER names each archive, so what moved stays one link away. Run it once per changed file, archives included
(an archive only grows)."""
import re, sys
from pathlib import Path

if len(sys.argv) < 3: sys.exit(__doc__)
before, after, *archives = (Path(a) for a in sys.argv[1:])
read = lambda p: p.read_text(encoding="utf-8", errors="replace") if p.is_file() else ""
lines = lambda text: {l.strip() for l in text.splitlines() if l.strip()}
missions = lambda text: re.findall(r"<!-- mission -->.*?<!-- /mission -->", text, re.S)
old, new = read(before), read(after)
kept = lines(new).union(*(lines(read(a)) for a in archives))
lost = [l for l in old.splitlines() if l.strip() and l.strip() not in kept]
bad = ([f"{len(lost)} lines are gone, not moved, the first: {lost[0].strip()[:120]}"] if lost else []) + \
      ["a mission block changed"] * (missions(old) != missions(new)) + \
      [f"{a.name} doesn't exist" for a in archives if not a.is_file()] + \
      [f"{after.name} doesn't link {a.name}" for a in archives if a.name not in new]
print("; ".join(bad) or f"nothing lost: {len(lines(old))} lines kept or moved, {len(old.encode()) / 1024:.1f} KB to {len(new.encode()) / 1024:.1f} KB")
sys.exit(1 if bad else 0)
