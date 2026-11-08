---
name: trunk-refactor
description: "Refactor a repository onto trunk-based development with lightweight feature flags and branch cleanup: only the trunk stays long-lived, environments become config instead of git branches, incomplete work lands on trunk behind a flag that defaults off, and every other branch is inventoried, ported, or listed for deletion. Use when asked to go trunk-based, kill the development/staging/production branches, collapse environment branches, set up feature flags, migrate dev->main->prod promotion, or clean up stale branches. Triggers: trunk-based, trunk based development, kill the development branch, environment branches, GitHub Environments, feature flags without a flag service, branch cleanup, promote the same commit everywhere. Run as /trunk-refactor."
when-to-use: "When a repository carries environment branches, long-lived feature branches, or per-environment builds, and the operator wants the trunk-based + flags model instead. Works on any stack: Compose, K3s/Kustomize/Helm, Ansible, Terraform/OpenTofu with ArgoCD, Bazel, manage.sh or Makefile entry points, Coder templates."
argument-hint: "[repo-path] [--dry-run]"
---

<!-- managed-by: evo-t1-coder-stack -->

# Trunk-based + feature flags + branch cleanup

Collapse a repository onto one long-lived branch, move every environment out of git and
into config, put unfinished work behind a flag that defaults off, then deal with the
branches that are left. The full prose with worked examples is
`docs/workflows/trunk-feature-flags-refactor.md`; this body is the procedure.

Run every command with your shell tool (`run_terminal_command`) and read files with
`read_file`. A command written in this body runs nothing until you run it.

Two numbers to keep in view: the phase count (6) and the criteria count (12). Nothing is
done until all 12 criteria pass, and the report at the end is a deliverable, not a summary.

## The model

1. `main` (or whatever the trunk is called) is the only long-lived branch and is always
   deployable.
2. `development`, `staging`, `production` are environments: secrets plus protection rules
   plus a value set. They are never git branches.
3. Work happens on short-lived branches (`feat/`, `fix/`, `refactor/`, `docs/`, `chore/`,
   `ci/`) cut from the tip of trunk and merged by pull request within days.
4. Anything unfinished lands on trunk behind a flag that defaults off.
5. Promotion applies the same commit or tag to a different environment. The artifact does
   not change between environments; only its values do.
6. Branch cleanup is part of the job: inventory, port what is valuable, list the rest.

## Ideal State Criteria

Each is binary. Prove it with the command, in the phase that creates it, and paste the
result into the final report. A criterion you could not prove is reported as unmet with
the reason; "should be fine" is a fail.

1. **One trunk.** `git ls-remote --heads origin` lists the trunk plus only branches on the
   approved-keep list. No `development`, `staging`, `qa`, `prod`, `production`, or
   `release/*` branch is live.
2. **Nothing stranded.** For every retired branch:
   `git rev-list --count origin/trunk..origin/<branch>` returns `0`, or its unique commits
   are recorded as ported in the report.
3. **Deployable trunk.** CI runs the repo's full gate on every pull request and on every push
   to trunk. Proof: `grep -n -A6 '^on:' .github/workflows/*.yml` (or the platform's own
   trigger file) shows both, and you can name the job that runs the gate.
4. **Naming enforced.** Every open branch matches `^(feat|fix|refactor|docs|chore|ci|test|perf|build)/`
   and `git for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:short)' refs/remotes/origin`
   shows nothing older than the agreed branch lifetime (default 14 days).
5. **Environments are config.** Each environment has exactly one named home for its values.
   Proof: `ls .env.* overlays/ inventories/ envs/ 2>/dev/null` (whichever the stack uses)
   names one home per environment, and every environment deploys from a trunk checkout.
6. **One artifact, many targets.** Proof: the promotion block pastes into a shell as written,
   and the same ref or image digest appears on both the dev and the stable side -
   `git rev-parse HEAD` on trunk equals the ref the stable deploy names.
7. **Off by default.** Every unfinished or experimental path is guarded by a named flag whose
   default is off on trunk: `grep -rn '<FLAG>' config/ .env.example .env.sample` shows the
   default as false.
