#!/usr/bin/env bash
# Checks the replay eval on its synthetic fixture: it replays each day, catches both real incidents with the right
# cause, counts the check bug as a false alarm, and fails the build when detection drops.
# Usage: tests/replay.test.sh   Needs bash, jq and python3. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
export AGENT_OPS_KIT="$PWD/tests/kit"  # the test copy of the kit's question spec, never the real kit
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
expect() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
F=eval/fixture
run() { python3 eval/replay.py --registry $F/REGISTRY.md --ledger $F/runs.jsonl --jobs $F/jobs.json --from 2026-01-05 --to 2026-01-12 "$@"; }
run --labels $F/labels.jsonl --min-detection 1 --max-false 0.25 > $T/r.json
expect "replay passes its own bar on the fixture" "[ \$? = 0 ]"
expect "both real incidents are caught" "jq -e '.fleet.detected == 2 and .fleet.missed == []' $T/r.json >/dev/null"
expect "the check bug counts as one false alarm" "jq -e '.fleet.false == 1 and .fleet.unlabelled == 0' $T/r.json >/dev/null"
expect "a failure shows by the next 09:30, a silent loop the morning after its missed run" "jq -e '.fleet.median_hours == 11.5' $T/r.json >/dev/null"
sed 's/"match": "silent"/"match": "a cause the builder never names"/' $F/labels.jsonl > $T/labels.jsonl
expect "a flag with the wrong cause isn't a catch, and the build fails" "! run --labels $T/labels.jsonl --min-detection 1 > $T/r2.json 2>/dev/null && jq -e '.fleet.detected == 1' $T/r2.json >/dev/null"
expect "the replay never reads a run from after its time" "FLEET_NOW=2026-01-07T09:30 python3 -c 'import os,json,subprocess,sys,tempfile,pathlib;d=tempfile.mkdtemp();pathlib.Path(d,\"f.json\").write_text(json.dumps({\"registry\":\"$F/REGISTRY.md\",\"ledger\":\"$F/runs.jsonl\",\"jobs\":\"$F/jobs.json\",\"checks\":d+\"/n\",\"out\":d+\"/o\",\"launch_agents\":d+\"/n\",\"tasks\":d+\"/n\",\"waiting\":{}}));subprocess.run([sys.executable,\"fleet/fleet.py\"],env={**os.environ,\"FLEET_CONFIG\":d+\"/f.json\"},check=True,capture_output=True);rows=json.loads(pathlib.Path(d,\"o/loops.json\").read_text())[\"rows\"];sys.exit(0 if [r[\"last_run\"] for r in rows if r[\"loop\"]==\"digest\"]==[\"2026-01-07T08:00\"] else 1)'"
exit $fail
