#!/usr/bin/env python3
"""A supervisor's weekly review, checked by a script, no model. Its review report must give every loop the registry's
Supervisor column assigns it one line, `- <loop>: <kept|changed|retired|paused> · read through YYYY-MM-DD`, and a loop
that left a ledger line before the report's date must have been read through at least that date. This proves coverage
and that each claim fits the ledger. It can't prove the reading was good.
Usage: supervision.py <supervisor> <report.md>   The report's date is the YYYY-MM-DD in its file name. Exits 1 with
each gap, else 0 with the loops reviewed."""
import collections, datetime as dt, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fleet import C, links, tables, when
from improve_read import jsonl

LINE = re.compile(r"^\s*[-*]\s*\**`?([A-Za-z0-9_.-]+)`?\**:\s*\**(kept|changed|retired|paused)\b.*?read through (\S+?)[,;.)]?(?=\s|$)", re.M | re.I)

def date(s):
    try: return dt.date.fromisoformat(s)
    except ValueError: return None

def review(supervisor, report):
    """(loops it supervises, gaps). A loop's Supervisor cell may name the supervisor by its job, as fleet.py allows."""
    day = date((re.search(r"\d{4}-\d{2}-\d{2}", Path(report).name) or [""])[0])
    if not day: return [], [f"{report}: no YYYY-MM-DD in the file name, so its date is unknown"]
    found = LINE.findall(Path(report).read_text(errors="replace"))
    said, twice = {loop: read for loop, _, read in found}, [l for l, n in collections.Counter(l for l, _, _ in found).items() if n > 1]
    mine = [loop for loop, v in links(*tables())[0].items() if v["supervisor"] == supervisor]
    last = {}
    for r in jsonl(C["ledger"]):
        at = when(str(r.get("date", "")))
        if r.get("loop") in mine and at and at.date() < day: last[r["loop"]] = max(last.get(r["loop"], at.date()), at.date())
    gaps = []
    for loop in mine:
        read = date(said.get(loop, ""))
        if loop not in said: gaps.append(f"{loop}: no `- {loop}: <decision> · read through <date>` line")
        elif loop in twice: gaps.append(f"{loop}: named on more than one line, so which verdict stands is unclear")
        elif not read or read > day: gaps.append(f"{loop}: read through {said[loop]}, which is no date on or before {day}")
        elif loop in last and last[loop] > read: gaps.append(f"{loop}: read through {read}, but it ran on {last[loop]}")
    return mine, gaps or ([] if mine else [f"no registry row names {supervisor} as its Supervisor"])

if __name__ == "__main__":
    if len(sys.argv) != 3: sys.exit(__doc__)
    mine, gaps = review(*sys.argv[1:])
    print("\n".join(gaps) or f"reviewed all {len(mine)}: {', '.join(mine)}")
    sys.exit(1 if gaps else 0)
