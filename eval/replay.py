#!/usr/bin/env python3
"""Replay eval for the fleet monitor: does it show the truth?

Rebuilds the dashboard as it would have looked at one time each day (default 09:30, when the heartbeat runs), from
a ledger, a registry and a jobs fixture, and scores the statuses it flags (failing, silent, chronic) against labelled
incidents. Optionally scores the heartbeat's own alert log and the messages it sent against the same labels.

usage: replay.py --registry R --ledger L --jobs J --labels LB --from YYYY-MM-DD --to YYYY-MM-DD
                 [--at HH:MM] [--heartbeat-log H] [--telegram-log T] [--min-detection F] [--max-false F] [--json OUT]

Labels, one JSON object a line: {"loop", "start", "end", "real": true|false, "cause", "match" (optional regex the
flag's detail must match for a real incident to count as caught: the right cause, not just the right loop),
"evidence" (something the monitor didn't write: a fix commit, a readback, a doc)}. A flag on a loop between an
incident's start and 24 hours after its end belongs to it. Flags no label covers are reported as unlabelled.

Exits 1 when detection is under --min-detection or the false share of flags is over --max-false, so a change to
the builder that hides real failures, or cries wolf more, fails the build."""
import argparse, datetime as dt, json, os, re, statistics, subprocess, sys, tempfile
from pathlib import Path

FLEET = Path(__file__).resolve().parent.parent / "fleet/fleet.py"
FLAGGED = {"failing", "silent", "chronic"}
GRACE = dt.timedelta(hours=24)


def load(f):
    return [json.loads(l) for l in Path(f).read_text().splitlines() if l.strip()]


def fleet_flags(a, days):
    """{day: {loop: detail}} for each replayed time."""
    out = {}
    with tempfile.TemporaryDirectory() as tmp:
        cfg = {"registry": a.registry, "ledger": a.ledger, "jobs": a.jobs, "checks": f"{tmp}/none", "out": f"{tmp}/out",
               "launch_agents": f"{tmp}/none", "tasks": f"{tmp}/none", "waiting": {}}
        Path(tmp, "fleet.json").write_text(json.dumps(cfg))
        for t in days:
            env = {**os.environ, "FLEET_CONFIG": f"{tmp}/fleet.json", "FLEET_NOW": t.isoformat()}
            subprocess.run([sys.executable, str(FLEET)], env=env, capture_output=True, check=True)
            rows = json.loads(Path(tmp, "out/loops.json").read_text())["rows"]
            out[t] = {r["loop"]: f'{r["status"]}: {r.get("detail") or ""}' for r in rows if r["status"] in FLAGGED}
    return out


def heartbeat_flags(log, ledger):
    """{time: {loop: detail}} from the heartbeat's own log. Its keys carry no detail, so a check alert takes the
    detail of that loop's last check line before the heartbeat ran (what it read), and a silent alert says silent."""
    runs = [r for r in load(ledger) if "check" in r]
    out = {}
    for l in Path(log).read_text().splitlines():
        if not l.startswith('{"checked"'):
            continue
        h = json.loads(l)
        t = dt.datetime.fromisoformat(h["checked"][:19])
        flags = {}
        for key in h["sent"]:
            kind, _, rest = key.partition(":")
            loop = rest.split(":")[0]
            if kind == "silent":
                flags[loop] = "silent"
            elif kind in ("check", "exit"):
                last = [r for r in runs if r["loop"] == loop and r["date"][:19] <= t.isoformat()]
                flags[loop] = f'{kind}: {last[-1].get("detail", "") if last else ""}'
        out[t] = flags
    return out


