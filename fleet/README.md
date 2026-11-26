# Fleet dashboard

One page for every scheduled loop you run, across all your projects: whether each one is healthy, when it runs next, what it cost, who checks its output, and everything waiting on you. `fleet.py` builds it with no model, so it's free to rebuild as often as you like.

```bash
python3 fleet/fleet.py && open ~/.agent-ops/fleet/dashboard.html
```

It works with nothing set up. With no registry it lists every job it finds with that job's own health and titles the page Loop health: what launchd, cron's output files and the cloud snapshot say, and no Factory graph, waiting list, cost or pass rate. That's the `loop-health` plugin. It gets more useful once your loops have a registry (`REGISTRY.example.md`) and log through agent-ops-kit's `bin/claude-run` and `bin/ops-check`. The `fleet` skill sets all of this up for you and never changes a job you already run.

## What it reads

| Source | Gives | Needed |
|---|---|---|
| `REGISTRY.md` | the loops, their project, schedule, charter, check and who checks their output; the services | no: without it every job shows its own health; with it, a job with no row shows as Unregistered |
| launchd (`~/Library/LaunchAgents`) and your crontab | what is actually scheduled, last exit, next run; for cron, the time the file a line writes its output to last changed (cron keeps no exit codes) | found on its own |
| `runs.jsonl` | last run, pass rate, cost, the last 10 outcomes | once loops run through `claude-run` and `ops-check` |
| `checks/<loop>.py` | an outcome for loops that write no ledger line, like cloud routines | per loop |
| `fleet/cloud.json` | Claude Code cloud routines and desktop-app tasks: schedule, next and last run | only with the claude.ai sync (`SYNC.md`) |
| `improvements.jsonl` | the improver's history: each change it made to a loop, what it read, the metric it should move and whether it did | once an improver runs |
| GitHub, a queue file, decision memos | what waits on you: PRs with your label, owner-you queue lines, open decisions in your repos' `docs/` and `bets/` | optional, `waiting` in `fleet.json` |
| `kpi.jsonl` | each loop's KPI, read weekly by the improver: its Good against the Floor in its charter | once an improver runs |
| Orders, charters, reports, message logs | what loops tell each other, on the Feeds tab and in each loop's drawer | Orders and reports once loops have them; logs and history files with `talk` in `fleet.json` |

Without a ledger, a launchd loop's last exit and the time its log file last changed stand in for its last run, so a fleet you haven't instrumented still shows what failed. A kept-alive service that launchd restarted within the hour after a failed exit is crashing, so it shows as failing. One that was stopped (SIGTERM), or has run for over an hour since, doesn't.

## Statuses

- **Failing:** the last outcome check failed (or, with no check, the last run exited non-zero).
- **Silent:** no run for one scheduled period plus 12 hours, or for a launchd interval job three intervals and at least an hour, or 1.5 times the median gap between its last 10 ledger lines if that is longer (a job that checks often and logs rarely); or a cloud routine whose next run claude.ai still had due an hour before the snapshot. With no registry, a log file that stopped changing isn't enough, since many scripts log somewhere else. Such a job shows as No run record and its detail gives the log's date. With a registry it still counts, so a registered loop that stops still alerts.
- **Flaky:** the last check passed but 3 of the last 7 failed.
- **Unregistered:** running, with no registry row.
- **Stale data:** the cloud snapshot is over 36 hours old.
- **Missing:** a registered routine or task the claude.ai snapshot doesn't list, so it was deleted or renamed there.
- A routine whose last run was cancelled or timed out is Failing; one still running isn't.
- **Unchecked:** runs, with nothing the builder can read that proves the outcome.
- A service (a Services row) is read like a loop, from its launchd job, routine or task, ledger lines under its name and `checks/<Service>.py`, so it can be Failing, Silent, Flaky, Missing or Paused; otherwise it shows as **Service**. A log file that stopped changing doesn't make it Silent.
- **Not run yet**, **Paused** (registered, not loaded or enabled, or its charter says `status: paused`), **Healthy**.
- A launchd job with a Month and Day runs every year on that date, so it reads yearly; a one-off job removes itself after it runs.
- **No run record:** nothing says when it last ran: a crontab line that sends its output nowhere, or, with no registry, a job whose log is missing or too old to trust.
- **Ran** (no registry only): the last run exited 0, or for cron, its output file changed on schedule. Nothing proves it did its job.

## Factory

The page has two tabs, Factory and Feeds, under one status line (what needs a look, what waits on you; tap it for the list). Every loop opens the same drawer from either tab.

