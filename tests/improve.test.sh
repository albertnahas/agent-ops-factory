#!/usr/bin/env bash
# Checks the improver's reading and its outcome check: the registry's Improver column, each loop's KPI line, and each
# change read as kept, reverted or closed, or left for later, from a made-up registry, ledger and history. A gh stand-in
# answers for the PRs, so nothing real is read.
# Usage: tests/improve.test.sh   Needs bash, jq and python3. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_DIR=$(mktemp -d) FLEET_NOW=2026-11-22T10:00:00
D=$AGENT_OPS_DIR
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/fleet" && export PATH="$D/bin:$PATH"
printf '#!/bin/sh\nexit 0\n' > "$D/bin/crontab"
cat > "$D/bin/gh" <<'EOF'
#!/bin/sh
case $3 in
  */pull/1|*/pull/2|*/pull/3|*/pull/4) echo '{"state":"MERGED","mergedAt":"2026-11-10T12:00:00Z"}';;
  */pull/5) echo '{"state":"CLOSED","mergedAt":null}';;
  */pull/6) echo '{"state":"MERGED","mergedAt":"2026-11-20T12:00:00Z"}';;
  */pull/7) echo '{"state":"OPEN","mergedAt":null}';;
  */pull/8) echo '{"state":"MERGED","mergedAt":"2026-11-15T12:00:00Z"}';;
  *) echo "no such PR: $3" >&2; exit 1;;
esac
EOF
chmod +x "$D/bin/"*
fail=0
expect() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
echo "{\"launch_agents\": \"$D/none\", \"tasks\": \"$D/none\"}" > "$D/fleet.json"
cat > "$D/REGISTRY.md" <<'EOF'
## Registry

| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Read by | Improver |
|---|---|---|---|---|---|---|---|---|
| up | Shop | cloud | routine:up | daily | | | you | on |
| down | Shop | cloud | routine:down | daily | | | you | on |
| even | Shop | cloud | routine:even | daily | | | you | On |
| bare | Shop | cloud | routine:bare | daily | | | you | on |
| nobar | Shop | cloud | routine:nobar | daily | | | you | on |
| off | Shop | cloud | routine:off | daily | | | you | |
EOF
# a check line a day from 1 to 21 Nov: up rises past its bar on the 10th; down drops below it on the 15th; guard improves on
# the 10th but its checks then fail every other day; late starts on the 13th. From the 10th noise moves by less than its
# noise, clear by far more, and tally's total gains 3 a run instead of 1 while its 7-day values stay flat; gappy gains 1 a run throughout but from the 10th logs
# its total only every other day
python3 - "$D/runs.jsonl" <<'EOF'
import json, sys
def line(loop, day, check="pass", **good): return json.dumps({"loop": loop, "date": f"2026-11-{day:02d}T12:00:00Z", "check": check, **good})
out = []
for d in range(1, 22):
    out += [line("up", d, value=0.7 if d < 10 else 0.9, better="higher", bar=0.8), line("down", d, value=80 if d < 15 else 50, better="higher", bar=62),
            line("guard", d, "pass" if d < 10 or d % 2 else "fail", value=20 if d < 10 else 10, better="lower"), line("even", d, value=5, better="higher", bar=5),
            line("bare", d), line("nobar", d, value=3, better="higher"), line("off", d, value=1, better="higher", bar=2),
            line("noise", d, value=(10, 14)[d % 2] + (d >= 10), better="higher"), line("clear", d, value=(10, 14)[d % 2] + 20 * (d >= 10), better="higher"),
            line("tally", d, value=100, better="higher", total=d if d < 10 else 3 * d - 18),
            line("gappy", d, value=7, better="higher", **({"total": d} if d < 10 or d % 2 else {}))]
out += [line("late", d, value=1, better="higher") for d in range(13, 22)] + [line("young", 21, value=9, better="higher"), "not json"]
open(sys.argv[1], "w").write("\n".join(out) + "\n")
EOF
c() { echo "{\"id\":\"$1\",\"date\":\"$2\",\"loop\":\"$3\",\"pr\":\"https://github.com/o/r/pull/$4\",\"change\":\"Change $1\",\"metric\":\"good\"$5}"; }
{
  c k1 2026-11-09 up 1 ',"better":"higher"'
  c g1 2026-11-09 guard 2 ',"better":"lower"'
  c e1 2026-11-09 even 3 ',"better":"higher"'
  c r1 2026-11-15 down 8 ',"better":"higher","runs":5'
  c d2 2026-11-20 down 9 ''
  c x1 2026-11-09 shut 5 ',"better":"higher"'
  c n1 2026-11-19 young 6 ',"better":"higher"'
  c o1 2026-11-21 wait 7 ',"better":"higher"'
  c s1 2026-11-21 wait 99 ',"better":"higher","runs":"7"'
  c l1 2026-11-14 late 8 ',"better":"higher","runs":5'
  c u1 2026-11-21 wait 66 ',"better":"higher"'
  echo 'not json'
} > "$D/improvements.jsonl"

