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

- LiteLLM is the only model transport. The seven aliases (`agent`, `agent-low`,
  `agent-medium`, `agent-xhigh`, `coder`, `coder-fast`, `chat`) resolve through it;
  `agent` is the tool-call-capable default. The key rides in `LITELLM_API_KEY`, so
  name it, never print it.
- Native `web_search` is parked by the stack (`disable_web_search = true`): no
  transport here serves that tool type. The `searxng` MCP server is the search lane.
- `bazelisk run //scripts:mcp-check` names the cause of a dead lane; a server missing
  from `~/.grok/config.toml` is a gap to report, and never a reason to launch one by hand.

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

## Step 5 -- the two conventions worth knowing on day one

- Terminals join one tmux session per folder, so a closed tab kills nothing. The
  **Grok Build** profile runs `grok-build-terminal`, which walks up to the repo root
  and resumes one `grok` session per repo.
- `~/.grok/notes/notes.md` is the canonical per-repo scratch file and is git-ignored
  through `core.excludesFile`. Put working notes there, not in a new root markdown.

## Then point at the next thing

- Operator docs: `README.md`, then `docs/` (`grok-build-and-agents.md` for the CLI and
  its lanes, `project-conventions.md` for shell style, `branching.md` for git).
- Anything in this repo: read it. A search lane answers the outside world only.
- To make a convention stick for every future session, propose a rule for the repo's
  `AGENTS.md`; to teach a procedure, add a skill under `.grok/skills/`. Files under
  `~/.grok` that carry the stack marker are stack-owned: change the seed in this repo
  and re-materialize it, never the copy that lives in a workspace.
