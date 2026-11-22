#!/usr/bin/env bash
# Checks the fleet builder: it runs with nothing set up, reads a registry and a ledger with junk lines in it, decides
# each status, and writes the data files and a dashboard that carries them.
# Usage: tests/fleet.test.sh   Needs bash, jq and python3. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_OPS_DIR"' EXIT
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

## Services

| Service | Job | What it is |
|---|---|---|
| Build | com.me.build | rebuilds the page |
EOF
{
  echo "{\"loop\":\"good\",\"date\":\"$(day 1)\",\"subtype\":\"success\",\"cost\":2}"
  echo "{\"loop\":\"good\",\"date\":\"$(day 1)\",\"check\":\"pass\",\"detail\":\"report landed\"}"
  echo "{\"loop\":\"broken\",\"date\":\"$(day 1)\",\"check\":\"fail\",\"detail\":\"report missing\"}"
  for v in fail fail fail pass; do echo "{\"loop\":\"flaky\",\"date\":\"$(day 1)\",\"check\":\"$v\"}"; done
  echo "{\"loop\":\"stray\",\"date\":\"$(day 1)\",\"subtype\":\"success\"}"
  printf 'not json\n{}\n'
} > "$AGENT_OPS_DIR/runs.jsonl"
echo "{\"at\":\"$(date +%FT%T%z | sed 's/\(..\)$/:\1/')\",\"routines\":[$(for r in good broken flaky fresh reader-job lonely watched; do printf '{"name":"%s","enabled":true,"cron":"0 6 * * *","next_run_at":null,"last_status":null,"last_finished_at":null},' $r; done | sed 's/,$//')],\"tasks\":[]}" > "$AGENT_OPS_DIR/fleet/cloud.json"

echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\", \"general\": [\"blog\"], \"waiting\": {\"queue\": {\"path\": \"$AGENT_OPS_DIR/QUEUE.md\", \"owner\": \"You\"}}}" > "$AGENT_OPS_DIR/fleet.json"
printf 'due | kind | item | owner | next action | done when | source\n---\n2026-12-01 | decision | Pick a price | You | decide | priced | agent\n' > "$AGENT_OPS_DIR/QUEUE.md"
scope() { jq -r --arg l "$1" '.rows[] | select(.loop == $l) | .scope' "$L"; }

expect "builds with a registry and a junky ledger" "python3 fleet/fleet.py >/dev/null"
expect "a passing check is healthy"            "[ \"\$(status good)\" = healthy ]"
expect "a failed check is failing"             "[ \"\$(status broken)\" = failing ]"
expect "3 of the last 7 failed is flaky"       "[ \"\$(status flaky)\" = chronic ]"
expect "never run is not run yet"              "[ \"\$(status fresh)\" = 'no runs yet' ]"
expect "a ledger name with no row is unregistered" "[ \"\$(status stray)\" = unregistered ]"
expect "checked by is a comma list"            "jq -e '.rows[] | select(.loop == \"broken\") | .checked_by == \"good, heartbeat\"' $L >/dev/null"
expect "every cell is a scalar, as on claude.ai" "jq -se 'all(.[].rows[][]; type != \"array\" and type != \"object\")' $L $AGENT_OPS_DIR/fleet/waiting.json >/dev/null"
expect "checked by resolves jobs and you, once each" "jq -e '.rows[] | select(.loop == \"reader\") | .checked_by == \"good, you, flaky, reader\"' $L >/dev/null"
expect "a service's job names the service"   "jq -e '.rows[] | select(.loop == \"watched\") | .checked_by == \"Build\"' $L >/dev/null"
sup() { jq -r --arg l "$1" '.rows[] | select(.loop == $l) | "\(.supervisor) | \(.supervisor_issue)"' "$L"; }
expect "a supervisor is a loop or you"         "[ \"\$(sup broken)\" = 'good | null' ] && [ \"\$(sup good)\" = 'you | null' ]"
expect "a supervisor's job names its loop"     "[ \"\$(sup reader | cut -d' ' -f1)\" = watched ]"
expect "no supervisor is fine"                 "[ \"\$(sup lonely)\" = 'null | null' ]"
expect "a missing supervisor is flagged"       "[ \"\$(sup fresh)\" = 'ghost | supervisor ghost is not a loop in the registry' ]"
expect "supervision cycles are flagged"        "sup flaky | grep -q 'comes back to it: flaky → flaky' && sup reader | grep -q 'reader → watched → reader' && sup watched | grep -q 'watched → reader → watched'"
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

| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by | Supervisor | Escalates to | Role |
|---|---|---|---|---|---|---|---|---|---|---|
| door | Shop | cloud | routine:door | daily | | | you | | | Master |
| boss | Shop | cloud | routine:boss | daily | | | you | | | manager |
| boss2 | Shop | cloud | routine:boss2 | daily | | | you | | | manager |
| worker | Shop | cloud | routine:worker | daily | | | boss | | | |
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
esc() { jq -r --arg l "$1" '.rows[] | select(.loop == $l) | "\(.escalates_to) \(.escalates_default) | \(.escalation_issue)"' "$L"; }
expect "a blank goes to the project's manager"  "[ \"\$(esc worker)\" = 'boss true | null' ]"
expect "a blank with no manager goes to the master" "[ \"\$(esc lone)\" = 'door true | null' ] && [ \"\$(esc boss | cut -d' ' -f1)\" = door ]"
expect "the master's blank is you, even beside a manager"    "[ \"\$(esc door)\" = 'you true | null' ]"
expect "only the master and break-glass reach you" "esc rogue | grep -q 'straight to you' && [ \"\$(esc pager)\" = 'you false | null' ]"
expect "a break-glass reason is on its row"      "jq -e '[.rows[] | select(.break_glass)] | map(\"\\(.loop)=\\(.break_glass)\") == [\"pager=production down\", \"stripe=money at risk, refunds\"]' $L >/dev/null"
expect "escalation cycles are flagged, by job too" "esc ping | grep -q 'comes back to it: ping → pong → ping'"
expect "a target that is no loop is flagged"     "esc astray | grep -q 'escalates to nowhere, which is not a loop'"
expect "one manager per project"                "esc boss | grep -q 'Shop has 2 managers' && esc boss2 | grep -q 'Shop has 2 managers'"
expect "a role is master or manager"            "esc odd | grep -q 'role chief'"
expect "every cell is still a scalar"           "jq -e 'all(.rows[][]; type != \"array\" and type != \"object\")' $L >/dev/null"
expect "the registry-only check names every escalation issue" "! python3 fleet/fleet.py --check > $AGENT_OPS_DIR/issues && diff <(jq -r '[.rows[] | select(.escalation_issue) | \"\\(.loop): \\(.escalation_issue)\"] + [\"phantom: break-glass names no loop or service in the registry\"] | join(\"; \")' $L) $AGENT_OPS_DIR/issues"

# Schedules: the next two fires after 10:00 on Sunday 22 Nov 2026 (or the day given), as crontab reads them.
fires() { python3 -c "import sys, datetime as dt; sys.path.insert(0, 'fleet'); from fleet import cron_spec, fires, nth
g = lambda: fires(cron_spec('$1', $2), dt.datetime(2026, 11, ${3:-22}, 10), 1, 400); print(' '.join(str(nth(g(), i))[:16] for i in range(2)))"; }
expect "names: mon"                            "[ \"\$(fires '0 9 * * mon' False)\" = '2026-11-23 09:00 2026-11-30 09:00' ]"
expect "names: jan"                            "[ \"\$(fires '0 9 1 jan *' False)\" = '2027-01-01 09:00 None' ]"
expect "day or weekday, as cron does"          "[ \"\$(fires '0 9 1 * 1' False 29)\" = '2026-11-30 09:00 2026-12-01 09:00' ]"
expect "day and weekday for an override"       "[ \"\$(fires '0 8 1-7 * 1' True)\" = '2026-12-07 08:00 2027-01-04 08:00' ]"
expect "a star minute is every minute"         "[ \"\$(fires '* * * * *' False)\" = '2026-11-22 10:01 2026-11-22 10:02' ]"
expect "weekday ranges wrap"                   "[ \"\$(fires '30 6 * * sat-sun' False)\" = '2026-11-28 06:30 2026-11-29 06:30' ]"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
