# **PROJECT_NAME**

**PROJECT_DESCRIPTION** -- a language-neutral starting point that already has the
boring parts decided.

Generated from `evo-t1-coder-stack/project-template` for
[**PROJECT_OWNER**/**PROJECT_SLUG**](https://github.com/__PROJECT_OWNER__/__PROJECT_SLUG__).

## Quick Start (30 seconds)

Two routes. Pick one.

**Route A: "Use this template" on GitHub**

1. Open the template repository and hit **Use this template** -> **Create a new
   repository**. Name it what you want; the render tokens get substituted for you.
2. `git clone https://github.com/__PROJECT_OWNER__/__PROJECT_SLUG__.git && cd __PROJECT_SLUG__`
3. `cp .env.example .env`, fill in what you actually need.
4. `make doctor` -- proves the toolchain that the lanes in this checkout need is
   installed and that every pin has a consumer. Pins for a lane you never rendered are
   reported as skipped, not missing. If it is red, open the repo in the dev container
   (step 5) instead of debugging your laptop.
5. `make test` and you have a green run with no code of your own in it.

**Route B: from the stack, with a language lane**

```bash
bazelisk run //scripts:new-repo -- my-tool --lane python
```

That renders the tokens, overlays the lane's toolchain plus its hello world and
tests, runs `git init`, and pushes to GitHub. Drop `--lane` for the default `shell`
lane; repeat the flag for more than one.

## What you get

| Feature                    | Status | Where                                                                  |
| -------------------------- | ------ | ---------------------------------------------------------------------- |
| One command surface        | yes    | [Makefile](Makefile) -- `make help` lists it                           |
| Pinned toolchain, one file | yes    | [tool-versions.env](tool-versions.env)                                 |
| Toolchain doctor           | yes    | `make doctor` -- fails on a missing or drifted pin for a lane you have |
| Test dispatcher, any lane  | yes    | [tests/run.sh](tests/run.sh)                                           |
| Agent contract             | yes    | [AGENTS.md](AGENTS.md) -- which check first, what counts as done       |
| Strict-built docs          | yes    | [docs/](docs/README.md), [ADRs](docs/adr/template.md)                  |
| Dev container              | yes    | [.devcontainer/](.devcontainer/README.md)                              |
| Container build            | yes    | [Dockerfile](Dockerfile), `Dockerfile.test`                            |
| Git hooks + secret scan    | yes    | `make hooks`, `.pre-commit-config.yaml`                                |
| CI                         | yes    | `.github/workflows/ci.yml` runs the same `make` targets                |
| Your code                  | no     | [src/](src/README.md) -- that is the part you write                    |

## Supported platforms

| Platform              | Status  | Notes                                                                |
| --------------------- | ------- | -------------------------------------------------------------------- |
| Linux, amd64          | yes     | the reference platform                                               |
| Linux, arm64          | yes     | dev container and images are arch-aware                              |
| macOS (Apple silicon) | partial | works; run the checks inside the dev container for identical results |
| Windows               | partial | via WSL2 or the dev container                                        |
| Docker 24+ / Podman   | yes     | multi-stage, rootless, non-root `USER`                               |

## Getting started

```bash
make doctor      # is my toolchain what CI will use?
make test-fast   # ~2 seconds: the shell lane, plus proof every runner exists
make lint        # every static check for the lanes present
make test        # every lane
make validate    # the local mirror of CI
make help        # the whole surface, self-documented
```

**Which check do I run first?** [AGENTS.md](AGENTS.md) has the cost-tiered table --
cheap targeted test, medium fast suite, expensive hermetic run. Start at the top and
only descend when the cheaper tier cannot answer your question.

Layout, in one pass:

```text
AGENTS.md            the contract: read before you edit
Makefile             the only command entry point
tool-versions.env    every version pin, and the rule that a key needs a consumer
Dockerfile           multi-stage runtime image (base/deps/builder/runner)
Dockerfile.test      separate test image, parameterised by TEST_MODE=unit|all
docs/                ARCHITECTURE.md, project-conventions.md, adr/
src/                 your code; the lane overlay adds the entry point
tests/run.sh         language-neutral dispatcher; a missing runner is an error
.evo-lanes/          optional language overlays (removed after scaffolding)
```

## Language lanes

A lane is an overlay: its toolchain, its hello world, and its tests. `tests/run.sh`
discovers whatever is present and runs it, so adding a lane never needs a Makefile
edit.

| Lane              | Installs / adds                                                                | Tests run by                 |
| ----------------- | ------------------------------------------------------------------------------ | ---------------------------- |
| `shell` (default) | shellcheck, shfmt, bats; `src/main.sh` plus bats tests under `tests/`          | `bats tests/*.bats`          |
| `python`          | ruff, mypy, pytest, coverage; a `__PROJECT_MODULE__` package, `pyproject.toml` | `python3 -m pytest -q tests` |
| `typescript`      | Node, tsc, eslint, prettier, vitest; `src/` TS sources, `package.json`         | `npm test`                   |
| `go`              | the Go toolchain and golangci-lint; a `go.mod` module and package tests        | `go test ./...`              |

Each lane's tools come from the same pins in `tool-versions.env`, in the dev
container and in CI alike.

## Configuration

**`.env` and `.env.example`.** Never edit or commit `.env`; it is gitignored and it
is yours. [`.env.example`](.env.example) is the shipped twin: every variable the
project reads, with a placeholder value and a comment saying what it does. The rule
is one-way -- add a variable to `.env.example` first, then read it in exactly one
place in the code. Anything that looks like a credential stays out of git entirely
(see _Secret hygiene_ in [AGENTS.md](AGENTS.md)).

**`tool-versions.env`.** One `KEY=version` per tool, no `export`, POSIX-sourceable.
It is the single source of truth, read by `.devcontainer/Dockerfile`,
`.github/workflows/ci.yml`, and `make doctor`. A key with no consumer is an error:
`make doctor` greps every consumer and fails on an orphan, because an unconsumed pin
drifts silently and looks identical to a tool someone quietly dropped. A key under a
`# -- <Lane> lane` heading is probed only when that lane is in the checkout, so a
shell-only project is never told to install the Go toolchain. Bump a version
here, nowhere else, and expect `make doctor` to be red until the dev container is
rebuilt.

**Container.** [`.devcontainer/`](.devcontainer/README.md) pins the dev environment
(Ubuntu 24.04, Zsh + Oh My Zsh, git, `gh`, Docker-in-Docker, Node LTS, Python 3.12,
non-root `vscode`) and its `postCreateCommand` verifies the toolchain rather than
installing into the running container.

## Project status

Actively maintained. This template is the current starting point for new repos in
this owner's fleet; changes land through PRs against `main` and are recorded in
[CHANGELOG.md](CHANGELOG.md) and in [docs/adr/](docs/README.md).

| Area                                            | State                              |
| ----------------------------------------------- | ---------------------------------- |
| Template core (docs, CI, container, dispatcher) | stable                             |
| `shell` lane                                    | stable                             |
| `python`, `typescript`, `go` lanes              | supported                          |
| Anything not listed                             | not built yet -- say what you need |

Roadmap: more lanes (`rust`, `java`), a release workflow with signed artifacts, and
an ADR for the lane-overlay format.

## License

Released under the license in [LICENSE](LICENSE); its copyright line names the year
and the holder you passed at render time. Contributions are accepted
under the same terms -- see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Report a security issue privately through
[SECURITY.md](SECURITY.md), not a public issue.
