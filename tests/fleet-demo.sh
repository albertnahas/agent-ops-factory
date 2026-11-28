#!/usr/bin/env bash
# Builds the fleet dashboard from an invented fleet of 30 loops: every status, a checker chain three deep, two loops
# that check each other, a checker the registry doesn't have, two loops nobody checks and a supervision tree with one
# missing parent. For screenshots and proofs.
# Usage: tests/fleet-demo.sh [folder]   Prints the dashboard's path. Needs bash and python3.
set -euo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_DIR=${1:-$(mktemp -d)}
export AGENT_OPS_KIT="$PWD/tests/kit"  # the test copy of the kit's question spec, never the real kit
mkdir -p "$AGENT_OPS_DIR/fleet"
echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\", \"tasks\": \"$AGENT_OPS_DIR/none\", \"refresh\": \"Demo data\"}" > "$AGENT_OPS_DIR/fleet.json"
# Most loops are cloud routines; two are desktop-app tasks, and one is a launchd job, which shows as paused (not loaded here).
runtime() { case $1 in fleet-sync|life-review) echo app;; app-beta) echo mac;; *) echo cloud;; esac; }
job() { case $(runtime "$1") in app) echo "task:$1";; mac) echo "com.demo.$1";; *) echo "routine:$1";; esac; }
# Supervisors write their children's Orders: each daily ops loop runs its project, one row names a loop that doesn't
# exist, and the rest have none.
supervisor() { case $1 in *-daily-ops) ;; shop-*) echo shop-daily-ops;; blog-writer|blog-editor|blog-seo) echo blog-daily-ops;;
  blog-links) echo blog-chief;; app-crash-triage|app-reviews|app-store-watch|app-release-notes) echo app-daily-ops;; esac; }
role() { case $1 in chief) echo chief;; shop-daily-ops|app-daily-ops) echo manager;; esac; }
escalates() { case $1 in blog-links) echo you;; esac; }
day() { date -v-"$1"d +%FT0"$2":00:00 2>/dev/null || date -d "$1 days ago" +%FT0"$2":00:00; }
# Two charters, each naming its Orders and its dated report, so a loop's detail links to what defines it.
charter() { case $1 in shop-daily-ops) echo '`charters/SHOP_OPS.md`';; shop-social-*) echo '`charters/SHOP_SOCIAL.md`';; esac; }
mkdir -p "$AGENT_OPS_DIR/charters/orders" "$AGENT_OPS_DIR/charters/reports/ops" "$AGENT_OPS_DIR/charters/reports/social"
for c in OPS:ops SOCIAL:social; do
  printf '# Shop %s loop\n\nRead [orders/%s.md](./orders/%s.md) right after this file.\n\n## Report\n\n`reports/%s/YYYY-MM-DD.md`\n' \
    "${c#*:}" "${c#*:}" "${c#*:}" "${c#*:}" > "$AGENT_OPS_DIR/charters/SHOP_${c%:*}.md"
  printf '# Orders\n' > "$AGENT_OPS_DIR/charters/orders/${c#*:}.md"
  for d in 2 1 0; do printf '# Report\n' > "$AGENT_OPS_DIR/charters/reports/${c#*:}/$(day "$d" 6 | cut -c1-10).md"; done
done
# The ops charter keeps a Floor in its Mission and its Orders raise the bar, so one loop shows its Floor and Target and the rest "Good: not set".
printf '\n## Mission\n\n<!-- mission -->\nShoppers get their orders.\n\n- **Floor:** at least 30 orders a week\n- **Source:** the orders table\n<!-- /mission -->\n' >> "$AGENT_OPS_DIR/charters/SHOP_OPS.md"
printf '\nTarget: at least 40 orders a week\n' >> "$AGENT_OPS_DIR/charters/orders/ops.md"

