#!/usr/bin/env bash
# Checks the fleet builder: it runs with nothing set up, reads a registry and a ledger with junk lines in it, decides
# each status, and writes the data files and a dashboard that carries them.
# Usage: tests/fleet.test.sh   Needs bash, jq and python3. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_DIR=$(mktemp -d) H=$(mktemp -d)
export AGENT_OPS_KIT="$PWD/tests/kit"  # the test copy of the kit's question spec, never the real kit
trap 'rm -rf "$AGENT_OPS_DIR" "$H" "$H.reg"' EXIT
# launchctl and crontab stand-ins, so this machine's own jobs stay out of the test: what $AGENT_OPS_DIR/launchctl.txt
# (launchctl list's table) and crontab.txt say
mkdir "$AGENT_OPS_DIR/bin" && export PATH="$AGENT_OPS_DIR/bin:$PATH"
printf '#!/bin/sh\n[ "$1" = list ] && cat "$AGENT_OPS_DIR/launchctl.txt" 2>/dev/null; exit 0\n' > "$AGENT_OPS_DIR/bin/launchctl"
printf '#!/bin/sh\ncat "$AGENT_OPS_DIR/crontab.txt" 2>/dev/null; exit 0\n' > "$AGENT_OPS_DIR/bin/crontab"
printf '#!/bin/sh\ncat "$AGENT_OPS_DIR/ps.txt" 2>/dev/null; exit 0\n' > "$AGENT_OPS_DIR/bin/ps"  # and ps: pid, how long it has run
chmod +x "$AGENT_OPS_DIR/bin/"*
fail=0
expect() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
L="$AGENT_OPS_DIR/fleet/loops.json"
status() { jq -r --arg l "$1" '.rows[] | select(.loop == $l) | .status' "$L"; }

echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\"}" > "$AGENT_OPS_DIR/fleet.json"
expect "builds with no registry and no ledger" "python3 fleet/fleet.py >/dev/null && jq -e '.rows == []' $L >/dev/null"

day() { date -v-"$1"d +%FT10:00:00 2>/dev/null || date -d "$1 days ago" +%FT10:00:00; }
cat > "$AGENT_OPS_DIR/REGISTRY.md" <<EOF
## Registry

| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by | Supervisor |
|---|---|---|---|---|---|---|---|---|
| good | Shop | cloud | routine:good | daily | | | you | You |
| broken | Shop | cloud | routine:broken | daily | | | good, heartbeat | good |
| flaky |  | cloud | routine:flaky | daily | | | you | flaky |
| fresh | Blog | cloud | routine:fresh | daily | | | you | ghost |
| reader | Blog | cloud | routine:reader-job | daily | | | routine:good, YOU, flaky, you, reader-job | routine:watched |
| lonely | Blog | cloud | routine:lonely | daily | | | |  |
| watched | Blog | cloud | routine:watched | daily | | | com.me.build | reader |
| jobless | Blog | mac |  | daily | | | |  |

## Services

| Service | Job | What it is |
|---|---|---|
| Build | com.me.build | rebuilds the page |
| Watchman | routine:watchman | watches the watcher |
| Sleeper | routine:sleeper | turned off on claude.ai |
| Gone | routine:gone | deleted on claude.ai |
| Poster | routine:poster | posts, then a check proves it |
EOF
{
  echo "{\"loop\":\"good\",\"date\":\"$(day 1)\",\"subtype\":\"success\",\"cost\":2}"
  echo "{\"loop\":\"good\",\"date\":\"$(day 1)\",\"check\":\"pass\",\"detail\":\"report landed\"}"
  echo "{\"loop\":\"broken\",\"date\":\"$(day 1)\",\"check\":\"fail\",\"detail\":\"report missing\"}"
  for v in fail fail fail pass; do echo "{\"loop\":\"flaky\",\"date\":\"$(day 1)\",\"check\":\"$v\"}"; done
  echo "{\"loop\":\"Poster\",\"date\":\"$(day 1)\",\"check\":\"fail\",\"detail\":\"post not on the API\"}"
  echo "{\"loop\":\"stray\",\"date\":\"$(day 1)\",\"subtype\":\"success\"}"
  printf 'not json\n{}\n'
} > "$AGENT_OPS_DIR/runs.jsonl"
{
  echo '{"id":"c1","date":"2026-11-01","loop":"broken","pr":"https://github.com/o/r/pull/1","change":"Retry the fetch","trace":["https://x/run/1","runs.jsonl:12"],"metric":"pass rate","read_date":"2026-11-15"}'
  echo '{"id":"c2","date":"2026-11-08","loop":"good","change":"Shorter prompt","outcome":"pending"}'
  echo '{"id":"c1","outcome":"kept","moved":true,"result":"pass rate 60% to 90%"}'
  printf 'not json\n{"id":"orphan"}\n'
} > "$AGENT_OPS_DIR/improvements.jsonl"
{
  echo '{"date":"2026-11-15","loop":"broken","kpi":"met","value":80,"bar":62,"floor":"at least 62%"}'
  echo '{"date":"2026-11-22","loop":"broken","kpi":"below","value":50,"bar":62,"of":2,"attempts":1,"since":"2026-11-22","escalated":false,"floor":"at least 62%"}'
  echo '{"date":"2026-11-22","loop":"good","kpi":"no KPI"}'
  echo '{"date":"2026-11-22","loop":"fresh","kpi":"measured","value":5,"better":"higher","as_of":"2026-11-21"}'
  printf 'not json\n{"loop":"flaky","kpi":"great"}\n'
} > "$AGENT_OPS_DIR/kpi.jsonl"
mkdir -p "$AGENT_OPS_DIR/eval" && echo '{"window":"2026-11-08 to 2026-11-22 at 09:30","floor":{"detection":0.66},"fleet":{"incidents":12,"detected":8,"detection":0.667,"median_hours":2.65,"false_share":0.542},"attention":{"per_day":3.13}}' > "$AGENT_OPS_DIR/eval/result.json"
echo "{\"at\":\"$(date +%FT%T%z | sed 's/\(..\)$/:\1/')\",\"routines\":[$(for r in good broken flaky fresh reader-job lonely watched watchman poster; do printf '{"name":"%s","enabled":true,"cron":"0 6 * * *","next_run_at":null,"last_status":null,"last_finished_at":null},' $r; done)$(printf %s '{"name":"sleeper","enabled":false}')],\"tasks\":[]}" > "$AGENT_OPS_DIR/fleet/cloud.json"

echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\", \"general\": [\"blog\"], \"waiting\": {\"queue\": {\"path\": \"$AGENT_OPS_DIR/QUEUE.md\", \"owner\": \"You\"}}}" > "$AGENT_OPS_DIR/fleet.json"
printf 'due | kind | item | owner | next action | done when | source\n---\n2026-12-01 | decision | Pick a price | You | decide | priced | agent\n' > "$AGENT_OPS_DIR/QUEUE.md"
scope() { jq -r --arg l "$1" '.rows[] | select(.loop == $l) | .scope' "$L"; }

