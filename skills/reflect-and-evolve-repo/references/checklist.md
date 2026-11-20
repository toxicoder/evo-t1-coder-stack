# Reflect and Evolve (Repo) - Working Checklist for the Repository

Read this before proposing anything, and again when the evidence is ambiguous. Every item names the command or path that answers it; a check you did not run is not evidence. The subject here is the repository: its code, scripts, docs, configs, and conventions. For the agent system that wraps it, use `skills/reflect-and-evolve/references/checklist.md`.

## Evidence checklist

- Working state and whatever is already half-landed, before anything else: `git status --short`, `git log --oneline -20`
- Branch hygiene against the trunk-based rule, newest first, so a stale work branch is a finding and not a surprise:
  `git for-each-ref --sort=-committerdate refs/heads | head -10`
- The rulebook that scopes the files you may touch, root and nested, not just the top file:
  `head -n 60 AGENTS.md`, `ls .grok/rules/*.md`
- The conventions page and the docs page that already owns the area, so the rule lands where a reader already looks:
  `head -n 40 docs/project-conventions.md`, `ls docs/*.md docs/operate/ docs/contribute/ docs/workflows/`
- The ranked session table, and the only sanctioned way into `~/.grok/sessions/`:

      python3 skills/reflect-and-evolve/scripts/session_signals.py \
        [--home DIR] [--repo PATH] [--limit N] [--since DAYS] [--json]

  Defaults: `--home` is `$GROK_HOME` else `~/.grok`, `--repo` the cwd, `--limit` 20, `--since` 90.
  It reads the store's summary documents and prints counts and titles; nothing in this page authorizes reading a transcript.
- The gate baseline, run now, so a later red is yours or is not: `bazelisk test //:test-fast`,
  `bazelisk test //:lint --test_tag_filters=manual`
- The operator CLIs and the suites that already cover them, so a check extends a script that exists instead of starting a new one:
  `ls scripts/*.sh`, `ls tests/bats/`
- What no Bazel target owns yet: `bazelisk run //scripts:bazel-map -- scope --untracked`. A file no filegroup claims answers
  `warning: the graph does not know <path>: no target declares it (a new file reaches the harness through a filegroup)`, which is
  the finding, not a broken command.
- The same question for a whole directory, then for one file: `bazelisk run //scripts:bazel-map -- unlisted docs`,
  `bazelisk run //scripts:bazel-map -- owners <path>`
- The twin a template payload file owes, so a change to one copy is never the whole change:
  `bazelisk run //scripts:bazel-map -- twins <path>`
- The last reflection's leftovers, and the scratch every later command here writes into, so create it once:
  `mkdir -p /tmp/reflect-and-evolve-repo`, `ls /tmp/reflect-and-evolve-repo/ 2>/dev/null` (silence after that mkdir means no
  leftovers; before it, silence also means the path is wrong)
- Hard limits, binding on every read above: never `cat` a `chat_history.jsonl`, `prompt_history.jsonl`, or `events.jsonl`; derive
  the `%2F`-escaped session directory with `ls ~/.grok/sessions/`, never by retyping it; cap every read with `head -n`, `--limit`,
  or a `/tmp` scratch file.
- Never list, read, or cite `/var/lib/grok-session-archive`. `.env` and `.env.*` are agent-denied: name the CLI that prints the
  value (`bazelisk run //scripts:dev-stack -- status`, `//scripts:bootstrap -- --check`, `//scripts:update-configs`) or read
  `.env.example` for the key's shape.

## Signal reading

Rank friction by what it says about the repository, never by its size, and read the table in the sweeper's own order: the score
`2*toolFailureCount + 2*errorCount + regenerationCount + compactionCount` descending, then recency. The columns print as
`sid8 title turns tools toolfail errors regen compaction ctx% age`. The top row is a candidate, not a verdict.

- Edits that keep landing in the same file, which is where a missing abstraction, a missing helper, or a missing convention lives:
  `git log --since=30.days --name-only --pretty=format: | grep -v '^$' | sort | uniq -c | sort -rn | head -10`. Discount the
  registries everyone must touch (`tests/BUILD.bazel`, a barrel, a render) and read what is left.
- A repeated user correction about a convention outweighs any count, so count the repeats off the `title` each `--json` row carries:
  `python3 skills/reflect-and-evolve/scripts/session_signals.py --repo . --json --limit 30 >
  /tmp/reflect-and-evolve-repo/signals.json` then
  `grep -o '"title": "[^"]*"' /tmp/reflect-and-evolve-repo/signals.json | sort | uniq -c | sort -rn | head -10`
- A gate that goes red twice for one cause is one finding with two rows, not two findings. Name the repeated `FAILED` label, read
  that suite's log once: `bazelisk test "//tests:bats_<stem>_test" --test_output=errors` (substitute the suite stem, dashes to
  underscores; the quotes keep the label one word).
- Many tool calls over few turns on one question is a manual procedure every session re-performs: the row is the evidence and the
  fix is a script under `scripts/` with a Bats twin, or one line in the docs page that owns the task. Not a new global rule.
