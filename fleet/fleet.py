#!/usr/bin/env python3
"""Fleet builder, no model. Reads $AGENT_OPS_DIR/fleet.json and writes <out>/loops.json (every scheduled loop, service and
one-off job with its health), <out>/waiting.json (everything waiting on you) and <out>/dashboard.html (both, drawn).
Sources: the registry file, launchd plists, your crontab, the run ledger, <out>/cloud.json (Claude routines and
desktop tasks, written by the claude.ai sync in fleet/SYNC.md), and optionally a queue file, GitHub PRs and decision memos.
fleet/README.md says how each status is decided."""
import datetime as dt, functools, json, math, os, plistlib, re, shlex, shutil, subprocess, sys, urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OPS = Path(os.environ.get("AGENT_OPS_DIR", Path.home() / ".agent-ops")).expanduser()
CONFIG = Path(os.environ.get("FLEET_CONFIG", OPS / "fleet.json")).expanduser()
WINDOW = 30  # days for pass rate and cost
STALE_SNAPSHOT_H = 36

def load_config():
    cfg = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    home = Path(cfg.get("home", OPS)).expanduser()
    path = lambda key, default: Path(cfg.get(key, home / default)).expanduser()
    return {**cfg, "home": home, "registry": path("registry", "REGISTRY.md"), "ledger": path("ledger", "runs.jsonl"),
            "checks": path("checks", "checks"), "out": path("out", "fleet"),
            "launch_agents": path("launch_agents", Path.home() / "Library/LaunchAgents"),
            "tasks": path("tasks", Path.home() / ".claude/scheduled-tasks"),
            "jobs": cfg.get("jobs") and Path(cfg["jobs"]).expanduser(),
            "improvements": path("improvements", "improvements.jsonl"),
            "refresh": cfg.get("refresh", "Rebuilt by fleet.py"), "waiting": cfg.get("waiting", {})}

C = load_config()
GH = shutil.which("gh") or next((p for p in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh") if Path(p).exists()), None)

def failed(r):
    """A Claude run that failed. A crash still says subtype success; exit and is_error are the truth."""
    return bool(r.get("subtype") != "success" or r.get("exit") or r.get("is_error"))

norm = lambda s: re.sub(r"[^a-z0-9]", "", (s or "").lower())
# Every source is read once, here at its edge: text with bad bytes replaced and split on \n only (U+2028 is text), names
# as strings, timestamps parsed, and anything else unusable left out, so one odd line never stops the build.
lines = lambda f: f.read_text(encoding="utf-8-sig", errors="replace").split("\n") if os.path.isfile(f) else []
name = lambda v: str(v) if isinstance(v, (str, int, float)) and str(v).strip() else None

def when(s):
    """A timestamp as naive local time to the second, or None. Takes Z, offsets and any fraction, as python 3.9 doesn't."""
    if not isinstance(s, str): return None
    s = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), s.strip())
    s = re.sub(r"([+-]\d\d)(\d\d)$", r"\1:\2", re.sub(r"Z$", "+00:00", s))  # date's %z: +0100
    try: t = dt.datetime.fromisoformat(s); return (t.astimezone().replace(tzinfo=None) if t.tzinfo else t).replace(microsecond=0)
    except (ValueError, OverflowError): return None  # not a time, or a "never" like 9999-12-31Z

def money(v):
    """A cost as a finite number, else 0."""
    try: return v if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else 0
    except OverflowError: return 0  # an int too big for a float

def check_of(loop):
    """checks/<loop>.py when the name is a plain file name and the file is there (a name too long for one is no file)."""
    f = C["checks"] / f"{loop}.py"
    return f if loop == Path(loop).name and os.path.isfile(f) else None

def scoping(registry):
    """name -> (the registry project it names, ignoring case and punctuation, or "", its scope). The scope is that
    project, or General: no project, a project listed under `general` in fleet.json, or nothing a registry row owns.
    Spellings of one project share its first row's."""
    projects = {}
    for r in registry:
        if r.get("Project"): projects.setdefault(norm(r["Project"]), r["Project"])
    general = {norm(g) for g in C.get("general", [])} | {"general"}
    def of(name):
        p = projects.get(norm(name), "")
        return p, p if p and norm(p) not in general else "General"
    return of

def cells(line, outer=True):
    """A table row's cells, split on | (`\\|` is a pipe inside a cell), less the pipes at either end if `outer`."""
    line = re.sub(r"^\||(?<!\\)\|$", "", line.strip()) if outer else line
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", line)]

def table(md, heading, *keys):
    """Rows of the first markdown table under `## heading`, as dicts keyed by header, and what's wrong with the rows
    left out: more cells than headers (an unescaped |), a blank key cell, or a first key a row above has in any case (the first counts)."""
    if f"## {heading}" not in md: return [], []
    sec = md.split(f"## {heading}", 1)[1].split("\n## ", 1)[0]
    rows = [l for l in sec.split("\n") if l.startswith("|")]
    if len(rows) < 2: return [], []
    head, out, bad, seen = cells(rows[0]), [], [], set()
    for l in rows[2:]:
        c = cells(l)
        r = dict(zip(head, c + [""] * len(head)))
        wrong = any(c[len(head):]) and f"{len(c)} cells under {len(head)} headers (a | in a cell is \\|)" or \
                next((f"no {k}" for k in keys if not r.get(k)), None) or \
                keys and r[keys[0]].casefold() in seen and f"a row above has this {keys[0]}; the first one counts"
        if wrong: bad.append(f"{heading} row {next(filter(None, c), '')[:60]}: {wrong}")
        else: out.append(r); seen.add(keys and r[keys[0]].casefold())
    return out, bad

# --- schedules: launchd calendar dicts and crons share one form, {Minute, Hour, Day, Month, Weekday} -> sets

NAMES = {n: i for i, n in enumerate(["sun", "mon", "tue", "wed", "thu", "fri", "sat"])} | \
        {n: i + 1 for i, n in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}

def cron_spec(expr, both=False):
    """Cron's rule: with both day of month and weekday restricted, either one matching fires. both=True makes it
    both, for registry overrides that describe what a runner really does ("first Monday": `0 8 1-7 * 1`). None for an
    expression cron would reject."""
    expr = re.sub(r"^CRON_TZ=\S+\s+", "", expr.strip())
    num = lambda s: NAMES[s.lower()[:3]] if s[:1].isalpha() else int(s)
    def field(f, lo, hi):
        if f == "*": return None
        out = set()
        for part in f.split(","):
            rng, _, step = part.partition("/")
            a, _, b = rng.partition("-")
            a, b = (lo, hi) if a == "*" else (num(a), num(b) if b else (hi if step else num(a)))
            if not lo <= a <= hi or not lo <= b <= hi: raise ValueError(part)
            if b < a and hi == 7: b += 7  # weekdays wrap: sat-sun
            out |= set(range(a, b + 1, int(step or 1)))
        if not out: raise ValueError(f)
        return out
    try:
        m, h, d, mo, wd = expr.split()[:5]
        return [{"Minute": field(m, 0, 59), "Hour": field(h, 0, 23), "Day": field(d, 1, 31),
                 "Month": field(mo, 1, 12), "Weekday": {w % 7 for w in field(wd, 0, 7)} if wd != "*" else None,
                 "either": not both and d != "*" and wd != "*"}]
    except (ValueError, KeyError): return None

