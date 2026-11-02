---
name: learn
description: "Orient to this workspace and this stack: probe what is actually running, report the lanes and gates you measured, then teach the user the one command that matters next. Use when asked to learn, explain, or get oriented in the environment."
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded.
     To take a seeded copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a
     marker-free file is user-owned, and the seeder leaves it alone
     unless you pass `--force`. A deletion is undone - the workspace
     boot writes the file again whenever it is absent, and
     `refresh-configs` re-seeds an absent target, so the next boot
     restores the stack's copy. To hide the slash command, set
     `disabled = ["learn"]` under `[skills]` in `~/.grok/config.toml`. -->

# Learn the workspace

When the user invokes this skill, orient them to where they actually are. Measure
before you speak: report what a probe answered, and say what you could not check.
Run the commands shown below with the `run_terminal_command` tool: a command
block in this body is an instruction to run, and nothing executes on its own.

## Step 1 -- establish where you are

    echo "CODER_WORKSPACE_ID=[${CODER_WORKSPACE_ID-unset}] EVO_T1_DEVCONTAINER=[${EVO_T1_DEVCONTAINER-unset}]"
    pwd; git rev-parse --show-toplevel 2>/dev/null; command -v grok; grok --version

- `CODER_WORKSPACE_ID` set: a Coder workspace container, and `docker` here addresses
  that workspace's own DinD sidecar (`DOCKER_HOST=tcp://dind:2375`), never the stack
  host's daemon. An empty `docker ps` is normal and does not mean the stack is down.
- `EVO_T1_DEVCONTAINER=1`: the contributor dev container, not a Coder workspace.
- Neither: a plain shell. Do not offer whole-stack commands from here.

## Step 2 -- report the lanes, from the environment

    env | grep -E '^(LITELLM_BASE_URL|SEARXNG_URL|CONTEXT7_API_KEY)=' | sed 's/=.*/=set/'
    grep -nE '^\[mcp_servers\.' ~/.grok/config.toml || echo "no MCP blocks declared"

- LiteLLM is the only model transport. Seven aliases (`agent`, `agent-low`,
  `agent-medium`, `agent-xhigh`, `coder`, `coder-fast`, `chat`) resolve through it;
  `agent` is the tool-call-capable default. Two more (`spark-coder`, `spark-chat`)
  reach the optional NVIDIA Spark Ollama boxes and answer only while those are up.
  The key rides in `LITELLM_API_KEY`, so name it, never print it, and read the
  current list from `litellm/config.yaml` rather than trusting this count.
- Native `web_search` is parked by the stack (`disable_web_search = true`): no
  transport here serves that tool type. The `searxng` MCP server is the search lane.
- `bazelisk run //scripts:mcp-check` names the cause of a dead lane; a server missing
  from `~/.grok/config.toml` is a gap to report, and never a reason to launch one by hand.
- Report the difference between what the templates declare and what this file holds.
  A lane whose block the template renders by default can still be absent here, because
  the last-booted workspace re-renders the shared `config.toml` for every owner, so
  name each missing lane rather than assuming it is parked.

## Step 3 -- the host, from a workspace

`host.docker.internal` is the stack host: `:4000` LiteLLM, `:3002` the Coder agent
tunnel, `:8181` SearXNG, `:9119` the Hermes dashboard. Whole-stack commands
(`dev-stack`, `prod-stack`, `refresh-configs`, `update-stack`, `pull-models`) run in a
host shell, not in a workspace.

## Step 4 -- the gates, and how work lands here

Short-lived branch off `main`, one logical change each, PR into `main`. Done means:

    bazelisk test //:test-fast        # the fast gate
    bazelisk test //:lint --test_tag_filters=manual
    bazelisk run //:fix               # format
    bazelisk run //:validate          # the full gate on demand

Prefer Bazelisk; Make is a shim. Each `scripts/<stem>.sh` is a Bazel target:
`bazelisk run //scripts:<stem> -- <args>`.

Read the summary line before re-running anything: `Executed 0 out of N tests: N tests
pass.` is a cached PASS over unchanged inputs, not a skipped or hollow run. Spend one
uncached pass (`bazelisk test //:test-fast --nocache_test_results`) before you open a
PR, and run long gates in the background rather than blocking a turn on them.

## Step 5 -- the two conventions worth knowing on day one

- Terminals join one tmux session per folder, so a closed tab kills nothing. The
  **Grok Build** profile runs `grok-build-terminal`, which walks up to the repo root
  and resumes one `grok` session per repo.
- `~/.grok/notes/<key>/notes.md` is the canonical per-repo scratch file (the key is
  the clone's `host/owner/repo`), and it is git-ignored through `core.excludesFile`.
  Put working notes there, not in a new root markdown.

## Then point at the next thing

- Operator docs: `README.md`, then `docs/` (`grok-build-and-agents.md` for the CLI and
  its lanes, `project-conventions.md` for shell style, `branching.md` for git).
- Anything in this repo: read it. A search lane answers the outside world only.
- To make a convention stick for every future session, propose a rule for the repo's
  `AGENTS.md`; to teach a procedure, add a skill at
  `~/.agents/skills/<name>/SKILL.md` (the Grok Build CLI reads that path, and the
  Coder Agents chat agent reads the `~/.coder/skills/<name>/SKILL.md` twin, so ship
  both). Files under `~/.grok` that carry the stack marker are stack-owned: change
  the seed in this repo and re-materialize it, never the copy that lives in a
  workspace.

## Go deeper, only when the user asks for it

Asked to learn deeply, or to fix what keeps going wrong, mine the session logs before
proposing anything:

- They live under `~/.grok/sessions/`, one directory per escaped cwd, each holding
  small `summary.json` files beside large `chat_history.jsonl` and `events.jsonl`.
  Index the summaries first (`session_summary`, `num_chat_messages`, `head_branch`),
  then read only the sessions that rank.
- A `jsonl` file is many megabytes: count and select with `jq` or `grep -c` into a
  scratch file under `/tmp`, and never paste a transcript into the reply.
- Sort what you find into what the guidance already covers, what it contradicts, and
  what it never says. Only the last two are work; a rule the agent ignored is not
  evidence the rule is wrong.
- Every correction lands in the seed that produces the file, with a test that fails
  when the claim drifts again. The payloads under `templates/common/` and
  `hermes/skills/` are the sources; the copies in a home directory are output.
