# Keeping a checkout's config current

Two kinds of file go stale in this repo, and because neither of them is
checked in, `git pull` cannot fix either one for you. `update-configs` is the
one command that refreshes both, and it is written to be safe to run when you
are not looking closely at the diff.

```sh
bazelisk run //scripts:update-configs -- env --dry-run
bazelisk run //scripts:update-configs -- env --interactive
bazelisk run //scripts:update-configs -- workspace --dry-run
bazelisk run //scripts:update-configs -- all
```

Run it after you pull, not before: a pull is what changes the templates these
tools copy from.

## What goes stale

**The env files.** `docker-compose.yml` builds its variable references in two
steps: `${VAR}` inside `expose` expands during the shell phase, so compose
never sees those variables and a changed value needs a rebuild, and an unset
variable collapses to `127.0.0.1:57620:57620/tcp`, which fails to bind. So the
host ports and addresses live in a key=value env file - `.env` for the stable
stack, `dev-stack.env` for the dev one - and each has a checked-in twin beside
it that carries the keys and explains them in the comment lines above. A pull
that renames, adds or retires a key silently changes what the stack runs on.

**The workspace config.** `~/.grok/AGENTS.md`, `~/.grok/config.toml`,
`~/.shared/vscode/settings.json`, `~/.tmux.conf` and the `~/.coder` and
`~/.agents` seeds are materialised inside each workspace when it first boots and
are never revisited after that. A re-pushed template only reaches workspaces
that have been **start**ed or **restart**ed since the push - **stop** and
**start** is what re-runs the provisioning script and therefore re-runs
`before_config`.

## The two passes

`env` reconciles one env file with its twin. It keeps every value you have set,
fills a key the twin adds with the twin's default, and moves a key the twin no
longer declares into a commented trailer at the end of the file - parked, with
its value and its explanation still readable, rather than deleted. The rewrite
lands in a staging file and replaces the live file only at the end, with mode
`600` kept.

`workspace` re-materialises the stack-owned config inside the targets you name.
The reseed set is the seven home-relative targets the templates seed -
`~/.tmux.conf`, `~/.grok/AGENTS.md`, `~/.coder/AGENTS.md`,
`~/.agents/INSTRUCTIONS.md`, the two `grok-build-delegation/SKILL.md` copies and
`~/.shared/vscode/settings.json` - and the same rule applies as in
`refresh-configs`: a file is replaced only while it still carries its
`managed-by: evo-t1-coder-stack` marker (or, for the settings file, its
`"__evoxT1Stack": true` key), so a config you hand-edit in a terminal is your
file and this tool will not move it. `--force` overrides that, per run, and says
so.

`all` runs `env` and then `workspace`.

## Flags

| Flag | Effect |
|---|---|
| `--dry-run` | print the plan, write nothing |
| `-i`, `--interactive` | stop and ask about every key that still needs a value |
| `--force` | reseed workspace files that carry no marker either |
| `--from <dir>` | read the payloads from that checkout instead of this one |
| `--home <dir>` | treat that host directory as a workspace `HOME` |
| `--container <name>` | address one container by name |

Every flag goes **after** the subcommand, so `update-configs --dry-run env` is a
usage error and prints the usage rather than guessing.

`--interactive` is what makes the env pass safe to run half-awake. For every key
whose value is empty or still `change-me…`/`NOTSET` it prints the explanation the
twin carries above that key and prompts for a value. A key whose name carries
`KEY`, `SECRET`, `TOKEN` or `PASSWORD` is echoed nowhere - the report says `set`
or `empty` and the prompt does not echo what you type - so a screenful of this
output is safe to paste into an issue. With no terminal to prompt through the
pass warns and leaves those keys alone, which is why `--dry-run` is the shape
that belongs in a script or CI.

## Where to run it

`workspace` addresses docker, so run it from a **host** shell. A terminal inside a
workspace is not a host shell: the `docker` CLI there is only installed so you can
drive that workspace's own DinD sidecar, so `docker ps` answers empty and an empty
`docker ps` means "wrong vantage", not "stack down". The pass now prints which
daemon it addressed and tells you to use a host shell, or to name the target:

```sh
bazelisk run //scripts:update-configs -- workspace --home ~/scratch/home
bazelisk run //scripts:update-configs -- workspace --container coder-alx-main
```

`--home` takes a host directory shaped like a workspace `HOME`, which is also how
you try a change on a scratch tree before pointing a live stack at it. See
[troubleshooting.md](troubleshooting.md) for the docker-vantage rules.

## What it will not do

- It never prints an env value that looks like a credential.
- It never drops a key your env file still sets; retired keys are commented out
  in place.
- It does not touch `~/.grok/config.toml`. That file is rendered *inside* the
  workspace, and `~/.grok` is one profile volume per owner, so a copy from the
  host would move the model list, the session-affinity key and the editor keys
  of every workspace sharing the profile. A **start/restart** re-renders it from
  this checkout, which is the only way a per-workspace value gets in, and the
  pass says so after it reseeds.
- `~/.shared/vscode/settings.json` is the one rendered target it does reseed, and
  it re-*renders* rather than copies: `${litellm_url}` and the `$${...}`
  dollar-brace unfoldings are rewritten, and that workspace's own `cline.apiKey`
  and `roo.openaiApiKey` are carried forward.

Inside a running container the same seven targets are `refresh-configs`'s job
too: same reseed set, same marker rule, and `--json` for a machine-readable
answer. [grok-build-and-agents.md](grok-build-and-agents.md) covers the profile
volume and what seeds on first boot.