every = lambda n: f"every {n // 60} min" if n % 60 == 0 else f"every {n} s"  # a StartInterval
RANGES = {"Minute": (0, 59), "Hour": (0, 23), "Day": (1, 31), "Month": (1, 12), "Weekday": (0, 7)}

def plist_spec(cals):
    """StartCalendarInterval dicts as specs; ValueError for one launchd wouldn't run (not a dict, a time not an int in range)."""
    if not all(isinstance(c, dict) and all(type(c[k]) is int and lo <= c[k] <= hi for k, (lo, hi) in RANGES.items() if k in c)
               for c in cals): raise ValueError(cals)
    return [{k: ({c[k] % 7} if k == "Weekday" else {c[k]}) if k in c else None for k in RANGES} for c in cals]

def fires(spec, start, direction, days=70):
    """Scheduled times after (direction 1) or before (-1) start, nearest first. Day and Weekday must both match,
    unless the spec says either (a crontab line restricting both). A missing Minute or Hour is every one."""
    day = start.replace(hour=0, minute=0, second=0, microsecond=0)
    for i in range(days):
        d = day + dt.timedelta(days=i * direction)
        ts = sorted({d.replace(hour=h, minute=m)
                     for s in spec
                     if (s["Month"] is None or d.month in s["Month"])
                     and ((d.day in s["Day"] or d.isoweekday() % 7 in s["Weekday"]) if s.get("either") else
                          (s["Day"] is None or d.day in s["Day"]) and (s["Weekday"] is None or d.isoweekday() % 7 in s["Weekday"]))
                     for h in (s["Hour"] or range(24)) for m in (s["Minute"] or range(60))}, reverse=direction < 0)
        yield from (t for t in ts if (t > start if direction > 0 else t <= start))

def nth(gen, n):
    for i, x in enumerate(gen):
        if i == n: return x

# --- what is scheduled on this machine

def launchd_jobs():
    """Each plist's job; a plist launchd wouldn't run (unreadable, wrong types, a time out of range) is left out."""
    jobs = {}
    if not shutil.which("launchctl") or not C["launch_agents"].is_dir(): return jobs
    listed = {}  # label -> (running, last exit), from one `launchctl list`: PID, Status, Label columns
    for l in subprocess.run(["launchctl", "list"], capture_output=True, text=True, errors="replace").stdout.split("\n"):
        m = re.match(r"(\S+)\t(-?\d+|-)\t(.+)$", l)
        if m: listed[m.group(3)] = (m.group(1) != "-", None if m.group(2) == "-" else int(m.group(2)))
    for p in sorted(C["launch_agents"].glob("*.plist")):
        try:
            pl = plistlib.loads(p.read_bytes())
            cal = pl.get("StartCalendarInterval")
            cals = cal if isinstance(cal, list) else [cal] if cal else []
            spec = plist_spec(cals)
        except Exception: continue
        label = name(pl.get("Label")) or p.stem
        running, code = listed.get(label, (False, None))
        interval = pl.get("StartInterval") if type(pl.get("StartInterval")) is int and pl["StartInterval"] > 0 else None
        args = [str(a) for a in pl.get("ProgramArguments") or [pl.get("Program", "")]] if isinstance(pl.get("ProgramArguments") or [], list) else []
        logs = [Path(pl[k]).expanduser() for k in ("StandardOutPath", "StandardErrorPath") if isinstance(pl.get(k), str)]
        stamps = [f.stat().st_mtime for f in logs if os.path.isfile(f)]
        jobs[label] = {
            "schedule": every(interval) if interval else ", ".join(" ".join(str(c.get(k, "*")) for k in RANGES) for c in cals),
            "vendor": ".app/Contents/" in str(args),
            "loaded": label in listed,
            "exit": None if running else code,  # a running job's last exit is history
            "spec": spec or None,
            "interval": interval,
            "oneoff": bool(cals) and all("Month" in c and "Day" in c for c in cals),
            "daemon": bool(pl.get("KeepAlive") or (pl.get("RunAtLoad") and not cals and not interval)),
            "keepalive": bool(pl.get("KeepAlive")),
            "log_at": dt.datetime.fromtimestamp(max(stamps)).replace(microsecond=0) if stamps else None,
            "runner": runner(args) or p, "log": logs[0] if logs else None,
        }
    return jobs

MACROS = {"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
          "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"}
INTERPRETERS = {"sh", "bash", "zsh", "python", "python3", "node", "ruby", "perl", "npx", "uvx", "bunx", "tsx", "ts-node"}  # the next word is the script
WRAPPERS = {"env", "exec", "nice", "nohup", "caffeinate", "timeout", "flock", "chronic", "ionice"}  # their own args come first
RUNNERS = INTERPRETERS | WRAPPERS
PACKAGERS = {"npm", "pnpm", "yarn", "bun", "uv", "poetry"}  # `npm run build` runs build
BUILTINS = {"cd", "source", ".", "test", "[", "[[", "echo", "printf", "export", "set", "true", "false", ":", "sleep", "ulimit", "umask"}

def cron_words(cmd):
    """A crontab command as shell words and operators, as cron's shell reads it; `sh -c "..."` is read inside."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try: words = list(lex)
    except ValueError: words = re.sub(r"[\"']", "", cmd).split()  # an unclosed quote
    for i, w in enumerate(words[:-1]):
        if re.fullmatch(r"-\w*c\w*", w) and i and Path(words[i - 1]).name in {"sh", "bash", "zsh"}:
            return cron_words(words[i + 1]) + words[i + 2:]
    return words

def cron_name(cmd):
    """The script a crontab command runs: past shells, interpreters, wrappers, builtins like `cd dir &&`, flags,
    numbers, redirects and VAR=value. After an interpreter, the next word; after a wrapper, its last word with a /
    in it, else its last word."""
    seg = []
    for w in cron_words(cmd) + [";"]:
        if w not in {"&&", "||", ";", "|", "&", "(", ")"}:
            seg.append(w); continue
        words, skip = [], False
        for k, x in enumerate(seg):
            if skip or x.startswith("-") or "=" in x or x.isdigit() and k + 1 < len(seg) and re.fullmatch(r"[<>&]+", seg[k + 1]):
                skip = False; continue
            if re.fullmatch(r"[<>&|]+", x):
                skip = not x.endswith("&") and x != ">&"; continue  # a redirect: its file, or `2>&1`'s fd, isn't the script
            if not x.isdigit(): words.append(x)
        if words and words[0] not in BUILTINS and Path(words[0]).name not in BUILTINS:
            if Path(words[0]).name in PACKAGERS and "run" in words[1:]: words = words[words.index("run", 1) + 1:] or words
            names = [Path(x).name for x in words]
            i = max(k for k, n in enumerate(names) if n in RUNNERS) if names[0] in RUNNERS else -1
            rest = words[i + 1:] or [words[i]]
            if i < 0 or names[i] in INTERPRETERS: return Path(rest[0]).name
            return Path(next((x for x in reversed(rest) if "/" in x), rest[-1])).name
        seg = []
    return "?"

def cron_output(cmd, env={}):
    """The file a crontab command's output goes to (stdout's, else stderr's), relative to $HOME, where cron runs it.
    A relative path is from the line's last `cd`. Variables come from the crontab's own NAME=value lines; one it
    doesn't set, or a name worked out as it runs ($(date)), stays in the path with its $."""
    words, outs, cwd = cron_words(cmd), {}, "."
    for i, w in enumerate(words[:-1]):
        to, fd = words[i + 1], words[i - 1] if i and words[i - 1].isdigit() and words[i - 1] + w in cmd else "1"  # `2>`, not `3 >`
        if w == "cd" and (not i or words[i - 1] in {"&&", ";", "("}): cwd = to
        elif w in (">", ">>", ">|") or w in ("&>", "&>>") or w == ">&" and not to.isdigit() and to != "-":
            outs.setdefault(fd, to)
        elif Path(w).name == "tee" and i and words[i - 1] == "|":
            outs.setdefault("1", next((x for x in words[i + 1:] if not x.startswith("-")), None))
    f = next((outs[k] for k in "12" if outs.get(k, "/dev/null") != "/dev/null"), outs.get("1") or outs.get("2"))
    env = {"HOME": str(Path.home()), "LOGNAME": os.environ.get("USER", ""), "USER": os.environ.get("USER", "")} | env
    expand = lambda x: Path(re.sub(r"\$\{?(\w+)\}?", lambda m: env.get(m[1], m[0]), re.sub(r"`[^`]*`", "$", x))).expanduser()
    return f and Path.home() / expand(cwd) / expand(f)

