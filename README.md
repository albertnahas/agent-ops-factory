# agent-ops-factory

**Want to know if your scheduled agent loops are healthy?** One line in Claude Code:

```
/plugin install loop-health --marketplace albertnahas/agent-ops-factory
```

Then ask "are my loops healthy?". It finds your launchd jobs and crontab lines (and your Claude Code cloud routines, if you let it read them) and opens one local page: what failed, what went quiet, what hasn't run yet. No registry, no account, nothing to wire up, and it doesn't need agent-ops-kit. The scan itself has no model in it, so rebuilding the page costs nothing. Without a run ledger it can only tell you whether a job ran and how it exited, not whether it did its job, and the page says so.

How it differs: OpenRoutine, AgentBeat and Pykero have you move your loops into them or wire each one up. This reads what you already have scheduled, on your machine and in the cloud.

Everything below is the bigger thing those loops came from.

## The factory

An AI software factory for one person: scheduled Claude Code loops that ship, grade, supervise and report. It's the setup I use to run a live product on a night shift of agents while I work my day job.

On [OpenWhen](https://www.openwhen.cards), a product I built and run alone, 277 PRs have merged since July 2026 (as of 21 Nov). The loops opened 170 of them, 77 of which are daily reports. The rest came from Claude Code sessions I directed and a few dependency bots. No loop PR has been reverted. The one revert on main since July undid a pricing change I pushed myself.

## Start with the kit

This repo sits on top of [agent-ops-kit](https://github.com/albertnahas/agent-ops-kit). The kit runs one loop safely: the charter and its merge policy, the PR grader, the guard hooks, `bin/claude-run` and the run ledger, outcome checks and the heartbeat. Set that up first and run one loop for a week. Come here once you run more than one.

The factory adds what you need for many loops:

- **The playbook** (`docs/FACTORY_PLAYBOOK.md`): which loops to start and in what order, how each one is checked, what it may cost, when it gets retired, and how big changes get decided as bets with a 14-day test.
- **Fleet dashboard** (`fleet/`): one page for every scheduled loop across all your projects. Healthy or not, when it runs next, what it cost, who checks its output, who supervises it, and everything waiting on you. Built with no model from your registry, launchd, cron and the kit's run ledger, so it's free to rebuild.
- **Loop planner** (`skills/plan-loops`, `docs/LOOP_CATALOG.md`): reads a project and proposes the loops it needs from a catalog of the ones that earned their keep, then builds the ones you approve with a charter, an outcome check, a schedule and a registry row.

## Install

You need Claude Code v2.1.295 or later, `gh`, `jq` and `python3`. Install the kit, then the factory:

```
/plugin install agent-ops-kit --marketplace albertnahas/agent-ops-kit
```

```
/plugin install agent-ops-factory --marketplace albertnahas/agent-ops-factory
```

The skills find the kit at `$AGENT_OPS_KIT`, default `~/.agent-ops/kit`, so keep a clone there too:

```bash
git clone https://github.com/albertnahas/agent-ops-kit ~/.agent-ops/kit
```

Then ask Claude Code to "start a software factory for this project" (the `factory` skill, which walks the playbook), "plan the loops this project needs" (`plan-loops`) or "set up my fleet dashboard" (`fleet`). Nothing it schedules or changes happens without your yes.

No plugins? Paste this into Claude Code instead:

> Clone https://github.com/albertnahas/agent-ops-kit to ~/.agent-ops/kit and https://github.com/albertnahas/agent-ops-factory to ~/.agent-ops/factory, read the factory's skills/fleet/SKILL.md and follow "Set up". Ask me before you schedule anything or write my crontab.

## Try it

```bash
git clone https://github.com/albertnahas/agent-ops-factory ~/.agent-ops/factory && cd ~/.agent-ops/factory
```

```bash
tests/fleet.test.sh && tests/health-demo.sh && tests/fleet-demo.sh
```

Every test line should say `ok`. `tests/health-demo.sh` builds the loop-health page from a made-up machine with no registry. The fleet demo builds a dashboard from a made-up fleet of 30 loops and prints its path, so you can see every status before you have a fleet of your own.

## Files

| File | What it does |
|---|---|
| `docs/FACTORY_PLAYBOOK.md` | The front door: the order to start loops in, the registry, budgets, fix or retire, when work earns a loop, bets and scaling. |
| `docs/LOOP_CATALOG.md` | The loop types a product needs, when it needs each, what checks it and who reads its output. |
| `fleet/` | The dashboard: `fleet.py` builds `loops.json`, `waiting.json` and `dashboard.html`; `README.md` says what it reads and how each status is decided; `SYNC.md` puts it on claude.ai with your cloud routines. |
| `skills/` | `loop-health` scans the machine and shows each loop's health with no setup, `factory` walks the playbook for a project, `plan-loops` designs and builds the loops a project needs, `fleet` sets up and runs the dashboard and retires loops. |
| `plugins/loop-health/` | The `loop-health` plugin: links to `skills/loop-health` and `fleet/`, so both plugins run the same code. |
| `tests/` | A fixture registry and ledger for the fleet builder, a demo machine with no registry, and a demo fleet. |

## Limits, honestly

- This runs one person's fleet: 42 jobs and services across 10 projects as of 22 Nov. If you run it on a team, I'd like to hear what breaks.
- The dashboard sees launchd, cron and your ledger on your machine. Cloud routines and desktop-app tasks only show up through the claude.ai sync, which runs as a desktop-app task twice a day.

MIT licensed. By [Albert Nahas](https://github.com/albertnahas).
