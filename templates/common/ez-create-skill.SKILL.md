---
name: ez-create-skill
description: "Scaffold a Grok Build skill from a description: gather the name and scope, draft the description and when-to-use text for approval, write the frontmatter and numbered body, verify with grok inspect. Triggers: create a skill, new skill, scaffold a skill, make a slash command. Run as /ez-create-skill."
when-to-use: "Use when the operator can describe the workflow they want captured but has no recent successful session to mine - that is /ez-skillify - or wants maximum control over the frontmatter and layout."
argument-hint: "[skill-name]"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded.
     To take a seeded copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a
     marker-free file is user-owned and the seeder leaves it alone
     unless you pass `--force`. A deletion is undone - the boot
     writes the file again whenever it is absent. To hide the slash
     command, set `disabled = ["ez-create-skill"]` under `[skills]`
     in `~/.grok/config.toml`. -->

# Create a skill

A skill is a folder holding one `skills/<name>/SKILL.md` plus optional `scripts/` and
`references/` siblings. It runs as `/name` when typed, and the model may invoke it when a
prompt matches `description` or `when-to-use`. It is not `AGENTS.md` (always-loaded project
rules) and not the memory system (`/remember`, `/memory`, `/dream`), which stores facts; a
skill stores a procedure. Upstream `/create-skill` is bundled and unfetchable here: that
download needs an x.ai sign-in this stack lacks (LiteLLM is the sole model transport), so
`~/.grok/bundled/` never exists. Hence the `ez-` prefix, which also clears the built-in
slash name.

Run each block with `run_terminal_command` (Grok Build CLI) or `execute` (Coder Agents chat
agent). A command written inline in a skill body runs nothing -- which is why the skill you
are about to write needs numbered steps that name their tool.

## Step 1 -- gather requirements

Ask for the name, the scope (Step 3 and the table at the end), and a plain-language
description of the workflow to capture. The name is lowercase letters, digits and hyphens,
2-64 characters, starting and ending with a letter or a digit. Spaces and underscores
normalize to hyphens; a bad name costs you a command you did not choose, reachable only by a
qualified name, and a rename in every home it was copied into.

Check the name is free BEFORE writing:

    ls ~/.agents/skills/ ~/.coder/skills/ 2>/dev/null
    ls "$(git rev-parse --show-toplevel)/.grok/skills" 2>/dev/null
    grok inspect

A name contested with a built-in or another skill is not an error: the built-in keeps the
bare name and yours is pushed to its qualified `scope:name` form. `grok inspect` tags it
`collides with /x -> scope:x`. Fix it with an `ez-` prefix or a rename.

## Step 2 -- draft the description and get approval

Write a `description` that states what the skill does, the phrases that trigger it, and the
slash-command name, plus matching `when-to-use` text. Show BOTH and wait for approval or
edits before touching disk: the description drives automatic invocation, so vague text makes
the skill dead weight. Too vague, nothing to match on:

    description: Create git commits

What fires:

    description: Create well-formatted git commits following conventional commit
    standards. Use when the user wants to commit changes or asks for /commit.

## Step 3 -- create the structure

    mkdir -p "$HOME/.agents/skills/<name>" "$HOME/.coder/skills/<name>"

Add `scripts/` or `references/` only if the skill needs them:

    mkdir -p "$HOME/.agents/skills/<name>/references"

## Step 4 -- write skills/<name>/SKILL.md

Line 1 is exactly `---`, the closing `---` sits alone on its own line, multi-word keys are
kebab-case. These are the only documented keys; the rest is drift the CLI ignores.

