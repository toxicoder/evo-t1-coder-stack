---
title: Project conventions
description: The shell, function, script, template and naming rules this repo holds itself to, and the gates that enforce them.
tags: [conventions, shell, style, contributing]
---

**What's on this page**

- The file header and the function docstring block both gates require
- Ingress rules: what runs from a shell and what is a Bazel target
- One language per file, the shared log contract, and the payload copies the templates share
- Names, flags, and the style guide shell follows

**What this enables**

- Writing a script that passes `//:lint` and `//tests:doc_coverage` first try
- Matching the house style instead of inventing a local one

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

Bazelisk is the only ingress, with one exception: `scripts/setup-host.sh`. That script is
the **stack host's** bootstrap — it installs Bazelisk, the shell/Starlark lint toolchain
(shellcheck, shfmt, buildifier) and Terraform — so it has to run before Bazel exists, and
stays the single documented `bash scripts/setup-host.sh`. On a laptop you do not run it:
the contributor container or `bazelisk run //scripts:test-in-image` brings the same pinned
toolchain in from `images/dev/` instead
([contribute/devcontainer.md](contribute/devcontainer.md)). `--repair` is the other half of
that exemption: leftover Docker bind-mounts in Bazel's runfiles tree make
`bazelisk run //scripts:prod-stack` die creating `prod-stack.runfiles` (`Permission
denied` on `homepage/assets/icons/evo-t1.svg`) before any stack script can run.
On Linux it also writes a systemd-resolved drop-in (`1.1.1.1` / `8.8.8.8`) and
runs `tailscale set --accept-dns=false` so host `git pull` still resolves
`github.com` when MagicDNS is the only nameserver.

Everything else is a Bazel target:

```bash
bazelisk test //:test-fast
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:validate
bazelisk run //:fix
bazelisk run //scripts:dev-stack -- status                      # the dev stack
bazelisk run //scripts:dev-stack -- status --project-name evo-t1-coder-stack   # the stable stack
bazelisk run //scripts:prod-stack -- status                     # the stable stack, as prod-stack names it (evo-t1-prod)
bazelisk run //scripts:new-workspace -- --dry-run https://github.com/org/repo.git
```

`make` only delegates. An operator CLI runs as `bazelisk run //scripts:<stem> -- <args>`
(`<stem>` = the file name under `scripts/`); `make help` lists the shims.

## Scripts

- No `eval`. Prefer `"${var}"`, `[[ ]]`, and `$(...)`.
- One language per file where reasonable. A bash, python, or awk program that lives
  inside another file is its own tested file, imported with `source`, `cat` + `sh -c`
  / `ssh`, `python3 file.py`, `awk -f`, or Terraform `file()` / `templatefile()`. Keep
  1–3 line awk, usage heredocs, Dockerfiles, YAML data, docs fences, and
  `python3 -m webbrowser`. Remote probes are POSIX and self-contained under
  `scripts/lib/probes/`; the host `cat`s them and tests run the file with `sh`.
- Operator CLIs source `scripts/lib/common.sh` and do not redefine `log` / `die` /
  `skip`. Grouping: `section` prints `== name ==`, `phase` prints `-> text`, `ok`
  prints `ok: text`, `summary` prints `summary: N ok, W warnings, F failed` plus
  `  failed: …` and optional `next: cmd`. `JSON_MODE` set sends prose to stderr.
  CLIs without `--json` unset `JSON_MODE` after source. Keep prefixes `warning:` /
  `note:` / `error:`.
- A script never runs another repo script by relative path, and never assumes the cwd is the
  checkout: it resolves the repo root from `${REPO_ROOT:-}` / `${GITHUB_WORKSPACE:-}` and then
  probes for it (see the harness doc), because a Bazel sandbox may only hold a copy.
- External tools are probed with `command -v` and reported as "not on PATH", not assumed.
  `require_tool` skips locally and fails under `CI=true`.
- A probe-style CLI takes its target as a flag (`--url`) rather than a hard-coded host, and reports
  "nothing answered" as a result rather than a crash, so one run works from the host and from inside
  a workspace and still answers the question the operator asked. Its suite stubs the transport.

## Templates

`templates/workspace/` (the plain dev container) and `templates/devcontainer/` (the
DinD-backed one) keep independent `.tftpl` payload copies (`startup.sh.tftpl`,
`settings.json.tftpl`, `grok-config.toml.tftpl`). The twins must change together — today
only `settings.json.tftpl` is byte-identical across the two directories, so edit both
copies of that payload. `templates/common/` exists once above the twins instead and
holds the single-copy payloads both templates consume: `GROK_BUILD_AGENTS.md`,
`vscode-alt.svg`, `notes-setup.sh`, `tmux.conf`, `grok-build-terminal.sh`,
`vscode-terminal-tmux.sh`, `grok-build-delegation.SKILL.md`, `coder-agents.md`,
`mcp-cache-proxy.json`, and `gh-token-refresh.sh.tftpl`. Markdown and JSON are
read with `file()` (chomp the markdown); shell helpers that Terraform must not
re-interpolate are also `file()` (so `$folder` stays `$folder`); `gh-token-refresh.sh.tftpl`
is `templatefile()` because it interpolates `${github_auth_id}`. `coder_script`
bodies are sibling `.tftpl` files next to each `main.tf` (`code-server.sh.tftpl`,
and on `devcontainer` also `dind-bootstrap.sh.tftpl`) rendered with `templatefile()`.
The SVG stays small enough that the resulting data URL fits Coder v2.36's 256-character
`workspace_apps.icon` column. The push
(`scripts/push-template.sh` through `template_push_one` in `scripts/lib/template-push.sh`)
stages every common payload beside each template's staged `main.tf` copy, which is the only place the
server-side Terraform can read them from, so editing the common copy changes both
templates; a staged copy that lacks any one of them fails the push early by design.