def cron_jobs():
    """Crontab lines as jobs named cron:<script name>; a later line with the same name gets a numeric suffix.
    Cron keeps no exit codes; the file a line sends its output to says when it last ran."""
    jobs, env = {}, {}
    if not shutil.which("crontab"): return jobs
    tab = subprocess.run(["crontab", "-l"], capture_output=True, text=True, errors="replace").stdout
    for line in tab.split("\n"):
        parts, var = line.split(), re.match(r"\s*(\w+)\s*=\s*(.*)", line)
        if var: env[var[1]] = var[2].strip().strip("\"'")
        if not parts or line.lstrip().startswith("#") or var: continue
        macro = parts[0] in MACROS
        expr = MACROS[parts[0]] if macro else " ".join(parts[:5])
        cmd = re.split(r"\s+", line.strip(), maxsplit=1 if macro else 5)[-1] if len(parts) > (1 if macro else 5) else ""
        if not cmd or parts[0].startswith("@") and not macro: continue  # @reboot: no calendar to check
        log = cron_output(cmd, env)
        unset = log and re.search(r"\$\w*", str(log))
        has_log = bool(log and str(log) != "/dev/null" and not unset)
        loop = re.search(r"(?:^|\s)OPS_LOOP=([\w.-]+)", cmd)  # the kit's claude-run logs the loop under $OPS_LOOP
        name = "cron:" + (loop[1] if loop else log.stem if has_log and cron_name(cmd) in {"claude", "claude-run"} else cron_name(cmd))
        while name in jobs: name += "+"
        jobs[name] = {"spec": cron_spec(expr), "schedule": expr, "loaded": True, "vendor": False, "oneoff": False,
                      "exit": None, "interval": None, "daemon": False, "has_log": has_log,
                      "unset": unset and unset[0],
                      "log_at": dt.datetime.fromtimestamp(log.stat().st_mtime).replace(microsecond=0) if log and os.path.isfile(log) else None,
                      "runner": runner(cron_words(cmd)), "log": log if has_log else None}
    return jobs

# --- what defines a loop: links to its charter, Orders, prompt, run script and latest report. A link is the file's
# page on GitHub when it is on its repo's default branch, else its path for you to copy; never the file's contents.

def runner(args):
    """The script a job runs: the last argument naming a file in your home folder (`bash run.sh`, `node watch.mjs`)."""
    files = [Path(a).expanduser() for a in args if a.startswith(("/", "~"))]
    return next((f.resolve() for f in reversed(files) if os.path.isfile(f) and Path.home().resolve() in f.resolve().parents), None)

def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True).stdout.strip()

@functools.cache
def origin(top):
    """(owner/name, default branch ref) of a checkout whose origin is on GitHub, else None."""
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", git(top, "remote", "get-url", "origin"))
    return (m.group(1), git(top, "symbolic-ref", "--short", "refs/remotes/origin/HEAD") or "origin/main") if m else None

def on_github(path):
    """(owner/name, ref, path in the repo) when path is on its GitHub checkout's default branch, else None. The default
    branch decides, not this checkout's files, so a stale or partial clone gives the same answer."""
    top = git(next(a for a in (path, *path.parents) if a.is_dir()), "rev-parse", "--show-toplevel")
    o = top and origin(top)
    if not o: return None
    rel = path.resolve().relative_to(Path(top).resolve()).as_posix()
    return (*o, rel) if subprocess.run(["git", "-C", top, "cat-file", "-e", f"{o[1]}:{rel}"], capture_output=True).returncode == 0 else None

def exists(path):
    return path.exists() or bool(on_github(path))

def read(path):
    g = on_github(path)
    return git(path.parent, "show", f"{g[1]}:{g[2]}") if g else path.read_text(errors="ignore")

def tilde(path):
    s, h = str(path), str(Path.home())
    return "~" + s[len(h):] if s == h or s.startswith(h + "/") else s

def where(path):
    if not path: return None
    g = on_github(path)
    return f"https://github.com/{g[0]}/blob/{g[1].split('/', 1)[1]}/{urllib.parse.quote(g[2])}" if g else tilde(path.resolve())

def locate(cell, project, roots):
    """The one file a registry cell's first backticked path names, looked for from your home (`~/…`), the registry's folder,
    and each checkout under memo_roots, dropping the cell's leading folders that end the checkout's path (`app/docs/X.md`
    in …/app); a bare name also in the docs/ of the repo named after the project. None unless they all are one file (two
    checkouts of a repo hold the same one)."""
    m = re.search(r"`([^`]+\.\w+)`", cell or "")
    if not m: return None
    t = Path(m.group(1)).expanduser()
    cands = {t} if t.is_absolute() else {C["registry"].parent / t}
    for repo, tops in ({} if t.is_absolute() else roots).items():
        for top in tops:
            cands |= {top.joinpath(*t.parts[k:]) for k in range(len(t.parts)) if k == 0 or top.parts[-k:] == t.parts[:k]}
            if norm(repo) == norm(project): cands.add(top / "docs" / t)
    found = {c.resolve() for c in cands if c.is_file()}
    return found.pop() if len({where(f) for f in found}) == 1 else None

def newest_report(charter, text):
    """The latest dated file in the folder the charter's report section names (`docs/ops-reports/YYYY-MM-DD.md`, found
    from the nearest folder above the charter that has it), read from its repo's default branch when the folder is
    there, else from disk."""
    for sec in re.split(r"^(?=#{1,4} )", text, flags=re.M):
        m = re.match(r"#{1,4} .*report", sec, re.I) and re.search(r"([\w./-]+)/YYYY-MM-DD\.md", sec)
        if not m: continue
        folder = next((a / m.group(1) for a in charter.parents if exists(a / m.group(1))), None)
        if not folder: return None
        g, dated = on_github(folder), re.compile(r"\d{4}-\d{2}-\d{2}\.md$")
        names = git(charter.parent, "ls-tree", "--full-tree", "--name-only", f"{g[1]}:{g[2]}").splitlines() if g else [f.name for f in folder.iterdir()]
        latest = max((n for n in names if dated.match(n)), default=None)
        return latest and where(folder / latest)
    return None

