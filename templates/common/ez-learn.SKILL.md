---
name: ez-learn
description: "Mine past agent chats and sessions for the instructions, conventions, and workflows the user keeps re-explaining; propose new skills, updates to existing ones, and retirements of stale skills, plugins, MCP servers, and rules. Use when asked to learn this workspace, what should become a skill, tidy up repeated guidance, or find stale skills."
when-to-use: "learn this workspace, what should become a skill, tidy up repeated guidance, find stale skills"
argument-hint: "[report|apply]"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. Edit it and delete the marker line to
     take this copy over; a deletion is undone by the workspace boot. To hide it, set
     `disabled = ["ez-learn"]` under `[skills]` in `~/.grok/config.toml`. -->

# Learn the workspace

`/ez-learn` mines past agent chats and sessions, not just this one, and turns what repeats
into skill proposals. It is workflow curation, never memory: `/remember`, `/memory`, and
`/dream` store durable facts. Upstream `/learn` is a bundled skill whose download needs an
x.ai sign-in this stack lacks (LiteLLM is the sole model transport), so
`~/.grok/bundled/` is never created and the stack ships this one.

A skill is a folder holding its `<name>/SKILL.md` plus optional `scripts/` and
`references/` siblings. Where it lands:

- Both homes. The Grok Build CLI reads `~/.agents/skills/<name>/SKILL.md`; the Coder Agents
  chat agent reads `~/.coder/skills/<name>/SKILL.md` only, and dedupe is first-match-wins,
  so a skill for both consumers ships in both.
- Skill versus rule. `AGENTS.md` is always loaded and holds the convention every session
  must follow; a skill loads when its `description` matches and holds a procedure.

Run the blocks below with `run_terminal_command` (Grok Build CLI) or `execute` (Coder Agents
chat agent); a command inline in a body runs nothing on its own.

## Step 1 -- establish where you are

    echo "CODER_WORKSPACE_ID=[${CODER_WORKSPACE_ID-unset}] EVO_T1_DEVCONTAINER=[${EVO_T1_DEVCONTAINER-unset}]"
    pwd; git rev-parse --show-toplevel 2>/dev/null; command -v grok; grok --version
    env | grep -E '^(LITELLM_BASE_URL|SEARXNG_URL|CONTEXT7_API_KEY)=' | sed 's/=.*/=set/'
    grep -nE '^\[mcp_servers\.' ~/.grok/config.toml || echo "no MCP blocks declared"

- `CODER_WORKSPACE_ID` set: a Coder workspace container; `docker` addresses that workspace's
  DinD sidecar (`DOCKER_HOST=tcp://dind:2375`), never the stack host's daemon, so an empty
  `docker ps` is normal.
- `EVO_T1_DEVCONTAINER=1`: the contributor dev container. Neither: a plain shell; no
  whole-stack commands from here.
- The corpus differs by place, and a `~/.grok/config.toml` left stale by whichever workspace
  booted last is itself a curation finding.
- LiteLLM is the only model transport. Seven aliases (`agent`, `agent-low`,
  `agent-medium`, `agent-xhigh`, `coder`, `coder-fast`, `chat`) resolve through it, `agent`
  the tool-call-capable default. Two more (`spark-coder`, `spark-chat`) reach the optional
  NVIDIA Spark Ollama boxes. Name `LITELLM_API_KEY`, never print it; the live list is
  `litellm/config.yaml`.
- `bazelisk run //scripts:mcp-check` names a dead lane; a server absent from
  `~/.grok/config.toml` is a gap to report, never a reason to launch it by hand.

## Step 2 -- inventory what is already declared

    ls -d "$HOME"/.agents/skills/*/ "$HOME"/.coder/skills/*/ 2>/dev/null
    find "$PWD" -maxdepth 3 -type d -name skills 2>/dev/null
    head -n 12 "$HOME"/.agents/skills/*/SKILL.md 2>/dev/null
    awk '/^\[skills\]/{f=1;next} /^\[/{f=0} f' ~/.grok/config.toml
    ls AGENTS.md */AGENTS.md 2>/dev/null; grok plugin list 2>/dev/null || echo "no plugins"

