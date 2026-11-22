#!/usr/bin/env python3
"""The improver's reading, no model: what fleet/README.md says under "KPIs and the bar" and "Improver history", done by
arithmetic. For each loop with Improver on it appends today's kpi.jsonl line from its latest Good in the ledger, and for each
change with no outcome whose PR closed, or merged and has `runs` valued checks since, it appends the outcome line.
Safe to run any time: a second run the same day appends nothing. Prints a summary, or with --json the same as data."""
import json, statistics, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fleet import C, GH, clock, lines, name, opted_in, tables, when

OF = 2  # attempts a loop below its Floor gets before it goes to you
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
    read = [r for r in merged.values() if r.get("outcome") in ("kept", "reverted")]
    return sum(r["outcome"] == "kept" and r.get("moved") is True for r in read), len(read)

def kpi(loop, rs, first, today):
    """Today's KPI line from the latest valued check, as of its date: met or below against its bar, measured with no bar,
    no KPI with no value."""
    valued = [r for r in rs if num(r.get("value"))]
    last = valued[-1] if valued else {}
    if not valued: return {"date": today, "loop": loop, "kpi": "no KPI"}
    line = {"date": today, "loop": loop, "as_of": last["at"].date().isoformat(), "value": last["value"], "better": last.get("better")}
    if not num(last.get("bar")): return {**line, "kpi": "measured"}
    line["bar"] = last["bar"]
    if not ahead(last["bar"], last["value"], last.get("better")): return {**line, "kpi": "met"}
    streak = []
    for r in reversed(valued):
        if not num(r.get("bar")) or not ahead(r["bar"], r["value"], r.get("better")): break
        streak.append(r)
    since = streak[-1]["at"].date().isoformat()
    attempts = sum(r.get("loop") == loop and str(r.get("date", "")) >= since for r in first.values())
    return {**line, "kpi": "below", "since": since, "attempts": attempts, "of": OF, "escalated": attempts >= OF}

def state(c):
    """The change's PR as {state, mergedAt}, or None when gh is missing or can't read it."""
    r = GH and subprocess.run([GH, "pr", "view", c["pr"], "--json", "state,mergedAt"], capture_output=True, text=True)
    return json.loads(r.stdout) if r and r.returncode == 0 else None

def goods(rs):
    """(what is read, each valued check as (at, number)): its value, or for a running total (its lines carry `total`, so
    its values are overlapping 7-day gains) its gain since the loop's previous total."""
    totals = [r for r in rs if num(r.get("total"))]
    if totals: return "gains in total", [(b["at"], b["total"] - a["total"]) for a, b in zip(totals, totals[1:])]
    return "values", [(r["at"], r["value"]) for r in rs if num(r.get("value"))]

def outcome(c, pr, rs):
    """The outcome line for a change whose PR closed, or merged with `runs` valued checks after it, against the `runs`
    valued checks before its date: kept when the mean after beats the mean before by more than two standard errors and
    the pass rate over the span after is no lower than over the span before. None while it can't be read yet;
    "unreadable" when too few checks came before it."""
    if pr["state"] == "CLOSED": return {"id": c["id"], "outcome": "closed", "moved": False, "result": "closed without merging"}
    if pr["state"] != "MERGED": return None
    runs, merged_at, opened, (what, good) = c.get("runs", 7), when(pr["mergedAt"]), when(str(c.get("date"))), goods(rs)
    after = [g for g in good if g[0] > merged_at][:runs]
    if len(after) < runs: return None
    base = [g for g in good if opened and g[0] < opened][-runs:]
    if len(base) < runs: return "unreadable"
    vs = lambda w: [v for _, v in w]
    rate = lambda span: sum(r["check"] == "pass" for r in span) / len(span)
    baseline, mean = statistics.mean(vs(base)), statistics.mean(vs(after))
    margin = 2 * (statistics.variance(vs(base)) / runs + statistics.variance(vs(after)) / runs) ** 0.5
    now, was = rate([r for r in rs if merged_at < r["at"] <= after[-1][0]]), rate([r for r in rs if base[0][0] <= r["at"] < opened])
    moved = (mean - baseline if c["better"] == "higher" else baseline - mean) > margin and now >= was
    return {"id": c["id"], "outcome": "kept" if moved else "reverted", "moved": moved, "baseline": baseline, "after": mean,
            "margin": margin, "pass_rate_before": was,
            "result": f"mean {mean:.4g} vs baseline {baseline:.4g} ({c['better']} is better, kept past a margin of {margin:.4g}) "
                      f"over {runs} {what}; "
                      f"checks passed {now:.0%} vs {was:.0%} before"}

def read():
    today, (first, merged), by = clock().date().isoformat(), history(), checks()
    done = {(r.get("date"), r.get("loop")) for r in jsonl(C["kpi"])}
    loops = [r["Loop"] for r in tables()[0] if opted_in(r)]
    kpis = [kpi(l, by.get(l, []), first, today) for l in loops if (today, l) not in done]
    unread = [c for c in merged.values() if c.get("outcome") in (None, "pending")]
    runs = lambda v: type(v) is int and v > 1
    readable = lambda c: name(c.get("pr")) and name(c.get("loop")) and c.get("better") in ("higher", "lower") and runs(c.get("runs", 7))
    outcomes, unreachable, unreadable = [], [], [c["id"] for c in unread if not readable(c)]
    for c in (c for c in unread if readable(c)):
        pr = state(c)
        o = pr and outcome(c, pr, by.get(str(c["loop"]), []))
        if not pr: unreachable.append(c["id"])
        elif o == "unreadable": unreadable.append(c["id"])
        elif o: outcomes.append(o)
    for f, new in ((C["kpi"], kpis), (C["improvements"], outcomes)):
        with open(f, "a") as out: out.writelines(json.dumps({k: v for k, v in r.items() if v is not None}) + "\n" for r in new)
    for o in outcomes: merged[o["id"]] = {**merged[o["id"]], **o}
    hits, n = hit_rate(merged)
    return {"date": today, "kpi": kpis, "outcomes": outcomes,
            "reverts_owed": [c["id"] for c in merged.values() if c.get("outcome") == "reverted" and not c.get("revert_pr")],
            "open": [c["id"] for c in unread if c["id"] not in unreadable and c["id"] not in {o["id"] for o in outcomes}],
            "unreadable": unreadable, "unreachable": unreachable,
            "hit_rate": {"hits": hits, "read": n, "stopped": n >= AFTER and hits / n < FLOOR}}

if __name__ == "__main__":
    r = read()
    if sys.argv[1:] == ["--json"]: print(json.dumps(r)); sys.exit()
    for k in r["kpi"]: print(f"kpi {k['loop']}: {k['kpi']}" + (f" ({k['value']} vs {k['bar']})" if "bar" in k else ""))
    for o in r["outcomes"]: print(f"change {o['id']}: {o['outcome']}, {o['result']}")
    h = r["hit_rate"]
    if r["unreadable"]: print(f"never read (a field is missing, or too few checks before it): {', '.join(r['unreadable'])}")
    if r["unreachable"]: print(f"gh couldn't read the PR, so not read today: {', '.join(r['unreachable'])}")
    print(f"open changes: {len(r['open'])} · reverts owed: {', '.join(r['reverts_owed']) or 'none'} · hit rate: {h['hits']} of {h['read']}"
          + (" · stopped: below 1 in 3" if h["stopped"] else ""))