8. **Complete flag inventory.** One checked-in file lists every flag with default, owner, and
   expiry: `ls config/flags*.yaml` finds it, and for each declared name
   `grep -rn "<FLAG>" .` finds a reader, while every read name has a declaration. No orphan in
   either direction.
9. **No secrets committed.** `git ls-files | grep -E '(^|/)\.env($|\.[a-z]+$)'` returns only
   sample/template names. Real secrets live in GitHub Environments or an untracked env file.
10. **Docs agree.** The branching doc, `CONTRIBUTING.md`, and `AGENTS.md` (or `CLAUDE.md`)
    all state the trunk model, and
    `grep -rn -w '<retired-branch>' docs/ CONTRIBUTING.md AGENTS.md` returns only the
    retirement note that mentions it.
11. **Gates green.** The repo's own pre-existing gate command
    (`bazelisk test //:test-fast`, `npm test`, `make test`, `./manage.sh <check>`, `pytest`)
    passes on the final commit, quoted with its summary line.
12. **Nothing destroyed.** `git ls-remote --heads origin` still lists every branch from the
    Phase 0 inventory that no one confirmed, and the report carries
    `git rev-parse origin/<branch>` for each branch proposed for deletion.

## Phase 0 - Inventory

Read-only. Make no edits and no commits. Write findings to a scratch file
(`/tmp/trunk-refactor/inventory.md`) and reuse them verbatim in the report.

1. Branches and their real state:

       git fetch --all --prune
       git remote -v
       git for-each-ref --sort=-committerdate \
         --format='%(refname:short)\t%(committerdate:short)\t%(authorname)' refs/remotes/origin
       git symbolic-ref refs/remotes/origin/HEAD   # the default branch

2. Unique work per candidate branch (do this for each non-trunk branch):

       base=$(git merge-base origin/trunk origin/<branch>)
       git rev-list --count "$base..origin/<branch>"          # commits not on trunk
       git log --oneline --no-merges "$base..origin/<branch>" | head -50
       git diff --stat "$base" "origin/<branch>" | tail -5
       git cherry -v origin/trunk "origin/<branch>" | head -50  # [-] = already merged

