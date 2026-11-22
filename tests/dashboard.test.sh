#!/usr/bin/env bash
# Checks the dashboard page itself in headless Chromium at phone width: the Factory tab stays fast on dense check graphs,
# and rows the builder may let through (a name that isn't a string, a loop named you or nobody, a due that isn't a date,
# a right-to-left project) still draw every tab.
# Usage: tests/dashboard.test.sh   Needs bash, python3, node and Playwright (PLAYWRIGHT=<path to its index.mjs> if node
# can't find it); without Playwright it builds the fixtures, prints their paths and skips. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_OPS_DIR"' EXIT
fail=0
expect() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\"}" > "$AGENT_OPS_DIR/fleet.json"
# fixture <name> < rows (loop|project|checked by): builds the dashboard from a registry of those rows, saved as <name>.html
fixture() {
  { printf '## Registry\n\n| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by |\n|---|---|---|---|---|---|---|---|\n'
    while IFS='|' read -r l p c; do echo "| $l | $p | cloud | routine:$l | daily | | | $c |"; done; } > "$AGENT_OPS_DIR/REGISTRY.md"
  python3 fleet/fleet.py >/dev/null && cp "$AGENT_OPS_DIR/fleet/dashboard.html" "$AGENT_OPS_DIR/$1.html"
}
# 12 loops that each check the other 11, and 40 loops that each check the two after: n! and 2^n paths through the graph.
# One loop in a second project, so the page has a scope to pick.
{ for i in $(seq 0 11); do echo "n$i|Shop|$(seq 0 11 | grep -vx "$i" | sed 's/^/n/' | paste -sd, - | sed 's/,/, /g')"; done; echo "solo|Blog|you"; } | fixture clique
{ for i in $(seq 0 39); do echo "l$i|Shop|$( [ $i -lt 38 ] && echo "l$((i + 1)), l$((i + 2))" || echo you)"; done; echo "solo|Blog|you"; } | fixture ladder
# rows straight into the page, past whatever the builder checks: a project pulled into Shop's scope by its checker, then
# names that aren't strings, loops named you and nobody, right-to-left and combining-mark projects, and dues that aren't dates
printf 'shop1|Shop|ops-a\nops-a|Ops|you\n' | fixture odd
python3 - "$AGENT_OPS_DIR" <<'EOF'
import json, sys; sys.path.insert(0, "fleet"); from fleet import html, C
loops, waiting = (json.loads((C["out"] / f"{n}.json").read_text()) for n in ("loops", "waiting"))
row = next(r for r in loops["rows"] if r["loop"] == "ops-a")
loops["rows"] += [{**row, "loop": n, "project": p, "scope": p, "checked_by": c} for n, p, c in
                  ((5, "Shop", "you"), (None, "Shop", "you"), ("you", "Shop", "ops-a"), ("nobody", "Shop", "you"), ("lonely", "Shop", ""),
                   ("لولאת-חנות-loop", "לולאת-חנות", "you"), ("zalgo-loop", "Zalgo-Z̷̢͓̈́a̸̧̛l̶g̷o̶", "you"))]
item = {"title": "Pick a price", "tag": "Decision", "source": "Queue", "kind": "Queue", "item": "Pick a price", "action": "decide",
        "where": "queue (decision)", "link": None, "since": None, "project": "", "scope": "General"}
waiting["rows"] = [{**item, "title": f"due {d}", "due": d} for d in ("tomorrow", "2026-13-45", "99999-01-01", "", None, "2026-11-01", "2099-01-01")]
html(loops["rows"], waiting["rows"], loops["meta"], "Loop fleet")
EOF
cp "$AGENT_OPS_DIR/fleet/dashboard.html" "$AGENT_OPS_DIR/odd.html"

# check <name> [scope]: the page's JSON line, killed after 30 s so a frozen tab fails rather than hangs
check() { perl -e 'alarm 30; exec @ARGV' node tests/dashboard.check.mjs "$AGENT_OPS_DIR/$1.html" "${2:-}" > "$AGENT_OPS_DIR/$1.json"; }
check clique Shop; [ $? -eq 2 ] && { echo "skip  no Playwright: fixtures were $AGENT_OPS_DIR/{clique,ladder,odd}.html"; trap - EXIT; exit 0; }
check ladder Shop; check odd Shop
q() { jq -e "$2" "$AGENT_OPS_DIR/$1.json" >/dev/null 2>&1; }
for f in clique ladder; do
  expect "$f: the Factory tab draws, scopes and shows its lines in under 3 s" "q $f '.ms.factory + .ms.checks + .ms.scope < 3000 and .factory.lines > 0'"
  expect "$f: no page errors" "q $f '.errors == []'"
done
expect "odd rows: no page errors on any tab"         "q odd '.errors == []'"
expect "odd rows: the Loops tab draws its cards"     "q odd '.loops.cards >= 3'"
expect "a loop named you or nobody leaves one You and one Nobody" "q odd '.factory.you == 1 and .factory.nobody == 1'"
expect "the scoped count counts the loops it draws"  "q odd '.factory as \$f | \$f.count | startswith(\"\(\$f.loops) loops\")'"
expect "a right-to-left name keeps its count after it" "q odd '.loops.countsAfterNames'"
expect "every waiting item is listed, dated or not"  "q odd '.waiting.badge == 7 and .waiting.rows == 7 and (.waiting.invalid | not)'"
expect "nothing is wider than the phone"             "q odd '.ms.overflow == 0'"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