expect "builds with a registry and a junky ledger" "python3 fleet/fleet.py >/dev/null"
expect "a passing check is healthy"            "[ \"\$(status good)\" = healthy ]"
expect "a failed check is failing"             "[ \"\$(status broken)\" = failing ]"
expect "3 of the last 7 failed is flaky"       "[ \"\$(status flaky)\" = chronic ]"
expect "never run is not run yet"              "[ \"\$(status fresh)\" = 'no runs yet' ]"
expect "a ledger name with no row is unregistered" "[ \"\$(status stray)\" = unregistered ]"
expect "a routine service is read from the snapshot: there, off, gone" "[ \"\$(status Watchman)\" = service ] && [ \"\$(status Sleeper)\" = paused ] && [ \"\$(status Gone)\" = missing ] && jq -e '.rows[] | select(.loop == \"Gone\") | .runtime == \"cloud\" and (.detail | test(\"no routine named gone in the claude.ai snapshot\"))' $L >/dev/null"
expect "a service that logs a failed check is failing, with its pass rate" "[ \"\$(status Poster)\" = failing ] && jq -e '.rows[] | select(.loop == \"Poster\") | .checks == \"0 of 1\" and .detail == \"post not on the API\"' $L >/dev/null"
expect "checked by is a comma list"            "jq -e '.rows[] | select(.loop == \"broken\") | .checked_by == \"good, heartbeat\"' $L >/dev/null"
expect "every cell is a scalar, as on claude.ai" "jq -se 'all(.[].rows[][]; type != \"array\" and type != \"object\")' $L $AGENT_OPS_DIR/fleet/waiting.json >/dev/null"
expect "a loop's KPI is its latest kpi.jsonl line, as scalar cells" "jq -e '[.rows[] | select(.loop == \"broken\" or .loop == \"good\" or .loop == \"flaky\" or .loop == \"fresh\") | [.loop, .kpi, .kpi_value, .kpi_attempts, .kpi_of, .kpi_since, .kpi_better]] | sort == [[\"broken\", \"below\", 50, 1, 2, \"2026-11-22\", null], [\"flaky\", null, null, null, null, null, null], [\"fresh\", \"measured\", 5, null, null, null, \"higher\"], [\"good\", \"no KPI\", null, null, null, null, null]]' $L >/dev/null"
expect "the replay eval's latest scores ride in the meta, beside the KPIs" "jq -e '[.meta[] | select(.label | startswith(\"Eval: \"))] == [{\"label\": \"Eval: Replay window\", \"value\": \"2026-11-08 to 2026-11-22 at 09:30\"}, {\"label\": \"Eval: Replay, dashboard\", \"value\": \"catches 67% of real incidents (8 of 12), floor 66% · 54% of its flags are false alarms · flags in 2.65 h (median)\"}, {\"label\": \"Eval: Messages to you\", \"value\": \"3.13 a day\"}]' $L >/dev/null"
C=$AGENT_OPS_DIR/fleet/changes.json
expect "the improver's history: one row a change, the last line for an id wins, newest first" "jq -e '[.rows[] | [.id, .outcome, .moved, .result]] == [[\"c2\", \"pending\", null, null], [\"c1\", \"kept\", true, \"pass rate 60% to 90%\"]]' $C >/dev/null"
expect "a change's trace is one link a line, every cell a scalar" "jq -e '(.rows[] | select(.id == \"c1\") | .trace == \"https://x/run/1\\nruns.jsonl:12\") and all(.rows[][]; type != \"array\" and type != \"object\")' $C >/dev/null"
expect "checked by resolves jobs and you, once each" "jq -e '.rows[] | select(.loop == \"reader\") | .checked_by == \"good, you, flaky, reader\"' $L >/dev/null"
expect "a service's job names the service"   "jq -e '.rows[] | select(.loop == \"watched\") | .checked_by == \"Build\"' $L >/dev/null"
sup() { jq -r --arg l "$1" '.rows[] | select(.loop == $l) | "\(.supervisor) | \(.supervisor_issue)"' "$L"; }
expect "a supervisor is a loop or you; a checker is a loop, a service or you" "[ \"\$(sup broken)\" = 'good | checker heartbeat is not a loop, a service or you' ] && [ \"\$(sup good)\" = 'you | null' ]"
expect "a supervisor's job names its loop"     "[ \"\$(sup reader | cut -d' ' -f1)\" = watched ]"
expect "no supervisor is fine; no reader is flagged" "[ \"\$(sup lonely)\" = 'null | nobody reads it' ]"
expect "a missing supervisor is flagged"       "[ \"\$(sup fresh)\" = 'ghost | supervisor ghost is not a loop in the registry' ]"
expect "a supervision cycle is drawn once, on its first loop" "sup flaky | grep -q 'comes back to it: flaky → flaky' && sup reader | grep -q 'reader → watched → reader' && sup watched | grep -q 'in the cycle through reader'"
expect "a registered row with no job is paused" "[ \"\$(status jobless)\" = paused ]"
expect "the registry-only check names the same issues" "! python3 fleet/fleet.py --check > $AGENT_OPS_DIR/issues && diff <(jq -r '[.rows[] | select(.supervisor_issue) | \"\\(.loop): \\(.supervisor_issue)\"] | join(\"; \")' $L) $AGENT_OPS_DIR/issues"
expect "no checker is an empty cell"           "jq -e '.rows[] | select(.loop == \"lonely\") | .checked_by == \"\"' $L >/dev/null"
expect "cost comes from the ledger"            "jq -e '.rows[] | select(.loop == \"good\") | .cost == 2' $L >/dev/null"
expect "a project is its own scope"           "[ \"\$(scope good)\" = Shop ]"
expect "no project is General"                 "[ \"\$(scope flaky)\" = General ]"
expect "a project listed as general is General, any case" "[ \"\$(scope fresh)\" = General ] && [ \"\$(jq -r '.rows[] | select(.loop == \"fresh\") | .project' $L)\" = Blog ]"
expect "an unregistered job is General"        "[ \"\$(scope stray)\" = General ]"
expect "a queue line waits in General"         "jq -e '.rows | length == 1 and .[0].scope == \"General\" and .[0].project == \"\"' $AGENT_OPS_DIR/fleet/waiting.json >/dev/null"
of() { python3 -c "import sys; sys.path.insert(0, 'fleet'); from fleet import scoping, C; C['general'] = ['ops']
print(*scoping([{'Project': p} for p in ('Shop', 'Social algorithms', 'Ops', '')])('$1'), sep='/')"; }
expect "a repo maps to its project, any case"  "[ \"\$(of SHOP)\" = Shop/Shop ]"
expect "punctuation doesn't count"             "[ \"\$(of social-algorithms)\" = 'Social algorithms/Social algorithms' ]"
expect "a repo of a general project is General" "[ \"\$(of ops)\" = Ops/General ]"
expect "a repo of no project is General"       "[ \"\$(of ops-queue)\" = /General ]"
expect "the dashboard carries the data"        "grep -q 'report missing' $AGENT_OPS_DIR/fleet/dashboard.html && grep -q 'dash-one-writer' $AGENT_OPS_DIR/fleet/dashboard.html"
expect "with no master, every loop escalates to you, unflagged" "jq -e '[.rows[] | select(.project != \"Unregistered\" and .project != \"Service\")] | all(.escalates_to == \"you\" and .escalates_default and .escalation_issue == null)' $L >/dev/null"

# Escalation: one master is the door to you; managers take their project's escalations; break-glass may skip the line.
cat > "$AGENT_OPS_DIR/REGISTRY.md" <<EOF
## Registry

| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by | Supervisor | Escalates to | Role | Moves |
|---|---|---|---|---|---|---|---|---|---|---|---|
| door | Shop | cloud | routine:door | daily | | | you | | | Master |
| boss | Shop | cloud | routine:boss | daily | | | you | | | manager |
| boss2 | Shop | cloud | routine:boss2 | daily | | | you | | | manager |
| worker | Shop | cloud | routine:worker | daily | | | boss | | | | new_senders |
| lone | Blog | cloud | routine:lone | daily | | | you | | | |
| rogue | Blog | cloud | routine:rogue | daily | | | you | | you | |
| pager | Blog | cloud | routine:pager | daily | | | you | | You | |
| ping | Blog | cloud | routine:ping | daily | | | you | | pong | |
| pong | Blog | cloud | routine:pong-job | daily | | | you | | routine:ping | |
| astray | Blog | cloud | routine:astray | daily | | | you | | nowhere | |
| odd | Blog | cloud | routine:odd | daily | | | you | | | chief |

## Services

| Service | Job | What it is |
|---|---|---|
| stripe | com.me.stripe | watches payments |

## Break-glass

| Who | Why |
|---|---|
| pager | production down |
| com.me.stripe | money at risk, refunds |
| phantom | security |
EOF
python3 fleet/fleet.py >/dev/null
expect "Moves carries the brief input a loop serves; blank is none" "jq -e '[.rows[] | select(.loop == \"worker\" or .loop == \"lone\") | .moves] == [\"new_senders\", null]' $L >/dev/null"
esc() { jq -r --arg l "$1" '.rows[] | select(.loop == $l) | "\(.escalates_to) \(.escalates_default) | \(.escalation_issue)"' "$L"; }
expect "a blank goes to the project's manager"  "[ \"\$(esc worker)\" = 'boss true | null' ]"
expect "a blank with no manager goes to the master" "[ \"\$(esc lone)\" = 'door true | null' ] && [ \"\$(esc boss | cut -d' ' -f1)\" = door ]"
expect "the master's blank is you, even beside a manager"    "[ \"\$(esc door)\" = 'you true | null' ]"
expect "only the master and break-glass reach you" "esc rogue | grep -q 'straight to you' && [ \"\$(esc pager)\" = 'you false | null' ]"
expect "a break-glass reason is on its row"      "jq -e '[.rows[] | select(.break_glass)] | map(\"\\(.loop)=\\(.break_glass)\") == [\"pager=production down\", \"stripe=money at risk, refunds\"]' $L >/dev/null"
expect "a service nothing runs is missing, not paused" "jq -e '.rows[] | select(.loop == \"stripe\") | .status == \"missing\" and (.detail | test(\"com.me.stripe\"))' $L >/dev/null"
expect "escalation cycles are flagged, by job too" "esc ping | grep -q 'comes back to it: ping → pong → ping'"
expect "a target that is no loop is flagged"     "esc astray | grep -q 'escalates to nowhere, which is not a loop'"
expect "one manager per project"                "esc boss | grep -q 'Shop has 2 managers' && esc boss2 | grep -q 'Shop has 2 managers'"
expect "a role is master or manager"            "esc odd | grep -q 'role chief'"
expect "every cell is still a scalar"           "jq -e 'all(.rows[][]; type != \"array\" and type != \"object\")' $L >/dev/null"
expect "the registry-only check names every escalation issue" "! python3 fleet/fleet.py --check > $AGENT_OPS_DIR/issues && diff <(jq -r '[.rows[] | select(.escalation_issue) | \"\\(.loop): \\(.escalation_issue)\"] + [\"phantom: break-glass names no loop or service in the registry\"] | join(\"; \"), \"warning: you: 10 loops name you in Checked by, more than 5; let a supervisor loop read most of them\"' $L) $AGENT_OPS_DIR/issues"

# What defines a loop: its charter (from the registry's folder, or a checkout whose path ends with the cell's leading
# folders), the Orders and dated report its charter names, a routine's page, a task's prompt, a job's script.
mkdir -p "$AGENT_OPS_DIR/docs/orders" "$AGENT_OPS_DIR/docs/reports" "$AGENT_OPS_DIR/tasks/nightly" "$AGENT_OPS_DIR/co/shop/docs" "$AGENT_OPS_DIR/co2/shop/docs"
printf '# Ops\n\nNot [orders/x.md] yet: first read [orders/ops.md](./orders/ops.md).\n\n## Steps\n\n`notes/YYYY-MM-DD.md`\n\n## Daily report\n\nWrite `docs/reports/YYYY-MM-DD.md`.\n' > "$AGENT_OPS_DIR/docs/OPS.md"
printf '## Mission\n\n<!-- mission -->\nMore orders.\n\n- **Floor:** at least 30 orders a week\n- **Source:** the orders table\n<!-- /mission -->\n' >> "$AGENT_OPS_DIR/docs/OPS.md"
printf '# Orders\n\nTarget: at least 40 orders a week\n' > "$AGENT_OPS_DIR/docs/orders/ops.md"
touch "$AGENT_OPS_DIR/docs/orders/ops.md" "$AGENT_OPS_DIR/docs/reports/2026-11-20.md" "$AGENT_OPS_DIR/docs/reports/2026-11-21.md" "$AGENT_OPS_DIR/docs/reports/index.md" "$AGENT_OPS_DIR/tasks/nightly/SKILL.md"
cat > "$AGENT_OPS_DIR/REGISTRY.md" <<EOF
## Registry

| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by |
|---|---|---|---|---|---|---|---|
| ops | Shop | cloud | routine:ops | daily | \`docs/OPS.md\` (the charter) | | you |
| nightly | | app | task:nightly | daily | shop repo | | you |
| bare | | cloud | routine:bare | daily | \`docs/GONE.md\` | | you |
EOF
echo "{\"at\":\"$(date +%FT%T%z | sed 's/\(..\)$/:\1/')\",\"routines\":[{\"id\":\"trig_01abc\",\"name\":\"ops\",\"enabled\":true,\"cron\":null,\"next_run_at\":null,\"last_status\":null,\"last_finished_at\":null}],\"tasks\":[{\"id\":\"nightly\",\"enabled\":true,\"cron\":null,\"next_run_at\":null,\"last_finished_at\":null}]}" > "$AGENT_OPS_DIR/fleet/cloud.json"
echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\", \"tasks\": \"$AGENT_OPS_DIR/tasks\"}" > "$AGENT_OPS_DIR/fleet.json"
python3 fleet/fleet.py >/dev/null
TMP=$(cd "$AGENT_OPS_DIR" && pwd -P)
def() { jq -r --arg l "$1" --arg k "$2" '.rows[] | select(.loop == $l) | .[$k] // ""' "$L" | sed "s|^$TMP/||"; }
expect "a charter is found from the registry's folder"  "[ \"\$(def ops charter)\" = docs/OPS.md ]"
expect "its Orders are the first orders file it names"  "[ \"\$(def ops orders)\" = docs/orders/ops.md ]"
expect "its report is the newest dated file its report section names" "[ \"\$(def ops report)\" = docs/reports/2026-11-21.md ]"
expect "Good is the charter's Floor and its Orders' Target" "[ \"\$(def ops floor)\" = 'at least 30 orders a week' ] && [ \"\$(def ops target)\" = 'at least 40 orders a week' ] && [ -z \"\$(def nightly floor)\" ]"
printf '# Orders\n' > "$AGENT_OPS_DIR/docs/orders/ops.md"; python3 -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("<!-- /mission -->\n", "").replace("More orders.\n", "More orders.\n<!-- /mission -->\n"))' "$AGENT_OPS_DIR/docs/OPS.md"; python3 fleet/fleet.py >/dev/null
expect "a Floor outside the mission markers, or no Target, shows nothing" "sed -n '/<!-- \\/mission -->/,\$p' $AGENT_OPS_DIR/docs/OPS.md | grep -q '^- \\*\\*Floor:' && [ -z \"\$(def ops floor)\$(def ops target)\" ]"
expect "a routine links to its claude.ai page"   "[ \"\$(def ops prompt)\" = https://claude.ai/code/routines/trig_01abc ]"
expect "a task links to its prompt file"         "[ \"\$(def nightly prompt)\" = tasks/nightly/SKILL.md ]"
expect "a charter cell with no path, or a missing file, links nothing" "[ -z \"\$(def nightly charter)\$(def bare charter)\$(def bare orders)\$(def bare report)\" ]"
expect "every link cell is a scalar"             "jq -e 'all(.rows[][]; type != \"array\" and type != \"object\")' $L >/dev/null"
# Weight: each charter, report folder and memory index against its budget; over budget is listed first
mkdir -p "$AGENT_OPS_DIR/mem/a" "$AGENT_OPS_DIR/mem/b" && printf -- '- one\n- two\n- three\n' > "$AGENT_OPS_DIR/mem/a/MEMORY.md" && printf -- '- one\n' > "$AGENT_OPS_DIR/mem/b/MEMORY.md"
touch "$AGENT_OPS_DIR/docs/reports/2026-11-22-review.md"
echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\", \"tasks\": \"$AGENT_OPS_DIR/tasks\", \"memory\": [\"$AGENT_OPS_DIR/mem/*/MEMORY.md\"], \"budgets\": {\"charter_kb\": 0.1, \"reports\": 2, \"index_lines\": 2}}" > "$AGENT_OPS_DIR/fleet.json"
python3 fleet/fleet.py >/dev/null; W="$AGENT_OPS_DIR/fleet/weight.json"
over() { jq -r '[.rows[] | select(.over) | "\(.kind) \(.size)"] | join(", ")' "$W"; }
expect "weight: a charter, a report folder (dated files only) and a memory index over budget, the one under not" "[ \"\$(over)\" = 'charter 0.3, memory 3, reports 3' ] && jq -e '[.rows[] | select(.kind == \"memory\")] | length == 2' $W >/dev/null"
expect "weight: a dated file with a suffix isn't the latest report" "[ \"\$(def ops report)\" = docs/reports/2026-11-21.md ]"
expect "weight: a memory index carries its KB and KB budget too" "jq -e '[.rows[] | select(.kind == \"memory\") | (.kb | type) == \"number\" and .kb_budget == 20] | all' $W >/dev/null"
expect "weight: a charter names the loops that read it" "jq -e '.rows[] | select(.kind == \"charter\") | .loops == [\"ops\"]' $W >/dev/null"
# The prompt builder's questions: the kit's spec, flattened to rows of scalars in its order, choices after their question.
Q="$AGENT_OPS_DIR/fleet/questions.json"
qs() { python3 -c "import sys; sys.path.insert(0, 'fleet'); import fleet; r, p, why = fleet.questions(); print(why or '')"; }
expect "questions follow the spec in order, a row per choice" "python3 -c 'import json,sys; s=json.load(open(\"tests/kit/skills/new-loop/questions.json\")); r=json.load(open(\"$Q\"))[\"rows\"]; sys.exit(0 if [(x[\"form\"],x[\"id\"],x[\"value\"]) for x in r]==[(f,q[\"id\"],v) for f in (\"new\",\"edit\") for q in s[f] for v in [None]+[c[\"value\"] for c in q.get(\"choices\",[])]] and [x[\"route\"] for x in r if x[\"id\"]==\"change\" and x[\"value\"]]==[\"orders\",\"founder\"] else 1)'"
expect "the spec's defaults are never asked" "jq -e '[.rows[].id] | index(\"limits\") == null' $Q >/dev/null"
expect "its prompt lines are in meta, every cell a scalar" "jq -e '([.meta[] | select(.label | startswith(\"prompt \")) | .value] == [\"/demo:new-loop\", \"/demo:new-loop edit\"]) and all(.rows[][]; type != \"array\" and type != \"object\")' $Q >/dev/null"
mkdir -p "$AGENT_OPS_DIR/kit2/skills/new-loop"; jq '.new[0].colour = "red" | .edit[0].kind = "date"' tests/kit/skills/new-loop/questions.json > "$AGENT_OPS_DIR/kit2/skills/new-loop/questions.json"
expect "a spec this build doesn't know asks nothing, and says why" "AGENT_OPS_KIT=$AGENT_OPS_DIR/kit2 python3 fleet/fleet.py 2>&1 >/dev/null | grep -q 'unknown key colour.*unknown kind date' && jq -e '.rows == []' $Q >/dev/null"
expect "no kit, no questions"                     "AGENT_OPS_KIT=$AGENT_OPS_DIR/none python3 fleet/fleet.py >/dev/null 2>&1 && jq -e '.rows == []' $Q >/dev/null"
KIT=${AGENT_OPS_KIT_REAL:-$HOME/.agent-ops/kit}
if [ -f "$KIT/skills/new-loop/questions.json" ]; then
  expect "the installed kit's spec is one this build reads" "[ -z \"\$(AGENT_OPS_KIT=$KIT qs)\" ]"
else echo "skip  the installed kit's spec is one this build reads (no kit at $KIT)"; fi
python3 fleet/fleet.py >/dev/null
touch "$AGENT_OPS_DIR/co/shop/docs/LOOP.md"
loc() { python3 -c "import sys; from pathlib import Path; sys.path.insert(0, 'fleet'); from fleet import locate
co = Path('$AGENT_OPS_DIR'); print(locate('\`$1\`', '$2', {'shop': [co / 'co/shop', co / 'co2/shop']}) or '')" | sed "s|^$TMP/||"; }
expect "leading folders that end a checkout's path drop" "[ \"\$(loc shop/docs/LOOP.md '')\" = co/shop/docs/LOOP.md ]"
expect "a bare name looks in the project's docs" "[ \"\$(loc LOOP.md Shop)\" = co/shop/docs/LOOP.md ] && [ -z \"\$(loc LOOP.md Blog)\" ]"
touch "$AGENT_OPS_DIR/co2/shop/docs/LOOP.md"
expect "two different files are no answer"      "[ -z \"\$(loc LOOP.md Shop)\" ]"
# On GitHub: a file on the default branch links to its page, read from that branch, so an uncommitted report is skipped.
R="$AGENT_OPS_DIR/gh/shop"; mkdir -p "$R/docs/orders" "$R/docs/reports"
cp "$AGENT_OPS_DIR/docs/OPS.md" "$R/docs/OPS.md"; touch "$R/docs/orders/ops.md" "$R/docs/reports/2026-11-20.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init && git -C "$R" branch -qM main
git -C "$R" remote add origin https://github.com/demo/shop.git && git -C "$R" update-ref refs/remotes/origin/main HEAD && git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
touch "$R/docs/reports/2026-11-21.md"
sed -i.bak 's|`docs/OPS.md` (the charter)|`'"$R"'/docs/OPS.md`|' "$AGENT_OPS_DIR/REGISTRY.md"
python3 fleet/fleet.py >/dev/null
expect "a charter on GitHub links to its page"    "[ \"\$(def ops charter)\" = https://github.com/demo/shop/blob/main/docs/OPS.md ]"
expect "its Orders and report come from the default branch" "[ \"\$(def ops orders)\" = https://github.com/demo/shop/blob/main/docs/orders/ops.md ] && [ \"\$(def ops report)\" = https://github.com/demo/shop/blob/main/docs/reports/2026-11-20.md ]"
w() { python3 -c "import sys; from pathlib import Path; sys.path.insert(0, 'fleet'); from fleet import where; print(where(Path(sys.argv[1])))" "$1"; }
mkdir -p "$R/my notes" && touch "$R/my notes/a.md" && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm notes && git -C "$R" update-ref refs/remotes/origin/main HEAD
expect "a path with spaces links encoded"        "[ \"\$(w \"$R/my notes/a.md\")\" = https://github.com/demo/shop/blob/main/my%20notes/a.md ]"

touch "$AGENT_OPS_DIR/run.sh"
run() { HOME="$AGENT_OPS_DIR" python3 -c "import sys; sys.path.insert(0, 'fleet'); from fleet import runner; print(runner(sys.argv[1:]) or '')" "$@" | sed "s|^$TMP/||"; }
expect "a job's script is its last argument in your home" "[ \"\$(run /bin/bash \"$AGENT_OPS_DIR/run.sh\" morning)\" = run.sh ] && [ -z \"\$(run /bin/bash -c 'echo hi')\" ]"

# Bad input: one odd line, file or field never stops the build or puts a list in a cell; it's left out, or flagged.
mk() { O=$AGENT_OPS_DIR/case-$1; mkdir -p "$O/fleet" "$O/la" "$O/checks"; echo "{\"launch_agents\": \"$O/la\", \"waiting\": {\"queue\": {\"path\": \"$O/QUEUE.md\", \"owner\": \"You\"}}}" > "$O/fleet.json"; }
build() { AGENT_OPS_DIR=$O FLEET_CONFIG=$O/fleet.json python3 fleet/fleet.py "$@" > "$O/said" 2>&1; }
get() { jq -r --arg l "$1" ".rows[] | select(.loop == \$l) | $2" "$O/fleet/loops.json"; }
reg() { printf '## Registry\n\n| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by | Supervisor |\n|---|---|---|---|---|---|---|---|---|\n'; printf '%s\n' "$@"; }
row() { echo "| $1 | ${3:-P} | cloud | routine:$1 | daily | | | you | ${2:-} |"; }
routine() { printf '{"name":%s,"enabled":%s,"cron":"0 6 * * *","next_run_at":%s,"last_status":%s,"last_finished_at":%s}' "$1" "${2:-true}" "${3:-null}" "${4:-null}" "${5:-null}"; }
cloud() { echo "{\"at\":\"$(date +%FT%T%z)\",\"routines\":[$1],\"tasks\":${2:-[]}}" > "$O/fleet/cloud.json"; }
scalar() { jq -se 'all(.[].rows[][]; type != "array" and type != "object")' "$O/fleet/loops.json" "$O/fleet/waiting.json" >/dev/null; }

mk ledger; reg "$(row a)" > "$O/REGISTRY.md"; cloud "$(routine '"a"')"
{ printf '{"loop":"a","date":"%s","check":"fail","detail":"report missing\xe2\x80\xa8really <!--<script>"}\n' "$(day 2)"
  printf '{"loop":"b\xc3\xa9","detail":"x\xc3\n{"loop":["l"],"date":"%s"}\n{"loop":"a","date":20261121}\n' "$(day 1)"
  printf '{"loop":"a","date":"%s","subtype":"success","cost":"1.5","detail":{"x":1}}\n{"loop":12345,"date":"%s","subtype":"success","cost":[1]}\n' "$(day 1)" "$(day 1)"
  printf '{"loop":"a","date":"%s","subtype":"success","cost":1e999}\n{"loop":"a","date":"9999-12-31T23:59:59Z","subtype":"success"}\n' "$(day 3)"
  python3 -c 'print("{\"x\": " + "[" * 100000 + "]" * 100000 + "}")'
  printf '{"loop":"a","date":"%s","check":"pass"}\n' "$(day 9)"
} > "$O/runs.jsonl"
expect "bad bytes, odd types and deep nesting in the ledger don't stop the build" "build && scalar"
expect "a failing check with a U+2028 in its output is still failing" "[ \"\$(get a .status)\" = failing ]"
expect "the latest date is the last run, wherever its line sits" "[ \"\$(get a .last_run)\" = \"\$(day 1 | cut -c1-16)\" ]"
expect "a cost that isn't a finite number counts as 0" "[ \"\$(get a .cost)\" = 0 ]"
expect "a numeric loop name is a string"       "[ \"\$(get 12345 .status)\" = unregistered ] && jq -e 'all(.rows[]; .loop | type == \"string\")' $O/fleet/loops.json >/dev/null"
expect "no text in the data can end the page's script" "grep 'window.FLEET' $O/fleet/dashboard.html | grep -v '<!--' | grep -q 'u003c!--'"

mk tz; reg "$(row a)" > "$O/REGISTRY.md"; cloud "$(routine '"a"')"
printf '{"loop":"a","date":"%s","subtype":"success","cost":1%s}\n' "$(date +%FT%T%z)" "$(printf '0%.0s' $(seq 400))" > "$O/runs.jsonl"
expect "a +0100 offset is read; a 400-digit cost counts as 0" "build && [ \"\$(get a .last_run)\" != null ] && [ \"\$(get a .cost)\" = 0 ]"

mk cloud; reg "$(row a)" "$(row b)" "$(row c)" > "$O/REGISTRY.md"
echo "{\"at\":\"$(date -u +%FT%TZ)\",\"routines\":[$(routine '"a"' true null '"CANCELLED"' '"2026-11-21T06:00:00.123456789Z"'),
$(routine '"b"' false '"2026-11-23T06:00:00Z"'),$(routine '"c"' true null '"SUCCEEDED"' '"2026-11-21T06:00:00Z"'),{\"enabled\":true},
{\"name\":5,\"enabled\":true,\"cron\":[\"0 6 * * *\"],\"last_finished_at\":\"2026-11-21T06:00:00Z\"},\"junk\"],\"tasks\":{\"x\":1}}" > "$O/fleet/cloud.json"
expect "a snapshot in any shape builds, Z times too" "build && scalar && [ \"\$(get a .status)\" != stale ]"
expect "a routine's status is read in any case" "[ \"\$(get c .result)\" = pass ]"
expect "a paused loop has no next run"         "[ \"\$(get b '\"\(.status) \(.next_due)\"')\" = 'paused null' ]"
expect "a numeric routine name is a string, a list cron no cell" "[ \"\$(get 5 '.schedule')\" = 'on event' ]"
echo '{}' > "$O/fleet/cloud.json"
expect "an empty snapshot is stale data"       "build && [ \"\$(get a .status)\" = stale ]"
echo "{\"at\":\"$(date +%FT%T)\",\"routines\":[$(routine '"a"')]}" > "$O/fleet/cloud.json"
expect "a snapshot time with no offset is local" "build && [ \"\$(get a .status)\" = 'no runs yet' ]"

mk mac; python3 - "$O/la" <<'P'
import plistlib, sys
for n, pl in {"str": {"Label": "com.t.str", "StartCalendarInterval": {"Hour": "9", "Minute": 0}}, "list": [1, 2],
              "fast": {"Label": 77, "ProgramArguments": ["/bin/echo", 5], "StartInterval": 30, "StandardOutPath": "/"},
              "intv": {"Label": "com.t.intv", "StartInterval": 300}, "exit": {"Label": "com.t.exit", "StartCalendarInterval": {"Hour": 9}},
              "crash": {"Label": "com.t.crash", "KeepAlive": True}, "steady": {"Label": "com.t.steady", "KeepAlive": True},
              "stopped": {"Label": "com.t.stopped", "KeepAlive": True}, "once": {"Label": "com.t.once", "KeepAlive": True}}.items():
    open(f"{sys.argv[1]}/{n}.plist", "wb").write(plistlib.dumps(pl))
P
printf 'PID\tStatus\tLabel\n-\t0\t77\n-\t0\tcom.t.intv\n-\t1\tcom.t.exit\n-\t0\tcom.t.str\n9\t1\tcom.t.crash\n8\t0\tcom.t.steady\n7\t-15\tcom.t.stopped\n6\t1\tcom.t.once\n' > "$O/launchctl.txt"; printf '    9    00:12\n    6 3-02:00:00\n' > "$O/ps.txt"
printf '*/0 * * * * /bin/x.sh\n0 25 * * * /bin/y.sh\n0 22-2 * * * /bin/z.sh\n5 L * * * /bin/w.sh\n0 6 * * * /bin/ok.sh\n0 6 * * * /bin/%s.sh >> /tmp/%s.log\n' "$(printf 'l%.0s' $(seq 300))" "$(printf 'l%.0s' $(seq 300))" > "$O/crontab.txt"
{ reg; for j in fast:77 intv:com.t.intv exit:com.t.exit crash:com.t.crash steady:com.t.steady stopped:com.t.stopped once:com.t.once; do echo "| ${j%%:*} | P | mac | ${j#*:} | daily | | | you | |"; done; } > "$O/REGISTRY.md"
echo "{\"loop\":\"intv\",\"date\":\"$(day 5)\",\"check\":\"pass\"}" > "$O/runs.jsonl"
expect "odd plists and crontab lines, a 300-character script name too, don't stop the build" "build && scalar && [ -z \"\$(get com.t.str .loop)\" ]"
expect "a 5-minute job quiet for 5 days is silent" "[ \"\$(get intv .status)\" = silent ]"
expect "a 30-second interval says so"          "[ \"\$(get fast .next_due)\" = 'every 30 s' ]"
expect "a launchd exit is the exit code"       "get exit .detail | grep -q '^last run exited 1;'"
expect "a kept-alive job running again after exiting 1 crashed, so it fails; one that never failed, was stopped, or has run 3 days since doesn't" "[ \"\$(get crash .status)\" = failing ] && get crash .detail | grep -q 'restarted' && [ \"\$(get steady .result)\$(get stopped .result)\$(get once .result)\" = nullnullnull ]"
expect "a crontab line cron would reject has no next run" "[ \"\$(get cron:x.sh .next_due)\$(get cron:y.sh .next_due)\$(get cron:z.sh .next_due)\$(get cron:w.sh .next_due)\" = nullnullnullnull ] && [ \"\$(get cron:ok.sh .next_due)\" != null ]"

mk qdir; mkdir "$O/QUEUE.md"
expect "a queue path that is a folder is no queue" "build"
mk queue; printf '# Queue\nFormat: due | kind | item\n2026-12-01 | decision | Pick A | B price | You | decide | priced | agent\n2026-12-02 | decision | A \\| B | you | decide | x | agent\n| 2026-12-03 | todo | outer | YOU | do | x | agent |\n | todo | no date | You | do | x | \n' > "$O/QUEUE.md"
W=$O/fleet/waiting.json
expect "a queue line with a stray | is flagged, not dropped; prose with a | is skipped" "build && jq -e '[.rows[] | select(.title | startswith(\"A queue line\"))] | length == 1' $W >/dev/null"
expect "a queue needs no header; \\| is a pipe; outer pipes, blank end cells and owner case are fine" "jq -e '[.rows[].item] | index(\"A | B\") and index(\"outer\") and index(\"no date\") and length == 4' $W >/dev/null"

mk reg; L300=$(printf 'l%.0s' $(seq 300)); echo "open('$O/ran', 'w')" > "$O/pwn.py"
{ reg "$(row dup '' Social-Algorithms)" "| DUP | P | cloud | routine:d2 | daily | | | other | x |" "| x | y | broken | table | P | cloud | routine:e | daily | | | you | |" \
      "$(row sp '' 'Social algorithms')" "$(row pipe '' 'A \| B')" "$(row "$(printf 'u\xe2\x80\xa8v')")" "$(row g '' General) |" "$(row "$L300")" "$(row ../pwn)" \
      "$(row you)" "$(row Nobody)" "$(row 'a b')"
  for l in t2:t1 t1:ta ta:tb tb:tc tc:tb; do row "${l%%:*}" "${l#*:}"; done; } > "$O/REGISTRY.md"
expect "a long name is a loop; an odd or U+2028 name, you or nobody is left out" "build && [ -n \"\$(get \"$L300\" .loop)\" ] && [ -z \"\$(get \"\$(printf 'u\xe2\x80\xa8v')\" .loop)\$(get you .loop)\$(get Nobody .loop)\$(get 'a b' .loop)\" ]"
expect "a loop name with ../ runs no check outside checks/" "[ ! -e $O/ran ]"
expect "two rows with one name in any case are one loop, the first row's" "[ \$(get dup .loop | wc -l) -eq 1 ] && [ -z \"\$(get DUP .loop)\" ] && [ \"\$(get dup .checked_by)\" = you ]"
expect "a row with a stray | is left out; \\| is a pipe in a cell" "[ -z \"\$(get x .loop)\" ] && [ \"\$(get pipe .project)\" = 'A | B' ]"
expect "an empty cell past the last header is fine" "[ -n \"\$(get g .loop)\" ]"
expect "spellings of a project share the first; a project called General is General" "[ \"\$(get sp .scope)\" = Social-Algorithms ] && [ \"\$(get g .scope)\" = General ]"
expect "a chain that runs into a supervision cycle is flagged" "get t2 .supervisor_issue | grep -q 'runs into the cycle through tb' && get tc .supervisor_issue | grep -q 'in the cycle through tb'"
build --check
expect "the registry's issues wait on you on the page" "jq -e '[.rows[] | select(.kind == \"Registry\") | .item] | any(test(\"row DUP: a row above\")) and any(test(\"cells under 9 headers\"))' $O/fleet/waiting.json >/dev/null"
expect "--check names a duplicate, a broken row and each cycle once" "grep -q 'row DUP: a row above has this Loop' $O/said && grep -q 'cells under 9 headers' $O/said && [ \$(grep -o 'comes back to it' $O/said | wc -l) -eq 1 ]"
expect "--check names each loop name it leaves out" "grep -q 'row you: a loop name is letters' $O/said && grep -q 'row Nobody: a loop name' $O/said && grep -q 'row a b: a loop name' $O/said"
mk chain; { reg "$(row c1)"; for i in $(seq 2 2000); do echo "| c$i | P | cloud | routine:c$i | daily | | | c$((i - 1)) | c$((i - 1)) |"; done; } > "$O/REGISTRY.md"
expect "--check walks a 2000-deep supervisor and checker chain in a blink" "perl -e 'alarm 3; exec @ARGV' env AGENT_OPS_DIR=$O FLEET_CONFIG=$O/fleet.json python3 fleet/fleet.py --check"
# Design answers: who reads a loop, a charter's pause, interval grace, and what claude.ai and launchd say.
mk readers; { reg "$(row boss)" "| w | P | cloud | routine:w | daily | | | boss, you | boss |" "| self | P | cloud | routine:self | daily | | | self | |" \
  "| r1 | P | cloud | routine:r1 | daily | | | r2 | |" "| r2 | P | cloud | routine:r2 | daily | | | r1 | |" "| ext | P | cloud | routine:ext | daily | | | vendor | |" \
  "| via | P | cloud | routine:via | daily | | | Build | |"
  for i in 1 2 3 4 5; do row "f$i"; done; printf '\n## Services\n\n| Service | Job | What it is |\n|---|---|---|\n| Build | com.b | builds |\n'; } > "$O/REGISTRY.md"
expect "Checked by: a self-check, a cycle and a stranger are flagged; a service ends a chain" "build && [ \"\$(get self .supervisor_issue)\" = 'Checked by names itself; nobody reads it' ] && [ \"\$(get r1 .supervisor_issue)\" = 'its checkers never reach you' ] && [ \"\$(get ext .supervisor_issue)\" = 'checker vendor is not a loop, a service or you' ] && [ \"\$(get via .supervisor_issue)\" = null ]"
expect "a loop with a supervisor loop doesn't also name you" "[ \"\$(get w .supervisor_issue)\" = 'Checked by names you, but boss supervises it' ] && [ \"\$(get f1 .supervisor_issue)\" = null ]"
build --check
expect "--check warns when more than 5 loops go straight to you" "grep -q '^warning: you: 7 loops name you in Checked by, more than 5' $O/said"
mk fan; { reg; for i in 1 2 3 4 5 6; do row "f$i"; done; } > "$O/REGISTRY.md"
expect "the fan-in warning alone prints and exits 0" "build --check && [ \"\$(cat $O/said)\" = 'warning: you: 6 loops name you in Checked by, more than 5; let a supervisor loop read most of them' ]"

mk pause; mkdir "$O/ch"; printf '# P\n\nstatus: paused\n' > "$O/ch/p.md"; printf '# A\n\nstatus: active\n' > "$O/ch/a.md"
reg '| p | P | cloud | routine:p | daily | `ch/p.md` | | you | |' '| a | P | cloud | routine:a | daily | `ch/a.md` | | you | |' > "$O/REGISTRY.md"
cloud "$(routine '"p"' true '"2026-01-01T06:00:00Z"'),$(routine '"a"')"
expect "a charter that says status: paused is paused, not silent" "build && [ \"\$(get p '\"\(.status) \(.next_due)\"')\" = 'paused null' ] && [ \"\$(get a .status)\" = 'no runs yet' ]"

ago() { date -v-"$1"H +%FT%T 2>/dev/null || date -d "$1 hours ago" +%FT%T; }
mk grace; python3 - "$O/la" <<'P'
import plistlib, sys
for n, i in {"five": 300, "hourly": 3600}.items(): open(f"{sys.argv[1]}/{n}.plist", "wb").write(plistlib.dumps({"Label": f"com.t.{n}", "StartInterval": i}))
open(f"{sys.argv[1]}/yr.plist", "wb").write(plistlib.dumps({"Label": "com.t.yr", "StartCalendarInterval": {"Month": 12, "Day": 25, "Hour": 9}}))
P
printf 'PID\tStatus\tLabel\n-\t0\tcom.t.five\n-\t0\tcom.t.hourly\n-\t0\tcom.t.yr\n' > "$O/launchctl.txt"
reg '| five | P | mac | com.t.five | 5 min | | | you | |' '| hourly | P | mac | com.t.hourly | hourly | | | you | |' > "$O/REGISTRY.md"
printf '{"loop":"five","date":"%s","check":"pass"}\n{"loop":"hourly","date":"%s","check":"pass"}\n' "$(ago 2)" "$(ago 2)" > "$O/runs.jsonl"
expect "an interval job is silent after 3 intervals, at least an hour" "build && [ \"\$(get five .status)\" = silent ] && [ \"\$(get hourly .status)\" = healthy ]"
expect "a plist with Month and Day is yearly" "get com.t.yr .schedule | grep -q '^yearly' && [ \"\$(get com.t.yr .cadence)\" = one-off ]"
expect "cadence reads the interval" "[ \"\$(get five .cadence)/\$(get hourly .cadence)\" = 'every 5 min/hourly' ]"
mk rare; python3 - "$O/la" <<'P'
import plistlib, sys
for n in ("idle", "dead", "busy"): open(f"{sys.argv[1]}/{n}.plist", "wb").write(plistlib.dumps({"Label": f"com.t.{n}", "StartInterval": 1800}))
P
printf 'PID\tStatus\tLabel\n-\t0\tcom.t.idle\n-\t0\tcom.t.dead\n-\t0\tcom.t.busy\n' > "$O/launchctl.txt"
reg '| idle | P | mac | com.t.idle | 30 min | | | you | |' '| dead | P | mac | com.t.dead | 30 min | | | you | |' '| busy | P | mac | com.t.busy | 30 min | | | you | |' > "$O/REGISTRY.md"
for h in 88 64 40 16; do printf '{"loop":"idle","date":"%s","subtype":"success","exit":0}\n{"loop":"idle","date":"%s","check":"pass"}\n' "$(ago $h)" "$(ago $h)"; done > "$O/runs.jsonl"
for h in 85 61 37; do printf '{"loop":"dead","date":"%s","check":"pass"}\n' "$(ago $h)"; done >> "$O/runs.jsonl"
for h in 19 18 17 16; do printf '{"loop":"busy","date":"%s","check":"pass"}\n' "$(ago $h)"; done >> "$O/runs.jsonl"
expect "an interval job that logs daily isn't silent between lines, and is past 1.5 of its gaps" "build && [ \"\$(get idle .status)\" = healthy ] && [ \"\$(get dead .status)\" = silent ]"
expect "an interval job that logs every run is still judged on its interval" "[ \"\$(get busy .status)\" = silent ]"
mk uneven; python3 - "$O/la" <<'P'
import datetime as dt, plistlib, sys
wd = lambda k: (dt.date.today() - dt.timedelta(days=k)).isoweekday() % 7
for n in ("ran", "missed"): open(f"{sys.argv[1]}/{n}.plist", "wb").write(plistlib.dumps({"Label": f"com.t.{n}", "StartCalendarInterval": [{"Weekday": wd(4), "Hour": 0, "Minute": 0}, {"Weekday": wd(5), "Hour": 0, "Minute": 0}]}))
P
printf 'PID\tStatus\tLabel\n-\t0\tcom.t.ran\n-\t0\tcom.t.missed\n' > "$O/launchctl.txt"
reg '| ran | P | mac | com.t.ran | two days a week | | | you | |' '| missed | P | mac | com.t.missed | two days a week | | | you | |' > "$O/REGISTRY.md"
at() { date -v-"$1"d +%FT00:01:00 2>/dev/null || date -d "$1 days ago" +%FT00:01:00; }
printf '{"loop":"ran","date":"%s","check":"pass"}\n{"loop":"missed","date":"%s","check":"pass"}\n' "$(at 4)" "$(at 5)" > "$O/runs.jsonl"
expect "a job that ran at its latest fire isn't silent before its next, however uneven its week" "build && [ \"\$(get ran .status)\" = healthy ] && [ \"\$(get missed .status)\" = silent ]"
expect "cadence reads the weekdays" "[ \"\$(get ran .cadence)\" = '2× weekly' ]"

mk statuses; reg "$(row run)" "$(row can)" "$(row tmo)" "$(row gone)" "$(row late)" > "$O/REGISTRY.md"
cloud "$(for r in run:running can:cancelled tmo:timed_out; do routine "\"${r%%:*}\"" true null "\"${r#*:}\"" "\"$(day 1)\""; printf ,; done)$(routine '"late"' true "\"$(day 2)\"")"
expect "a running routine isn't failing; cancelled and timed out are" "build && [ \"\$(get run .status)\" != failing ] && [ \"\$(get can .status)\$(get tmo .status)\" = failingfailing ]"
expect "a routine claude.ai doesn't list is missing" "[ \"\$(get gone '\"\(.status) \(.next_due)\"')\" = 'missing null' ]"
expect "a next run claude.ai still had due in the past is silent" "[ \"\$(get late .status)\" = silent ]"

mk none
expect "--check fails with no registry to check" "! build --check && grep -q 'no Registry rows' $O/said"

G=$AGENT_OPS_DIR/memo; git init -q --bare "$G.git" && git clone -q "$G.git" "$G" 2>/dev/null && mkdir "$G/docs"
printf '## Founder decisions\n\n- Price the shop By 2026-12-01\n\n**Decision:**\n\n## Next\n' > "$G/docs/BETS.md"
git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm m && git -C "$G" push -q origin HEAD 2>/dev/null && git -C "$G" remote set-head origin -a >/dev/null
expect "a blank Decision line leaves the memo's decisions open" "[ \"\$(python3 -c \"import sys; sys.path.insert(0, 'fleet'); from fleet import memo_items; print(len(memo_items('o', 'r', '$G', {})))\")\" = 1 ]"
mkdir "$G/bets" && printf '## Founder decisions\n\n- Bet 1: approve? By 2026-11-24\n' > "$G/bets/shop.md"
git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm b && git -C "$G" push -q origin HEAD 2>/dev/null
expect "a memo in bets/ is read too" "python3 -c \"import sys; sys.path.insert(0, 'fleet'); from fleet import memo_items; print([i['where'] for i in memo_items('o', 'r', '$G', {})])\" | grep -q 'r/bets/shop.md'"

mk sync; build; python3 - "$O/fleet" <<'P'
import datetime as dt, hashlib, json, os, sys
d = sys.argv[1]; t = int(dt.datetime.now().timestamp())
for f in ("loops.json", "waiting.json", "changes.json", "questions.json", "talk.json"): os.utime(f"{d}/{f}", (t + .5, t + .5))
json.dump({"at": dt.datetime.fromtimestamp(t).isoformat(), "blobs": {"loops": 1, "waiting": 1, "changes": 1, "questions": 1, "talk": 1},
           "page": hashlib.sha256(open("fleet/dashboard/index.html", "rb").read()).hexdigest()}, open(f"{d}/receipt.json", "w"))
json.dump({"at": dt.datetime.fromtimestamp(t).astimezone().isoformat(), "routines": [], "tasks": []}, open(f"{d}/cloud.json", "w"))
P
sync() { AGENT_OPS_DIR=$O FLEET_CONFIG=$O/fleet.json python3 fleet/sync_check.py > "$O/said" 2>&1; }
expect "a receipt from the second the data was written passes" "sync"
jq '.kit_pull = "fatal: Not possible to fast-forward"' "$O/fleet/receipt.json" > "$O/r" && cp "$O/fleet/receipt.json" "$O/r0" && mv "$O/r" "$O/fleet/receipt.json"
expect "a failed kit pull in the receipt fails the check" "! sync && grep -q \"kit didn't update: fatal\" $O/said"
mv "$O/r0" "$O/fleet/receipt.json"
jq -c '.rows = [{"loop": "a", "schedule": ["0 6 * * *"]}]' "$O/fleet/loops.json" > "$O/l" && mv "$O/l" "$O/fleet/loops.json" && touch -t "$(date -v-1M +%Y%m%d%H%M 2>/dev/null || date -d '1 minute ago' +%Y%m%d%H%M)" "$O/fleet/loops.json"
expect "the sync check fails on a cell that isn't a scalar" "! sync && grep -q \"isn't a scalar\" $O/said"

# Talk: what loops tell each other, read from their Orders, their latest report, message logs and a file's commits.
mk talk; d1=$(day 1 | cut -c1-10)
reg "| boss | P | cloud | routine:boss | daily | | | you | |" "| shop | P | cloud | routine:shop | daily | \`LOOP.md\` | | boss | boss |" \
    "| shop2 | P | cloud | routine:shop2 | daily | \`LOOP.md\` | | boss | boss |" > "$O/REGISTRY.md"
mkdir -p "$O/orders" "$O/reports" "$O/q"
printf '# Shop\n\nOrders: `orders/shop.md`.\n\n## Report\n\n`reports/YYYY-MM-DD.md`\n' > "$O/LOOP.md"
printf '| Order | Moves | Read date |\n|---|---|---|\n| **Raise the cap** to 5 ([CAP.md](CAP.md)) | sales | 2026-12-01 |\n\n## Changes\n\ndate | why | by\n%s | Cap raised after the read | strategy\n%s | Too old to show | strategy\n' "$d1" "$(day 30 | cut -c1-10)" > "$O/orders/shop.md"
printf '## 1. TLDR\n- fine\n\n## 6. Escalations\n1. **Price** needs the founder\n\n## Orders requests\n- Raise the cap to 8\n' > "$O/reports/$d1.md"
{ printf '{"date":"%s","subject":"Three things for you","loop":"shop"}\nnot json\n{"date":"%s","subject":"old"}\n{"date":"%s","subject":["x"]}\n{"date":"%s","subject":"Cap hit","from":"routine:shop2"}\n' "$(day 1)" "$(day 30)" "$(day 1)" "$(day 1)"; } > "$O/sent.jsonl"
git -C "$O/q" init -q && echo line > "$O/q/QUEUE.md" && git -C "$O/q" add -A && git -C "$O/q" -c user.name=t -c user.email=t@t commit -qm "queue: price line"
jq --arg s "$O/sent.jsonl" --arg q "$O/q/QUEUE.md" '.talk = {"logs": [{"path": $s, "to": "you"}], "history": [{"path": $q, "to": "queue", "kind": "queue"}]}' "$O/fleet.json" > "$O/f" && mv "$O/f" "$O/fleet.json"
build; T=$O/fleet/talk.json; t() { jq -e "$1" "$T" >/dev/null; }
expect "talk: a standing order, from the supervisor, once for the loops sharing it, with its read date" "t '[.rows[] | select(.kind == \"order\")] | length == 1 and .[0].from == \"boss\" and .[0].to == \"shop, shop2\" and .[0].read_date == \"2026-12-01\" and .[0].text == \"Raise the cap to 5 (CAP.md)\" and .[0].at == null'"
expect "talk: an Orders change in the window, by its writer; an older one left out" "t '[.rows[] | select(.kind == \"change\")] | length == 1 and .[0].from == \"strategy\" and .[0].at == \"$d1\"'"
expect "talk: the latest report's escalations go up, its Orders requests to the supervisor" "t '[.rows[] | select(.from == \"shop\")] | (map(select(.kind == \"escalation\" and .text == \"Price needs the founder\" and .to != null)) | length == 1) and (map(select(.kind == \"request\" and .to == \"boss\")) | length == 1) and (map(select(.kind == \"report\" and .to == \"boss\")) | length == 1)'"
expect "talk: a logged message keeps its sender, a job label shown as its loop; junk, old and list subjects are left out" "t '[.rows[] | select(.kind == \"message\")] | length == 2 and any(.[]; .from == \"shop\" and .to == \"you\" and .loop == \"shop\") and any(.[]; .from == \"shop2\" and .text == \"Cap hit\")'"
expect "talk: a file's commits are news, from no one it can name" "t '[.rows[] | select(.kind == \"queue\")] | length == 1 and .[0].text == \"queue: price line\" and .[0].from == null'"
expect "talk: newest first, standing orders last, every cell a scalar; a loop's lines in its project, the rest General" "t '(.rows | map(.at // \"\") | . == (sort | reverse)) and .rows[-1].at == null and all(.rows[][]; type != \"array\" and type != \"object\") and all(.rows[]; .scope == (if .kind == \"queue\" then \"General\" else \"P\" end))' && t '.meta[] | select(.label == \"Window\") | .value == \"14 days\"'"
expect "talk: the page carries it" "grep -q 'Raise the cap to 5' $O/fleet/dashboard.html"

# Schedules: the next two fires after 10:00 on Sunday 22 Nov 2026 (or the day given), as crontab reads them.
fires() { python3 -c "import sys, datetime as dt; sys.path.insert(0, 'fleet'); from fleet import cron_spec, fires, nth
g = lambda: fires(cron_spec('$1', $2), dt.datetime(2026, 11, ${3:-22}, 10), 1, 400); print(' '.join(str(nth(g(), i))[:16] for i in range(2)))"; }
expect "names: mon"                            "[ \"\$(fires '0 9 * * mon' False)\" = '2026-11-23 09:00 2026-11-30 09:00' ]"
expect "names: jan"                            "[ \"\$(fires '0 9 1 jan *' False)\" = '2027-01-01 09:00 None' ]"
expect "day or weekday, as cron does"          "[ \"\$(fires '0 9 1 * 1' False 29)\" = '2026-11-30 09:00 2026-12-01 09:00' ]"
expect "day and weekday for an override"       "[ \"\$(fires '0 8 1-7 * 1' True)\" = '2026-12-07 08:00 2027-01-04 08:00' ]"
cad() { python3 -c "import sys; sys.path.insert(0, 'fleet'); from fleet import cron_spec, cadence; print(' / '.join(cadence(cron_spec(e)) for e in sys.argv[1:]))" "$@"; }
expect "cadence names each schedule shape"     "[ \"\$(cad '*/5 * * * *' '* * * * *' '0 * * * *' '0 9,17 * * *' '0 9 * * 1-5' '0 9 1 * *' '0 9 1 1 *' '0 9 * 12 *' '0 9 15 * 1' '0,10,50 * * * *' '0 0,3,6 * * 1-5' '0 9 1 */3 *')\" = 'every 5 min / every minute / hourly / 2× daily / 5× weekly / monthly / yearly / daily in Dec / weekly and monthly / 72× daily / 15× weekly / 4× yearly' ]"
expect "cadence counts a repeated time once"   "[ \"\$(python3 -c \"import sys; sys.path.insert(0, 'fleet'); from fleet import cron_spec, cadence; print(cadence(cron_spec('0 9 * * 1') * 2))\")\" = weekly ]"
expect "a star minute is every minute"         "[ \"\$(fires '* * * * *' False)\" = '2026-11-22 10:01 2026-11-22 10:02' ]"
expect "weekday ranges wrap"                   "[ \"\$(fires '30 6 * * sat-sun' False)\" = '2026-11-28 06:30 2026-11-29 06:30' ]"

# No registry: every job found shows its own health, from launchd, cron's output files and the cloud snapshot.
P=$(tests/health-demo.sh "$H") && L=$H/fleet/loops.json
expect "health: builds with no registry"       "[ -f $P ] && jq -e '.meta[] | select(.label == \"Mode\") | .value == \"health\"' $L >/dev/null"
expect "health: exit 0 with a fresh log ran"   "[ \"\$(status com.example.morning-digest)\" = ran ]"
expect "health: an interval job ran"           "[ \"\$(status com.example.inbox-triage)\" = ran ]"
expect "health: a non-zero exit is failing"    "[ \"\$(status com.example.price-watch)\" = failing ] && [ \"\$(jq -r '.rows[] | select(.loop == \"com.example.price-watch\") | .detail' $L)\" = 'last run exited 1' ]"
expect "health: an old log makes the last run unknown, not silent" "jq -e '.rows[] | select(.loop == \"com.example.weekly-review\") | .status == \"no record\" and .last_run == null and (.detail | test(\"unknown\"))' $L >/dev/null"
expect "health: a routine past its period is silent" "[ \"\$(status competitor-digest)\" = silent ]"
expect "health: a job launchd keeps running is a service" "jq -e '.rows[] | select(.loop == \"com.example.notes-sync\") | .project == \"Service\" and .status == \"service\"' $L >/dev/null"
expect "health: a job run only at login is a service that says so" "jq -e '.rows[] | select(.loop == \"com.example.login-mount\") | .project == \"Service\" and .schedule == \"runs once at login\"' $L >/dev/null"
expect "health: a dated job is a one-off"      "[ \"\$(status com.example.launch-reminder)\" = one-off ]"
expect "health: unloaded and vendor jobs stay out" "! jq -e '.rows[] | select(.loop | test(\"old-experiment|vendor\"))' $L >/dev/null"
expect "health: cron with an output file ran"  "[ \"\$(status cron:backup.sh)\" = ran ]"
expect "health: an output file under a variable the crontab doesn't set has no record" "jq -e '.rows[] | select(.loop == \"cron:photo-sync.sh\") | .status == \"no record\" and (.detail | test(\"PHOTO_LOGS\"))' \$L >/dev/null"
expect "health: a claude -p line is named after its output file, relative to its cd" "[ \"\$(status cron:notes-digest)\" = ran ]"
expect "health: a claude-run line is named after its OPS_LOOP" "[ \"\$(status cron:inbox-zero)\" = 'no record' ]"
expect "health: cron with no output file has no record" "[ \"\$(status cron:feed-poller.py)\" = 'no record' ]"
expect "health: cron names skip shells, @reboot is skipped" "[ \"\$(status cron:never-ran.sh)\" = 'no runs yet' ] && ! jq -e '.rows[] | select(.loop | test(\"on-boot|bash|cd\$\"))' $L >/dev/null"
expect "health: routines show their last status" "[ \"\$(status repo-dependency-check)\" = ran ] && [ \"\$(status release-notes-draft)\" = failing ] && [ -z \"\$(status paused-idea)\" ]"
expect "health: nothing unregistered, no cost or pass rate" "jq -e '[.rows[] | select(.status == \"unregistered\" or .cost != null or .pass_rate != null)] == []' $L >/dev/null"
expect "health: no registry path in the data"  "jq -e '.meta[] | select(.label == \"Registry\") | .value == null' $L >/dev/null"
expect "health: a job named after a ledger loop is that loop" "python3 -c \"import sys; sys.path.insert(0, 'fleet'); from fleet import discovered
j = {k: {'loaded': True, 'vendor': False, 'oneoff': False, 'daemon': False, 'schedule': ''} for k in ('com.me.digest', 'cron:digest.sh')}
l, _ = discovered(j, {}, {}, {'digest': {'last': '2099'}}, '2000'); assert [r['Loop'] for r in l] == ['digest', 'cron:digest.sh'], l\""
expect "health: an exit code with no log time is no record" "[ \"\$(status com.example.cache-warm)\" = 'no record' ]"
expect "health: sh -c, cd and timeout are skipped; &> is an output file" "[ \"\$(status cron:nightly-export.sh)\" = ran ]"
cat > "$H/cron-cases.py" <<'PY'
import sys; from pathlib import Path; sys.path.insert(0, 'fleet'); from fleet import cron_name, cron_output
names = {'cd /a && ./run.sh >> l 2>&1': 'run.sh', 'PATH=/x timeout 60 python3 /o/job.py': 'job.py', 'backup.sh>>/tmp/l 2>&1': 'backup.sh',
         '/bin/sh -lc "cd /x; ./y.sh"': 'y.sh', 'nice -n 5 /x/z.sh > /tmp/out': 'z.sh', 'bash -lc "source ~/.profile; /a/h.sh"': 'h.sh',
         'test -x f && f': 'f', '[ -f x ] && y': 'y', '( cd /a && ./z.sh )': 'z.sh', 'timeout -s KILL 300 x': 'x', 'flock -n lock x': 'x',
         "sh -c 'echo hi; x'": 'x', 'rsync -a src dst': 'rsync', '. ~/.profile && /a/dot.sh': 'dot.sh',
         'flock -n /tmp/lock /a/m.sh': 'm.sh', 'env python3 /o/e.py --out x.txt': 'e.py', '/a/u.sh "unclosed': 'u.sh',
         'npm run build': 'build', 'cd /a && uv run python s.py': 's.py', 'npx tsx /a/job.ts': 'job.ts'}
outs = {'/a/q.sh >> "/t/sp ace/q.log" 2>&1': '/t/sp ace/q.log', 'bash -c "x > inner.log"': str(Path.home() / 'inner.log'),
        'x &> /t/r.log': '/t/r.log', 'x 2> /t/err.log': '/t/err.log', 'x 2>&1 >> /t/o.log': '/t/o.log', 'x 2>&1': 'None',
        'x 2>&1 | tee -a /t/tee.log': '/t/tee.log', 'x >& /t/both.log': '/t/both.log', 'x 3> /t/fd3.log': 'None',
        'x >> $NOPE/a.log': str(Path.home() / '$NOPE/a.log'), 'cd /a && ./x.sh >> log 2>&1': '/a/log',
        'x >> /t/p_$(date +%F).log': '/t/p_$', 'x >> /t/`date`.log': '/t/$.log', 'x >/dev/null 2>>/t/e.log': '/t/e.log',
        'x --days 3 > /t/d.log': '/t/d.log'}
bad = {k: cron_name(k) for k, v in names.items() if cron_name(k) != v} | {k: cron_output(k) for k, v in outs.items() if str(cron_output(k)) != v}
assert not bad, bad
assert str(cron_output('x >> ${L}/a.log', {'L': '/t'})) == '/t/a.log'
PY
expect "cron: names past shells, wrappers, builtins and redirects; output files quoted, relative or &>" "python3 $H/cron-cases.py"
cp -R "$H" "$H.reg" && printf '## Registry\n\n| Loop | Project | Runtime | Job | Schedule |\n|---|---|---|---|---|\n| weekly | Ops | mac | com.example.weekly-review | weekly |\n' > "$H.reg/REGISTRY.md"
sed -i.bak "s|$H|$H.reg|g" "$H.reg/fleet.json" "$H.reg/bin/"* && AGENT_OPS_DIR="$H.reg" PATH="$H.reg/bin:$PATH" python3 fleet/fleet.py >/dev/null
expect "with a registry, an old log still means silent" "jq -e '.rows[] | select(.loop == \"weekly\") | .status == \"silent\"' $H.reg/fleet/loops.json >/dev/null"
expect "health: the page is titled Loop health" "grep -q '<title>Loop health</title>' $H/fleet/dashboard.html"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
