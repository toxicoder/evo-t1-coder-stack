# Reflect and Evolve - Working Checklist

Read this before proposing anything, and again when the evidence is ambiguous. Every item names the command or path that answers it; a check you did not run is not evidence.

## Evidence checklist

- Rulebook and every nested copy that scopes the files you may touch, not just the top file:
  `ls -l ~/.grok/AGENTS.md AGENTS.md .grok/rules/*.md docs/*.md`
- Skill roster, one purpose each, so a rule does not restate a body that already owns it:
  `grep -m1 -H '^description:' ~/.agents/skills/*/SKILL.md | cut -c1-160 | head -30`
- The ranked session table, the only sanctioned way into `~/.grok/sessions/`:

      python3 skills/reflect-and-evolve/scripts/session_signals.py \
        [--home DIR] [--repo PATH] [--limit N] [--since DAYS] [--json]

  Defaults: `--home` is `$GROK_HOME` else `~/.grok`, `--repo` the cwd, `--limit` 20, `--since` 90.
- `/ez-learn` session logs, newest first, so a fact is not written twice (substitute `<slug>-<hash8>`, which `ls -d ~/.grok/memory/*/` prints):
  `ls -t ~/.grok/memory/<slug>-<hash8>/sessions/ | head -10`

### Notes, config, and the checks that already exist

- Notes file and code index for this clone, with `<host>/<owner>/<repo>` substituted by this clone's own:
  `tail -n 60 ~/.grok/notes/<host>/<owner>/<repo>/notes.md`, `head -n 10 ~/.grok/notes/<host>/<owner>/<repo>/code-index.md`
  No index until you build it: `python3 ~/.agents/skills/ez-code-index/scripts/code_index.py --repo .` writes `code-index.json` and `code-index.md` beside that notes file, and its header carries the `sha` it was built from, to compare with `git rev-parse HEAD`.
- Agent config and the guards that wrap every tool call: `head -n 60 ~/.grok/config.toml`,
  `ls ~/.grok/hooks/bin/`, `head -n 40 ~/.grok/hooks/bin/deny-patterns.txt`
- Operator CLIs and the coverage they already carry, so a check is extended and not invented:
  `ls scripts/*.sh`, `bazelisk run //scripts:bazel-map -- scope --untracked`
- The last reflection's leftovers, and the scratch every later command here writes into, so create it once:
  `mkdir -p /tmp/reflect-and-evolve`, `ls /tmp/reflect-and-evolve/ 2>/dev/null` (silence after that mkdir means no leftovers; before it, silence also means the path is wrong),
  `git status --short`, `git for-each-ref --sort=-committerdate refs/heads | head -10`
- The gate baseline, run now, so a later red is yours or is not: `bazelisk test //:test-fast`,
  `bazelisk test //:lint --test_tag_filters=manual`

### Limits binding on every read

- Hard limits, binding on every read above: never `cat` a `chat_history.jsonl`, `prompt_history.jsonl`, or `events.jsonl` into the
  transcript; derive the `%2F`-escaped session directory with `ls ~/.grok/sessions/`, never by retyping it; cap every read with
  `head -n`, `--limit`, or a `/tmp` scratch file.
- Never list, read, or cite `/var/lib/grok-session-archive`. `.env` and `.env.*` are agent-denied: name the CLI that prints the value
  (`bazelisk run //scripts:dev-stack -- status`, `//scripts:bootstrap -- --check`, `//scripts:update-configs`) or read
  `.env.example` for the key's shape.

## Signal reading

Rank friction by what it says about the system, never by its size, and read the table in the sweeper's own order: `2*toolFailureCount + 2*errorCount + regenerationCount + compactionCount` descending, then recency.

The top row is a candidate, not a verdict.

### Reading each signal

- A high `toolFailureCount` concentrated in one tool name is a guard, a hook, or a missing rule. Take counts and titles only, never a
  message body: `python3 skills/reflect-and-evolve/scripts/session_signals.py --json --limit 30 >
  /tmp/reflect-and-evolve/signals.json`, then `head -c 2000` of it.
- A repeated user correction outweighs any count, so count the repeats off the `title` each `--json` row carries:
  `grep -o '"title": "[^"]*"' /tmp/reflect-and-evolve/signals.json | sort | uniq -c | sort -rn | head -10`
- A high `errorCount` over a quiet tool log is the model layer or the lane, not the rulebook: check the pins in
  `~/.grok/config.toml` and the fleet queue before writing prose about it.