def score(flags, labels):
    """Detection, false alarms and latency of a {time: {loop: detail}} series against the labels."""
    span = lambda lb, t: lb["loop"] in flags[t] and dt.datetime.fromisoformat(lb["start"]) <= t <= dt.datetime.fromisoformat(lb["end"]) + GRACE
    caught = lambda lb, t: span(lb, t) and re.search(lb.get("match") or "", flags[t][lb["loop"]] or "", re.I)
    real = [lb for lb in labels if lb["real"]]
    hits, misses = [], []
    for lb in real:
        first = next((t for t in sorted(flags) if caught(lb, t)), None)
        (hits if first else misses).append({**lb, "hours": round((first - dt.datetime.fromisoformat(lb["start"])).total_seconds() / 3600, 1) if first else None})
    true = false = unlabelled = 0
    unknown = []
    for t in sorted(flags):
        for loop, detail in flags[t].items():
            if any(caught(lb, t) for lb in real):
                true += 1
            elif any(span(lb, t) for lb in labels):
                false += 1
            else:
                unlabelled += 1
                unknown.append(f"{t:%Y-%m-%d} {loop}: {detail[:100]}")
    flagged = true + false
    return {"incidents": len(real), "detected": len(hits), "detection": round(len(hits) / len(real), 3) if real else None,
            "median_hours": statistics.median(h["hours"] for h in hits) if hits else None,
            "flags": flagged + unlabelled, "true": true, "false": false, "unlabelled": unlabelled,
            "false_share": round(false / flagged, 3) if flagged else None,
            "missed": [f'{m["loop"]} {m["start"][:16]}: {m["cause"]}' for m in misses], "unlabelled_flags": unknown}


def attention(log, start, end):
    days = (end - start).days + 1
    sent = [m for m in load(log) if start.isoformat() <= m["date"][:10] <= end.isoformat()]
    per = {}
    for m in sent:
        per[m["date"][:10]] = per.get(m["date"][:10], 0) + 1
    return {"messages": len(sent), "per_day": round(len(sent) / days, 2), "days_over_one": sum(n > 1 for n in per.values()), "days": days}


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    for k in ("registry", "ledger", "jobs", "labels"):
        p.add_argument(f"--{k}", required=True)
    p.add_argument("--from", dest="start", required=True)
    p.add_argument("--to", dest="end", required=True)
    p.add_argument("--at", default="09:30")
    p.add_argument("--heartbeat-log")
    p.add_argument("--telegram-log")
    p.add_argument("--min-detection", type=float)
    p.add_argument("--max-false", type=float)
    p.add_argument("--json")
    a = p.parse_args()
    start, end = dt.date.fromisoformat(a.start), dt.date.fromisoformat(a.end)
    hh, mm = map(int, a.at.split(":"))
    days = [dt.datetime.combine(start + dt.timedelta(days=i), dt.time(hh, mm)) for i in range((end - start).days + 1)]
    labels = load(a.labels)
    result = {"window": f"{start} to {end} at {a.at}", "floor": {"detection": a.min_detection, "false_share": a.max_false}, "fleet": score(fleet_flags(a, days), labels)}
    if a.heartbeat_log:
        hb = {t: f for t, f in heartbeat_flags(a.heartbeat_log, a.ledger).items() if start <= t.date() <= end}
        began = min(hb) if hb else None  # incidents over before its log began aren't its misses
        result["heartbeat"] = score(hb, [lb for lb in labels if began and dt.datetime.fromisoformat(lb["end"]) + GRACE >= began])
    if a.telegram_log:
        result["attention"] = attention(a.telegram_log, start, end)
    text = json.dumps(result, indent=1)
    if a.json:
        Path(a.json).write_text(text + "\n")
    print(text)
    f = result["fleet"]
    low = a.min_detection is not None and (f["detection"] or 0) < a.min_detection
    noisy = a.max_false is not None and (f["false_share"] or 0) > a.max_false
    if low or noisy:
        print(f'replay: detection {f["detection"]} (min {a.min_detection}), false share {f["false_share"]} (max {a.max_false})', file=sys.stderr)
    sys.exit(1 if low or noisy else 0)


if __name__ == "__main__":
    main()