def job_links(j):
    """A local job's script (else its plist) and its log file."""
    j = j or {}
    return {"runner": where(j.get("runner")), "log": tilde(Path(j["log"]).resolve()) if j.get("log") else None}

def definitions(reg, kind, ref, item, roots):
    """A registry loop's charter, its Orders (the first `orders/<name>.md` its charter names that is beside it), its prompt (a
    routine's claude.ai page, a desktop task's SKILL.md), its latest report, whether the charter says `status: paused`, the
    Floor its Good section keeps inside `mission` markers, and the Target line of its Orders."""
    charter = locate(reg.get("Charter"), reg.get("Project", ""), roots)
    text = read(charter) if charter else ""
    orders = next((f for f in (charter.parent / "orders" / n for n in re.findall(r"orders/([\w.-]+\.md)", text)) if exists(f)), None)
    task = C["tasks"] / ref / "SKILL.md"
    good = re.search(r"^## Good\b(.*?)(?=^## |\Z)", text, re.M | re.S)
    floor = good and "<!-- mission -->" in good.group(1) and re.search(r"^[-*\s]*\*\*Floor:\*\*\s*(.+?)\s*$", good.group(1), re.M)
    target = orders and re.search(r"^[-*\s]*\**Target(?::\**|\**:)\s*(.+?)\s*$", read(orders), re.M | re.I)
    return {"charter": where(charter), "orders": where(orders),
            "floor": floor.group(1) if floor else None, "target": target.group(1) if target else None,
            "prompt": f"https://claude.ai/code/routines/{item['id']}" if kind == "routine" and (item or {}).get("id")
                      else where(task) if kind == "task" and task.is_file() else None,
            "report": newest_report(charter, text) if charter else None,
            "charter_paused": bool(re.search(r"^status:[ \t]*paused\b", text, re.M))}

# --- the ledger claude-run and ops-check append to

def fixture_jobs(f):
    """Jobs from a fixture file in place of launchd and the crontab, for a replay: {label: {"cron": "30 9 * * *"} or
    {"interval": seconds}, optionally "loaded" (default true) and "exit"}. Nothing on this machine is read."""
    jobs = {}
    for label, j in json.loads(f.read_text()).items():
        spec = cron_spec(j["cron"]) if j.get("cron") else None
        jobs[label] = {"schedule": j.get("cron") or (every(j["interval"]) if j.get("interval") else ""),
                       "vendor": False, "loaded": j.get("loaded", True), "exit": j.get("exit"), "spec": spec,
                       "interval": j.get("interval"), "oneoff": False, "daemon": False, "keepalive": False,
                       "log_at": None, "runner": None, "log": None}
    return jobs

def ledger(now):
    """Runs by loop. A line counts with a loop name and a date it can read; its date becomes local time, so runs sort by
    when they happened, not by where they sit in the file."""
    runs = []
    for l in lines(C["ledger"]):
        try: r = json.loads(l)
        except (ValueError, RecursionError): continue
        loop, date = (name(r.get("loop")), when(r.get("date"))) if isinstance(r, dict) else (None, None)
        if loop and date and date <= now:  # a replay at a past time sees only what had happened by then
            runs.append({**r, "loop": loop, "date": date.isoformat(), "cost": money(r.get("cost")),
                         "detail": "" if r.get("detail") is None else str(r["detail"])})
    if not runs: return {}, None
    runs.sort(key=lambda r: r["date"])
    by = {}
    for r in runs: by.setdefault(r["loop"], []).append(r)
    since = (now - dt.timedelta(days=WINDOW)).isoformat()
    first = min(r["date"] for r in runs)[:10]
    out = {}
    for loop, rs in by.items():
        checks = [r for r in rs if "check" in r]
        claude = [r for r in rs if "check" not in r]
        win_checks = [r for r in checks if r["date"] >= since]
        win_claude = [r for r in claude if r["date"] >= since]
        if checks:
            last_ok, detail = checks[-1]["check"] == "pass", " ".join(checks[-1]["detail"].split())
            passes, total = sum(r["check"] == "pass" for r in win_checks), len(win_checks)
        else:
            last_ok = not failed(claude[-1])
            detail = f"run ended {claude[-1].get('subtype')} (exit {claude[-1].get('exit')})"
            passes, total = sum(not failed(r) for r in win_claude), len(win_claude)
        last7 = [r["check"] for r in checks[-7:]]
        history = "".join("p" if r["check"] == "pass" else "f" for r in checks[-10:]) if checks else \
                  "".join("f" if failed(r) else "p" for r in claude[-10:])
        out[loop] = {
            "last": max(r["date"] for r in rs), "last_ok": last_ok, "detail": detail[:200],
            "passes": passes, "total": total, "chronic": last7.count("fail") >= 3,
            "fails7": f"{last7.count('fail')} of last {len(last7)}",
            "cost": round(sum(r["cost"] for r in win_claude), 2),
            "has_checks": bool(checks), "history": history,
        }
    return out, first

IMPROVEMENT = ("id", "date", "loop", "pr", "change", "trace", "hypothesis", "metric", "baseline", "replay_before",
               "replay_after", "read_date", "outcome", "moved", "result", "revert_pr")

def improvements(scope_of):
    """The improver's history from improvements.jsonl: a line per change when its PR opens, then lines with the same id
    as it is read (append only; later fields win, and a null never erases one). Rows of scalars, newest first, scoped like their loop: a list (the
    trace's links) as one link a line, anything else not a number or true/false as text."""
    by = {}
    for l in lines(C["improvements"]):
        try: r = json.loads(l)
        except (ValueError, RecursionError): continue
        if isinstance(r, dict) and name(r.get("id")):
            by[str(r["id"])] = {**by.get(str(r["id"]), {}), **{k: v for k, v in r.items() if v is not None}}
    cell = lambda v: (v if v is None or isinstance(v, (int, float, bool)) else "\n".join(map(str, v)) if isinstance(v, list)
                      else json.dumps(v) if isinstance(v, dict) else str(v))
    rows = [{**{k: cell(r.get(k)) for k in IMPROVEMENT}, "outcome": str(r.get("outcome") or "pending").lower(),
             "scope": scope_of.get(str(r["loop"]), "General")} for r in by.values() if name(r.get("loop"))]
    return sorted(rows, key=lambda r: str(r["date"] or ""), reverse=True)

