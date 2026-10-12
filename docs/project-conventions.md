# Project conventions

Shell follows the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
Branch rules live in [branching.md](branching.md); the Bazel harness lives in
[contribute/building-with-bazel.md](contribute/building-with-bazel.md) and
[contribute/test-with-bazel.md](contribute/test-with-bazel.md).

## File header

Every `scripts/**/*.sh` file starts with a `# ## ` header that names the file and says whether it is an entry point or a sourced library.

## Functions

Every function carries this block immediately above the definition:

```bash
# @function name
# One sentence.
# Globals:
#   NAME, or None
# Arguments:
#   $1 - meaning
# Outputs:
#   What is printed
# Returns:
#   0, a status, or the exit code
```

`tests/doc_coverage.sh` fails the build when a header or a block is missing.

## Tests

Every function under `scripts/` is named by an asserting test under `tests/`: one suite per
module, plus one test per entry-level function that drives the whole script (`tests/bats/
entry-fns.bats` is where those live). `tests/shell_inventory.sh` fails when a name is
missing, and `tests/doc_coverage.sh` when a `# @function` block is missing or incomplete.
Tests are hermetic: docker, ssh, curl, git and the other external tools resolve through
`tests/bats/tool_stubs`.

## Ingress

Bazelisk is the only ingress, with one exception: `scripts/setup-host.sh`. That script is a
one-time host bootstrap — it installs Bazelisk, the shell/Starlark lint toolchain
(shellcheck, shfmt, buildifier) and Terraform — so it has to run before Bazel exists, and
stays the single documented `bash scripts/setup-host.sh`.

Everything else is a Bazel target:

```bash
bazelisk test //:test-fast
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:validate
bazelisk run //:fix
bazelisk run //scripts:dev-stack -- status --project-name evo-t1-dev
bazelisk run //scripts:new-workspace -- --dry-run https://github.com/org/repo.git
```

`make` only delegates. An operator CLI runs as `bazelisk run //scripts:<stem> -- <args>`
(`<stem>` = the file name under `scripts/`); `make help` lists the shims.

## Scripts

- No `eval`. Prefer `"${var}"`, `[[ ]]`, and `$(...)`.
- A script never runs another repo script by relative path, and never assumes the cwd is the
  checkout: it resolves the repo root from `${REPO_ROOT:-}` / `${GITHUB_WORKSPACE:-}` and then
  probes for it (see the harness doc), because a Bazel sandbox may only hold a copy.
- External tools are probed with `command -v` and reported as "not on PATH", not assumed.
  `require_tool` skips locally and fails under `CI=true`.

## Templates

`templates/workspace/` (the plain dev container) and `templates/devcontainer/` (the
DinD-backed one) keep independent `.tftpl` payload copies (`startup.sh.tftpl`,
`settings.json.tftpl`, `grok-config.toml.tftpl`). The twins must change together — today
only `settings.json.tftpl` is byte-identical across the two directories, so edit both
copies of that payload. `templates/common/GROK_BUILD_AGENTS.md` — the orchestration
protocol the startup scripts seed into every workspace's `~/.grok/AGENTS.md` — exists
once above the twins instead: the push (`scripts/push-template.sh` through
`template_push_one` in `scripts/lib/template-push.sh`) stages it into each template's
pushed copy, which is the only place the server-side Terraform can `file()`-read it
from, so editing the common copy changes both templates.

## Names and flags

- `devcontainer` — the dev-container template (directory `templates/devcontainer`, Coder
  template name `devcontainer`), always backed by its own DinD sidecar. Its sibling is
  `workspace`: directory `templates/workspace`, template name `workspace`, the plain
  dev container with the optional `dind` parameter.
- `devcontainer.json` — a file the *repository* carries, never one this repo ships.
  `coder_devcontainer.repo` in `templates/devcontainer/main.tf` sets no `config_path`, so
  `@devcontainers/cli` on the DinD sidecar searches the clone for
  `.devcontainer/devcontainer.json` (or a `devcontainer.json` anywhere inside it).
- `additional_repos` — the `--additional-repos` flag on the new-workspace CLI, and the
  `coder_parameter` of the same name that receives its value in both templates
  (`mutable = true`, default empty): extra git URLs for the workspace's clone folders,
  given as `url1,url2` or one URL per line. The flag exists on
  `bazelisk run //scripts:new-workspace` only — `dev-stack` has no `--additional-repos`
  (its flags are `-p`, `-f`, `-e`, `--tail`, `--follow`, `--json`, `-y`, `-h`).
- `--project-name` — every `dev-stack` subcommand (`up`, `down`, `status`, `logs`, `reset`),
  default `evo-t1-dev`.
- `--check` — the read-only mode `scripts/setup-host.sh` and `scripts/bootstrap.sh` both
  take. `setup-host --check` names the tools that are missing and installs nothing;
  `bootstrap --check` prints the same probes the full run makes (tools, compose plugin,
  placeholder secrets by name, hosts, certs, GPU, images) and writes nothing. An
  unrecognised argument in either script is an error, never a silent fall-through to the
  mutating run.
- GitHub auth is Coder External Auth, id `primary-github`. There is no GitHub-token
  template variable and no PAT in any agent env map.

Runtime stays `docker compose`: Bazel runs the CLIs that drive Compose and never talks to a
daemon, a Spark box, or a model registry by itself. No Kubernetes layer.
