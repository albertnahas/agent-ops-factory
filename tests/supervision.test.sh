#!/usr/bin/env bash
# Checks fleet/supervision.py from a made-up registry, ledger and review reports. Nothing real is read.
# Usage: tests/supervision.test.sh   Needs bash and python3. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_DIR=$(mktemp -d) FLEET_CONFIG=/nonexistent
D=$AGENT_OPS_DIR
trap 'rm -rf "$D"' EXIT
fail=0
expect() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
cat > "$D/REGISTRY.md" <<'R'
## Registry

| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by | Supervisor |
|---|---|---|---|---|---|---|---|---|
| boss | Shop | cloud | routine:boss | daily | | | you | |
| posts | Shop | mac | com.t.posts | daily | | | boss | boss |
| ads | Shop | mac | com.t.ads | weekly | | | boss | boss |
| fixes | Shop | cloud | routine:fixes | on demand | | | boss | routine:boss |
| other | Shop | mac | com.t.other | daily | | | you | |
R
printf '%s\n' '{"loop":"posts","date":"2026-11-22T20:00:00","check":"pass"}' '{"loop":"posts","date":"2026-11-23T07:00:00","check":"pass"}' \
  '{"loop":"ads","date":"2026-11-18T09:00:00","check":"pass"}' 'not json' > "$D/runs.jsonl"
S() { python3 fleet/supervision.py boss "$D/$1" > "$D/said" 2>&1; }
cat > "$D/2026-11-23.md" <<'M'
5. **Actions taken**
   - **posts**: kept · read through 2026-11-22 · its E1 order reads on 12-12
   - `ads`: **changed** in #40 · read through 2026-11-18
   - fixes: Kept · read through 2026-11-16, no fix PRs this week
M
expect "every supervised loop, one named by its job and one in bold, passes" "S 2026-11-23.md && grep -q 'reviewed all 3: posts, ads, fixes' $D/said"
sed '/fixes/d' "$D/2026-11-23.md" > "$D/b-2026-11-23.md"
expect "a supervised loop with no line fails"        "! S b-2026-11-23.md && grep -q 'fixes: no' $D/said"
sed 's/read through 2026-11-22/read through 2026-11-20/' "$D/2026-11-23.md" > "$D/c-2026-11-23.md"
expect "reading through less than the loop's last run fails" "! S c-2026-11-23.md && grep -q 'posts: read through 2026-11-20, but it ran on 2026-11-22' $D/said"
expect "a run on the report's own day isn't owed"    "S 2026-11-23.md"
echo '4. **Supervision:** posts, ads and fixes Orders kept.' > "$D/d-2026-11-23.md"
expect "one sentence for every loop fails, naming each" "! S d-2026-11-23.md && [ \$(grep -c ': no ' $D/said) -eq 3 ]"
cp "$D/2026-11-23.md" "$D/report.md"
expect "a report with no date in its name fails"     "! S report.md && grep -q 'no YYYY-MM-DD' $D/said"
expect "a supervisor no row names fails"             "! python3 fleet/supervision.py nobody-here $D/2026-11-23.md > $D/said && grep -q 'no registry row names nobody-here' $D/said"
sed 's/read through 2026-11-18/read through 9999-99-99/' "$D/2026-11-23.md" > "$D/e-2026-11-23.md"
expect "a read-through that's no date fails"         "! S e-2026-11-23.md && grep -q 'ads: read through 9999-99-99, which is no date' $D/said"
sed 's/read through 2026-11-18/read through 2026-11-30/' "$D/2026-11-23.md" > "$D/f-2026-11-23.md"
expect "a read-through after the report's day fails" "! S f-2026-11-23.md && grep -q 'ads: read through 2026-11-30' $D/said"
{ cat "$D/2026-11-23.md"; echo '   - ads: retired · read through 2026-11-18'; } > "$D/g-2026-11-23.md"
expect "a loop on two lines fails"                   "! S g-2026-11-23.md && grep -q 'ads: named on more than one line' $D/said"
[ "$fail" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