| Key | Use it when |
|---|---|
| `name` | Always; rule in Step 1; else the folder name wins. |
| `description` | Always: what it does, its triggers, the slash name. |
| `when-to-use` | Trigger phrases kept apart from `description`. |
| `allowed-tools` | A tool subset: YAML list or comma/space text. |
| `argument-hint` | It takes arguments; shown in autocomplete. |
| `user-invocable` | Only to set `false`: hides it from the slash menu. |
| `disable-model-invocation` | Only your `/name` runs it, never the model. |
| `model` | A model other than the session's. |
| `effort` | A different reasoning effort. |
| `license` | Shipping a license identifier. |
| `compatibility` | Named binaries, as `Requires git, docker, jq`. |
| `metadata` | String pairs; `author`, `short-description` are promoted. |

Ask about two of them: `disable-model-invocation: true` when only an explicit slash command
should run it, and `user-invocable: false` when only the model should reach it. Never both.

Body rules: ordered numbered steps; the verification command written as a step the agent
runs; tools named (`read_file`, `search_replace`, `run_terminal_command`); conventions
stated outright; one workflow per skill. Stay under the 25,000-token inline cap: only that
much is read, so long reference material goes in a sibling under `references/`, read with an
offset and limit.

A minimal complete skill:

```markdown
---
name: tidy-scratch
description: "Clear this repo's /tmp scratch files and report what went. Use when asked to
  clear scratch output. Run as /tidy-scratch."
---

## Step 1 -- list what is there, with `run_terminal_command`

    ls -la /tmp/<repo>-scratch 2>/dev/null

## Step 2 -- remove it per path

    find /tmp/<repo>-scratch -type f -delete

## Step 3 -- report how many went and what still stands
```

## Step 5 -- verify and hand over

Read it back and prove what a parser checks: line 1 exactly `---`, the fence closes, the
frontmatter parses.

    f="$HOME/.agents/skills/<name>/SKILL.md"
    head -n 1 "$f"
    awk 'NR > 1 && /^---[[:space:]]*$/ { print NR; exit }' "$f"
    sed -n '2,$p' "$f" | sed '/^---$/,$d' | python3 -c 'import sys,yaml; print(sorted(yaml.safe_load(sys.stdin.read())))'

Then report what the CLI resolved -- the `source` path and `userInvocable`:

    grok inspect
    grok inspect --json

Tell the user to invoke `/name` in a new turn, arguments typed after the name; it lands in
the slash menu within seconds because skills reload from disk. If it is missing, `[skills]`
in `~/.grok/config.toml` explains: `paths` scans an extra directory, `ignore` hides a skill
entirely, `disabled` keeps it listed but inactive.

## Where it goes in this stack

| Path | Tier | Read by |
|---|---|---|
| `./.grok/skills/<name>/` | Local (CWD), highest | Grok Build CLI only |
| `<repo_root>/.grok/skills/<name>/` | Repo | CLI only, withheld until the folder is trusted |
| `~/.grok/skills/<name>/` | User | Grok Build CLI only |
| `~/.agents/skills/<name>/` | User, CLI side | Grok Build CLI |
| `~/.coder/skills/<name>/` | Chat side | the Coder Agents chat agent only |

The stack's rule: a user-scope skill that should work on both consumers ships in BOTH
`~/.agents/skills/<name>/SKILL.md` (CLI side) and `~/.coder/skills/<name>/SKILL.md`
(chat side). The chat agent reads `~/.coder/skills/` only, never `~/.grok/skills/` or a
repo's `.grok/skills/`, and dedupe is first-match-wins, so one home means one blind
consumer. A repo-scoped skill is the team choice because it travels with git; add the
two-home pair when the chat agent needs it too.

A file carrying the stack marker `managed-by: evo-t1-coder-stack` is stack-owned and the boot
rewrites an absent copy: edit the seed in this repo's `templates/common/` and re-materialize
with `bazelisk run //scripts:refresh-configs`, never write a home by hand. See
`docs/grok-build-and-agents.md`.

## Boundaries

- Commit nothing unless asked.
- Never put a secret, token, or `.env` value in a skill body: name the key
  (`LITELLM_API_KEY`), never its value.
- The trio splits by evidence: `/ez-skillify` captures the session that just worked,
  `/ez-learn` mines many sessions and proposes, this command builds from a description.
