---
name: ez-learn
description: "Learn what a session taught and make it durable: extract facts from this conversation into a session log, fold the session logs into organized memory, save one note, or browse and clear what was stored. This is this stack's copy of the upstream Grok Build memory commands /flush, /dream, /remember, and /memory. Use when asked to learn this workspace, remember what was learned, flush or consolidate memory, or tidy up stored notes."
when-to-use: "learn this workspace, remember what we learned, flush memory, consolidate memory, tidy up stored notes"
argument-hint: "[flush|dream|remember <note>|browse|clear]"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded.
     To take a seeded copy over, edit it and delete the stack-owned marker line:
     a marker-free file is user-owned and the seeder leaves it alone
     unless you pass `--force`. A
     deletion is undone - the workspace boot writes the file again whenever it
     is absent, and `refresh-configs` re-seeds an absent target, so the next
     boot restores the stack's copy. To hide the slash command, set
     `disabled = ["ez-learn"]` under `[skills]` in `~/.grok/config.toml`. -->

# Learn: turn a session into durable memory

`/ez-learn` reproduces the four upstream Grok Build commands that persist what a
session learned: `/flush`, `/dream`, `/remember`, and `/memory`. Upstream ships
those as built-ins, not as files on disk: `/flush`, `/dream`, and `/memory` are
entries in the shell's built-in command table and `/remember` is a pager command.
The first three are gated behind cross-session memory, which is **off by default**
and needs a configured memory store before `/flush` and `/dream` even advertise;
`/remember` is the least gated of the four. This skill runs the same two passes from
its own body and lands the same files, so the behaviour is there without turning the
gated feature on: the stack seeds this file instead, and the `ez-` prefix keeps it
clear of the built-in names.

Skill authoring is a different pair. `/ez-create-skill` stands in for `create-skill`,
one of the platform skills upstream serves through the skills bundle and extracts
under `~/.grok/bundled/skills/`. `/ez-skillify` captures the same artifact out of a
session that already worked, and no published source names that command upstream.
That bundle sync wants an x.ai sign-in this stack does not have.
LiteLLM is the sole model transport here, so `~/.grok/bundled/` is never created and
the stack seeds those two files instead.

Run every block below with `run_terminal_command` (Grok Build CLI) or `execute`
(Coder Agents chat agent); a command written inline in this body runs nothing on
its own.

`/ez-learn` stores durable facts. It is not skill authoring: to turn a repeated
procedure into a skill use `/ez-skillify`, and `/ez-create-skill` to scaffold one
from a description. Those two write skill files; this one writes memory files.

## Default: report-only, then apply on request

`/ez-learn` with no argument reports and writes nothing: it prints the resolved
root, the workspace directory name, the session-log files it would fold, and the
exact markdown it proposes to write. Nothing touches disk until you ask for the
subcommand, and a write names the path it touched. Pass `--force` only to
overwrite a memory file whose contents you have already read.

## Step 0 -- resolve the root, the scope, and the gate

    grok_home="${GROK_HOME:-$HOME/.grok}"
    grep -nE '^\[memory(_v2)?\]|^\[compaction\.memory_flush\]' "$grok_home/config.toml" 2>/dev/null || echo "no memory tables set"
    echo "GROK_MEMORY=[${GROK_MEMORY-unset}]"

Memory is **off by default**, and each command's gate is fail-closed. Precedence
is env `GROK_MEMORY` -> CLI flag -> `[memory] enabled` -> remote setting ->
default `false`.

- `GROK_MEMORY=0` or `--no-memory` turns memory off for the whole process and
  nothing can turn it back on inside the session. Report
  `Memory is turned off for this session.`
  and stop; the fix is a new session without the flag.
- `[memory] enabled = true` or `GROK_MEMORY=1` selects the legacy layout.
- `[memory_v2] enabled = true` selects v2 and rescues a `[memory] enabled = false`.
- `/remember` is the least gated; `/flush` and `/dream` need memory enabled,
  because they only make sense if a later session can read back what they wrote.

Root and scope follow the mode:

| Mode | Global scope | Workspace scope |
|---|---|---|
| legacy | `~/.grok/memory/` | `~/.grok/memory/<slug>-<hash8>/` |
| v2 | `~/.grok/memory-v2/global/` | `~/.grok/memory-v2/workspaces/<slug>-<hash8>/` |

v2 keeps `topics/`, `observations/_inbox/`, `archive/`, `memory_state.sqlite`,
`index.sqlite`, and a generated `MEMORY.md` per scope, and never reads or writes
the legacy tree. Only immediate children of `topics/` and `observations/_inbox/`
ending in `.md` count; a deeper nesting is invisible to the index and to dream.

