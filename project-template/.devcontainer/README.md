# Dev container

One command gets you the exact toolchain CI uses. Everything here is pinned by
[../tool-versions.env](../tool-versions.env); nothing in this directory hardcodes a
version.

## Open it

- **VS Code**: install `Dev Containers`, then `Dev Containers: Reopen in Container`.
- **CLI**: `devcontainer up --workspace-folder .`
- **Plain Docker** (no features applied, still a usable shell):

  ```bash
  docker build -f .devcontainer/Dockerfile -t __PROJECT_SLUG__-dev .
  docker run --rm -it __PROJECT_SLUG__-dev zsh
  ```

## What is in it

| Layer                      | Source of truth                                                 |
| -------------------------- | --------------------------------------------------------------- |
| Base image                 | `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`             |
| Shell, prompt              | Zsh + Oh My Zsh, set as the default shell                       |
| Git, `gh`, Docker          | devcontainer features (`git`, `github-cli`, `docker-in-docker`) |
| Node, Go, Python CLI tools | `Dockerfile`, from `tool-versions.env`                          |
| User                       | `vscode` (uid 1000), `remoteUser: vscode`                       |
| Sizing                     | `hostRequirements`: 2 cpus, 4gb, 10gb                           |

`postCreateCommand` runs `make doctor && make test-fast`. It **verifies** the
container instead of installing into it: if a pinned tool is missing or answers
`--version` with a number that is not in `tool-versions.env`, the container start
fails and tells you which key is wrong. That is deliberate -- a container that
"starts fine" with a drifted tool is how a green CI comes to mean nothing.

## Rebuild rules

- After editing `tool-versions.env`: `Dev Containers: Rebuild Container`. The image
  build re-probes every tool, so a bad pin fails the build rather than the pipeline.
- After editing `devcontainer.json` features: rebuild too; features are applied on
  top of `Dockerfile`, so both are re-run.
- Do not `pip install` / `npm install -g` into a running container to "make a check
  pass". Fix the pin or the Dockerfile line so the next person gets it too.

## Why this directory exists at all (parent stack)

This directory is not only for VS Code. Its presence is the signal the parent
`evo-t1-coder-stack` stack reads: `new-workspace.sh` probes the target repo for
`.devcontainer/` and routes the repo to Coder's **`devcontainer`** template when it
finds one, and to the plain **`workspace`** template when it does not. Deleting or
renaming this directory silently changes how the repo is provisioned on the stack --
you would land on the plain workspace template, without this image, and nothing
would announce the difference.

If you deliberately want the plain template, remove `.devcontainer/` in its own
commit and say so in the message.
