---
name: security-audit
description: "Audit a repository or a diff for the defects that actually get exploited:
  secrets in a tracked file, command and query injection, missing or inverted authorization
  checks, deserialization of untrusted input, and egress nobody intended. Inventories
  sources and sinks separately, traces each source to a sink with a fleet of read-only
  tracers, then reports findings by severity with the one line of proof that makes each
  checkable. Run as /security-audit <path-or-diff> [--scope secrets|injection|authz|egress]."
when-to-use: "Use before releasing anything that reaches the network, a shell, a parser, a
  credential, or a permission decision, or to sweep a history for a committed secret."
argument-hint: "<path-or-diff> [--scope secrets|injection|authz|egress] [--json]"
compatibility: "Requires git and grep. Uses Grok Build subagents (spawn_subagent) for the
  trace lanes and the repository's own gate to re-prove a fix. Adds no dependency."
metadata:
  author: "operator"
  short-description: "Sources, sinks, traces, and a severity-ranked proof line"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["security-audit"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Security audit

## The order, and the proof line

Sources first, sinks second, traces third, verdicts last. A finding is one line of proof
someone else can re-run -- `path:line`, the command, and what it printed.

This is the parent's runbook. A depth-1 child may spawn `spawn_subagent` for read-only mappers only,
and only when it ships no file of its own; every writer here is still yours to launch.

Run every block below with `run_terminal_command` (Grok Build CLI) or `execute` (Coder
Agents chat agent); a command written inline in this body runs nothing on its own.

## Two consumers, one file

The CLI reads `~/.agents/skills/<name>/SKILL.md`, and a copy under
`<repo_root>/.grok/skills/` is CLI-only because the Coder Agents chat agent reads only
`~/.coder/skills/<name>/SKILL.md`. Keep the pair; never ship one home alone.

## Local references, models, and the call budget

Everything here is read from the checkout; a research lane is for a fact outside this
repository -- a published advisory, a library's documented default.

Models are the local aliases only: `agent`, `agent-low`, `agent-medium`, `agent-xhigh`,
`agent-swarm`, `agent-explore`, `agent-review`. No cloud id. Budget 15 to 30 of your own calls
plus the trace wave, and the run stays report-only until the operator asks for the fix.

## Step 0 -- scope it, and bound what you will touch (2 calls)

Name the target, the diff base, and what counts as in scope, so the report can say what it
did not cover:

    git rev-parse --abbrev-ref HEAD
    git diff --name-only <base>...HEAD | head -50
    git ls-files | grep -Ei '(^|/)(\.env|\.npmrc|\.netrc|id_rsa|credentials)' | head -50

### Never open a dotenv file

Never open a `.env` or `.env.*` file: the agent is denied that read, and the audit needs
the key name in a tracked path, not the value. Read `.env.example` for a value's shape.

## Step 1 -- inventory the sources (read-only, on `agent-explore`, up to 4 calls)

Sources are anywhere untrusted text enters:

- CLI and query arguments
- request bodies and headers
- filenames and paths
- environment variables
- parsed YAML, JSON, and TOML
- command output
- anything from a socket

Spawn one `explore` child per entry-point family on `agent-explore`, the lane for pure mapping, for
one table -- file, line, what it accepts, and who controls the bytes.

## Step 2 -- inventory the sinks (same lane, up to 4 calls)

Sinks are anywhere those bytes can do damage:

- shell invocation and `eval`
- writes outside an expected root
- SQL and template strings
- deserialization
- argv built by concatenation
- authorization decisions
- every outbound URL

Grep wide, then read what survives:

    git grep -nE '\beval\b|shell=True|os\.system|xargs|rm -rf' | head -50
    git grep -nE 'https?://|curl |wget |requests\.(get|post)|fetch\(' | head -50

### Treat unexpected egress as a finding on its own

Unexpected egress is a finding on its own: a URL built from input, or an outbound call in a
path that should be local-only, is what a quiet exfil looks like.

## Step 3 -- trace each source to a sink (1 call per source family)

### Trace one family per child

Follow every source to the sinks it can reach and record whether a check on the way actually
constrains it or only appears to. Spawn one read-only child per source family, and note that
at or above three independent children goes on `agent-swarm`, which spreads them over every
Spark box; below three, run them on `agent` in one turn.

### Re-run the trace before it becomes a finding

A delegated result is a claim, not a fact, so before a trace becomes a finding you re-run
its command, and its author names the `path:line` where bytes cross from trusted to
untrusted.

Missing or inverted authorization gets the same treatment as injection: show the
branch that lets the request through, not your belief that it should not.

## Step 4 -- report by severity, each with its proof line (1 call)

### Rank on what an attacker gains

Rank on what an attacker gains, not how ugly the code is:

- critical is RCE, credential disclosure, or an authz bypass on a reachable path
- high is injection or secret exposure needing one precondition you can name
- medium is a hardening gap
- low is hygiene

### What each line carries

Each line carries:

- severity
- class
- `path:line`
- the proof command with the one line it printed
- the fix in one sentence
- the test that would have caught it

Quote a secret's name, never its value, and redact anything you paste to a partial match.

## Step 5 -- remediate, then re-prove the gate (4 to 8 calls)

### Take the normal path

When the operator asks for the fix, take the normal path:

- a branch off `main`
- the smallest patch that closes the sink
- a test that fails before it and passes after, with the failing output quoted in the pull request

Then run the gate yourself -- discover the current repository's own fast test command and lint
command from its `AGENTS.md`, `README`, CI workflow, Makefile, or build file, and paste both
exactly as that repo states them:

    <the repo's own fast test command>
    <the repo's own lint command>

### Re-run the greps and the proof line

Re-run the Step 2 greps on the fixed tree and show the count moving. A finding closed
without its proof line re-run is a finding still open, and a fix that spans several files
is `/ez-micro-plan` territory like any other multi-file change.
