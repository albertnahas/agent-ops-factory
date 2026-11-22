# Fleet dashboard

One page for every scheduled loop you run, across all your projects: whether each one is healthy, when it runs next, what it cost, who checks its output, and everything waiting on you. `fleet.py` builds it with no model, so it's free to rebuild as often as you like.

```bash
python3 fleet/fleet.py && open ~/.agent-ops/fleet/dashboard.html
```

It works with nothing set up. With no registry it lists every job it finds with that job's own health and titles the page Loop health: what launchd, cron's output files and the cloud snapshot say, and no Factory or Waiting tab, cost or pass rate. That's the `loop-health` plugin. It gets more useful once your loops have a registry (`REGISTRY.example.md`) and log through agent-ops-kit's `bin/claude-run` and `bin/ops-check`. The `fleet` skill sets all of this up for you and never changes a job you already run.

## What it reads

| Source | Gives | Needed |
|---|---|---|
| `REGISTRY.md` | the loops, their project, schedule, charter, check and who checks their output; the services | no: without it every job shows its own health; with it, a job with no row shows as Unregistered |
| launchd (`~/Library/LaunchAgents`) and your crontab | what is actually scheduled, last exit, next run; for cron, the time the file a line writes its output to last changed (cron keeps no exit codes) | found on its own |
| `runs.jsonl` | last run, pass rate, cost, the last 10 outcomes | once loops run through `claude-run` and `ops-check` |
| `checks/<loop>.py` | an outcome for loops that write no ledger line, like cloud routines | per loop |
| `fleet/cloud.json` | Claude Code cloud routines and desktop-app tasks: schedule, next and last run | only with the claude.ai sync (`SYNC.md`) |
| `improvements.jsonl` | the improver's history: each change it made to a loop, what it read, the metric it should move and whether it did | once an improver runs |
| GitHub, a queue file, decision memos | what waits on you: PRs with your label, owner-you queue lines, open decisions in your repos' `docs/` | optional, `waiting` in `fleet.json` |

Without a ledger, a launchd loop's last exit and the time its log file last changed stand in for its last run, so a fleet you haven't instrumented still shows what failed.

## Statuses

- **Failing:** the last outcome check failed (or, with no check, the last run exited non-zero).
- **Silent:** no run for one scheduled period plus 12 hours, or for a launchd interval job three intervals and at least an hour; or a cloud routine whose next run claude.ai still had due an hour before the snapshot. With no registry, a log file that stopped changing isn't enough, since many scripts log somewhere else. Such a job shows as No run record and its detail gives the log's date. With a registry it still counts, so a registered loop that stops still alerts.
- **Flaky:** the last check passed but 3 of the last 7 failed.
- **Unregistered:** running, with no registry row.
- **Stale data:** the cloud snapshot is over 36 hours old.
- **Missing:** a registered routine or task the claude.ai snapshot doesn't list, so it was deleted or renamed there.
- A routine whose last run was cancelled or timed out is Failing; one still running isn't.
- **Unchecked:** runs, with nothing the builder can read that proves the outcome.
- **Not run yet**, **Paused** (registered, not loaded or enabled, or its charter says `status: paused`), **Healthy**.
- A launchd job with a Month and Day runs every year on that date, so it reads yearly; a one-off job removes itself after it runs.
- **No run record:** nothing says when it last ran: a crontab line that sends its output nowhere, or, with no registry, a job whose log is missing or too old to trust.
- **Ran** (no registry only): the last run exited 0, or for cron, its output file changed on schedule. Nothing proves it did its job.

## Factory

The Factory tab draws who checks what: every loop on the left, the loops and scripts that read other loops' output in the middle, and you on the right. A loop's **Checked by** cell draws its lines. A name there is a loop's or service's name or its job (with or without `routine:` or `task:`), or `you`; any other name shows as a checker that isn't in the registry. Loops with no checker run into **Nobody**, the gap to close. Tap or point at a loop to trace its chain both ways. The optional **Supervisor** column adds dotted lines from each supervisor to the loops whose Orders it writes; a supervisor that isn't a loop, or a cycle, gets a dotted outline and says why when tapped. `fleet/fleet.py --check` reads only the registry and fails on any of these, so the claude.ai sync's outcome check (`SYNC.md` step 6) fails with them and the kit's heartbeat alerts you. **Escalates to** adds thick amber lines: where each loop sends what needs a person. Loops of one project that follow the default share one line from their frame, so an override stands out. The master (Role `master`) sits in the last column, above You, and break-glass entries get red lines straight to You. The count at the top is the number of paths to you, against a target of the master plus the break-glass rows. Tap You to light only those paths. The row above the graph picks what it draws: checks, supervision and escalation lines in any mix, and Problems, which keeps only the failing, silent, flaky, unchecked or unread loops and what they reach. It opens on escalations alone, and this browser remembers your choice. `--check` fails on a loop that reaches you without being the master or break-glass, on an escalation cycle, and on a target that isn't a loop. It also fails with no registry rows, on a name two rows share in any case (the first counts), on a loop name that isn't letters, digits, `_`, `.` and `-` or is `you` or `nobody`, and on a row with more cells than headers; write a `|` inside a cell as `\|`. Checked by fails on a loop nobody but itself reads, a checker that is no loop, service or you, checkers that only lead round loops (a cycle, or a loop nobody reads), and `you` on a loop whose Supervisor is a loop: its supervisor reads it. A service ends a chain. More than 5 loops naming `you` in Checked by is a fan-in warning: `--check` prints it on a `warning:` line but still passes, and it waits on you on the page. You read everything yourself, so put a supervisor loop in between. A row whose name breaks the rule is left out, so its job shows as Unregistered until it's renamed. These go in the row's supervisor issue. A cycle is described once, on its first loop by name. With no master named, every loop escalates to you and nothing is flagged. With a project picked at the top, it draws that project's loops and every loop their links reach, so each chain stays whole.