A workspace under an ephemeral path (a `tmp*` directory) is skipped silently: the
upstream log lines are `MEMORY_EPHEMERAL_SKIP: daily log write skipped`,
`... workspace long-term write skipped`, and `... workspace append skipped`. If
you detect that, say so instead of writing.

## Step 1 -- name the workspace directory

The directory is `<slug>-<hash8>`: `slug` is the lowercase repo or directory name
and `hash8` is the first 8 hex chars of a blake3 digest. The hash input is the
normalized `org/repo` from the `origin` remote with any `.git` and trailing slash
stripped; with no git remote it is the canonical absolute cwd. Slug rules:
lowercase, every run of non-`[a-z0-9]` becomes a single `-`, truncated to 40
chars, edge dashes stripped, and empty becomes `workspace`.

    git -C "$PWD" remote get-url origin 2>/dev/null || echo "no origin: hash the canonical cwd"
    ls -1d "$grok_home"/memory*/ 2>/dev/null

Never invent the digest. **Reuse the directory that already exists**: match an
existing `<slug>-*` under the workspace root and use it, so a note you write lands
where the CLI's own writes land. Only when nothing matches do you create one, and
then compute the digest rather than guess it.

## Step 2 -- flush this conversation into a session log

Feed the conversation to this extraction instruction, which is the upstream
`FLUSH_SYSTEM_PROMPT` with its wording kept:

    You are a memory assistant. Extract ALL useful information from this conversation
    that would help you be more effective in future sessions with this user. Write a
    concise markdown summary with ## headers covering:

    - **Decisions & rationale** - what was chosen and why
    - **Technical context** - architecture, APIs, patterns, tools, file paths discussed
    - **Debugging techniques & tools** - external APIs, CLI commands, query patterns,
      investigation workflows, or services discovered or used during debugging
    - **Problems & solutions** - bugs found, how they were fixed, workarounds

    Prioritize reusable mechanisms, rules, and root causes over a narration of the
    task. When project structure matters, name the concrete directories and stable
    repo-relative paths; include an absolute workspace root only when it is
    operationally necessary and appears in the conversation. Copy exact identifiers
    and numerical values only when they appear verbatim in the supplied conversation.
    Never infer a missing value; omit the detail instead.

    Omit any section where there is nothing substantive to report. Do NOT include
    user preferences like OS, shell, or editor - these belong in global memory. Do
    NOT include an ephemeral progress section - transient status is not useful for
    future sessions.

    Respond with NO_REPLY if nothing genuinely useful was learned - a routine task
    that followed standard patterns, brief Q&A, or sessions with no novel decisions
    or discoveries are not worth persisting. Only write content that a future session
    would concretely benefit from.

A second and later flush in the same session uses the delta form: same sections,
but "Extract ONLY information that is NEW since the previous flush", and the
previous flush output is appended under a `--- Previous flush content ---` rule.

Then apply the acceptance rules, in this order, before anything is written:

1. Empty, or a reply that reduces to `noreply` once lowercased with non-alphanumerics
   stripped (`NO_REPLY`, `no reply`, `No-Reply` all match; `no reply needed` does
   not), means `NothingToStore`. Say so and write nothing.