def discovered(jobs, routines, tasks, led, week):
    """With no registry, everything found stands in for its own row: loops for scheduled jobs, routines, tasks and
    recent ledger names, services for jobs launchd keeps running. One-offs and vendors' jobs keep their own paths."""
    mine = {k: j for k, j in jobs.items() if j["loaded"] and not j["vendor"] and not j["oneoff"]}
    named = {norm(n): n for n in led}  # a job named after a ledger loop is that loop: com.me.digest, cron:digest.sh
    stem = lambda k: Path(k[5:]).stem if k.startswith("cron:") else k.rsplit(".", 1)[-1]
    loops = []
    for k, j in mine.items():
        n = named.get(norm(stem(k)))
        if not j["daemon"]: loops.append({"Loop": n if n and n not in {r["Loop"] for r in loops} else k, "Job": k,
                                          "Runtime": "cron" if k.startswith("cron:") else "mac", "Schedule": j["schedule"]})
    loops += [{"Loop": n, "Job": f"routine:{n}", "Runtime": "cloud", "Schedule": r.get("cron") or "on event"}
              for n, r in routines.items() if r.get("enabled") and (r.get("cron") or r.get("last_finished_at"))]
    loops += [{"Loop": t, "Job": f"task:{t}", "Runtime": "app", "Schedule": x.get("cron") or ""} for t, x in tasks.items() if x.get("enabled")]
    loops += [{"Loop": n, "Job": ""} for n, l in led.items() if l["last"] >= week and n not in {r["Loop"] for r in loops}]
    services = [{"Service": k, "Job": k, "What it is": "kept running by launchd" if j["keepalive"] else "runs once at login"}
                for k, j in mine.items() if j["daemon"]]
    return loops, services

def tables():
    """The registry's Registry, Services and Break-glass rows, and what's wrong with the rows left out. A loop's name is
    letters, digits, _ . and -, and not you or nobody, so it is a file name, a ledger key and a graph node as written."""
    md = "\n".join(lines(C["registry"]))
    (registry, b1), (services, b2), (glass, b3) = (table(md, "Registry", "Loop"), table(md, "Services", "Service"),
                                                   table(md, "Break-glass"))
    ok = lambda n: re.fullmatch(r"[A-Za-z0-9_.-]+", n) and n.lower() not in ("you", "nobody")
    b1 += [f"Registry row {r['Loop'][:60]}: a loop name is letters, digits, _ . and -, and not you or nobody" for r in registry if not ok(r["Loop"])]
    return [r for r in registry if ok(r["Loop"])], services, glass, b1 + b2 + b3

FAN_IN = 5  # more loops than this naming you in Checked by is a fan-in warning, which --check prints but doesn't fail on

def links(registry, services, glass, bad=(), health=False):
    """Each registry loop's Checked by, Supervisor and Escalates to, and each break-glass entry's reason. A name is a loop's
    or service's name or its job, with or without the routine:/task: prefix, or you; any other name is kept as written, a
    checker the registry doesn't have. Supervisor, optional, is the one loop that writes this loop's Orders (or you): a
    parent that is no loop, or a chain that comes back to the row, is its supervisor_issue. Escalates to, optional, is
    where the loop sends what needs a person; blank means its project's manager, else the master, else you (always you for the master). Once a loop
    has Role master, only it and the Break-glass table may reach you; escalation_issue says what breaks that. A cycle is
    drawn once, from its first loop by name; the other loops on it, and those whose chain runs into it, name that loop.
    Checked by is checked too (not in health mode, whose rows have none): no reader but itself, a reader that is no loop,
    service or you, readers that only lead round loops (a cycle, or one nobody reads), and you on a loop with a supervisor loop.
    Returns (loops, break-glass reasons by name, issues that belong to no one loop: the `bad` rows tables() left out
    and Break-glass rows that name nothing, and warnings: more than FAN_IN loops read straight by you)."""
    named = [(r["Loop"], r["Job"]) for r in registry] + [(r["Service"], r["Job"]) for r in services]
    alias = {k: n for n, j in named for k in (j, j.partition(":")[2]) if k} | {n: n for n, _ in named}
    resolve = lambda c: "you" if c.lower() == "you" else alias.get(c, c)
    cell = lambda r, k: r.get(k, "").strip()
    reasons = {resolve(cell(g, "Who")): cell(g, "Why") for g in glass if cell(g, "Who")}
    roles = {r["Loop"]: cell(r, "Role").lower() or None for r in registry}
    projects = {r["Loop"]: r.get("Project", "") for r in registry}
    masters = [l for l, k in roles.items() if k == "master"]
    managers = {}
    for loop, k in roles.items():
        if k == "manager": managers.setdefault(projects[loop], []).append(loop)
    def default(loop):
        up = [m for m in managers.get(projects[loop], [])[:1] + masters[:1] if m != loop and roles[loop] != "master"]
        return up[0] if up else "you"
    readers = {r["Loop"]: list(dict.fromkeys(resolve(c.strip()) for c in cell(r, "Checked by").split(",") if c.strip())) for r in registry}
    out = {r["Loop"]: {"checked_by": ", ".join(readers[r["Loop"]]),
                       "supervisor": resolve(cell(r, "Supervisor")) if cell(r, "Supervisor") else None,
                       "role": roles[r["Loop"]], "break_glass": reasons.get(r["Loop"]),
                       "escalates_to": resolve(cell(r, "Escalates to")) if cell(r, "Escalates to") else default(r["Loop"]),
                       "escalates_default": not cell(r, "Escalates to")} for r in registry}
    def cycles(key, what):
        """loop -> what is wrong with its `key` chain, or None. Each loop is walked once."""
        fate, said = {}, {}  # loop -> (the cycle's first loop, the cycle drawn from it) or None; loop -> its issue
        for start in out:
            at, up = {}, start
            while up in out and up not in fate and up not in at: at[up] = len(at); up = out[up][key]
            path = list(at)
            if up in at:
                ring = path[at[up]:]; i = ring.index(min(ring)); ring = ring[i:] + ring[:i]
                fate.update(dict.fromkeys(ring, (ring[0], " → ".join(ring + ring[:1]))))
                said.update({n: f"{what} comes back to it: {fate[n][1]}" if n == ring[0] else f"{what} is in the cycle through {ring[0]}" for n in ring})
                path = path[:at[up]]
            fate.update(dict.fromkeys(path, fate.get(up)))
            said.update(dict.fromkeys(path, fate.get(up) and f"{what} runs into the cycle through {fate[up][0]}"))
        return said
    sup, esc = cycles("supervisor", "supervision"), cycles("escalates_to", "escalation")
    known = set(out) | {s["Service"] for s in services}
    # loops whose readers lead out of the loops (to you, a service or a stranger, flagged on its own); reader -> loops it reads
    reach, reads = {l for l, rs in readers.items() if any(c not in out for c in rs)}, {}
    for l, rs in readers.items():
        for c in rs: reads.setdefault(c, []).append(l)
    todo = list(reach)
    while todo:
        for l in reads.get(todo.pop(), []):
            if l not in reach: reach.add(l); todo.append(l)
    for loop, l in out.items():
        rs = [c for c in readers[loop] if c != loop]
        issues = [f"supervisor {l['supervisor']} is not a loop in the registry" if l["supervisor"] not in {**out, "you": 0, None: 0}
                  else sup[loop]] + ([] if health else [
                  loop in readers[loop] and "Checked by names itself",
                  not rs and "nobody reads it",
                  *(f"checker {c} is not a loop, a service or you" for c in rs if c not in known | {"you"}),
                  rs and loop not in reach and "its checkers never reach you",
                  l["supervisor"] in out and "you" in rs and f"Checked by names you, but {l['supervisor']} supervises it"])
        l["supervisor_issue"] = "; ".join(i for i in issues if i) or None
        project, to = projects[loop], l["escalates_to"]
        issues = [l["role"] not in (None, "master", "manager") and f"role {l['role']} is neither master nor manager",
                  l["role"] == "master" and len(masters) > 1 and f"{len(masters)} loops have Role master; the door to you is one loop",
                  l["role"] == "manager" and len(managers[project]) > 1 and f"{project or 'no project'} has {len(managers[project])} managers",
                  l["break_glass"] == "" and "its break-glass row needs a reason",
                  to not in {**out, "you": 0} and f"escalates to {to}, which is not a loop in the registry",
                  to == "you" and masters and loop not in masters and l["break_glass"] is None
                  and "escalates straight to you; only the master and break-glass loops may",
                  esc[loop]]
        l["escalation_issue"] = "; ".join(i for i in issues if i) or None
    fan = [] if health else [l for l, rs in readers.items() if "you" in rs]
    warn = [f"you: {len(fan)} loops name you in Checked by, more than {FAN_IN}; let a supervisor loop read most of them"] * (len(fan) > FAN_IN)
    loose = list(bad) + [f"{who}: break-glass names no loop or service in the registry" for who in reasons if who not in known] + \
            [f"{who}: its break-glass row needs a reason" for who, why in reasons.items() if who in known - set(out) and not why]
    return out, reasons, loose, warn