The Factory tab draws who checks what: every loop on the left, the loops and scripts that read other loops' output in the middle, and you on the right. A loop's **Checked by** cell draws its lines. A name there is a loop's or service's name or its job (with or without `routine:` or `task:`), or `you`; any other name shows as a checker that isn't in the registry. Loops with no checker run into **Nobody**, the gap to close. Point at a loop to trace its chain both ways; tap it to open its drawer. On a phone the graph becomes a list of loops grouped by who reads them. The optional **Supervisor** column adds dotted lines from each supervisor to the loops whose Orders it writes; a supervisor that isn't a loop, or a cycle, gets a dotted outline and says why when tapped. `fleet/fleet.py --check` reads only the registry and fails on any of these, so the claude.ai sync's outcome check (`SYNC.md` step 6) fails with them and the kit's heartbeat alerts you. **Escalates to** adds thick amber lines: where each loop sends what needs a person. Loops of one project that follow the default share one line from their frame, so an override stands out. The master (Role `master`) sits in the last column, above You, and break-glass entries get red lines straight to You. The count at the top is the number of paths to you, against a target of the master plus the break-glass rows. Tap You to light only those paths. The row above the graph picks what it draws: escalation, check or supervision lines, one at a time, and Problems, which keeps only the failing, silent, flaky, unchecked or unread loops and what they reach. It opens on escalations alone, and this browser remembers your choice. `--check` fails on a loop that reaches you without being the master or break-glass, on an escalation cycle, and on a target that isn't a loop. It also fails with no registry rows, on a name two rows share in any case (the first counts), on a loop name that isn't letters, digits, `_`, `.` and `-` or is `you` or `nobody`, on a row with more cells than headers, and on an Improver cell that isn't `on` or blank; write a `|` inside a cell as `\|`. Checked by fails on a loop nobody but itself reads, a checker that is no loop, service or you, checkers that only lead round loops (a cycle, or a loop nobody reads), and `you` on a loop whose Supervisor is a loop: its supervisor reads it. A service ends a chain. More than 5 loops naming `you` in Checked by is a fan-in warning: `--check` prints it on a `warning:` line but still passes, and it waits on you on the page. You read everything yourself, so put a supervisor loop in between. A row whose name breaks the rule is left out, so its job shows as Unregistered until it's renamed. These go in the row's supervisor issue. A cycle is described once, on its first loop by name. With no master named, every loop escalates to you and nothing is flagged. With a project picked at the top, it draws that project's loops and every loop their links reach, so each chain stays whole.

## What defines a loop

Open a loop, from the Factory, Feeds or the status line, and the links in its drawer lead to what makes it: its **charter**, its **Orders**, its **prompt** (a cloud routine's page on claude.ai, a desktop task's `SKILL.md`), its **run script** (else its plist), its **latest report** and its **run log**. `fleet.py` finds them without a model and stores only where they are, never what they say:

- The charter is the first backticked path in the registry's Charter cell, looked for from your home (`~/…`), the registry's folder, and every checkout under `memo_roots`, where a cell's leading folders that end a checkout's path drop (`app/docs/LOOP.md` in `…/app`). A bare file name is also looked for in the `docs/` of the repo named after the loop's project. Anything but one file links nothing.
- Orders are the first `orders/<name>.md` the charter names that sits beside it. The latest report is the newest dated file in the folder the charter's report section names (a heading with "report" in it, then a path like `docs/ops-reports/YYYY-MM-DD.md`).
- A file on its repo's default branch on GitHub links to its page there, read from that branch, so a stale clone or an uncommitted file doesn't count. Any other file shows its path, and the button copies it: a claude.ai page can only link to web addresses.
- A cloud routine's page needs its id in `cloud.json`, which the claude.ai sync (`SYNC.md`) writes.
- A registered loop whose charter isn't found says **Charter: none**, so the gap shows. Write `none` in the Charter cell when there is none.
- Above the links, the drawer says who reads the loop, who supervises it, where it escalates, its role and any break-glass reason, then **Good**: the `**Floor:**` line the charter keeps in its Mission, read only inside `mission` markers, and any `Target:` line of its Orders. With no Floor it says Good: not set. A loop that is Unchecked says what that costs: nothing writes a pass or fail line for it.
- A service whose job nothing on this machine runs, or a routine or task the claude.ai snapshot doesn't list, is Missing, not Paused.

## Talk