# The registry column
python3 fleet/fleet.py >/dev/null
expect "Improver on (any case) rides on the loop's row, blank is off" "jq -e '[.rows[] | select(.loop == \"up\" or .loop == \"even\" or .loop == \"off\") | [.loop, .improver]] | sort == [[\"even\", true], [\"off\", false], [\"up\", true]]' $D/fleet/loops.json >/dev/null"
expect "--check passes Improver on and blank" "python3 fleet/fleet.py --check >/dev/null"
sed 's/| you | |$/| you | maybe |/' "$D/REGISTRY.md" > "$D/bad.md" && echo "{\"registry\": \"$D/bad.md\"}" > "$D/bad.json"
expect "--check rejects any other Improver value" "! FLEET_CONFIG=$D/bad.json python3 fleet/fleet.py --check > $D/said && grep -q 'Registry row off: Improver is on or blank' $D/said"

# The reading
python3 fleet/improve_read.py --json > "$D/read.json"
K=$D/kpi.jsonl
kpi() { jq -c --arg l "$1" 'select(.loop == $l) | del(.date)' "$K"; }
expect "met: the latest value at or past its bar, as of its date"        "[ \"\$(kpi up)\" = '{\"loop\":\"up\",\"as_of\":\"2026-11-21\",\"value\":0.9,\"better\":\"higher\",\"bar\":0.8,\"kpi\":\"met\"}' ] && [ \"\$(kpi even)\" = '{\"loop\":\"even\",\"as_of\":\"2026-11-21\",\"value\":5,\"better\":\"higher\",\"bar\":5,\"kpi\":\"met\"}' ]"
expect "below: since the streak began, attempts since then, escalated at 2 of 2" "[ \"\$(kpi down)\" = '{\"loop\":\"down\",\"as_of\":\"2026-11-21\",\"value\":50,\"better\":\"higher\",\"bar\":62,\"kpi\":\"below\",\"since\":\"2026-11-15\",\"attempts\":2,\"of\":2,\"escalated\":true}' ]"
expect "measured: a value with no bar"                  "[ \"\$(kpi nobar)\" = '{\"loop\":\"nobar\",\"as_of\":\"2026-11-21\",\"value\":3,\"better\":\"higher\",\"kpi\":\"measured\"}' ]"
expect "no KPI: no value"                               "[ \"\$(kpi bare)\" = '{\"loop\":\"bare\",\"kpi\":\"no KPI\"}' ]"
expect "a loop without Improver on gets no KPI line"     "[ -z \"\$(kpi off)\" ] && [ \$(wc -l < $K) -eq 5 ] && jq -e 'select(.date == \"2026-11-22\")' $K >/dev/null"
O() { jq -Rc --arg i "$1" 'fromjson? | select(.id == $i and .outcome) | [.outcome, .moved]' "$D/improvements.jsonl"; }
expect "kept: the mean beat the baseline it computed from the runs before, and the pass rate held" "[ \"\$(O k1)\" = '[\"kept\",true]' ] && jq -Re 'fromjson? | select(.id == \"k1\" and .outcome) | .baseline == 0.7 and .pass_rate_before == 1 and (.result | startswith(\"mean 0.9 vs baseline 0.7\"))' $D/improvements.jsonl >/dev/null"
expect "reverted: a worse mean, an equal mean, or a lower pass rate" "[ \"\$(O r1)\" = '[\"reverted\",false]' ] && [ \"\$(O e1)\" = '[\"reverted\",false]' ] && [ \"\$(O g1)\" = '[\"reverted\",false]' ]"
expect "closed: the PR closed without merging"           "[ \"\$(O x1)\" = '[\"closed\",false]' ]"
expect "nothing: too few runs after or before, an open PR, runs not a whole number, or gh failing" "[ -z \"\$(O n1)\$(O o1)\$(O s1)\$(O l1)\$(O u1)\" ]"
expect "outcome lines carry no date, so the change keeps its own" "jq -Rse '[split(\"\\n\")[] | fromjson? | select(.outcome)] | length == 5 and all(has(\"date\") | not)' $D/improvements.jsonl >/dev/null"
expect "--json: reverts owed, open changes and the hit rate" "jq -e '.reverts_owed == [\"g1\",\"e1\",\"r1\"] and .open == [\"n1\",\"o1\",\"u1\"] and .unreadable == [\"d2\",\"s1\",\"l1\"] and .unreachable == [\"u1\"] and .hit_rate == {\"hits\":1,\"read\":4,\"stopped\":false}' $D/read.json >/dev/null"
cp "$K" "$D/kpi.before" && cp "$D/improvements.jsonl" "$D/imp.before"
python3 fleet/improve_read.py > "$D/said"
expect "a second run the same day appends nothing"       "cmp -s $K $D/kpi.before && cmp -s $D/improvements.jsonl $D/imp.before"
expect "the summary says what is owed"                   "grep -q 'reverts owed: g1, e1, r1 · hit rate: 1 of 4' $D/said"

