---
name: ez-code-index
description: "Build one small local map of a clone -- its top-level symbols and the spread of
  files over the tree -- as JSON for a program and a Markdown page a person reads, filed beside
  that repository's notes file on the per-owner notes volume, so the next session loads a map
  instead of grepping the tree again. Use when asked to build a code index, to say where a
  symbol lives without re-searching, or to hand a fleet a cheap map before it fans out. Run as
  /ez-code-index [repo-path]."
when-to-use: "Use at the start of work in a clone you do not already hold in context, before
  dispatching a mapper child, and whenever a session is about to spend turns on `rg` for what a
  stored map already answers. Skip it for a single file you are editing right now."
argument-hint: "[repo-path] [--limit N] [--json]"
compatibility: "Requires python3 and git (at least one commit and an origin remote, which is
  where the key and the sha come from). Uses rg when it is on PATH, else walks the tree itself."
metadata:
  author: "operator"
  short-description: "Local symbol-and-file map of one clone, beside its notes file"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["ez-code-index"]` under `[skills]`
     in `~/.grok/config.toml`. -->

# Code index

One clone goes in, two artifacts come out, and a later session reads them instead of re-deriving
the tree.

The helper is `scripts/code_index.py` beside this file; the body names the `~/.agents`
path the CLI reads and the seeder keeps a `cp` twin under `~/.coder/skills` for the chat agent.

## Where it lives, and why nothing in the clone changes

    ~/.grok/notes/<host>/<owner>/<repo>/code-index.json   # for a program
    ~/.grok/notes/<host>/<owner>/<repo>/code-index.md     # for a person

The key is the one `notes_repo_key` in `~/.grok/notes-setup.sh` files the notes file under, so the
index lands beside it on the per-owner notes volume (`grok-notes-<owner-id>`) that `shared`
mode mounts into every one of that owner's workspaces -- one build serves all of them.

Nothing is copied into the clone, so `git status` stays clean and no git-ignore change is needed
anywhere.

## Build it

Once per session, or whenever the staleness check below says the map is stale:

    python3 ~/.agents/skills/ez-code-index/scripts/code_index.py --repo <clone>

### The flags it takes

That prints one stdout line, `ok: N files, M symbols -> <dir>/code-index.md`, and takes only four
flags:

- `--repo` (required)
- `--home DIR` for another profile home (a Bats suite points it at a scratch home)
- `--json` to print the whole record instead of the summary line
- `--limit N` to move the symbol cap

### The exit codes

- 0 wrote the index
- 1 the clone is not indexable
- 2 usage

Exit 1 names its reason on stderr (not a git tree, no commit yet, or no origin remote to
take the key from) and that is a finding to report, not a directory to invent. Both files land by
temp-then-rename, and with no `rg` on the box the same skip list drives an `os.walk` instead.

## Read it instead of searching

The rule: read `code-index.md` before you grep. Consult it first when the question is

- "where does X live" -- the symbol list answers it with `path:line`;
- "what calls Y" -- it hands you the shortlist of files worth opening;
- "what is in this directory" -- the two top-directory tables answer it;
- before you dispatch a mapper child -- a loaded map is cheaper than one a child re-derives.

Do a fresh `rg` when the recorded sha no longer matches the working tree, when the question is
about a file you are editing right now, or when the answer has to be exhaustive -- the caps below
make the map a sample, not a list of everything.

## Check staleness first

The banner on both artifacts records the commit the index was built at, so one pair of commands
settles whether a line in it is worth acting on:

    grep -m1 -- '- sha:' ~/.grok/notes/<host>/<owner>/<repo>/code-index.md
    git -C <clone> rev-parse HEAD

Equal: the map is current. Different: rebuild it, then read it.

The banner also carries:

- the UTC build time
- the file and symbol counts
- the tool version
- whether `rg` or the walk produced it

## Fan-out discipline

Reading the index is the mapper's job, not the parent's.

- A mapper on `agent-explore` reads `code-index.md` and reports the rows that answer the question
  with `path:line`, which keeps the tree out of the parent's context.
- A wave of writers on `agent-swarm` gets the digest -- the top-directory tables plus the symbols
  inside each writer's owned paths -- in its brief, so five children do not each spend five calls
  rediscovering one map.
- The skeptic on `agent-review` never trusts an index claim: it re-reads each one at `path:line`
  before it marks the claim kept.

## Its limits, plainly

- A symbol map, not a call graph: "what calls Y" narrows the candidates, and the call site still
  needs a read.
- Capped, and it says so: at most 400 symbols (`--limit` moves that) and 200 files, spread across
  the top directories rather than the first N in path order, named on stderr and in `## Cap`.
- A snapshot, not a live view: it indexes the working tree as it stood when the build ran, and
  the recorded sha is what you price that against.
- Partial by design: top-level definitions only -- Python `class`/`def`, shell functions and the
  `# @function` tag, Go `func`, TS/JS `export`, and BUILD/`.bzl` `name = "..."` targets.

## Done means

    python3 ~/.agents/skills/ez-code-index/scripts/code_index.py --repo <clone>
    # prints: ok: N files, M symbols -> ~/.grok/notes/<host>/<owner>/<repo>/code-index.md
    grep -m1 -- '- sha:' ~/.grok/notes/<host>/<owner>/<repo>/code-index.md  # equals the line below
    git -C <clone> rev-parse HEAD
    # and each answer taken from the index was re-read at that path:line in the checkout

Quote the command and the line it printed. An exit 1 with its stderr quoted is a finding, never a
green; a run that capped quotes its `note: capped ...` stderr line and both `## Cap` lines.
