---
title: Trunk-based + flags refactor
description: "The full procedure for moving a repository onto trunk-based development: environments become configuration instead of git branches, unfinished work ships behind a flag that defaults off, and every other branch is inventoried, ported, or listed for deletion. Worked examples for Compose, K3s, Ansible, Terraform/ArgoCD, Bazel and manage.sh stacks."
tags: [git, branching, ci, feature-flags, environments, refactor]
---

# Trunk-based + flags refactor

**What's on this page**

- The model in six statements, and what each one rules out
- The ideal-state checklist a refactor has to satisfy before it is called done
- How an environment is expressed without a branch, per stack
- The flag ladder, from one env var up to a checked-in `config/flags.yaml`
- The branch-cleanup cookbook: classify, port, preserve, list for deletion
- Per-repository notes for the four reference repos
- The safety lines that never move

**What this enables**

- Deleting the `development` branch without losing a commit that was only ever on it
- Deploying dev, staging and production from one commit instead of three builds
- Shipping work that is not finished, on the trunk, without exposing it
- Running the same procedure in any of this fleet's repositories with `/trunk-refactor`

This is the human-readable twin of the `trunk-refactor` skill
(`skills/trunk-refactor/SKILL.md`). The skill is what an agent session follows; this page is
what a person reads, with the examples the skill leaves out to stay short. The branch rules
themselves live in [Branching](../branching.md) - this page is about getting a repository *onto*
those rules.

## The model, in six statements

1. One long-lived branch. It is normally `main`, it is always deployable, and it is what every
   environment is built from.
2. An environment is a set of values, a set of secrets, and a place to run. It is a GitHub
   Environment, a compose project, a namespace, an inventory group. It is not a git branch.