## What defines a loop

Open a loop, in the lists or by tapping it on the Factory tab, and the buttons under it lead to what makes it: its **charter**, its **Orders**, its **prompt** (a cloud routine's page on claude.ai, a desktop task's `SKILL.md`), its **run script** (else its plist), its **latest report** and its **run log**. `fleet.py` finds them without a model and stores only where they are, never what they say:

- The charter is the first backticked path in the registry's Charter cell, looked for from your home (`~/…`), the registry's folder, and every checkout under `memo_roots`, where a cell's leading folders that end a checkout's path drop (`app/docs/LOOP.md` in `…/app`). A bare file name is also looked for in the `docs/` of the repo named after the loop's project. Anything but one file links nothing.
- Orders are the first `orders/<name>.md` the charter names that sits beside it. The latest report is the newest dated file in the folder the charter's report section names (a heading with "report" in it, then a path like `docs/ops-reports/YYYY-MM-DD.md`).
- A file on its repo's default branch on GitHub links to its page there, read from that branch, so a stale clone or an uncommitted file doesn't count. Any other file shows its path, and the button copies it: a claude.ai page can only link to web addresses.
- A cloud routine's page needs its id in `cloud.json`, which the claude.ai sync (`SYNC.md`) writes.

## Improver history

Every change an improver makes to a loop is a PR, and each also gets one line in `improvements.jsonl`, next to the run ledger and append-only. The line written when the PR opens holds `id`, `date`, `loop`, `pr` (its link), `change` (one line), `trace` (links to the runs or ledger lines it read, never copied text), `hypothesis`, `metric`, `baseline`, `replay_before` and `replay_after` when a replay proves it, and `read_date`. At the read date one more line with the same `id` adds `outcome` (`kept`, `reverted`, or `closed` for a PR that never merged), `moved` (true or false), `result` and, for a revert, `revert_pr`; later fields win. A loop's panel lists its changes, and the Factory tab's Improver card lists them all with the hit rate: of the merged changes that were read, the share kept that moved their metric. The card shows only once there is a change. The improver's own runs log a ledger line like any loop's, so the heartbeat watches it.

## Config

`$AGENT_OPS_DIR/fleet.json` (default `~/.agent-ops/fleet.json`; `FLEET_CONFIG` overrides the path). Every key is optional; `fleet.example.json` shows them all. Paths default to the same folder: `REGISTRY.md`, `runs.jsonl`, `checks/`, and `fleet/` for the output. `tasks` is where desktop-app scheduled tasks keep their prompts (default `~/.claude/scheduled-tasks`).

## Projects and General

The picker at the top of the page narrows every tab to one project: the overview's status line, numbers and lists, the loops and what waits on you. General holds what belongs to no one product: loops with no project, the projects you list under `general` in `fleet.json` (say your ops and personal loops), services, one-off and unregistered jobs, and queue lines. A PR or an open decision belongs to the registry project its repo is named after, ignoring case and punctuation (`social-algorithms` is Social algorithms), and to General otherwise. Each row carries the result as `scope`, so the page never repeats the rule; within General, the Loops tab still shows each project's own card.

## Keeping it fresh

The build is a service, not a loop: schedule `python3 fleet/fleet.py` every 30 minutes with launchd or cron, and list it under Services in your registry. The claude.ai dashboard (`SYNC.md`) is an optional second view: it adds your cloud routines and desktop tasks, and opens on any device you're signed in on.

## Actions

The page can't change your machine, so each action copies something for you to run: launchd's run-now and stop commands, and a retire prompt you paste into Claude Code. The prompt asks for your reason, shows what it will remove and waits for your yes before it unloads the job and deletes its registry row.

## Does it show the truth?

`eval/replay.py` replays the builder at one time a day over a past ledger and scores what it flagged against labelled incidents: how many real failures it caught with the right cause, how fast, and how many flags were false alarms. Two seams make that possible: `FLEET_NOW` sets the time the build runs as (runs after it are ignored), and `jobs` in `fleet.json` names a fixture of jobs (`{"label": {"cron": "0 9 * * *"}}`) read in place of launchd and the crontab. `--min-detection` fails the run when detection falls, so run it before any change to the builder, the heartbeat or a check. Keep your real ledger slice and labels private; `eval/fixture/` is a made-up one, and `tests/replay.test.sh` runs it.
