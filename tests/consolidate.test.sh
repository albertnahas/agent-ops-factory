#!/usr/bin/env bash
# Checks consolidate/check.py: a move into a linked archive passes; a lost line, a changed mission block, an unlinked
# or missing archive fails. Usage: tests/consolidate.test.sh   Needs bash and python3. Writes only to a temp folder.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
expect() { if eval "$2" >/dev/null; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
check() { python3 consolidate/check.py "$@"; }
printf '# Ops\n\n<!-- mission -->\nKeep it up.\n<!-- /mission -->\n\n## Rules\n\n- Grade every PR.\n\n## History\n\n- 2026-09-01: the outage.\n- 2026-09-02: decided to grade every PR.\n' > "$T/before.md"
printf '# Ops\n\n<!-- mission -->\nKeep it up.\n<!-- /mission -->\n\n## Rules\n\n- Grade every PR.\n\nHistory: [OPS.archive.md](./OPS.archive.md)\n' > "$T/after.md"
printf '# Ops archive\n\n## Moved 2026-11-27 from "History"\n\n## History\n\n- 2026-09-01: the outage.\n- 2026-09-02: decided to grade every PR.\n' > "$T/OPS.archive.md"
expect "a move into a linked archive passes" "check $T/before.md $T/after.md $T/OPS.archive.md"
grep -v outage "$T/OPS.archive.md" > "$T/lossy.md"; cp "$T/after.md" "$T/after-lossy.md"; sed -i.bak 's/OPS.archive.md/lossy.md/g' "$T/after-lossy.md"
expect "a line in neither the file nor the archive fails, and says which" "{ check $T/before.md $T/after-lossy.md $T/lossy.md || true; } | grep -q 'the first: - 2026-09-01: the outage' && ! check $T/before.md $T/after-lossy.md $T/lossy.md"
sed 's/Keep it up./Keep it up, mostly./' "$T/after.md" > "$T/after-mission.md"; printf -- '- Keep it up.\n' >> "$T/after-mission.md"
expect "a changed mission block fails, even with its words kept" "! check $T/before.md $T/after-mission.md $T/OPS.archive.md"
grep -v archive "$T/after.md" > "$T/after-unlinked.md"
expect "an archive the file doesn't link fails" "! check $T/before.md $T/after-unlinked.md $T/OPS.archive.md"
expect "a missing archive fails" "! check $T/before.md $T/after.md $T/gone.md"
cp "$T/OPS.archive.md" "$T/old-archive.md"; printf '\n## Moved 2026-12-01 from "Rules"\n' >> "$T/OPS.archive.md"
expect "an archive that only grew passes against its old copy" "check $T/old-archive.md $T/OPS.archive.md"
expect "an archive that shrank fails against its old copy" "! check $T/OPS.archive.md $T/old-archive.md"
printf '# Ops\n\n- Grade every PR.\n- Grade every PR.\n  - nested rule\n' > "$T/dup.md"; printf '# Ops\n\n- Grade every PR.\n- nested rule\n[a](a.md)\n' > "$T/dup-after.md"; : > "$T/a.md"
expect "a dropped duplicate or a changed indent is a lost line" "{ check $T/dup.md $T/dup-after.md $T/a.md || true; } | grep -q '^2 lines are gone'"
expect "a missing or empty BEFORE proves nothing" "! check $T/gone.md $T/after.md && : > $T/empty.md && ! check $T/empty.md $T/after.md"
sed 's|(./OPS.archive.md)|OPS.archive.md is somewhere|' "$T/after.md" > "$T/after-named.md"
expect "naming the archive without linking it fails" "! check $T/before.md $T/after-named.md $T/OPS.archive.md"
sed 's|(./OPS.archive.md)|(https://example.com/OPS.archive.md)|' "$T/after.md" > "$T/after-away.md"
expect "a link to the archive's name on another site isn't a link to it" "! check $T/before.md $T/after-away.md $T/OPS.archive.md"
expect "the pass says how many lines moved" "check $T/before.md $T/after.md $T/OPS.archive.md | grep -q ', 3 moved out,'"
[ "$fail" -eq 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