- A high `regenerationCount` with few tool calls means the answer missed the ask: the fix is a scope or definition rule in the body
  that owns that task, not a new global rule.
- A high `compactionCount`, or a `ctx%` at the top of the range the store really holds (live values run 0 to about 75 and never near 100), is an output-budget failure: some page told a session to read without a cap. Put the cap on that page.

### Ruling a pattern in

- One session is an anecdote and three is a pattern: require three distinct `sid8` rows of the same shape before ruling a problem in,
  and list them in the report.
- Many tool calls on one question with zero failures is a mapping job that should have been a child; the rule to write names the
  delegation in the page that gave that order.

## Change quality bar

A proposal is made only when all five lines exist.

A missing line is a follow-up, not a change.

- Evidence: one sentence, the `sid8` rows behind it, and the path of every file read to get it, written to
  `/tmp/reflect-and-evolve/findings.md` before any edit.
- Cost removed: the future session cost in the units the table reports (calls, turns, failures, compactions), and what the next
  session stops doing.
- One seam: the one file and section where the rule is read, proven the only home by `grep -rn '<the new phrase>' ~/.grok/AGENTS.md
  AGENTS.md .grok/rules/ skills/ templates/common/` (your phrase in place of the placeholder); where two pages must carry it, one is the source and the other points at it.
- A way to tell it fired: a Bats assertion, a gate command, or a greppable marker a later session leaves behind. Name it now:
  `bazelisk test "//tests:bats_<stem>_test"` (substitute the suite stem; the quotes keep the label one word), `bazelisk test //:test-fast`
- The deletion that comes with it: the owner, the condition that makes the rule stale, and the command that finds it then. A rule
  with no exit is deleted by surprise.

### The cheapest carrier

- Take the cheapest carrier: a line in a page the agent already reads, then a helper in a script that exists, then a program under
  `skills/<name>/scripts/` (stdlib only). No new dependency, gate, or platform.
- Ship the `~/.agents/skills/<name>/SKILL.md` and `.grok/skills/<name>/SKILL.md` pair together, edit a stack-owned page under
  `templates/common/` and re-materialize it, and let docs and tests move with the behaviour.

## What not to do

- A rule that restates a rule: search with `grep -rin '<key phrase>' ~/.grok/AGENTS.md AGENTS.md .grok/rules/ skills/
  templates/common/` (your phrase in place of the placeholder) and tighten the line that already answers it.
- Prose where a script belongs, and a script where one line is enough: a step every run performs verbatim is a script, and a
  three-line fix does not earn two hundred lines of Python.
- Widening a gate instead of steering the agent: never relax a Bazel target, a lint filter, or a hook to make a run pass; put the
  rule where the agent reads it.

### Reads and seeds you may not touch

- Hand-editing a workspace copy of a seed: anything under `~/.grok/` carrying the `managed-by: evo-t1-coder-stack` marker is
  rewritten on the next boot. Edit the seed and re-materialize it.
- Reading `.env` or `.env.*`, or listing, reading, or citing `/var/lib/grok-session-archive`: the deny has no exception and the
  archive is never a source of session state.
- Dumping session JSON into the transcript: no `cat` of `chat_history.jsonl`, `prompt_history.jsonl`, or `events.jsonl`; select with
  `--limit`, `head -n`, or a `/tmp` scratch file, and remove it when done.
- A reflection that changes five unrelated small things: one change per branch with its own proof; the other four findings are rows
  in the report.

## Run report

Step 5 of the body closes with this. Copy the skeleton, fill every cell, and quote command output rather than paraphrasing it.

    ## Reflection - <YYYY-MM-DD> <repo>
    Evidence reviewed: <sessions scanned, with the --limit and --since used; rulebook, roster, notes, config, hooks read>
    Problems found:
    | # | Signal | Sessions (sid8) | Count | Ruled in/out and why |
    Changes made:
    | Path | Change | Seam that reads it | Proof command | Result |
    Gates: <exact command> -> <summary line, quoted>
    Follow-ups deferred: <finding> -- <why it waits, and the count that promotes it>
    Not doing: <rejected change> -- <reason>

### Where the report goes

- Every Proof command row is a command you ran in this session, with its real output line; name what you did not check rather than
  leaving a confident blank.
- Append the report to `~/.grok/notes/<host>/<owner>/<repo>/notes.md` (substituted as above) so the next reflection meets it as the leftover inventory, then `find /tmp/reflect-and-evolve -type f -delete 2>/dev/null || true`.