# The outcome check
chk() { python3 improver/check.py > "$D/said"; }
expect "check fails while a revert is owed"              "! chk && grep -q 'g1 was reverted with no revert_pr' $D/said"
for i in g1 e1 r1; do echo "{\"id\":\"$i\",\"revert_pr\":\"https://github.com/o/r/pull/1$i\"}" >> "$D/improvements.jsonl"; done
expect "check passes and prints the hit rate as its Good, no bar before 6 are read" "chk && [ \"\$(tail -1 $D/said)\" = 'good: 0.250 higher' ]"
printf '{"id":"h%s","loop":"up","outcome":"kept","moved":true}\n' 1 2 >> "$D/improvements.jsonl"
expect "from 6 read changes the bar is the Floor, 1 in 3" "chk && [ \"\$(tail -1 $D/said)\" = 'good: 0.500 higher 0.333' ]"
full='"date":"2026-11-22","pr":"https://github.com/o/r/pull/20","change":"Shorter steps","trace":["runs.jsonl:4"],"hypothesis":"h","metric":"good","better":"higher","runs":7,"read_date":"2026-11-30"'
cp "$D/improvements.jsonl" "$D/imp.ok"
echo "{\"id\":\"t1\",\"loop\":\"up\",$full}" >> "$D/improvements.jsonl"
expect "check passes one full change today"              "chk"
echo "{\"id\":\"t2\",\"loop\":\"down\",$full}" >> "$D/improvements.jsonl"
expect "check fails two changes today"                   "! chk && grep -q '2 changes opened today, at most 1' $D/said"
cp "$D/imp.ok" "$D/improvements.jsonl" && echo '{"id":"t3","date":"2026-11-22","loop":"up","pr":"https://github.com/o/r/pull/21"}' >> "$D/improvements.jsonl"
expect "check fails a change that lacks a field"         "! chk && grep -q 't3 lacks change, trace, hypothesis' $D/said"
cp "$D/imp.ok" "$D/improvements.jsonl" && echo "{\"id\":\"t5\",\"loop\":\"up\",${full/\"runs\":7/\"runs\":\"7\"}}" >> "$D/improvements.jsonl"
expect "check fails runs that isn't a whole number of at least 2" "! chk && grep -q \"t5 has runs '7'\" $D/said"
cp "$D/imp.ok" "$D/improvements.jsonl" && echo "{\"id\":\"t4\",\"loop\":\"off\",$full}" >> "$D/improvements.jsonl"
expect "check fails a change on a loop without Improver on" "! chk && grep -q 't4 names off' $D/said"
cp "$D/imp.ok" "$D/improvements.jsonl" && jq -c 'select(.loop != "bare")' "$D/kpi.before" > "$K"
expect "check fails with a KPI line missing today"        "! chk && grep -q 'no KPI line today for bare' $D/said"

cp "$D/REGISTRY.md" "$D/reg" && sed -E 's/ [oO]n \|$/ |/' "$D/reg" > "$D/REGISTRY.md"
expect "check fails when it read no loop at all"          "! chk && grep -q 'no loop has Improver on' $D/said"
cp "$D/reg" "$D/REGISTRY.md"

# The noise margin
{ c n2 2026-11-09 noise 1 ',"better":"higher"'; c c2 2026-11-09 clear 2 ',"better":"higher"'; c t2 2026-11-09 tally 3 ',"better":"higher"'; c p2 2026-11-09 gappy 4 ',"better":"higher","runs":3'; } > "$D/improvements.jsonl"
python3 fleet/improve_read.py >/dev/null
R() { jq -c --arg i "$1" 'select(.id == $i and .outcome) | [.outcome, .baseline, .after, (.margin * 1000 | round)]' "$D/improvements.jsonl"; }
expect "reverted: a change whose mean moved by less than two standard errors" "[ \"\$(R n2)\" = '[\"reverted\",11.714285714285714,13.285714285714286,2286]' ]"
expect "kept: a change that moved its mean by far more"  "[ \"\$(R c2)\" = '[\"kept\",11.714285714285714,32.285714285714285,2286]' ]"
expect "a running total is read on its gain each run"     "[ \"\$(R t2)\" = '[\"kept\",1.0,3.0,0]' ] && jq -e 'select(.id == \"t2\" and .outcome) | .result | contains(\"over 7 gains per check in total\")' $D/improvements.jsonl >/dev/null"
expect "a gap in a running total is not read as a gain"   "[ \"\$(R p2)\" = '[\"reverted\",1.0,1.0,0]' ]"
expect "a reverted change's result doesn't say kept"   "jq -e 'select(.id == \"n2\" and .outcome) | .result | contains(\"kept\") | not' $D/improvements.jsonl >/dev/null"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