loops=(
  # loop|project|read by|outcomes, oldest first (p pass, f fail, - none)|days since last run
  "shop-daily-ops|Shop|you|pppppppppp|0"
  "shop-support|Shop|shop-daily-ops, you|ppppppppp|0"
  "shop-support-fix|Shop|shop-daily-ops|ppfpp|1"
  "shop-e2e-smoke|Shop|heartbeat, shop-daily-ops|pppppppf|0"
  "shop-publish|Shop|heartbeat|pppppppppp|0"
  "shop-growth|Shop|shop-daily-ops, you|pppp|2"
  "shop-social-morning|Shop|you|ppfpfpfpp|0"
  "shop-social-evening|Shop|you|pppppp|0"
  "shop-reddit|Shop|you|ppppp|0"
  "shop-product|Shop|you|p|6"
  "blog-daily-ops|Blog|you|pppppp|0"
  "blog-writer|Blog|blog-editor|pppppp|0"
  "blog-editor|Blog|blog-daily-ops|pppppp|0"
  "blog-seo|Blog||pppp|0"
  "blog-links|Blog|you|pppppf|0"
  "app-daily-ops|Mobile app|you|ppppppp|0"
  "app-crash-triage|Mobile app|app-daily-ops|ppppp|0"
  "app-reviews|Mobile app|app-store-watch|ppppp|0"
  "app-store-watch|Mobile app|app-reviews|ppppp|0"
  "app-release-notes|Mobile app||-|0"
  "app-beta|Mobile app|you|ppp|5"
  "heartbeat|Ops|uptime-pager|pppppppppp|0"
  "chief|Ops|you|pppppppppp|0"
  "vault-sync|Ops|heartbeat|pppppppppp|0"
  "fleet-sync|Ops|you|ppppp|0"
  "news-radar|Personal|you|pppppp|0"
  "job-watch|Personal|you|ppppp|0"
  "events-radar|Personal|you|pppp|0"
  "reading-list||you|ppp|0"
  "life-review|Personal|you|-|0"
)
{
  printf '## Registry\n\n| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Read by | Supervisor | Escalates to | Role |\n|---|---|---|---|---|---|---|---|---|---|---|\n'
  for l in "${loops[@]}"; do IFS='|' read -r name project by _ _ <<< "$l"; echo "| $name | $project | $(runtime "$name") | $(job "$name") | daily | $(charter "$name") | | $by | $(supervisor "$name") | $(escalates "$name") | $(role "$name") |"; done
  printf '\n## Services\n\n| Service | Job | What it is |\n|---|---|---|\n| Fleet build | com.demo.fleet-build | rebuilds the dashboard |\n| payments-watch | com.demo.payments-watch | disputes and refunds |\n'
  printf '\n## Break-glass\n\n| Who | Why |\n|---|---|\n| shop-e2e-smoke | production down |\n| payments-watch | money at risk |\n'
} > "$AGENT_OPS_DIR/REGISTRY.md"
{
  for l in "${loops[@]}"; do
    IFS='|' read -r name _ _ hist ago <<< "$l"
    [ "$hist" = - ] && continue
    for ((i = 0; i < ${#hist}; i++)); do
      c=${hist:i:1}; d=$((ago + ${#hist} - 1 - i))
      echo "{\"loop\":\"$name\",\"date\":\"$(day "$d" 6)\",\"subtype\":\"success\",\"cost\":0.4$((i % 10)),\"secs\":$((240 + i * 37))}"
      echo "{\"loop\":\"$name\",\"date\":\"$(day "$d" 7)\",\"check\":\"$([ "$c" = p ] && echo pass || echo fail)\",\"detail\":\"$([ "$c" = p ] && echo 'report landed' || echo 'report missing')\"}"
    done
  done
  echo "{\"loop\":\"stray-script\",\"date\":\"$(day 1 6)\",\"subtype\":\"success\"}"
} > "$AGENT_OPS_DIR/runs.jsonl"
routines=$(for l in "${loops[@]}"; do IFS='|' read -r name _ _ _ _ <<< "$l"; [ "$(runtime "$name")" = cloud ] || continue
  printf '{"id":"trig_demo_%s","name":"%s","enabled":true,"cron":"0 6 * * *","next_run_at":null,"last_status":null,"last_finished_at":null},' "${name//-/_}" "$name"; done)
tasks=$(for l in "${loops[@]}"; do IFS='|' read -r name _ _ _ _ <<< "$l"; [ "$(runtime "$name")" = app ] || continue
  printf '{"id":"%s","enabled":true,"cron":"0 6 * * *","next_run_at":null,"last_finished_at":null},' "$name"; done)
echo "{\"at\":\"$(date +%FT%T%z | sed 's/\(..\)$/:\1/')\",\"routines\":[${routines%,}],\"tasks\":[${tasks%,}]}" > "$AGENT_OPS_DIR/fleet/cloud.json"
python3 fleet/fleet.py >/dev/null
echo "$AGENT_OPS_DIR/fleet/dashboard.html"