def snapshot():
    """<out>/cloud.json, written by a model from the claude.ai API, so any shape: (its time, routines by name, tasks by
    id), each item reduced to the fields the builder reads, in the types it reads them as."""
    try: s = json.loads((C["out"] / "cloud.json").read_text(errors="replace"))
    except (OSError, ValueError, RecursionError): s = {}
    s = s if isinstance(s, dict) else {}
    items = lambda key, id: {n: {
        "id": name(r.get("id")), "enabled": bool(r.get("enabled")), "cron": r.get("cron") if isinstance(r.get("cron"), str) else None,
        "next_run_at": when(r.get("next_run_at")), "last_finished_at": when(r.get("last_finished_at")),
        "last_status": None if r.get("last_status") is None else str(r["last_status"]).lower()[:100]}
        for r in (s.get(key) if isinstance(s.get(key), list) else []) if isinstance(r, dict) for n in [name(r.get(id))] if n}
    return when(s.get("at")), items("routines", "name"), items("tasks", "id")

def build():
    now = when(os.environ.get("FLEET_NOW")) or dt.datetime.now().replace(microsecond=0)  # FLEET_NOW replays a past time
    registry, services, glass, bad = tables()
    jobs = fixture_jobs(C["jobs"]) if C["jobs"] else {**launchd_jobs(), **cron_jobs()}
    led, first = ledger(now)
    snap_at, routines, tasks = snapshot()
    snap_age_h = (now - snap_at).total_seconds() / 3600 if snap_at else None
    health = not registry and not services  # no registry: show every job's own health, nothing a registry would add
    if health: (registry, services), glass = discovered(jobs, routines, tasks, led, (now - dt.timedelta(days=7)).isoformat()), []
    link, reasons, loose, warn = links(registry, services, glass, bad, health)
    window_from = max(first or now.date().isoformat(), (now - dt.timedelta(days=WINDOW)).date().isoformat())
    rows, claimed = [], set()
    gh = C["waiting"].get("github") or {}
    roots = checkouts(gh.get("owner"), tuple(gh.get("memo_roots", ())))

    def iso(t): return t.isoformat(timespec="minutes") if t else None

    for reg in registry:
        loop, job = reg["Loop"], reg["Job"]
        claimed.add(job)
        kind, _, ref = job.partition(":") if job.startswith(("routine:", "task:")) else ("local", "", job)
        ref = ref or job
        override = re.search(r"`([\d*,\-/ ]+)`", reg.get("Schedule", ""))
        row = {"loop": loop, "project": reg.get("Project", ""), "runtime": reg.get("Runtime", ""), "job": job,
               "schedule": (reg.get("Schedule", "").replace(override.group(0), "") if override else reg.get("Schedule", "")).replace("`", "").strip(" ()"),
               "last_run": None, "result": None, "detail": "", "next_due": None,
               "pass_rate": None, "checks": None, "cost": None, "status": None, **link[loop]}
        spec, live, j, item = None, True, None, None
        if kind == "local":
            j = jobs.get(ref)
            live = (health and not ref) or bool(j and j["loaded"])  # with no registry, a ledger name is live while it logs
            spec = j and j["spec"]
            if j and j["interval"]: row["next_due"] = every(j["interval"])
        else:
            item = (routines if kind == "routine" else tasks).get(ref)
            live = bool(item and item.get("enabled"))
            if item and item["cron"]: spec = cron_spec(item["cron"])
            if item: row["next_due"] = iso(item["next_run_at"])
            if item and item["last_finished_at"] and loop not in led:
                row["last_run"] = iso(item["last_finished_at"])
                row["result"] = None if item["last_status"] == "running" else "pass" if item["last_status"] == "succeeded" else "fail"
                row["detail"] = f"routine run {item['last_status']}"
        row.update(definitions(reg, kind, ref, item, roots), **job_links(j))
        if override: spec = cron_spec(override.group(1), both=True)
        if spec and not (row["next_due"] and kind != "local"):
            row["next_due"] = iso(nth(fires(spec, now, 1), 0))
        if not spec and not row["next_due"]:
            row["next_due"] = "on event"
        check = check_of(loop)
        if loop in led:
            l = led[loop]
            row.update(last_run=l["last"][:16], result="pass" if l["last_ok"] else "fail", detail=l["detail"],
                       pass_rate=round(l["passes"] / l["total"], 3) if l["total"] else None,
                       checks=f"{l['passes']} of {l['total']}", cost=l["cost"], history=l["history"])
            if l["chronic"]: row["detail"] = f"{l['fails7']} checks failed. " + row["detail"]
        elif check:  # loops that don't log (cloud routines): the builder runs their plain check
            c = subprocess.run([sys.executable, str(check)], capture_output=True, text=True, errors="replace")
            row["result"] = "pass" if c.returncode == 0 else "fail"
            row["detail"] = " ".join((c.stdout or c.stderr).split())[:200]
        elif j and j.get("exit") is not None:  # nothing logged: launchd's last exit and its log file's time
            row.update(result="pass" if j["exit"] == 0 else "fail", last_run=iso(j["log_at"]),
                       detail=f"last run exited {j['exit']}" + ("" if j["log_at"] else "; it has no log file, so when it last ran is unknown"))
        elif j and j.get("log_at"):  # cron: no exit code, only the time its output file last changed
            row.update(last_run=iso(j["log_at"]), detail="cron keeps no exit codes; last run is when its output file last changed")
        elif j and j.get("has_log") is False:
            row["detail"] = ("its output file's name is worked out as it runs, so when it last ran is unknown" if j.get("unset") == "$" else
                             f"its output file uses {j['unset']}, which the crontab doesn't set, so when it last ran is unknown" if j.get("unset") else
                             "cron keeps no record of runs: send this line's output to a file (>> file 2>&1) to see when it last ran")
        checked = (loop in led and led[loop]["has_checks"]) or bool(check)
        late = False
        if spec and row["last_run"]:
            prev1, prev2 = nth(fires(spec, now, -1), 0), nth(fires(spec, now, -1), 1)
            late = bool(prev1 and prev2) and now - dt.datetime.fromisoformat(row["last_run"]) > (prev1 - prev2) + dt.timedelta(hours=12)
        elif j and j["interval"] and row["last_run"]:  # three periods, at least an hour
            late = now - dt.datetime.fromisoformat(row["last_run"]) > max(dt.timedelta(seconds=3 * j["interval"]), dt.timedelta(hours=1))
        if item and live and item["next_run_at"] and snap_at and item["next_run_at"] < snap_at - dt.timedelta(hours=1):
            late = True  # claude.ai still had this run due an hour before the snapshot
        if health and late and j and loop not in led and not check:  # an old log is no proof: scripts often log elsewhere
            row.update(last_run=None, detail="; ".join(filter(None, [row["detail"], f"its log last changed {j['log_at']:%d %b}, so when it last ran is unknown"])))
            late = False
        row["status"] = ("paused" if row.pop("charter_paused")
                         else "stale" if kind != "local" and (snap_age_h is None or snap_age_h > STALE_SNAPSHOT_H)
                         else "missing" if kind != "local" and not item
                         else "paused" if not live
                         else "failing" if row["result"] == "fail"
                         else "silent" if late
                         else ("no record" if j and j.get("has_log") is False else "no runs yet") if not row["last_run"] and not row["result"]
                         else "chronic" if loop in led and led[loop]["chronic"]
                         else "healthy" if checked
                         else "no record" if health and j and not row["last_run"]  # an exit code with no time: not on schedule
                         else "ran" if health
                         else "no check")
        if row["status"] in ("paused", "missing"): row["next_due"] = None  # it won't run
        if row["status"] == "missing": row["detail"] = f"no {kind} named {ref} in the claude.ai snapshot: deleted or renamed there?"
        rows.append(row)

    for svc in services:
        claimed.add(svc["Job"])
        j = jobs.get(svc["Job"], {})
        rows.append({"loop": svc["Service"], "project": "Service", "runtime": "mac", "job": svc["Job"],
                     "schedule": svc.get("What it is", ""), "break_glass": reasons.get(svc["Service"]), **job_links(j),
                     "status": "missing" if not j else "paused" if not j.get("loaded") else "service" if j.get("exit") in (0, None) else "failing",
                     "detail": f"last run exited {j['exit']}" if j.get("exit") not in (0, None)
                               else f"nothing on this machine runs a job named '{svc['Job']}'" if not j else ""})

    for label, j in jobs.items():
        if label in claimed or j["vendor"] or not j["loaded"]: continue
        runtime = "cron" if label.startswith("cron:") else "mac"
        if j["oneoff"]:
            rows.append({"loop": label, "project": "One-off", "runtime": runtime, "job": label, "status": "one-off", **job_links(j),
                         "next_due": iso(nth(fires(j["spec"], now, 1, days=400), 0)), "schedule": "yearly, unless it removes itself after it runs"})
            continue
        rows.append({"loop": label, "project": "Unregistered", "runtime": runtime, "job": label, "status": "unregistered", **job_links(j),
                     "next_due": iso(nth(fires(j["spec"], now, 1), 0)) if j["spec"] else None,
                     "schedule": ("crontab line" if runtime == "cron" else "launchd job") + " in no registry or services row"})
    for name, r in routines.items():
        if f"routine:{name}" not in claimed and r.get("enabled") and (r.get("cron") or r.get("last_finished_at")):
            rows.append({"loop": name, "project": "Unregistered", "runtime": "cloud", "job": f"routine:{name}",
                         "status": "unregistered", "schedule": r.get("cron") or "on event"})
    for tid, t in tasks.items():
        if f"task:{tid}" not in claimed and t.get("enabled"):
            rows.append({"loop": tid, "project": "Unregistered", "runtime": "app", "job": f"task:{tid}",
                         "status": "unregistered", "schedule": t.get("cron") or ""})
    names = {r["loop"] for r in rows}
    week = (now - dt.timedelta(days=7)).isoformat()
    for loop, l in led.items():
        if loop not in names and l["last"] >= week:
            rows.append({"loop": loop, "project": "Unregistered", "runtime": "?", "job": "", "status": "unregistered",
                         "last_run": l["last"][:16], "schedule": "logs to the ledger with no registry row"})
    of = scoping(registry)
    for r in rows: r["scope"] = of(r["project"])[1]
    keys = ["loop", "project", "scope", "runtime", "job", "schedule", "status", "last_run", "result", "detail",
            "next_due", "pass_rate", "checks", "cost", "history", "checked_by", "supervisor", "supervisor_issue",
            "role", "escalates_to", "escalates_default", "break_glass", "escalation_issue",
            "charter", "orders", "prompt", "runner", "report", "log", "floor", "target"]
    rows = [{k: r.get(k) for k in keys} for r in rows]

    meta = [{"label": "Built", "value": now.isoformat(timespec="minutes")},
            {"label": "Mode", "value": "health" if health else "fleet"},
            {"label": "Pass rate and cost window", "value": f"{window_from} to {now.date()}" + (f" (the ledger starts {first})" if first else " (no ledger yet)")},
            {"label": "Routine snapshot", "value": snap_at.isoformat() if snap_at else "none"},
            {"label": "Cost", "value": "Claude API-equivalent estimate from the ledger; loops that don't run through claude-run aren't metered"},
            {"label": "Refresh", "value": C["refresh"]},
            {"label": "Registry", "value": None if health else str(C["registry"]).replace(str(Path.home()), "~")},
            {"label": "Builder", "value": str(Path(__file__).resolve()).replace(str(Path.home()), "~")},
            {"label": "uid", "value": str(os.getuid())}]
    items = waiting(now, of, loose + warn)
    changes = improvements({r["loop"]: r.get("scope") or "General" for r in rows})
    write("loops", rows, meta)
    write("waiting", items, meta[:1])
    write("changes", changes, meta[:1])
    html(rows, items, meta, "Loop health" if health else "Loop fleet", changes)
    return rows