2. Cap the body at 8000 characters, the `max_flush_write_chars` default.
3. A body with no `## ` and no `# ` is `Rejected`: "flush response lacks markdown
   structure (no ## headers)". Do not write a body that fails this.

Dedup before writing: compare the candidate against the chunks already stored and
skip a near-verbatim rephrasing. Upstream embeds and asks sqlite-vec for 3 nearest
neighbours and calls it a duplicate above cosine similarity 0.92 (`[compaction.
memory_flush] semantic_dedup_threshold`, 0.92 when unset). Without an embedding
provider upstream skips dedup entirely, so do the honest equivalent: diff against
the existing sections and drop what is already said.

Write to the workspace session log, created on first flush and appended after:

    ~/.grok/memory/<slug>-<hash8>/sessions/YYYY-MM-DD-<slug>-<sid8>.md

`YYYY-MM-DD` is the UTC date, `sid8` is the first 8 chars of the session id, and
`slug` is short and derived from the first user message. A repeat flush appends
`\n\n---\n\n` then `<!-- flush HH:MM:SS UTC -->` then the body, which is what the
dream pass later splits entries on.

## Step 3 -- dream: fold the session logs into organized memory

Dream is the reflective pass, and it is the step that actually learns.

Read every `sessions/*.md` in the workspace directory **except** the current
session's, sorted by name, plus the existing workspace `MEMORY.md`. Skip scaffold
files: shorter than 500 chars and containing `Auto-populated by dream consolidation`,
`Add project-specific knowledge here`, or `Add any cross-project preferences here`.
Stop adding files once the assembled input reaches 32000 chars, and leave the unread
tail alone so a later pass can reach it.

Apply the upstream `DREAM_SYSTEM_PROMPT`, wording kept:

    You are performing a dream - a reflective pass over memory files. Synthesize
    recent session logs into durable, well-organized memories so future sessions
    orient quickly.

    You will receive the contents of recent session logs. You may also receive an
    existing memory document - merge it with new sessions rather than discarding
    prior knowledge. Your job:

    1. **Merge** related information into coherent topic summaries
    2. **Resolve** contradictions - if a recent session disproves an older fact, keep
       only the current truth
    3. **Convert** relative dates ("yesterday", "last week") to absolute dates
    4. **Discard** ephemeral details:
       - Greetings, meta-commentary, tool output noise
       - Message counts and tool-usage statistics
       - 'Current state' and 'Next steps' sections
       - User preferences already in global memory (OS, shell, editor)
       - Session metadata (dates, message counts)
    5. **Preserve** decisions, rationale, architecture, preferences, and
       problem/solution pairs
    6. **Generalize** task narratives into reusable mechanisms, rules, and root causes
    7. **Ground details** - use stable repo-relative paths for project structure;
       include an absolute workspace root only when operationally necessary and
       present in the session logs. Copy exact identifiers and numerical values only
       when they appear verbatim in the input; omit unsupported details

    Respond with a single markdown document. Use ## headers to separate topics. Each
    topic should be self-contained and useful to a future session that knows nothing
    about the current conversation.

    If the session logs contain nothing worth persisting, respond with NO_REPLY.

Assemble the prompt as `--- Existing Memory (merge with new sessions) ---`, the
existing document capped at 16000 chars, then one
`--- Session: <stem> ---` block per log in sorted order. Cap the finished document
at 16000 chars. No `## ` headers means no write.

Then, in this order:

1. Overwrite `~/.grok/memory/<slug>-<hash8>/MEMORY.md` with the document **as-is**.
   Dream output is not normalized, so its heading structure survives. In v2, patch
   or create `topics/<lowercase-slug>.md` instead - each starting with `# Title`, a
   one-line description under 160 bytes, then `## ` sections - and archive the
   consumed observations rather than deleting them.
2. Delete the session logs you actually consumed, keeping any file modified in the
   last 300 seconds, since a concurrent session may still be appending to it. Never
   delete a log you did not read.
3. Regenerate the v2 `MEMORY.md` index only by full regeneration; it opens with
   `> Generated by Grok. Do not edit this file directly.` and hand-editing it is
   lost on the next pass.

Take a lock before the model pass and skip with `lock held by another process,
skipping` if it is held; the automatic pass also waits for `min_hours` 24 and
`min_sessions` 5, and an explicit dream bypasses those two gates only.

## Step 4 -- one note, the browser, and the purge

`/ez-learn remember <note>` mirrors `/remember`, the one member with a confirmation
step: show the note and get an explicit yes before saving. Normalize it first -
keep the structure if it already starts with `#`; if it is one line the line
becomes the heading; if the first line is at most 80 chars it becomes `## <line>`
over the rest; otherwise it goes under `## Note`. User preferences belong in
**global** memory: legacy appends to `~/.grok/memory/MEMORY.md`, v2 publishes an
observation into the global `observations/_inbox/`. v2 rejects a note over 64 KiB.
Images do not travel with a note.

`/ez-learn browse` mirrors `/memory`: list the files with source, size, and mtime,
and print `No memory files have been recorded yet.` for a genuinely empty store.
An empty list can also mean a listing error, so report the error rather than
presenting a broken store as a fresh one. `/memory` takes no arguments.

`/ez-learn clear` mirrors `grok memory clear`, which is the only destructive
member and defaults to the **workspace** scope. `--workspace`, `--global`, and
`--all` are mutually exclusive. Name what is about to go and confirm:

    The following will be deleted:
      <label>: <path>

    Are you sure? [y/N]

Anything but `y` or `yes` prints `Cancelled.` Expect `Nothing to clear: no memory
files found.`, `  Cleared: <label>`, `Memory cleared.`, and `Memory partially
cleared. Errors:` as separate outcomes.

## Step 5 -- go deeper into past sessions only when asked

The dream pass folds the memory session logs it already owns. Reaching past those
into the raw transcripts is extra depth, and it happens **only when the user asks**
for it, never as a default.

Session transcripts live under `~/.grok/sessions/`, one directory per escaped
working directory, each holding small `summary.json` files beside large
`chat_history.jsonl` and `events.jsonl`. Index the summaries first
(`session_summary`, `num_chat_messages`, `head_branch`) and read only the sessions
that rank. A `jsonl` file is many megabytes: count and select with `jq` or `grep -c`
into a scratch file under `/tmp`, and never paste a transcript into the reply.
Clean the scratch files up when you are done.

What you mine must survive the acceptance rules in Step 2 before it becomes memory.
A fact that only describes the course of a session is not memory; a mechanism, a
rule, or a root cause is.

Two things decide whether a number taken from those transcripts means anything.

The first is where the text actually is. `chat_history.jsonl` keeps assistant
entries with an empty `content` array: the reasoning is in `updates.jsonl`, under
`.params.update.sessionUpdate == "agent_message_chunk"`, at
`.params.update.content.text`. A sweep that opens only `chat_history.jsonl` recovers
the questions and none of the answers.

The second is that counting an error string across transcripts also counts the
stack's own guidance, which quotes the very string it warns about, because that
guidance is re-injected into every conversation. Measured over 271 sessions for
`Unknown Task.model slug`: 106 hits in 83 sessions as raw `grep -c` over
`chat_history.jsonl`, and 30 hits in 8 sessions once the lines carrying the quoted
guidance are dropped - one session alone contributed 18 of the 106. So a count
becomes a claim only after:

1. The session you are in is excluded, and so is every child session you spawned.
   Their prompts carry the literal patterns you are counting.
2. Lines carrying the guidance prose are dropped. Counting inside tool results only
   is the honest form.
3. The method is written beside the number. A count with no method is a guess with
   three digits, and the next reader cannot tell which it is.

A defect a transcript reports described the tree as it was then. Read the current
file before proposing the fix: over that same 271-session sweep, two of the three
candidate fixes were already in the tree, one of them with a comment at the exact
line explaining the bug it prevented.

## Step 6 -- report the same lines upstream reports

Say what happened in the upstream wording, so a user who knows the real commands
recognizes the result.

Flush reports one of:

    Memory flushed through turn N.
    Memory flushed.
    Memory flush did not finish; capture will retry in the background.
    Memory flush failed.
    Memory flush timed out; capture continues in the background.
    Memory is turned off for this session.
    Another memory flush is already running.

Dream reports one of:

    Dream merged N observations into M topics.
    Dream completed.
    Nothing to consolidate.
    Dream is already running; try again when it finishes.
    Dream did not finish; it will retry automatically.
    Dream failed.
    Dream ran in shadow mode; nothing was written.
    Dream cancelled.
    Dream is turned off for this session.

Singularize the merge line (`1 observation`, `3 topics`). A skipped run reports
`skipped: <reason>`.

## Where a correction belongs

Every claim above comes from the upstream Rust source at
`crates/codegen/xai-grok-memory/` and `crates/codegen/xai-grok-shell/src/session/`.
When a claim drifts, fix the seed at `templates/common/ez-learn.SKILL.md` and let
`refresh-configs` re-materialize it; **never edit the copy in a home** - a deletion
is undone by the next boot, so only the seed survives. This command is itself a
seeded skill: the Grok Build CLI reads `~/.agents/skills/<name>/SKILL.md` and the
Coder Agents chat agent reads only `~/.coder/skills/<name>/SKILL.md`, which is why a
skill that serves both consumers ships in both homes. Re-seed with
`bazelisk run //scripts:refresh-configs -- workspace`, prove the change with
`bazelisk test //:test-fast`, and add a Bats assertion in
`tests/bats/ez-learn-skill.bats` that fails when the claim drifts again.

Prove the command is actually wired up with `grok inspect` (or `grok inspect --json`
to read `userInvocable` and the `source` path, which is the file you edited). If a
name collides with a bundled or plugin command, the qualified form `/local:ez-learn`
disambiguates it.

The rest of the repo's conventions live in `README.md` and `docs/`, with
`docs/grok-build-and-agents.md` covering the CLI and its lanes and
`docs/project-conventions.md` covering shell style. Anything in this repository is
answered by reading it; the search lanes answer the outside world only.