The Feeds tab shows what loops tell each other, read where they already write it, so nothing new has to talk. `fleet.py` writes it as a fifth dataset, `talk`, one row per line said, newest first, from the last `talk.days` days (14 unless set):

- **Orders.** Each standing order in a loop's Orders file (the first column of its `Order` table, with its read date) comes from its supervisor, or from you when it has none. Each line under `Changes` (`date | why | by`) is an Orders change from whoever its `by` cell names.
- **Charter changes.** Each commit to a loop's charter on its repo's default branch. A commit doesn't say who asked for it, so the sender is unknown.
- **Its latest report.** The report itself goes to whoever checks the loop. The items under an `Escalations` heading go where it escalates. The items under `Orders requests` go to its supervisor.
- **Message logs** (`talk.logs`). JSON lines with `date`, `subject` and the sender as `from` or `loop`, and optionally `to`, which otherwise comes from the log's `to`. Log only the subject, never the body.
- **History files** (`talk.history`). Each commit to a file, like a queue, by its subject.

A sender nothing records shows as unknown. It's never guessed. Loops that share a charter or Orders file get one row, sent to all of them. Each row is one line and a link, never a body, so reports that quote strangers stay where they are. Every checkout whose files are read is fetched first, once a build, so a clone nobody pulls still shows today's default branch.

Feeds lists the lines newest first under day labels, each said once. Tap a loop's name and its drawer opens beside the page: its status, the path its output takes to you, its changes and links, **Orders now**, then the **Conversation**, every line it said or heard as a chat, oldest first. The box under it writes a message to that loop as a prompt to copy into Claude Code; the page itself sends nothing. Escape, the close button or a tap outside closes it.

## Start or change a loop

The page runs nothing, so it builds prompts. **New loop**, above the Factory graph, asks the kit's new-loop questions and builds the prompt `/agent-ops-kit:new-loop` takes; **Change this loop**, in each registered loop's drawer, builds its `edit` prompt (and replaces the copy-a-retire-prompt button there, since retiring is one of its choices). Copy the prompt into Claude Code: the skill asks for anything missing and confirms before it changes a thing.

The questions are never written into the page. `fleet.py` reads them from the kit's `skills/new-loop/questions.json` (config `kit`, default `$AGENT_OPS_KIT`, else `~/.agent-ops/kit`), the same file the skill and `bin/new-loop` read, into a fourth dataset, `questions`: a row per question and per choice, in the spec's order, and the prompt lines in its meta. A built prompt is the prompt line, then one `<id>: <value>` line per answer: a repeated answer once per line, a longtext answer kept to its one line, empty ones left out. The spec's `defaults`, the answers the skill fills in for a starter and states once, are never asked. Answers that land in a mission block, and the change choices that route to a founder PR, are marked founder. A spec with a key, kind or choice field this build doesn't know builds no form and says why on stderr, so the form never asks something the skill doesn't. The edit form shows where the loop runs now, its schedule and supervisor. The tests use `tests/kit`, a copy of the spec with every kind and key, and also check the installed kit's spec when there is one.

## Improver history