# --- what waits on you

def short(text, cap=72):
    """A scannable title: parentheticals and trailing dates out, cut at the first clause break, then at a word."""
    t = re.sub(r"\s*\([^)]*\)", "", text).strip()
    t = re.sub(r"\s*By \d{4}-\d{2}-\d{2}\.?$", "", t)
    t = re.split(r"; | — |\. (?=[A-Z])|(?<=\?) ", t)[0].rstrip(".")
    head = t.split(": ", 1)[0]
    t = head if len(head) >= 15 and head != t else t
    return t if len(t) <= cap else t[:cap].rsplit(" ", 1)[0] + "…"

@functools.cache
def checkouts(owner, roots):
    """Repo name -> its checkouts, for the GitHub repos (of owner, when given) under the roots."""
    seen = {}
    for root in (Path(r).expanduser() for r in roots):
        for g in root.glob("**/.git"):
            if "node_modules" in g.parts or len(g.relative_to(root).parts) > 5: continue
            url = subprocess.run(["git", "-C", str(g.parent), "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
            m = re.search(rf"github\.com[:/]{re.escape(owner) if owner else '[^/]+'}/([^/.]+)", url)
            if m: seen.setdefault(m.group(1), []).append(g.parent)
    return seen

def memo_items(owner, repo, path, cfg):
    """Open decisions in a checkout's docs/ on its default branch: bullets under a `decisions` heading (closed once
    every `**Decision:**` line is filled), and table rows whose last cell is the `awaiting` status."""
    heading, awaiting = cfg.get("decisions", "Founder decisions"), cfg.get("awaiting", "Awaiting founder")
    subprocess.run(["git", "-C", str(path), "fetch", "-q", "origin"], capture_output=True)
    ref = git(path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD") or "origin/main"
    hits = subprocess.run(["git", "-C", str(path), "grep", "-l", "-i", "-e", heading, "-e", awaiting, ref, "--", "docs"],
                          capture_output=True, text=True).stdout.split()
    items = []
    for hit in hits:
        file = hit.split(":", 1)[1]
        text = re.sub(r"^```.*?^```", "", subprocess.run(["git", "-C", str(path), "show", hit], capture_output=True, text=True, errors="replace").stdout,
                      flags=re.M | re.S)  # templates in fenced blocks aren't open decisions
        link = f"https://github.com/{owner}/{repo}/blob/{ref.split('/', 1)[1]}/{file}"
        src = {"kind": "Memo decision", "tag": "Decision", "source": f"{repo} · {Path(file).stem}", "where": f"{repo}/{file}", "link": link, "repo": repo}
        sec = re.search(rf"^#+ {re.escape(heading)}\s*\n(.*?)(?=^#|\Z)", text, re.M | re.S | re.I)
        decisions = re.findall(r"\*\*Decision:\*\*[ \t]*(.*)", text)  # a blank one is open
        answered = decisions and all(d.strip() and d.strip() != "approve / reject / defer" for d in decisions)
        for line in (sec.group(1).splitlines() if sec and not answered else []):
            if line.lstrip().startswith(("- ", "* ")):
                item = line.lstrip()[2:].strip()
                due = re.search(r"\bBy (\d{4}-\d{2}-\d{2})", item)
                items.append({**src, "item": item, "due": due.group(1) if due else None})
        rows = [l.strip("| ").split("|")[0].strip().replace("`", "") for l in text.splitlines()
                if l.startswith("|") and re.search(rf"\|\s*{re.escape(awaiting)}\s*\|?\s*$", l, re.I)]
        if rows:
            items.append({**src, "title": f"{len(rows)} items in {Path(file).stem} await your call",
                          "item": f"{len(rows)} rows awaiting your call: " + "; ".join(rows),
                          "action": "mark each row's decision", "due": None})
    return items

def waiting(now, of, issues=()):
    """Everything waiting on you, what's wrong in the registry too."""
    cfg = C["waiting"]
    items = [{"kind": "Registry", "source": "Registry", "tag": "To do", "item": i, "action": "fix the registry", "where": "registry",
              "due": None} for i in issues]
    q = cfg.get("queue")
    for line in lines(Path(q["path"]).expanduser()) if q else []:
        f = cells(line, outer=False)
        f = f[1:-1] if len(f) == 9 and not f[0] and not f[-1] else f  # written as a markdown table
        if len(f) != 7 and not re.match(r"\|?\s*\d{4}-\d\d-\d\d", line.strip()) or f[0].lower() == "due": continue  # prose, header, separator
        if len(f) != 7:
            items.append({"kind": "Queue", "source": "Queue", "tag": "To do", "title": "A queue line that can't be read",
                          "item": line.strip(), "action": "give it the 7 cells (a | in a cell is \\|)", "where": "queue",
                          "link": q.get("link"), "due": None})
        elif f[3].lower() == q["owner"].lower():
            items.append({"kind": "Queue", "source": "Queue", "item": f[2], "action": f[4], "where": f"queue ({f[1]})",
                          "tag": "Decision" if f[1] == "decision" or f[4].lower().startswith(("decide", "pick")) else "To do",
                          "link": q.get("link"), "due": f[0]})
    gh = cfg.get("github")
    if gh and GH:
        res = subprocess.run([GH, "search", "prs", "--owner", gh["owner"], "--label", gh.get("label", "founder"), "--state", "open",
                              "--json", "repository,number,title,createdAt,url", "--limit", "100"], capture_output=True, text=True)
        for p in json.loads(res.stdout) if res.returncode == 0 else []:
            items.append({"kind": "PR", "tag": "PR review", "source": f"{p['repository']['name']}#{p['number']}",
                          "item": p["title"], "action": "review: merge or close",
                          "where": f"{p['repository']['nameWithOwner']}#{p['number']}", "link": p["url"], "due": None,
                          "repo": p["repository"]["name"],
                          "since": p["createdAt"][:10]})
        if gh.get("memo_roots"):
            for repo, paths in sorted(checkouts(gh["owner"], tuple(gh["memo_roots"])).items()):
                items += memo_items(gh["owner"], repo, paths[0], gh)
    keys = ["title", "tag", "source", "kind", "item", "action", "where", "link", "due", "since"]
    return sorted(({**{k: i.get(k) for k in keys}, "title": i.get("title") or short(i["item"]),
                    **dict(zip(("project", "scope"), of(i.get("repo"))))} for i in items),
                  key=lambda i: (i["due"] or "9999", i["kind"]))

# --- output

def write(name, rows, meta):
    C["out"].mkdir(parents=True, exist_ok=True)
    (C["out"] / f"{name}.json").write_text(json.dumps({"rows": rows, "meta": meta}, indent=1, ensure_ascii=False) + "\n")

def html(rows, items, meta, title, changes=()):
    """The same page the claude.ai dashboard runs, with a local stand-in for its runtime and the data inlined."""
    data = json.dumps({"loops": {"rows": rows, "meta": meta}, "waiting": {"rows": items, "meta": meta[:1]},
                       "changes": {"rows": list(changes), "meta": meta[:1]},
                       "look": json.loads((ROOT / "dashboard/look.json").read_text()),
                       "params": json.loads((ROOT / "dashboard/params.json").read_text())}, ensure_ascii=False).replace("<", "\\u003c")  # no </script> or <!-- can end the script
    page = (ROOT / "dashboard/index.html").read_text()
    shim = (ROOT / "dashboard/local.js").read_text()
    (C["out"] / "dashboard.html").write_text(
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        f'<title>{title}</title></head><body>\n<script>window.FLEET = {data};</script>\n<script>{shim}</script>\n'
        f'<div id="dash-root">\n{page}\n</div>\n</body></html>\n')

if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:  # registry only, for an outcome check: every "loop: issue" on one line, exit 1 if any;
        registry, services, glass, bad = tables()  # then each warning on its own line, which doesn't fail
        loops, _, loose, warn = links(registry, services, glass, bad)
        issues = [f"{loop}: {i}" for loop, l in loops.items() for i in (l["supervisor_issue"], l["escalation_issue"]) if i] + loose \
                 or ([] if registry else [f"no Registry rows in {C['registry']}"])
        if issues: print("; ".join(issues))
        for w in warn: print(f"warning: {w}")
        sys.exit(bool(issues))
    rows = build()
    counts = {}
    for r in rows: counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(json.dumps(counts), "->", C["out"] / "dashboard.html")
