#!/usr/bin/env bash
# Checks the dashboard page itself in headless Chromium: the Factory graph stays fast on dense check graphs, the phone's
# route list shows its first rows and a See all, a big fleet's Factory asks for a project, one drawer serves every loop, and rows the
# builder may let through (a name that isn't a string, a loop named you or nobody, a due that isn't a date, a right-to-left
# or very long project) still draw both tabs.
# Usage: tests/dashboard.test.sh   Needs bash, python3, node and Playwright (PLAYWRIGHT=<path to its index.mjs> if node
# can't find it). Without Playwright it fails, unless DASHBOARD_TEST=skip. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_DIR=$(mktemp -d)
export AGENT_OPS_KIT="$PWD/tests/kit"  # the test copy of the kit's question spec, never the real kit
trap '[ -n "${KEEP:-}" ] || rm -rf "$AGENT_OPS_DIR"' EXIT
fail=0
expect() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
echo "{\"launch_agents\": \"$AGENT_OPS_DIR/none\"}" > "$AGENT_OPS_DIR/fleet.json"
# fixture <name> < rows (loop|project|read by): builds the dashboard from a registry of those rows, saved as <name>.html
fixture() {
  { printf '## Registry\n\n| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Read by |\n|---|---|---|---|---|---|---|---|\n'
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
loops["rows"] += [{**row, "loop": n, "project": p, "scope": p, "read_by": c} for n, p, c in
                  ((5, "Shop", "you"), (None, "Shop", "you"), ("you", "Shop", "ops-a"), ("nobody", "Shop", "you"), ("lonely", "Shop", ""),
                   ("لولאת-חנות-loop", "לולאת-חנות", "you"), ("zalgo-loop", "Zalgo-Z̷̢͓̈́a̸̧̛l̶g̷o̶", "you"), ("long-loop", "P" * 255, "you"))]
loops["rows"].append({**row, "loop": "stray", "project": "Unregistered", "scope": "Unregistered", "status": "unregistered", "detail": None, "read_by": None})
item = {"title": "Pick a price", "tag": "Decision", "source": "Queue", "kind": "Queue", "item": "Pick a price", "action": "decide",
        "where": "queue (decision)", "link": None, "since": None, "project": "", "scope": "General"}
waiting["rows"] = [{**item, "title": f"due {d}", "due": d} for d in ("tomorrow", "2026-13-45", "99999-01-01", "", None, "2026-11-01", "2099-01-01")]
scope = {r["loop"]: r["scope"] for r in loops["rows"]}
change = lambda i, loop, **k: {"id": f"c{i}", "date": f"2026-11-0{i}", "loop": loop, "scope": scope[loop], "pr": f"https://github.com/o/r/pull/{i}",
                               "change": f"Change {i} to {loop}", "trace": "https://example.com/run/1\nruns.jsonl:12", "hypothesis": "the fetch times out",
                               "metric": "pass rate", "better": "higher", "runs": 7, "read_date": "2099-01-01",
                               "outcome": "pending", "moved": None, "result": None, "revert_pr": None, **k}
changes = [change(6, "shop1", outcome="closed"), change(5, "shop1", outcome="closed"), change(4, "ops-a", outcome="kept", moved=False), change(3, "shop1"), change(2, "shop1", outcome="reverted", revert_pr="https://github.com/o/r/pull/9"),
           change(1, "shop1", outcome="kept", moved=True, result="pass rate 90%")]
kpi = {"shop1": {"improver": True, "floor": "at least 62%", "kpi": "below", "kpi_value": 50, "kpi_of": 2, "kpi_attempts": 1, "kpi_since": "2026-11-15", "kpi_escalated": False, "kpi_as_of": "2026-11-21"},
       "ops-a": {"floor": "at most 3", "kpi": "met", "kpi_value": 2}, "lonely": {"kpi": "measured", "kpi_value": 5, "kpi_better": "higher", "kpi_as_of": "2026-11-22", "kpi_since": 7}}
for r in loops["rows"]: r.update(kpi.get(r["loop"], {}))
said = lambda **k: {"at": None, "kind": "order", "from": None, "to": None, "loop": None, "text": "Hold the price", "read_date": None,
                    "link": "https://github.com/o/r/blob/main/orders.md", "scope": "Shop", **k}
talk = [said(at="2026-11-25T08:11", kind="message", to="you", text="Three things for you today", scope="General"),
        said(at="2026-11-25", kind="escalation", **{"from": "shop1"}, to="ops-a", loop="shop1", text="Price needs the founder " * 12),
        said(at="2026-11-24", kind="change", **{"from": "strategy"}, to="shop1", loop="shop1", text="Price held after the read"),
        said(kind="order", **{"from": "you"}, to="shop1", loop="shop1", read_date="2026-12-01")]
html(loops["rows"], waiting["rows"], loops["meta"], "Loop fleet", changes, heard=(talk, loops["meta"][:1]))
EOF
cp "$AGENT_OPS_DIR/fleet/dashboard.html" "$AGENT_OPS_DIR/odd.html"
# a fleet of 70: Shop has 30 loops, 22 of them failing, and Blog 40 healthy ones
python3 - <<'EOF'
import json, sys; sys.path.insert(0, "fleet"); from fleet import html, C
loops = json.loads((C["out"] / "loops.json").read_text())
row = next(r for r in loops["rows"] if r["loop"] == "ops-a")
rows = [{**row, "loop": f"{p.lower()}{i:02d}", "project": p, "scope": p, "read_by": "you", "status": "failing" if p == "Shop" and i < 22 else "healthy"}
        for p, n in (("Shop", 30), ("Blog", 40)) for i in range(n)]
html(rows, [], loops["meta"], "Loop fleet")
EOF
cp "$AGENT_OPS_DIR/fleet/dashboard.html" "$AGENT_OPS_DIR/big.html"

# check <name> [scope]: the page's JSON line, killed after 30 s so a frozen tab fails rather than hangs
check() { perl -e 'alarm 30; exec @ARGV' node tests/dashboard.check.mjs "$AGENT_OPS_DIR/$1.html" "${2:-}" > "$AGENT_OPS_DIR/$1.json"; }
check clique Shop
if [ $? -eq 2 ]; then
  [ "${DASHBOARD_TEST:-}" = skip ] && { echo "skip  no Playwright, as DASHBOARD_TEST=skip asks"; exit 0; }
  echo "FAIL  no Playwright: install it, set PLAYWRIGHT to its index.mjs, or skip with DASHBOARD_TEST=skip"; exit 1
fi
check ladder Shop; check odd Shop; check big
q() { jq -e "$2" "$AGENT_OPS_DIR/$1.json" >/dev/null 2>&1; }
for f in clique ladder; do
  expect "$f: the Factory tab draws, scopes and shows its lines in under 3 s" "q $f '.ms.factory + .ms.checks + .ms.scope < 3000 and .factory.lines > 0'"
  expect "$f: no page errors" "q $f '.errors == []'"
done
expect "odd rows: no page errors on either tab"      "q odd '.errors == []'"
expect "odd rows: the phone lists loops by who reads them, no graph, no canvas" "q odd '.loops.sections >= 3 and .loops.rows > 0 and .loops.graph == 0 and (.loops.canvas | not)'"
expect "a desktop node opens its loop's drawer"     "q odd '.factory.drawer'"
for f in clique odd; do
  expect "$f: scrolling over the graph moves it, not the page; Ctrl-scroll zooms" "q $f '.canvas.wheel and .canvas.zoom != \"100%\"'"
  expect "$f: zoomed and redrawn, every line starts on its chip" "q $f '.canvas.onChips'"
  expect "$f: a drag moves the graph and opens nothing; Fit shows all of it" "q $f '.canvas.drag and .canvas.fit'"
  expect "$f: another tab and back keeps the view; a double click opens one drawer" "q $f '.canvas.tabKeeps and .canvas.once'"
  expect "$f: Expand fills the view with the whole graph, modal, a drawer opens over it, Escape twice comes back to the view before" "q $f '.canvas.big and .canvas.bigFits and .canvas.bigModal and .canvas.drawerOver and .canvas.back'"
done
expect "a loop named you or nobody leaves one You and one Nobody" "q odd '.factory.you == 1 and .factory.nobody == 1'"
expect "the scoped count counts the loops it draws"  "q odd '.factory as \$f | \$f.count | startswith(\"\(\$f.loops) loops\")'"
expect "a right-to-left name keeps its count after it" "q odd '.loops.countsAfterNames'"
expect "every waiting item is listed, dated or not"  "q odd '.waiting.badge == 7 and .waiting.rows == 7 and (.waiting.invalid | not)'"
expect "a loop's drawer lists its changes"              "q odd '.loops.changes == 5'"
expect "the Improver card lists the scope's changes and its hit rate, which a closed change doesn't count in" "q odd '.improver.rows == (if .improver.scope == \"Shop\" then 5 else 6 end) and (.improver.rate | startswith(\"1 of 2 moved their metric\")) and .improver.detail'"
expect "a fleet with no changes shows no Improver card" "q clique '.improver.rows == 0 and .improver.hidden'"
# the form asks the spec's questions in its order and builds the prompt the skill reads, checked against the spec file itself
want() { python3 - "$1" "$2" <<'P'
import json, sys
s, form = json.load(open("tests/kit/skills/new-loop/questions.json")), json.load(open(sys.argv[1]))["form"]
def lines(f, loop=None):
    out = [s["prompt"][f]]
    for q in s[f]:
        v = (q["choices"][0]["value"] if q["kind"] == "choice" else loop if q["id"] == "loop" and loop else ["x", "y"] if q.get("repeat")
             else "a b" if q["kind"] == "longtext" else q.get("default") if q["kind"] in ("number", "integer") else "v-" + q["id"])
        out += [f"{q['id']}: {x}" for x in (v if isinstance(v, list) else [v] if v is not None else [])]
    return "\n".join(out)
ok = {"fields": form["fields"] == [q["id"] for q in s["new"]] and form["editFields"] == [q["id"] for q in s["edit"]],
      "new": form["new"]["prompt"] == lines("new"), "edit": form["edit"]["prompt"] == lines("edit", form["loop"])}[sys.argv[2]]
sys.exit(0 if ok else 1)
P
}
expect "the form asks the spec's questions, in its order" "want $AGENT_OPS_DIR/clique.json fields"
expect "the form offers the skill command to copy, so Claude writes the whole loop" "q clique '.form.skill == \"/demo:new-loop\"'"
expect "the project is picked from the fleet's projects, or typed as a new one" "q clique '(.form.projects | first) == \"None\" and (.form.projects | last) == \"New project…\" and (.form.projects | index(\"Shop\")) != null'"
expect "an empty form asks for each required answer first" "q clique \".form.empty.prompt == null and .form.empty.missing == $(jq '[.new[] | select(.required)] | length' tests/kit/skills/new-loop/questions.json)\""
expect "New loop builds the skill's prompt, with a Copy button" "want $AGENT_OPS_DIR/clique.json new && q clique '.form.new.copy'"
expect "Change this loop builds the edit prompt for that loop, founder route marked" "want $AGENT_OPS_DIR/clique.json edit && q clique '.form.edit.founder == 1 and .form.loop != \"\"'"
expect "the open form and its prompt fit the phone" "q clique '.form.overflow == 0'"
expect "with no question spec there's no builder" "q odd '.form.offered == 0'"
expect "a loop's drawer says the improver may visit it" "q odd '.loops.read | test(\"The improver may change it\")'"
expect "a Good with no bar shows as measured, with which way is better" "q odd '.loops.measured == \"Good: 5 · higher is better · as of 22 Nov · no Floor set\"'"
expect "a loop's drawer shows its Good against its Floor and its attempts" "q odd '.loops.good == \"Good: 50 vs Floor at least 62% · below since 15 Nov · attempt 1 of 2 · as of 21 Nov\"'"
expect "Evaluations, in the picked project, shows the fleet KPIs and lists the loops below the bar" "q odd '.evals.rows[\"Loops at or above their Floor\"] == \"0% of measured (0 of 1)\" and .evals.rows[\"Loops whose Good is measured\"] == \"33% (2 of 6)\" and .evals.rows[\"Improver hit rate\"] == \"1 of 2 read changes moved their Good\" and .evals.below == 1'"
expect "with no data, every evaluation says not measured, none hidden" "q clique '.evals.rows[\"Loops at or above their Floor\"] == \"not measured\" and .evals.rows[\"Replay\"] == \"not measured\" and (.evals.rows[\"Improver hit rate\"] | startswith(\"not measured\")) and .evals.below == 0'"
expect "nothing is wider than the phone"             "q odd '.ms.overflow == 0'"
expect "Feeds: each dated line once, no unknown sender" "q odd '.talk.rows == 3 and (.talk.unknown | not)'"
expect "Feeds: a name opens the loop's drawer: its health, goal, who it works with, Orders now, then the Conversation, focus on Close, as wide as the phone" "q odd '.talk.sheet == \"shop1\" and .talk.sections == [\"Health\", \"Goal\", \"Works with\", \"Orders now\", \"Conversation\"] and .talk.bubbles > 0 and .talk.focus == \"Close\" and .talk.overflow <= 0 and .talk.inView'"
expect "Feeds: the drawer is modal: the page behind it is inert, Tab stays inside, a redraw keeps focus and scroll" "q odd '.talk.inert and .talk.trapped and .talk.redraw.focus and .talk.redraw.top > 0'"
expect "Feeds: Escape closes the drawer, frees the page and returns to the name clicked" "q odd '.talk.closed'"
expect "Feeds: a name deep in the feed opens the whole drawer in view, the page no wider" "q odd '.talk.deep.scrolled and .talk.deep.fits and .talk.deep.page <= 0'"
expect "Feeds: the composer turns a message into a prompt to copy" "q odd '.talk.compose != null'"
expect "every loop's drawer and row expansion draw, an unregistered one with no detail too" "q odd '.every == [] and .everyCount > 10'"
expect "Feeds: Escape hides a relation tip shown by keyboard focus or hover first, then closes the drawer, with no page error" "q odd '.talk.tip.shown and .talk.tip.hidden and .talk.tip.open and .talk.tip.hover and .talk.tip.hoverHidden and .talk.tip.hoverOpen and .errors == []'"
expect "Feeds: a fleet that said nothing says so" "q clique '.talk.rows == 0'"
expect "a long name keeps its loop count in view" "q odd '.loops.countsVisible'"
expect "a route shows 25 loops, then See all opens the rest in place" "q big '.loops.firstCard == 25 and .loops.firstCardAll == 30'"
expect "Needs you shows 20 to look at"              "q big '.attention == 20'"
expect "a loop opened from Needs you goes back to it" "q big '.back.loop != null and .back.title != .back.loop'"
expect "a big fleet's Factory on All projects offers its projects, most problems first, and draws the one picked" \
  "q big '.factory.loops == 0 and .factory.note and .factory.picks == [\"Shop · 22 with a problem\", \"Blog · 40 loops\"] and .factory.picked == 30 and .errors == []'"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
