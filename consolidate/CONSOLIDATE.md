# Consolidate: keep what every run reads small, and lose nothing

Loops write every day, and some of what they write is read again on every run: a loop's charter, an agent's memory index. Left alone those only grow. Runs get slower and dearer, and a memory index past the length its tool loads is cut off without a word. Consolidation moves what is past its daily use into an archive file the original links to. It never deletes. A decision or an event that mattered is either still where the run reads it, or one link away.

It isn't a loop of its own. `fleet/fleet.py` measures each file against its budget, with no model, and writes `<out>/weight.json`. Whatever loop does your spare work (a master or queue loop) gets the files that are over, and follows this page for each one, one PR or one folder at a time. Or run it by hand.

## Budgets

Set in `fleet.json` under `budgets`; these are the defaults.

| What | Budget | Why |
|---|---|---|
| A loop's charter (`charter_kb`) | 32 KB | read in full on every run of the loop |
| A report folder (`reports`) | 30 dated files | runs read the latest few, people browse the rest |
| An agent memory index (`index_lines`, `index_kb`) | 150 lines, 20 KB | Claude Code loads the first 200 lines or 25 KB of `MEMORY.md` and drops the rest |

`memory` in `fleet.json` is a list of globs for the indexes to measure, such as `~/.claude/projects/*/memory/MEMORY.md`.

## What moves and what stays

Stays where the run reads it:
- every `mission` block, byte for byte (only its owner changes those);
- every rule, hard limit and step the loop still follows, and every decision still in force, with its date (its full reasoning may move);
- anything a script parses: the `status:` line, the report section and its `YYYY-MM-DD.md` path, the Orders link, any format a check reads.

Moves to the archive, word for word:
- history: what happened when, incidents and their timelines, old numbers;
- experiments that have concluded (the rule they left behind stays);
- rules that were replaced, with the date and what replaced them;
- in a memory index, entries about work that is finished or a project that is gone, and duplicates (keep the better one).

If you can't tell whether something is still in use, it stays. Under budget is the aim, not a reason to move a live rule; a file that can't get under budget safely is reported with why.

## How, by kind

**Charter.** The archive is `<NAME>.archive.md` beside it (`docs/OPS_LOOP.archive.md` for `docs/OPS_LOOP.md`), newest on top, each move under a heading `## Moved YYYY-MM-DD from "<section>"`. The charter keeps one line where the moved text was, or one near the top, linking the archive. One PR per charter, in its repo, graded like any other. Don't consolidate a charter while an improver change on it is still being read; it would muddy the read.

**Report folder.** `git mv` the dated reports older than the newest 30 into `<folder>/archive/`, in a PR whose diff is renames only. Nothing else changes.

**Memory index.** Memory folders aren't in git, so nothing in them is ever deleted. Only the index shrinks, and its lines move word for word; the memory files stay where they are, so every link still works. First choice: group a narrow topic (one side project, one hobby, personal details for forms) into `topic-<name>.md` in the same folder, and leave one index line for it that says when to read it: `- [Garden app](topic-garden.md): 21 memories about the side project; read before working on it`. Those memories are still live, one link away. Only what is over, a finished project or a closed watch, goes to `archive.md`, under a heading with the date, linked by the index's last line: `- [Archive](archive.md): older memories, out of the index; read it when a past decision or event matters`. To merge two duplicate memories, write the merged text into one, then move the other's index line to the archive; both files stay.

## Proof, before you open the PR or call it done

Save each file as it was before you touch it, then run, for every changed file:

```bash
python3 <factory>/consolidate/check.py <before> <after> <archive>
```

It passes only when every line of the old file is still in the new one or in the archive, the `mission` blocks are unchanged, and the new file links the archive. Run it on the archive too, against its old copy, when it already existed: an archive only grows. Put its output line in the PR body or the run's report. A report folder's proof is its diff: renames only.