3. Work happens on short-lived branches cut from the tip of the trunk and merged by pull
   request within days: `feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `ci/`.
4. Incomplete or experimental work lands on the trunk behind a flag that defaults off.
5. Promotion is the same commit or tag applied to a different environment. Nothing is rebuilt
   per environment, because a per-environment build is a per-environment bug surface.
6. Branch cleanup is part of the work, not a chore someone does later.

What the model rules out: long-lived `development`/`staging`/`production` branches; "merge to
development first"; a release branch that has to be kept forever; cherry-picking a fix from one
environment branch to another; and a flag platform nobody asked for.

The failure that motivates all of this is the merge that goes the wrong way. A `development`
branch that is 134 commits ahead of `main` (a real number from a real repository in this fleet)
is not a staging area, it is a second product whose differences nobody is reconciling, and the
day someone finally merges it, the review is unreviewable.

## Ideal-state checklist

The skill's twelve binary criteria, in prose. Each needs a command's output as proof.

| # | Criterion | How you prove it |
| --- | --- | --- |
| 1 | One trunk, no environment branches | `git ls-remote --heads origin` |
| 2 | No branch holds commits the trunk lacks | `git rev-list --count origin/main..origin/<branch>` is `0` |
| 3 | Trunk is gated | the CI file names a job that runs the full gate on pull request and on push to trunk |
| 4 | Branch names and ages obey the rule | `git for-each-ref` over `refs/remotes/origin` |
| 5 | Every environment has one home for its values | the file or overlay exists and no branch is needed to deploy |
| 6 | One artifact, many targets | the promotion command block, pasted and working |
| 7 | Unfinished work is off by default | the flag's default reads as false in the sample dotenv or flags file |
| 8 | The flag inventory is complete both ways | `grep -rn "<FLAG>" .` finds a reader for every declaration and a declaration for every read |
| 9 | No committed secrets | `git ls-files` shows only sample dotenv names |
| 10 | The docs agree with the tree | branching doc, contributing, and agent rules say the same thing |
| 11 | The repo's own gates are green | the gate command with its summary line |
| 12 | Nothing was destroyed | no force-push, no unconfirmed remote delete, every proposed deletion carries its tip SHA |

## Inventory first

Before any edit, answer five questions and keep the answers in a scratch file:

    git fetch --all --prune
    git for-each-ref --sort=-committerdate \
      --format='%(refname:short)\t%(committerdate:short)\t%(authorname)' refs/remotes/origin
    git remote show origin | sed -n '/HEAD branch/p'

1. **Which branches exist, how old are they, who owns them?**
2. **What does each non-trunk branch hold that the trunk does not?**

       base=$(git merge-base origin/main origin/<branch>)
       git rev-list --count "$base..origin/<branch>"
       git log --oneline --no-merges "$base..origin/<branch>" | head -50
       git diff --stat "$base" "origin/<branch>" | tail -5
       git cherry -v origin/main origin/<branch> | head -50

   `git cherry` marks a commit `-` when an equivalent patch is already upstream. A branch that
   is `ahead=0` behind trunk is done, and its row reads "delete" without further argument.
3. **How is anything deployed here?** Look, do not assume: `compose*.yml`, `docker-compose*.yml`,
   `kustomization.yaml`, `values.yaml`, `inventories/`, `*.tf`, `argocd/`, `manage.sh`,
   `Makefile`, `MODULE.bazel`, `.github/workflows/`, `templates/*/main.tf`.
4. **What flags already exist?** `grep -rnE 'FEATURE_|_ENABLED|^\s*profiles:'` over the compose
   files, dotenv samples, Terraform variables and scripts.
5. **What is the gate you must not break?** `bazelisk test //:test-fast`, `npm test`,
   `make test`, `./manage.sh <check>`, `pytest`, `go test ./...`. Run it before you start so a
   later red is attributable.

## Environments without environment branches

An environment may differ from its neighbour in values, secrets, and where it runs. If a branch
differs in *code*, that code belongs on the trunk behind a flag.

### Docker Compose

Name the deployment, not the branch:

    # .env.dev and .env.staging hold values only; secrets come from the environment store
    docker compose -p comfy-dev     --env-file .env.dev     up -d
    docker compose -p comfy-stable  --env-file .env.stable  up -d

The project name (`-p`) is what isolates networks, volumes and container names, which is how two
environments share a host. Every published port has to be a value for that to work:
`"${APP_PORT:-3000}:3000"`. Optional services go behind a profile:

    services:
      experimental-indexer:
        profiles: ["experimental"]
        image: ghcr.io/example/indexer:1.4.2

so `docker compose up` stays clean and `--profile experimental` opts in.

This fleet's own dev-versus-stable split is the reference implementation: separate project
names, separate dotenv files, and a subdomain composed from parts rather than from a branch
name, driven by `bazelisk run //scripts:dev-stack -- up`,
`bazelisk run //scripts:prod-stack -- up`, and `bazelisk run //scripts:update-stack` for the
pull-and-deploy pair. In that repository the environment branches were still sitting on the
remote (`dev`, `development`, `staging`, `uat`, `prod`) while every one of them reported
`ahead=0` against `main`: five branches, zero unique commits, waiting for someone to confirm the
delete.

### K3s / Kubernetes

One namespace per environment, one overlay per environment, one image reference:

    overlays/
      base/         kustomization.yaml, deployments, services
      dev/          namespace: lab-dev,      patches, imageTag
      staging/      namespace: lab-staging,  patches, imageTag
      production/   namespace: lab-prod,     patches, imageTag

Promotion edits the tag, not a branch:

    cd overlays/staging && kustomize edit set image ghcr.io/example/app=ghcr.io/example/app:2026.11.3
    kubectl apply -k overlays/staging

With Helm the same shape is `values/dev.yaml`, `values/staging.yaml`, and
`helm upgrade --install app ./chart -n lab-staging -f values/staging.yaml --set image.tag=...`.
Secrets come from the cluster's own store or an external secret, never from the overlay.

### Ansible

The playbook is the trunk; the environment is inventory:

    inventories/
      dev/hosts.yml
      staging/hosts.yml
      production/hosts.yml
      group_vars/dev.yml
      group_vars/staging.yml
      group_vars/production.yml
      vault/production.vault.yml        # encrypted, and the only per-environment secret file

    ansible-playbook -i inventories/staging site.yml --limit app
    ansible-playbook -i inventories/production site.yml --limit app --check   # then without --check

Promotion is the same playbook revision and role versions against a different inventory. A
branch that carries playbook changes is a pull request; a branch that carries only variable
changes is a file under `group_vars/`.

### Terraform / OpenTofu with ArgoCD

Environment is a workspace or an `envs/<env>/` directory that instantiates one shared module;
`terraform plan` against `envs/staging` and `envs/production` is the same module revision twice.
ArgoCD gets one `Application` per environment, all pointing at the same Kustomize or chart path,
and promotion is a commit that bumps the image tag (by hand, or by the Image Updater). A
per-environment ArgoCD branch is a sync-drift generator and a rollback trap.

### Coder and template parameters

Where the switch selects infrastructure rather than behaviour, use the platform's own parameter
surface: a `variable` in the workspace template plus the values each workspace supplies, which is
how this stack already separates a development workspace from a stable one. Bump the template
revision; do not fork a template per environment.

## The flag ladder

Climb as far as you need and stop.

1. **One env var, read at one seam**, documented in the dotenv sample with its off default. This
   carries most needs: `FEATURE_AGENT_TUNNEL_V2=0`.
2. **Compose `profiles:`** when what you are hiding is a whole service.
3. **A checked-in `config/flags.yaml`** once there are enough switches that a reviewer cannot
   hold them, or when one tree runs in several environments with different settings. Copy
   `config/flags.yaml.example` from this repository. Keep the schema - `default`, `owner`,
   `description`, `expires`, `environments`, optional `stacks` overrides - and keep the real
   process environment winning, so CI and an operator can still force a value.
4. **The platform's parameters** (Terraform variables, Helm values, Ansible vars, Coder template
   variables) when the flag selects infrastructure.

A flag service, an SDK, or a database-backed flag table is a decision an operator makes
explicitly. It is not the default for a home lab or a single-node host, and it is never what a
first pass should add.

Rules that keep flags alive long enough to be removed:

- One naming convention. `FEATURE_<THING>` for behaviour, a plain value for a setting. The name
  in the inventory is exactly the name the process reads, so `grep` is a complete audit.
- Off by default on the trunk. An on-by-default flag is an unfinished feature that became
  load-bearing on the day it shipped.
- Owner and expiry on every flag, and one `chore:` pull request that deletes the flag, its
  off-path, and any branch still carrying it.
- Read once, branch there. A flag checked in nine modules is nine edits when it retires.
- The gate runs with it off; at least one test or documented smoke command runs with it on.

## Branch cleanup cookbook

One verdict per branch, with the evidence beside it.

| Verdict | Test | What you do |
| --- | --- | --- |
| merged | `rev-list --count` is 0, or `git cherry` marks every commit `-` | list for deletion |
| superseded | its files exist on trunk in another form | list for deletion, citing what superseded it |
| port | small, complete, still wanted | re-adapt onto a new short-lived branch, open a pull request |
| preserve | valuable and incomplete | port behind a flag that defaults off |
| dead | no value, or explicitly abandoned | list for deletion with the reason |
| release-bearing | carries an untagged version | tag the tip, push the tag, then list the branch |

Porting is re-adaptation. Take the files, then fix them against today's trunk:

    git switch -c feat/tunnel-v2-port origin/main
    git checkout origin/development -- src/tunnel/ tests/tunnel/
    # read every file you just took, delete what trunk already does better,
    # wire the unfinished path behind FEATURE_AGENT_TUNNEL_V2 (default off)
    <repo gate>

Cherry-picking is for a coherent run of commits you want verbatim, and `-x` keeps the source SHA
in the message so the provenance survives:

    git cherry-pick -x a1b2c3d..e4f5g6h

A port that also reformats is two pull requests. A port of a whole branch at once is a review
nobody does properly.

Then hand the deletions to a human:

| Branch | Age | Author | Unique commits | Verdict | Recovery SHA |
| --- | --- | --- | --- | --- | --- |
| development | 2026-11-02 | someone | 0 | delete | `a1b2c3d` |
| staging | 2026-08-14 | someone | 0 | delete | `e4f5g6h` |

with the commands they will run:

    git push origin --delete staging uat prod
    git fetch --all --prune

Record the tip SHA of every branch in that table before anything goes. A recorded SHA is
recoverable until garbage collection; an unrecorded one is not.

## Per-repository notes

Verified against the remotes on 2026-11-08. Repositories move: re-run the Phase 0 inventory
rather than trusting this table.

| Repository | Default | Environment-shaped branches | Deployment mechanism | First move |
| --- | --- | --- | --- | --- |
| `toxicoder/evo-t1-coder-stack` | `main` | `dev`, `development`, `staging`, `uat`, `prod` - all `ahead=0` | Bazel gate, Compose dev and stable stacks, Coder templates | Confirm deletion of the five merged branches; the model is already documented |
| `toxicoder/nvidia-dgx-spark-lab` | `main` | `development` (+ `dev`), `development` 134 ahead / 27 behind | Bazel, Ansible, Helm, Kustomize under `k8s/` with a `k8s/dev/` overlay, Compose for dashboard and hermes | Port the 134 commits in slices onto `main`, flag-off the unfinished ones, then retire `development` |
| `toxicoder/ez-comfy-stack` | `main` | `development` (+ `dev`), `development` 523 ahead / 19 behind, plus `feat/`, `fix/`, `feature/`, `docs/` families | Compose (`docker/docker-compose.yml`), `scripts/manage.sh`, Makefile, an image-publish workflow | Port in themed slices; the published image tag is the promotion lever, so land the tag story first and normalise the `feature/` prefix to `feat/` |
| `toxicoder/inkorporated` | `main` | `development` (+ `dev`), `development` 0 ahead / 2 behind | Bazel, Ansible and Terraform under `infrastructure/`, CI plus presubmit workflows | `development` is already merged: list it for deletion, then fix the naming families |

Two patterns worth reading across those rows. A branch family that is `ahead=0` (this repo,
`inkorporated`) is a cleanup with no risk once a human confirms it. A branch family that is
hundreds of commits ahead (`nvidia-dgx-spark-lab`, `ez-comfy-stack`) is a porting programme:
slice by area, land each slice green, and let the flags hold what is not finished. Both begin
with the same inventory, and both end with a table a person signs off on.

## Safety lines

- No force-push, no rewritten shared history, no merging your own pull request.
- No remote branch deleted without explicit confirmation, and never a trunk ref.
- No secret in a committed file, including the flags file and per-environment value files.
  Samples hold key names and inert defaults; secrets go to the GitHub Environment or the
  cluster's secret store.
- Keep the existing gates green and extend what exists. No new CI system, no Kubernetes, no
  flag platform, no new dependency.
- One logical change per branch and per pull request, with docs and tests in the same change.
- A default-branch rename is its own confirmed step, done after the content has converged,
  because GitHub rewrites links, protections and open pull requests when it happens.

## Running it

The skill is `skills/trunk-refactor/SKILL.md`. A session in this repository reaches it through
`AGENTS.md`; any other repository gets it by installing it into the two skill homes the agents
read:

    mkdir -p ~/.agents/skills ~/.coder/skills
    cp -r skills/trunk-refactor ~/.agents/skills/
    cp -r skills/trunk-refactor ~/.coder/skills/

Then, in a new session in the repository you want to convert:

    /trunk-refactor

Discovery reloads from disk, so the copy above needs a new turn before the slash command
appears. The run ends with the report the skill specifies: summary, criteria table, branch
decisions, environment mapping, flags introduced, promotion commands, deletions pending
confirmation, and next manual steps.
