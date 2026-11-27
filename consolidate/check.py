#!/usr/bin/env python3
"""Proof that a consolidation lost nothing (consolidate/CONSOLIDATE.md). No model.
Usage: check.py BEFORE AFTER [ARCHIVE ...]
BEFORE is the file as it was, AFTER as it is now, each ARCHIVE a file the moved text went to. Passes when every
non-blank line of BEFORE, as many times as it appears and with its indentation, is still in AFTER or in an archive;
every `mission` block is unchanged; and AFTER links each archive (a markdown link to it), so what moved stays one link
away. It proves nothing is lost, not that what moved was past its use: it prints how many lines moved, for the reviewer
to read. Run it once per changed file, archives included (an archive only grows)."""
import re, sys
from collections import Counter
from pathlib import Path

if len(sys.argv) < 3: sys.exit(__doc__)
before, after, *archives = (Path(a) for a in sys.argv[1:])
read = lambda p: p.read_text(encoding="utf-8", errors="replace") if p.is_file() else ""
lines = lambda text: Counter(l.rstrip() for l in text.splitlines() if l.strip())
missions = lambda text: re.findall(r"<!-- mission -->.*?<!-- /mission -->", text, re.S)
old, new = read(before), read(after)
if not lines(old): sys.exit(f"{before} is missing or empty, so it proves nothing: save the file as it was first")
kept = lines(new) + sum((lines(read(a)) for a in archives), Counter())
lost = list((lines(old) - kept).elements())
moved = sum((lines(old) - lines(new)).values())
bad = ([f"{len(lost)} lines are gone, not moved, the first: {lost[0].strip()[:120]}"] if lost else []) + \
      ["a mission block changed"] * (missions(old) != missions(new)) + \
      [f"{a.name} doesn't exist" for a in archives if not a.is_file()] + \
      [f"{after.name} doesn't link {a.name}" for a in archives if not re.search(rf"\]\((?![a-z]+:)(?:[^)]*/)?{re.escape(a.name)}\)", new)]
print("; ".join(bad) or f"nothing lost: {sum(lines(old).values())} lines, {moved} moved out, "
                         f"{len(old.encode()) / 1024:.1f} KB to {len(new.encode()) / 1024:.1f} KB")
sys.exit(1 if bad else 0)
