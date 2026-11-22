# Loop registry

Every scheduled loop you run, one row each. `fleet/fleet.py` reads the two tables below by their headings, so keep the column names. A loop that isn't here doesn't exist as far as the fleet is concerned, and the dashboard shows any running job with no row as Unregistered.

- **Loop** is the name it logs under (`OPS_LOOP`); for a cloud routine that doesn't log, the routine's name. Letters, digits, `_`, `.` and `-` only, unique ignoring case, and never `you` or `nobody`. A check script at `<checks>/<Loop>.py` is run by the builder when the loop writes no ledger line.
- **Job** is what triggers it: a launchd label, `cron:<script name>` (a crontab line), `routine:<name>` (Claude Code cloud routine) or `task:<id>` (desktop-app scheduled task).
- **Schedule** is for people. A cron in backticks overrides the job's own trigger, for runners that skip some fires. In an override, a day of month and a weekday must both match (`0 8 1-7 * 1` is the first Monday); crontab itself fires on either.
- **Checked by** is who reads its output after its check passes: other loops by name, `heartbeat`, or `you`, comma-separated. Each is a loop or service with a row here, or `you`; a loop with a Supervisor loop leaves `you` out, as its supervisor reads it. `docs/LOOP_CATALOG.md` says who usually does for each kind of loop.
- **Supervisor** (optional) is the loop that writes this loop's Orders (`docs/orders/<name>.md`). One per loop at most, and one loop can supervise many. Leave it blank for none.
- **Escalates to** (optional) is where the loop sends anything that needs a person: a loop, or `you`. Blank means its project's manager, else the master, else you. Fill it only to override that.
- **Role** (optional) is `master` for the one loop that may message you, or `manager` for the loop that takes its project's escalations (one per project). Once a loop is the master, `fleet.py --check` fails on any other loop that escalates to you, unless it's in the Break-glass table.
- **Improver** (optional) is `on` to let the fleet's improver (`improver/IMPROVER.md`) change how this loop works; blank means it never does. `fleet.py --check` fails on any other value.
- **Charter** is a backticked path to the loop's charter, which the dashboard links to, with the Orders and latest report the charter names (`fleet/README.md`, "What defines a loop"). Words alone link nothing.
- **Project** groups the dashboard; leave it empty for loops that serve no one project (they show under General, with any project `fleet.json` lists under `general`).

## Registry

| Loop | Project | Runtime | Job | Schedule | Charter | Outcome check | Checked by | Supervisor | Escalates to | Role | Improver |
|---|---|---|---|---|---|---|---|---|---|---|---|
| myapp-daily-ops | MyApp | cloud | routine:myapp-daily-ops | daily 06:00 | `myapp/docs/AGENT_LOOP.md` | report PR for today (`checks/myapp-daily-ops.py`) | you |  |  |  | on |
| myapp-smoke | MyApp | mac | com.me.myapp-smoke | daily 05:30 | `myapp/e2e/` | the tests | heartbeat, myapp-daily-ops | myapp-daily-ops |  |  |  |
| heartbeat |  | mac | com.me.heartbeat | daily 09:30 | `bin/heartbeat.py` | its own liveness line | you |  |  |  |  |
| master |  | mac | com.me.master | daily 08:00 | `MASTER.md` | queue is valid (`checks/master.py`) | you |  |  | master |  |

## Services

Daemons, dashboards and model-free jobs: they run with no model, so they have no charter, readers or improver. Name one as it logs to the ledger and its checks still count.

| Service | Job | What it is |
|---|---|---|
| Fleet dashboard build | com.me.fleet-build | rebuilds `fleet/dashboard.html` every 30 minutes, no model |
| payments-watch | com.me.payments-watch | hourly script: disputes and refunds |

## Break-glass

Loops and services that may message you directly, skipping the master, and why. Keep it to money at risk, production down and security. Each row is a standing exception, so give it a reason you'd defend.

| Who | Why |
|---|---|
| payments-watch | money at risk |
