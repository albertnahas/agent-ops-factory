#!/usr/bin/env python3
"""The improver's reading, no model: what fleet/README.md says under "KPIs and the bar" and "Improver history", done by
arithmetic. For each loop with Improver on it appends today's kpi.jsonl line from its latest Good in the ledger, and for each
change with no outcome whose PR closed, or merged and has `runs` valued checks since, it appends the outcome line.
Safe to run any time: a second run the same day appends nothing. Prints a summary, or with --json the same as data."""
import json, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fleet import C, GH, clock, lines, name, opted_in, tables, when

OF = 2  # attempts a loop below its Floor gets before it goes to you
NO_GOOD = ("measure", "check_detection")  # changes that move no Good, so the hit rate leaves them out
FLOOR, AFTER = 1 / 3, 6  # the improver's own Floor: a hit rate of 1 in 3, once 6 changes are read

def jsonl(f):
    out = []
    for l in lines(f):
        try: r = json.loads(l)
        except (ValueError, RecursionError): continue
        if isinstance(r, dict): out.append(r)
    return out

num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
ahead = lambda a, b, better: a < b if better == "lower" else a > b  # strictly better

def checks():
    """Each loop's check lines, oldest first, with `at` parsed."""
    by = {}
    for r in jsonl(C["ledger"]):
        if "check" in r and name(r.get("loop")) and when(r.get("date")): by.setdefault(str(r["loop"]), []).append({**r, "at": when(r["date"])})
    for rs in by.values(): rs.sort(key=lambda r: r["at"])
    return by

def history():
    """(the line each change opened with, by id; each change with its later lines merged in, later fields winning)."""
    first, merged = {}, {}
    for r in jsonl(C["improvements"]):
        if not name(r.get("id")): continue
        first.setdefault(str(r["id"]), r)
        merged[str(r["id"])] = {**merged.get(str(r["id"]), {}), **{k: v for k, v in r.items() if v is not None}}
    return first, merged

def hit_rate(merged):
    """(hits, read): of the changes read as kept or reverted, those kept that moved their Good."""
    read = [r for r in merged.values() if r.get("outcome") in ("kept", "reverted") and r.get("metric") not in NO_GOOD]
    return sum(r["outcome"] == "kept" and r.get("moved") is True for r in read), len(read)

def kpi(loop, rs, first, today):
    """Today's KPI line: met or below from the latest valued check against its bar; no KPI with no value or no bar."""
    valued = [r for r in rs if num(r.get("value"))]
    last = valued[-1] if valued else {}
    if not num(last.get("bar")): return {"date": today, "loop": loop, "kpi": "no KPI", "value": last.get("value")}
    line = {"date": today, "loop": loop, "value": last["value"], "bar": last["bar"]}
    if not ahead(last["bar"], last["value"], last["better"]): return {**line, "kpi": "met"}
    streak = []
    for r in reversed(valued):
        if not num(r.get("bar")) or not ahead(r["bar"], r["value"], r["better"]): break
        streak.append(r)
    since = streak[-1]["at"].date().isoformat()
    attempts = sum(r.get("loop") == loop and str(r.get("date", "")) >= since for r in first.values())
    return {**line, "kpi": "below", "since": since, "attempts": attempts, "of": OF, "escalated": attempts >= OF}

def outcome(c, rs):
    """The outcome line for an open change, or None while its PR is open or too few valued checks ran since it merged."""
    pr = json.loads(subprocess.run([GH, "pr", "view", c["pr"], "--json", "state,mergedAt"], capture_output=True, text=True, check=True).stdout)
    if pr["state"] == "CLOSED": return {"id": c["id"], "outcome": "closed", "moved": False, "result": "closed without merging"}
    if pr["state"] != "MERGED": return None
    runs, merged_at = c.get("runs") or 7, when(pr["mergedAt"])
    after = [r for r in rs if r["at"] > merged_at]
    valued = [r for r in after if num(r.get("value"))][:runs]
    if len(valued) < runs: return None
    span = [r for r in after if r["at"] <= valued[-1]["at"]]
    mean, rate = sum(r["value"] for r in valued) / runs, sum(r["check"] == "pass" for r in span) / len(span)
    moved = ahead(mean, c["baseline"], c["better"]) and rate >= c["pass_rate_before"]
    return {"id": c["id"], "outcome": "kept" if moved else "reverted", "moved": moved,
            "result": f"mean {mean:.4g} vs baseline {c['baseline']:.4g} ({c['better']} is better) over {runs} runs; "
                      f"checks passed {rate:.0%} vs {c['pass_rate_before']:.0%} before"}

def read():
    today, (first, merged), by = clock().date().isoformat(), history(), checks()
    done = {(r.get("date"), r.get("loop")) for r in jsonl(C["kpi"])}
    loops = [r["Loop"] for r in tables()[0] if opted_in(r)]
    kpis = [kpi(l, by.get(l, []), first, today) for l in loops if (today, l) not in done]
    open_ = [c for c in merged.values() if c.get("outcome") in (None, "pending") and name(c.get("pr")) and name(c.get("loop"))
             and c.get("better") in ("higher", "lower") and num(c.get("baseline")) and num(c.get("pass_rate_before"))]
    outcomes = [o for c in open_ for o in [outcome(c, by.get(str(c["loop"]), []))] if o]
    for f, new in ((C["kpi"], kpis), (C["improvements"], outcomes)):
        with open(f, "a") as out: out.writelines(json.dumps({k: v for k, v in r.items() if v is not None}) + "\n" for r in new)
    for o in outcomes: merged[o["id"]] = {**merged[o["id"]], **o}
    hits, n = hit_rate(merged)
    return {"date": today, "kpi": kpis, "outcomes": outcomes,
            "reverts_owed": [c["id"] for c in merged.values() if c.get("outcome") == "reverted" and not c.get("revert_pr")],
            "open": [c["id"] for c in merged.values() if c.get("outcome") in (None, "pending")],
            "hit_rate": {"hits": hits, "read": n, "stopped": n >= AFTER and hits / n < FLOOR}}

if __name__ == "__main__":
    r = read()
    if sys.argv[1:] == ["--json"]: print(json.dumps(r)); sys.exit()
    for k in r["kpi"]: print(f"kpi {k['loop']}: {k['kpi']}" + (f" ({k['value']} vs {k['bar']})" if "bar" in k else ""))
    for o in r["outcomes"]: print(f"change {o['id']}: {o['outcome']}, {o['result']}")
    h = r["hit_rate"]
    print(f"open changes: {len(r['open'])} · reverts owed: {', '.join(r['reverts_owed']) or 'none'} · hit rate: {h['hits']} of {h['read']}"
          + (" · stopped: below 1 in 3" if h["stopped"] else ""))