List the dirs and read each frontmatter (`name`, `description`, `when-to-use`); never guess a
skill's job from its folder name. That `find` covers the CLI's repo and `~/.grok` tiers,
which the chat agent never reads; `[skills]`, when present, holds `paths`, `ignore`,
`disabled`. A finding the guidance or `AGENTS.md` already covers is not work.

## Step 3 -- mine the session corpus

    find ~/.grok/sessions -name summary.json 2>/dev/null | head -60 > /tmp/ez-learn-index.txt
    xargs -r jq -r '[.updated_at, .num_chat_messages, .head_branch, .session_summary] | @tsv' < /tmp/ez-learn-index.txt | sort -r | head -25

- `~/.grok/sessions/` is one dir per %-escaped cwd: small `summary.json` files beside
  multi-megabyte `chat_history.jsonl` and `events.jsonl`. Derive those names with `find` or
  `ls`, never reconstruct them from memory.
- Index the summaries first (`session_summary`, `num_chat_messages`, `head_branch`), rank,
  read only what ranks. Cap the sweep: the deep pass is spent only when the user asks for a
  full-transcript sweep.
- Count and select with `jq` or `grep -c` into a scratch file under `/tmp`; never paste a
  transcript into the reply.
- Hunt for instructions repeated across sessions, corrections the user made to the agent,
  commands run in the same shape more than once, and guidance that contradicts `AGENTS.md`
  or is absent from it. Keep the digest in `~/.grok/notes/<key>/notes.md`.

## Step 4 -- sort findings into three buckets

Already covered, contradicts the guidance, never said. Only the last two are work; a rule the
agent ignored is not evidence the rule is wrong.

## Step 5 -- propose each finding in one shape

One block per finding: `kind` (new skill | update | retire | config cleanup); suggested
`name` (lowercase letters, digits, hyphens); suggested scope (both homes, or the repo tier
when team-relevant); `description` and `when-to-use` with the trigger phrases; the numbered
steps; the evidence -- which sessions, how many times. A `retire` proposal names the stale
thing and the evidence it is stale, never deleting on its own.

## Step 6 -- run it in one of two modes

Report-only, the default: print the counts and the Step 5 blocks, write nothing.
Step-through apply: one proposal at a time, with its evidence, offered as accept / edit /
reject; wait for the answer, then move on.

## Step 7 -- where an accepted change is written

- Stack work goes to the seed that produces the file: the payloads under `templates/common/`
  and `hermes/skills/`, and the config templates. Never edit the copy in a home -- a file
  carrying the stack marker is stack-owned, and the boot or `refresh-configs` restores it.
- A skill for the user's own use goes into BOTH `~/.agents/skills/<name>/SKILL.md` and
  `~/.coder/skills/<name>/SKILL.md`, or the chat agent never sees it.
- `/ez-skillify` captures the session that just worked, `/ez-create-skill` scaffolds from a
  description: `/ez-learn` proposes, those two write.

## Step 8 -- verify discovery, retire without deleting

    grok inspect
    grok inspect --json

Confirm the name is listed, its `source` is the path you wrote, `userInvocable` is true; a
contested bare name is tagged `collides with /x -> scope:x`. To retire without deleting:
`disabled = ["name"]` under `[skills]` keeps a skill listed and inactive,
`ignore = ["path"]` hides it entirely, and a plugin goes in `[plugins].disabled`.
`/skills` is the interactive form of the same switch: it lists every discovered skill
with its source and toggles one out of the slash menu without touching the file.

A seed change runs the repo gates:

    bazelisk test //:test-fast
    bazelisk test //:lint --test_tag_filters=manual
    bazelisk run //:fix
    bazelisk run //:validate

Each `scripts/<stem>.sh` is a target: `bazelisk run //scripts:<stem> -- <args>`. Read the
summary line first: `Executed 0 out of N tests: N tests pass.` is a cached PASS over
unchanged inputs; spend one uncached pass
(`bazelisk test //:test-fast --nocache_test_results`) before the PR.

## Then point at the next thing

- Operator docs: `README.md`, then `docs/` (`grok-build-and-agents.md` for the CLI and its
  lanes, `project-conventions.md` for shell style, `branching.md` for git).
- Anything in this repo: read it. A search lane answers the outside world only.
- Run it periodically. A convention every session must follow belongs in `AGENTS.md`; a
  procedure belongs in a skill, shipped in both homes.
