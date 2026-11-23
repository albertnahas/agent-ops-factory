#!/usr/bin/env python3
"""A supervisor's weekly review, checked by a script, no model. Its review report must give every loop the registry's
Supervisor column assigns it one line, `- <loop>: <kept|changed|retired|paused> · read through YYYY-MM-DD`, and a loop
that left a ledger line before the report's date must have been read through at least that date. This proves coverage
and that each claim fits the ledger. It can't prove the reading was good.
Usage: supervision.py <supervisor> <report.md>   The report's date is the YYYY-MM-DD in its file name. Exits 1 with
each gap, else 0 with the loops reviewed."""
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fleet import C, tables
from improve_read import jsonl

LINE = re.compile(r"^\s*[-*]\s*`?([A-Za-z0-9_.-]+)`?:\s*\**(kept|changed|retired|paused)\b.*?read through (\d{4}-\d{2}-\d{2})", re.M | re.I)

def review(supervisor, report):
    """(loops it supervises, gaps)."""
    day = re.search(r"\d{4}-\d{2}-\d{2}", Path(report).name)
    if not day: return [], [f"{report}: no YYYY-MM-DD in the file name, so its date is unknown"]
    said = {loop: read for loop, _, read in LINE.findall(Path(report).read_text(errors="replace"))}
    mine = [r["Loop"] for r in tables()[0] if r.get("Supervisor", "").strip() == supervisor]
    last = {}
    for r in jsonl(C["ledger"]):
        at = str(r.get("date", ""))[:10]
        if r.get("loop") in mine and at < day[0]: last[r["loop"]] = max(last.get(r["loop"], ""), at)
    gaps = [f"{loop}: no `- {loop}: <decision> · read through <date>` line" for loop in mine if loop not in said]
    gaps += [f"{loop}: read through {said[loop]}, but it ran on {last[loop]}" for loop in mine
             if loop in said and last.get(loop, "") > said[loop]]
    return mine, gaps or ([] if mine else [f"no registry row names {supervisor} as its Supervisor"])

if __name__ == "__main__":
    if len(sys.argv) != 3: sys.exit(__doc__)
    mine, gaps = review(*sys.argv[1:])
    print("\n".join(gaps) or f"reviewed all {len(mine)}: {', '.join(mine)}")
    sys.exit(1 if gaps else 0)