3. Deployment mechanism. Detect it; never assume it:

       ls | grep -iE '^(docker-compose|compose)' ; find . -maxdepth 3 \
         \( -name 'compose*.yml' -o -name 'compose*.yaml' -o -name 'docker-compose*.yml' \) \
         -not -path '*/node_modules/*' | head -20
       ls -d k8s kubernetes manifests overlays base charts helm ansible playbooks inventories \
         terraform tofujit envs stacks argocd kustomize 2>/dev/null
       ls MODULE.bazel WORKSPACE BUILD.bazel MODULE.bazel.lock manage.sh Makefile 2>/dev/null
       ls .github/workflows 2>/dev/null
       ls -d .coder *.tf templates/* 2>/dev/null

4. Existing flags and env surface (keys only, never values from a populated dotenv):

       grep -rnE '^[A-Z][A-Z0-9_]*=' .env.example .env.sample 2>/dev/null | cut -d= -f1 | head -60
       grep -rnE 'FEATURE_|_ENABLED|^profiles:' --include='*.yml' --include='*.yaml' \
         --include='*.tf' --include='Makefile' --include='*.sh' . | head -40
       grep -rnE '^\s*profiles:' --include='compose*.y*ml' --include='docker-compose*.y*ml' .
       ls config/flags* flags.* 2>/dev/null

   Read `.env.example` or `.env.sample` for key names. A populated `.env` is off-limits:
   name the operator CLI that prints the value instead.

5. The gate to keep green, from what is on disk: Bazel (`bazelisk test //:test-fast` then
   `//:lint`), npm (`npm test`, `npm run lint`), `make test`, `./manage.sh <check>`,
   `pytest`, `go test ./...`, `cargo test`. Record the exact command and run it now, before
   you touch anything, so a later failure is yours or is not.

6. Environments in use today, and how each differs from the others: values, secrets, hosts,
   namespaces, ports, resource sizes. Where two environments differ by *code*, that is the
   work of Phase 2 and Phase 3.

Record in the inventory file: trunk name, every branch with age/author/unique-commit count/
classification draft, deployment mechanism, gate command, flag surface, environment list.

## Phase 1 - Establish the trunk-based rules in writing

Docs first: a branch model nobody wrote down gets re-litigated by the next session.

- `docs/branching.md` (create or rewrite): trunk is the only long-lived branch; branch
  prefixes and their meaning; cut from the tip of trunk; lifetime target and what to do when
  trunk moves under you (rebase your own branch, never a shared one); merge by pull request;
  delete on merge; commit prefixes with an imperative summary.
- `CONTRIBUTING.md`: the same rules for humans, plus two sentences the branching doc states
  in full - environments are not branches, and unfinished work ships behind a flag that
  defaults off.
- `AGENTS.md` (or `CLAUDE.md`): a short non-negotiable block, eight lines at most, that
  states the model and points at the skill and this doc. Future agent sessions load this file
  every turn; it is where the model becomes durable.
- Environments as GitHub Environments: name them (`development`, `staging`, `production`),
  attach protection rules and secrets per environment, and have the deploy job declare
  `environment: <name>`. Configure in the UI or with `gh api`; the commands are in the docs
  file. An environment's protection review is the gate that a branch name used to fake.
- CI: one job runs the full gate on `pull_request` and on `push` to trunk; deploy jobs pick
  their environment by `environment:` and a ref or tag input, never by branch name.

Do not rename the trunk or delete anything in this phase. A default-branch rename is its own
confirmed step (Phase 4) because GitHub rewrites links, PRs, and protections when it happens.

## Phase 2 - Environments without environment branches

Pick the row that matches what Phase 0 found. An environment may differ from another in three
things only: values, secrets, and where it runs. Any other difference is code, and code goes
to Phase 3 behind a flag.

| Stack | The environment is | Its values live in | Promotion |
| --- | --- | --- | --- |
| Docker Compose | project name plus env file | `docker compose -p <app>-<env> --env-file .env.<env> up -d`; optional services behind `profiles:` | same image tag, different `--env-file` |
| K3s / Kubernetes | namespace | `overlays/<env>/` (Kustomize `namespace`, `namePrefix`, patches) or `values/<env>.yaml` (Helm) | `kustomize edit set image` / `--set image.tag=` on the same digest |
| Ansible | inventory group | `inventories/<env>/hosts.yml` plus `group_vars/<env>.yml` | same playbook and role version, `-i inventories/<env>` |
| Terraform / OpenTofu | workspace or `envs/<env>/` | per-env backend, `terraform.tfvars`, one module per stack | plan the same module revision per workspace |
| ArgoCD | Application | `applications/<env>-*.yaml` pointing at one Kustomize/chart path | a commit that bumps the image tag |
| Plain hosts | host plus env file | one env file and one unit per host, templated from trunk | redeploy the same release tag |
| Coder / template params | template variable | `variable` in the template plus the workspace's own values | bump the template revision, not a branch |

Steps:

1. List what each environment branch changed versus trunk. Each change becomes either a value
   in that environment's file, a secret in the environment store, or a flag.
2. Give the values a home per the table, and make the parameter names the same across
   environments so one file diffs against another with no noise. Ports, hostnames, replica
   counts, and resource sizes are values.
3. Write the promotion path as commands a tired person can paste: the dev stack command, the
   merge, then the stable stack command, all against one ref or tag.
4. Delete the environment branch only in Phase 4, after its content is provably elsewhere.

Compose details that matter: a distinct `-p <project>` per environment isolates networks,
volumes, and container names; parameterize every published port (`"${APP_PORT:-3000}:3000"`)
so two environments can coexist on one host; put optional services under `profiles:` and a
flag.

## Phase 3 - Lightweight feature flags

Use the first mechanism that carries the need. Stop there.

1. **Environment variable plus dotenv sample.** The default for any code path. Read it at one
   seam, document the key in `.env.example` / `.env.sample` with its off default.
2. **Compose `profiles:`** when the thing to hide is a whole service rather than a branch of
   code: `profiles: ["experimental"]` plus `--profile experimental` to opt in.
3. **A checked-in `flags.yaml`** (or `config/flags/`) when more than a handful of switches
   exist, or when the same tree runs in several environments with different settings. Copy
   `config/flags.yaml.example`; keep the schema (default, owner, description, expires,
   environments, per-stack overrides) and let the real process environment still win.
4. **The platform's own parameter surface** when the flag selects infrastructure: Coder
   template variables, Terraform variables, Helm values, Ansible vars.

Do not add a flag service, an SDK, a database-backed flag table, or per-request flag plumbing
unless the operator asks for it by name.

Rules that make flags survivable:

- One naming convention repo-wide; `FEATURE_<THING>` for behaviour, a plain value for a
  setting. The key in the flags file is the exact name the process reads.
- Off by default on trunk. An on-by-default flag is a feature that was never finished and is
  now load-bearing.
- Every flag carries an owner and an expiry (a date, or a condition a human can check). A flag
  past its expiry is deleted along with its off-path in one `chore:` pull request.
- Read the flag in one place and branch there, so deleting it later is one edit and a grep.
- The gate runs with the flag off, and at least one test or documented smoke command exercises
  it on. Both states are real code.
- `grep -rn "<FLAG>" .` is the inventory check: a declared name nobody reads is dead, a read
  name nobody declared is invisible to a reviewer.

## Phase 4 - Branch cleanup and feature preservation

Classify every non-trunk branch from the Phase 0 inventory. One row each, one verdict each:

| Verdict | Test | Action |
| --- | --- | --- |
| merged | `rev-list --count` is 0, or `git cherry` shows all `-` | list for deletion |
| superseded | its files exist on trunk in another form | list for deletion, citing what superseded it |
| port | small, complete, still wanted | new short-lived branch, re-adapted to trunk, PR |
| preserve | valuable and incomplete | port behind a flag that defaults off, PR |
| dead | no value, or explicitly abandoned | list for deletion with the evidence that says so |
| release-bearing | carries a version nobody tagged | tag the tip, push the tag, then list the branch |

Porting is re-adaptation, not cherry-pick archaeology:

    git switch -c feat/<slug>-port origin/trunk
    git checkout origin/<branch> -- <paths>       # take the files, then read and fix them
    # or, for a coherent run of commits: git cherry-pick -x <sha>..
    <repo gate>                                    # green before you open the PR

Adapt the ported code to trunk's current structure, wire it behind a flag when incomplete, and
keep one logical change per pull request. A port that drags in a reformat is two pull requests.

Deletion is a human action:

- Never delete a remote branch on your own initiative. Present the list, with tip SHA, age,
  author, and the reason, and wait for explicit confirmation.
- Record every tip SHA in the report before anything is deleted. A branch whose SHA is
  recorded stays recoverable until garbage collection.
- Hand over the exact commands rather than running them, unless the operator tells you to.
- Never force-push, never rewrite a shared branch, never touch the trunk ref.

When the trunk itself is a rename (the working branch is `development` and the trunk should be
`main`): converge the content first, then propose the default-branch rename as a separate
confirmed step, because GitHub updates links, protections, and open PRs when it happens and
local clones need `git fetch --all --prune` afterwards.

## Phase 5 - Verify and polish

1. Re-run all 12 Ideal State Criteria and keep each proof.
2. Run the repo's own gates, quoted with their summary lines. Keep existing gates green;
   extend a script or target that already exists rather than adding a new one.
3. Docs: the branching doc, contributing, agent rules, the flags inventory, and the promotion
   commands all describe what the tree now does. Grep for the retired branch names one last
   time and confirm only the retirement note mentions them.
4. Check every relative link you added resolves, and every code fence names its language.

## Stack adaptation notes

Read the matching subsection of `docs/workflows/trunk-feature-flags-refactor.md` before you
touch a stack you do not already know. Short version, measured against the remotes on 2026-11-08
- re-run Phase 0, because these numbers move and a skill note is a hint while the checkout is the
fact:

- **`toxicoder/evo-t1-coder-stack`** (trunk `main`): Bazelisk is the ingress and the gate
  (`bazelisk test //:test-fast`, `//:lint`, `//:validate`). Environments are already dev versus
  stable stacks chosen by compose project name, dotenv file and subdomain parts, driven by
  `//scripts:dev-stack`, `//scripts:prod-stack` and `//scripts:update-stack`. `docs/branching.md`
  already forbids environment branches, yet `dev`, `development`, `staging`, `uat` and `prod`
  were still on the remote, every one of them `ahead=0` against `main`: a Phase 4 deletion list,
  not a Phase 2 problem. A new flag that reaches a workspace also needs both template twins.
- **`toxicoder/nvidia-dgx-spark-lab`** (trunk `main`, `development` 134 ahead / 27 behind):
  Bazel plus Ansible (`ansible/ansible.cfg`), Helm (`helm/lab-dashboard/values.yaml`) and
  Kustomize (`k8s/base`, `k8s/dev`, `k8s/monitoring`, `k8s/cert-manager`), with Compose for the
  dashboard and hermes. Environment-as-overlay already exists at `k8s/dev/`, so the job is to
  port the 134 commits in slices onto `main`, flag off what is unfinished, and add
  `k8s/staging/` or `k8s/production/` overlays beside `k8s/dev/` rather than a branch.
- **`toxicoder/ez-comfy-stack`** (trunk `main`, `development` 523 ahead / 19 behind): Compose
  (`docker/docker-compose.yml`) driven by `scripts/manage.sh` and a Makefile, with an
  image-publish workflow. The published image tag is the promotion lever, so land the tag story
  first. Branch families there include `feature/` and bare `docs/` names outside the sanctioned
  prefix set - normalise `feature/` to `feat/` as part of the cleanup, and expect to port in
  themed slices at that size.
- **`toxicoder/inkorporated`** (trunk `main`, `development` 0 ahead / 2 behind): Bazel plus
  Ansible and Terraform under `infrastructure/`, with `ci`, `presubmit`, `domain-validation` and
  docs-deploy workflows. `development` is already fully merged, so it is a confirmed delete.
  Before you list any branch here, check whether it is holding an unreleased migration - that is
  a port, not a delete.

The general shape: a branch that is `ahead=0` is a cleanup with a confirmation in front of it; a
branch that is hundreds of commits ahead is a porting programme that needs slicing, flags, and
several pull requests.

## Safety constraints

- No force-push, no history rewrite on a shared branch, no merge of your own pull request
  unless the operator asks.
- No remote branch deleted without explicit confirmation; deliver the list and commands.
- No secrets in a committed file, including the flags file and any per-environment value file.
  Samples carry key names and inert defaults.
- Never read `.env` or `.env.*`: use the CLI that prints the value, or read the sample for the
  key's shape.
- Prefer extending an existing script, target, or gate over adding a tool, a CI system, a
  platform, or a dependency. No Kubernetes, no flag service, no new framework.
- One logical change per branch and per pull request; docs and tests move with the behaviour.
- If the tree is dirty when you arrive, say so and work around it. Do not "tidy" changes that
  are not yours.
- A step you cannot complete is reported as incomplete with the reason. A criterion quietly
  dropped is a failed run.

## Required output format

Finish with exactly these sections, in this order. Tables stay tables; quote command output, do
not paraphrase it.

    ## Summary
    <repo, trunk name, what changed in one paragraph, gate command with its summary line>

    ## Ideal State Criteria
    | # | Criterion | Pass/Fail | Proof (command and result) |

    ## Branch decisions
    | Branch | Age | Author | Unique commits | Verdict | Evidence | Recovery SHA |

    ## Environments
    | Environment | Home (project/namespace/overlay/inventory) | Values file | Secrets | Deploy command |

    ## Flags introduced
    | Flag | Default | Guards | Owner | Expiry | Where declared | Where read |

    ## Promotion commands
    <the exact dev -> trunk -> stable sequence, one block, copy-pasteable>

    ## Deletions pending confirmation
    <exact commands for the operator to run, or "None.">

    ## Next manual steps
    <handoffs: GitHub UI clicks, secrets to move into Environments, branch protections to set,
    the default-branch rename if one is still owed, flags to retire and when>