Every change an improver makes to a loop is a PR, and each also gets lines in `improvements.jsonl`, next to the run ledger and append-only; this is the one definition of their fields. The improver opens a change with `id`, `date`, `loop`, `pr` (its link), `change` (one line), `trace` (links to the runs or ledger lines it read, never copied text), `hypothesis`, `metric`, `better` (`higher` or `lower`), `runs` (how many checks to read on each side of the change, a whole number of at least 2, 7 unless given) and `read_date`. `improve_read.py` reads it, by arithmetic, in one more line with the same `id` and no `date`: `outcome` (`kept`, `reverted`, or `closed` for a PR that never merged), `moved` (true or false), `baseline` and `after` (the means of the last `runs` values before the change's `date` and the first `runs` after its merge), `margin`, `pass_rate_before` (0 to 1, the share of checks that passed over the span before) and `result`, a sentence saying the same. A loop whose check lines carry `total` is a running total, whose values are overlapping 7-day gains, so it is read on each check's gain since the loop's previous total instead, divided by the checks it spans. `moved` is the mean after beating `baseline` in the `better` direction by more than `margin`, two standard errors (2·√(s_before²/runs + s_after²/runs), sample standard deviations), with the pass rate over the span after no lower; the outcome is `kept` if it moved, else `reverted`, so a change too small to tell from noise is reverted. The improver then opens the revert and adds a line with the `id` and its `revert_pr`. Later fields win. A change with no `better`, a `runs` that isn't a whole number of at least 2, or fewer than `runs` values before it is never read; one whose PR gh can't read is read on a later run. A loop's drawer lists its changes, and the Improver card under Fleet health lists them all with the hit rate: of the merged changes that were read, the share kept that moved their metric. The card shows only once there is a change. The improver's own runs log a ledger line like any loop's, so the heartbeat watches it.

An ops repo runs the improver from the factory checkout, as it runs the claude.ai sync: a short pointer file in the ops repo holds the `status:` line its runner reads and says to follow `improver/IMPROVER.md` in place with its own values for the factory path, the ops-check path, the reports folder, the hard-stop command and the schedule.

## KPIs and the bar

Every loop's KPI is its Good, its North Star (the `good:` line its check prints), against the Floor its charter sets. The improver's `fleet/improve_read.py` appends one line a day it runs to `kpi.jsonl` for each loop with Improver on in the registry, from the latest check line with a `value` in the ledger: `date`, `loop`, `kpi` (`met` when the value is at or past its `bar`, `below`, `measured` when the check prints a value with no bar, or `no KPI` when it prints no value), `value`, `better`, `bar`, `as_of` (the date of the check it came from, so a stale value shows), and for a loop below its Floor `since` (the day the run of below values began), `attempts` (changes opened on it since), `of` (2, the attempts it gets before it goes to you) and `escalated`. The improver's own charter and check are in `improver/`. The latest line per loop becomes its row's `kpi*` cells. A loop's drawer shows "Good: 50 vs Floor at least 62% · below since 15 Nov · attempt 1 of 2 · as of 21 Nov" with its check pass rate as health, "Good: 5 · higher is better · as of 22 Nov · no Floor set" for a Good measured with no bar, or "not measured" before its Good is read.

Fleet health, folded under the Factory graph, puts every evaluation in one place, for the picked project: the share of loops with a bar at or above their Floor, the share measured (with a bar or without), how many have a Floor, the checks passed, the replay eval's latest scores (`eval/result.json`, config key `eval`: what the dashboard and the heartbeat catch, their false alarms and time to flag, against the eval's floor), and the improver's hit rate. Anything with no data yet says "not measured". Loops below their Floor are listed under it.

## Config

`$AGENT_OPS_DIR/fleet.json` (default `~/.agent-ops/fleet.json`; `FLEET_CONFIG` overrides the path). Every key is optional; `fleet.example.json` shows them all. Paths default to the same folder: `REGISTRY.md`, `runs.jsonl`, `checks/`, and `fleet/` for the output. `tasks` is where desktop-app scheduled tasks keep their prompts (default `~/.claude/scheduled-tasks`).

## Projects and General

The picker at the top of the page narrows both tabs to one project: the status line, the loops, the feed and what waits on you. General holds what belongs to no one product: loops with no project, the projects you list under `general` in `fleet.json` (say your ops and personal loops), services, one-off and unregistered jobs, and queue lines. A PR or an open decision belongs to the registry project its repo is named after, ignoring case and punctuation (`social-algorithms` is Social algorithms), and to General otherwise. Each row carries the result as `scope`, so the page never repeats the rule.

## Keeping it fresh

The build is a service, not a loop: schedule `python3 fleet/fleet.py` every 30 minutes with launchd or cron, and list it under Services in your registry. The claude.ai dashboard (`SYNC.md`) is an optional second view: it adds your cloud routines and desktop tasks, and opens on any device you're signed in on.

## Actions

The page can't change your machine, so each action copies something for you to run: launchd's run-now and stop commands, and a retire prompt you paste into Claude Code. The prompt asks for your reason, shows what it will remove and waits for your yes before it unloads the job and deletes its registry row.

## Does it show the truth?

`eval/replay.py` replays the builder at one time a day over a past ledger and scores what it flagged against labelled incidents: how many real failures it caught with the right cause, how fast, and how many flags were false alarms. Two seams make that possible: `FLEET_NOW` sets the time the build runs as (runs after it are ignored), and `jobs` in `fleet.json` names a fixture of jobs (`{"label": {"cron": "0 9 * * *"}}`) read in place of launchd and the crontab. It's a report, not a gate: `--json` writes the result the dashboard's Evaluations card reads, and `--min-detection` records the floor detection is read against (and exits 1 below it, for anyone who wants to gate on it). Keep your real ledger slice and labels private; `eval/fixture/` is a made-up one, and `tests/replay.test.sh` runs it.