- A directory that returns rows from `bazelisk run //scripts:bazel-map -- unlisted <dir>` is invisible to `//:test-fast` and
  `//:lint`; that is a gate hole before it is ever a code problem.
- Convention drift in the history itself: run both counts over the last thirty subjects and compare them yourself,
  `git log --pretty='%s' -30 | grep -cE '^(feat|fix|docs|test|chore|ci|refactor): '` against
  `git log --pretty='%s' -30 | wc -l` (both numbers are yours; this page pins no value, because one commit makes a printed value
  wrong). Anything short of equal is a candidate `docs/branching.md` problem, and the subjects the first command left out are the
  evidence: `git log --pretty='%s' -30 | grep -vE '^(feat|fix|docs|test|chore|ci|refactor): ' | head`. Read them before ruling
  drift in, since a trunk-based history accounts most of its gap with merge commits.
- One session is an anecdote and three is a pattern: require three distinct `sid8` rows of the same shape before ruling a problem
  in, and list all three in the report.

## Change quality bar

A proposal is made only when all five lines exist; a missing line is a follow-up, not a change.

- Evidence: one sentence, the `sid8` rows and the `path:line` behind it, and every file read to get it, written to
  `/tmp/reflect-and-evolve-repo/findings.md` before any edit.
- Cost removed: the future session cost in the units the table reports (calls, turns, failures, compactions), and what the next
  session stops doing.
- One seam: the one file and section where the rule is read, proven the only home by
  `grep -rn '<the new phrase>' AGENTS.md .grok/rules/ docs/ skills/ templates/` (your phrase in place of the placeholder). Where
  two pages must carry it, one is the source and the other points at it; where a payload has a twin, `-- twins <path>` names the
  second file that moves with it.
- A way to tell it fired: a Bats assertion in the suite that owns the script, or the gate command that goes red without it. Name
  it now: `bazelisk test "//tests:bats_<stem>_test"`, `bazelisk test //:test-fast`,
  `bazelisk test //:lint --test_tag_filters=manual`
- The deletion that comes with it: the owner, the condition that makes it stale, and the command that finds it then. A rule with
  no exit is deleted by surprise.
- Take the cheapest carrier: a line in a docs page the reader already opens, then a helper in `scripts/lib/` that an existing CLI
  sources, then a program under `skills/<name>/scripts/` (stdlib only). No new dependency, gate, platform, or Kubernetes.
- One branch per change, cut off the tip of `main` before the first edit, with its own commit and its own proof command.

## What not to do

- Widening a gate instead of steering the work: never relax a Bazel target, a lint filter, a `# shellcheck disable`, or a hook to
  make a run pass. Fix the source, or report the gate itself as the finding.
- Hand-editing a workspace copy of a seed: anything under `~/.grok/` carrying the `managed-by: evo-t1-coder-stack` marker is
  rewritten on the next boot. Edit the seed under `templates/common/` and re-materialize it.
- Editing a render instead of its source: `proxy/router.conf` and `proxy/router.gen.conf` are generated; edit
  `proxy/router.conf.template` or the naming keys in `scripts/lib/domain.sh`.
- Reading `.env` or `.env.*`, or listing, reading, or citing `/var/lib/grok-session-archive`: the deny has no exception and the
  archive is never a source of state.
- Dumping session JSON into the transcript: no `cat` of `chat_history.jsonl`, `prompt_history.jsonl`, or `events.jsonl`; select
  with `--limit`, `head -n`, or a `/tmp` scratch file, and clear it when done.
- A new dependency, framework, CI system, or Kubernetes anything: the runtime stays `docker compose` and LiteLLM stays the sole
  model transport.
- A first-party `CHANGELOG.md`: this repo keeps none, so the record is the commit message and the pull request body.
- A reflection that changes five unrelated small things: one change per branch with its own proof; the other four findings are
  rows in the report.

## Run report

Step 5 of the body closes with this. Copy the skeleton, fill every cell, and quote command output rather than paraphrasing it.

    ## Reflection (repo) - <YYYY-MM-DD> <repo>
    Evidence reviewed: <sessions scanned, with the --limit and --since used; git range, hot files, gate baseline, rulebook and docs pages read>
    Problems found:
    | # | Signal | Sessions (sid8) | Files (path:line) | Count | Ruled in/out and why |
    Changes made:
    | Path | Change | Seam that reads it | Proof command | Result |
    Gates: <exact command> -> <summary line, quoted>
    Follow-ups deferred: <finding> -- <why it waits, and the count that promotes it>
    Not doing: <rejected change> -- <reason>

- Every Proof command row is a command you ran in this session, with its real output line; name what you did not check rather than
  leaving a confident blank.
- Append the report to `~/.grok/notes/<host>/<owner>/<repo>/notes.md` (substitute this clone's own) so the next reflection meets it
  as the leftover inventory, then `find /tmp/reflect-and-evolve-repo -type f -delete 2>/dev/null || true`.