Dollar escaping differs across those two layers. A `templatefile()` `.tftpl` treats `$$`
as an escaped `$` everywhere (`$name` or `$${name}`), and leaves `$((` arithmetic
alone. An HCL heredoc in `main.tf` (`<<-EOT`) only escapes `$${name}` to `${name}`;
a lone `$` is already literal, so shell arithmetic is `$((...))` with one dollar.
`$$((` is two dollars, and Coder runs `coder_script` bodies as `bash -c`, which
expands `$$` to the PID. Do not wrap `templatefile()` in `chomp()`.

## Names and flags

- `devcontainer` — the dev-container template (directory `templates/devcontainer`, Coder
  template name `devcontainer`), always backed by its own DinD sidecar. Its sibling is
  `workspace`: directory `templates/workspace`, template name `workspace`, the plain
  dev container with the optional `dind` parameter.
- `devcontainer.json` — a file the *application repository* carries, and the one thing the
  `devcontainer` template builds. `coder_devcontainer.repo` in
  `templates/devcontainer/main.tf` sets no `config_path`, so `@devcontainers/cli` on the
  DinD sidecar searches the clone for `.devcontainer/devcontainer.json` (or a
  `devcontainer.json` anywhere inside it). This repo ships a `.devcontainer/` of its own —
  the **contributor** one for a laptop and CI, built from `images/dev/Dockerfile` — and it
  is not that nested kind: `.devcontainer/contributor-env` alongside it makes
  `probe_repo` answer a miss, so a Coder workspace of this repo stays on the `workspace`
  template instead of building its own container inside its own DinD sidecar. Other
  repositories keep carrying their own nested dev-container files, and those are still a
  probe hit. See [contribute/devcontainer.md](contribute/devcontainer.md).
- `additional_repos` — the `--additional-repos` flag on the new-workspace CLI, and the
  `coder_parameter` of the same name that receives its value in both templates
  (`mutable = true`, default empty): extra git URLs for the workspace's clone folders,
  given as `url1,url2` or one URL per line. The flag exists on
  `bazelisk run //scripts:new-workspace` only - the stack runners (`dev-stack`,
  `prod-stack`) have no `--additional-repos` (their flags are `-p`, `-f`, `-e`,
  `--tail`, `--follow`, `--json`, `-y`, `-h`).
- `--project-name` - every stack-runner subcommand (`up`, `down`, `status`, `logs`, `reset`),
  on both `dev-stack` and `prod-stack`. `dev-stack` defaults to `evo-t1-dev`, the dev sandbox;
  `prod-stack` defaults to `evo-t1-prod`, the stable stack it brings up, and it addresses a
  stable stack brought up by hand with `--project-name evo-t1-coder-stack` (the checkout
  folder's name). The env file follows the runner: the dev project takes `dev-stack.env`
  beside the compose file when one exists, and any other project gets none, so a run aimed at
  the stable stack never picks up the dev host ports; `prod-stack` names no env file unless
  `-e` does, and compose then reads the `.env` beside the compose file itself.
- `--check` — the read-only mode `scripts/setup-host.sh` and `scripts/bootstrap.sh` both
  take. `setup-host --check` names the tools that are missing, leftover runfiles that
  will make `bazelisk run` fail with Permission denied, and whether `github.com`
  resolves, and installs nothing; `setup-host --repair` is the recovery for those
  leftovers and, on Linux, for MagicDNS-only host DNS (uses sudo when chmod or
  `/etc` is not enough). `bootstrap --check` prints the same
  probes the full run makes (tools, compose plugin, placeholder secrets by name, hosts,
  certs, GPU, images) and writes nothing. An unrecognised argument in either script is
  an error, never a silent fall-through to the mutating run.
- GitHub auth is Coder External Auth, id `github` by default (Coder's injected
  GitHub App when coder.env is absent). A custom OAuth app in coder.env keeps
  its `CODER_EXTERNAL_AUTH_0_ID` (commonly `primary-github`); push-template.sh
  forwards that id. There is no GitHub-token template variable and no PAT in
  any agent env map.

Runtime stays `docker compose`: Bazel runs the CLIs that drive Compose and never talks to a
daemon, a Spark box, or a model registry by itself. No Kubernetes layer.
