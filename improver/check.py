#!/usr/bin/env python3
"""Outcome check for an improver run (improver/IMPROVER.md): today's KPI line for every loop with Improver on, a revert PR
for every reverted change, at most one change opened today, and that one pre-registered in full on a loop with Improver
on. Prints its hit rate as the Good once a change is read, with the Floor as the bar once 6 are."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "fleet"))
from fleet import C, clock, opted_in, tables
from improve_read import AFTER, FLOOR, history, hit_rate, jsonl

REQUIRED = ("id", "date", "loop", "pr", "change", "trace", "hypothesis", "metric", "better", "runs", "read_date")
today, (first, merged) = clock().date().isoformat(), history()
loops = {r["Loop"] for r in tables()[0] if opted_in(r)}
read = {r.get("loop") for r in jsonl(C["kpi"]) if r.get("date") == today}
new = [c for c in first.values() if c.get("date") == today]
bad = [f"no KPI line today for {l}" for l in sorted(loops - read)] + \
      [f"{c['id']} was reverted with no revert_pr" for c in merged.values() if c.get("outcome") == "reverted" and not c.get("revert_pr")] + \
      [f"{len(new)} changes opened today, at most 1"] * (len(new) > 1) + \
      [f"{c['id']} lacks {', '.join(k for k in REQUIRED if c.get(k) in (None, '', []))}" for c in new if any(c.get(k) in (None, "", []) for k in REQUIRED)] + \
      [f"{c['id']} has runs {c['runs']!r}, not a positive whole number" for c in new if c.get("runs") is not None and not (type(c["runs"]) is int and c["runs"] > 0)] + \
      [f"{c['id']} names {c.get('loop')}, which hasn't Improver on" for c in new if c.get("loop") not in loops]
hits, n = hit_rate(merged)
print("; ".join(bad) or f"read {len(loops)} loops, {len(new)} change opened today, hit rate {hits} of {n}")
if n: print(f"good: {hits / n:.3f} higher" + (f" {FLOOR:.3f}" if n >= AFTER else ""))
sys.exit(1 if bad else 0)
