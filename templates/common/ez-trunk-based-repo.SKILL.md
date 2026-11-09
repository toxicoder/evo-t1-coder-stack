---
name: ez-trunk-based-repo
description: "Convert any repository onto trunk-based development: only the trunk stays long-lived; development, staging and production become GitHub Environments, compose projects, namespaces or inventory groups instead of git branches; unfinished work lands on trunk behind a flag off by default; every other branch is inventoried, ported, or listed for deletion with its tip SHA. Triggers: trunk-based, environment branches, feature flags, branch cleanup, convert this repo to trunk-based. Run as /ez-trunk-based-repo [repo-path] [--dry-run]."
when-to-use: "When a repo carries development/staging/production branches, long-lived feature branches, or per-environment builds. Any stack: Compose, existing K3s, Ansible, Terraform/ArgoCD, Bazel, manage.sh, Coder templates, JS/TS apps."
argument-hint: "[repo-path] [--dry-run]"
compatibility: "Any git repository with one remote, on Linux or macOS; needs git and the repo's own gate."
metadata:
  author: "operator"
  short-description: "Collapse a repo onto one trunk: environments as config, flags off by default."
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["ez-trunk-based-repo"]`
     under `[skills]` in `~/.grok/config.toml`. -->

# Convert a repository to trunk-based development

Cut each work branch (`feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `ci/`) from the tip of trunk before the
first edit, merge it by pull request within days, delete it on merge. Run every command below with your shell tool
(`run_terminal_command`); inline text runs nothing by itself. `--dry-run`: Phase 0 and the report only.

## Ideal State Criteria

Binary. Unproven is a fail with its reason; each needs command output in the report.

1. One trunk: `git ls-remote --heads origin` lists trunk plus approved-keep only: no `dev`, `development`,
   `staging`, `qa`, `uat`, `prod`, `production`, `release/*`.
2. Nothing lost: `git rev-list --count` is `0` per retired branch or its commits are recorded ported; each
   proposed deletion carries its tip SHA.
3. Gated trunk: one CI job runs the repo's full gate on `pull_request` and on `push` to trunk, and it passes on
   the final commit, summary quoted.
4. Naming: every open branch matches `^(feat|fix|refactor|docs|chore|ci|test|perf|build)/` and is younger than
   14 days or the stated target.
5. One artifact: each environment has one value home (GitHub Environment, compose project plus env file, namespace
   or overlay, inventory group, host) and deploys from a trunk checkout.
6. Promotion names one ref or digest for every environment; no deploy path reads a branch name.
7. Flags: one checked-in file declares each with `default: false`, owner, expiry, and one reader; the gate runs
   both states.
8. No committed secrets: `git ls-files | grep -E '(^|/)\.env($|\.[a-z]+$)'` returns only sample names.
9. Docs agree: branching doc, `CONTRIBUTING.md`, agent file state the model; a retired branch name survives only
   in the retirement note.

## Phase 0 -- Inventory (read-only)

Write findings to `/tmp/ez-trunk-based-repo/inventory.md` and reuse them verbatim in the report. No edits, commits,
or ref moves. Budget 20 shell calls; at 20 stop probing and start deciding. Run the branch trio per non-trunk
branch (`-` in `git cherry` means the patch is already upstream, so real work shows as `+`):

```bash
git fetch --all --prune
TRUNK=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||'); echo "$TRUNK"
git for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:short) %(authorname)' refs/remotes/origin
git rev-list --count "origin/$TRUNK..origin/$BRANCH"
git log --oneline --no-merges "origin/$TRUNK..origin/$BRANCH" | head -30
git cherry -v "origin/$TRUNK" "origin/$BRANCH" | head -30
ls -d compose*.y*ml k8s overlays helm ansible inventories terraform envs argocd .coder templates config .github/workflows .env.example package.json Makefile manage.sh MODULE.bazel 2>/dev/null
grep -rlE 'FEATURE_|_ENABLED|profiles:' --include='*.y*ml' --include='*.tf' --include='*.sh' . | head -20
```

Name the gate you must not break (`package.json` scripts, `Makefile` targets, `MODULE.bazel`, CI steps; e.g.
`npm test`, `pytest`, `bazelisk test //:test-fast`) and run it now, so a later red is yours to attribute. Record
how the repo deploys and each environment's gaps in hosts, ports, namespaces, project names, sizes, secrets: value
gaps to Phase 2, code gaps to Phase 3.
Exit: trunk; branches with age, author, unique count, verdict; deploy mechanism; gate and result; flag surface;
environment list.

## Phase 1 -- Write the trunk rules down

Edit the doc that exists; add no parallel one.

- `docs/branching.md`: trunk alone long-lived; the prefix set; cut from the tip of trunk before the first edit;
  the lifetime target; rebase your own branch when trunk moves, never a shared one; merge by pull request; delete
  on merge; imperative commit prefixes.
- `CONTRIBUTING.md`: the same for humans, plus: environments are not branches, unfinished work ships behind a flag
  off by default.
- The agent file (`AGENTS.md`, else `CLAUDE.md`): eight lines stating the model and naming this slash command;
  agent sessions load it every turn, which makes it durable.
- CI: one job runs the full gate on `pull_request` and on `push` to trunk; deploy jobs pick the environment with
  `environment:` plus a ref or tag input. Name the GitHub Environments and attach secrets and protection rules:
  that review is the gate a branch name used to fake (`gh api` or the UI).

Move no ref here; a default-branch rename is its own confirmed step, in Phase 4.
Exit: three docs state one model, CI gates trunk, no deploy path reads a branch name.

## Phase 2 -- Environments without environment branches

An environment differs in values, secrets, and where it runs; split each environment branch's diff three ways:
value, secret, flag. Keep parameter names identical across environments.

**Docker Compose.** Knob: project name plus env file; `-p` isolates networks, volumes and names, so two stacks
share a host. Run `docker compose -p app-dev --env-file .env.dev up -d`, then the same with `-p app-stable`.
Promotion: one image tag, another `--env-file`. Optional services go under `profiles:`.

**Kubernetes / K3s** (where it already runs; never add it). Knob: namespace plus one overlay or values file;
promotion edits a tag. Run `kustomize edit set image <img>=<img>:<tag>` then `kubectl apply -k overlays/staging`,
or `helm upgrade --install app ./chart -f values/staging.yaml --set image.tag=<tag>`. Secrets come from the cluster
store, never an overlay.

**Ansible.** Knob: inventory group -- `inventories/<env>/hosts.yml`, `group_vars/<env>.yml`. Promotion reruns the
same playbook revision against another inventory: `ansible-playbook -i inventories/staging site.yml --check`, then
without `--check`.

**Terraform / OpenTofu and ArgoCD.** Knob: a workspace, or `envs/<env>/` on one shared module with its own backend
and tfvars; plan the same module revision per workspace. ArgoCD: one Application per environment at the same path
or chart; promotion is a commit bumping the image tag.

**Bazel.** Bazel owns artifact and gate and knows no environment: one target set on trunk, the environment from the
launcher (env file, compose project name, config setting). Gate with the Phase 0 Bazel targets; add none. The
published image tag is the promotion lever.

**manage.sh / Makefile.** Knob: an environment argument -- `./manage.sh deploy --env staging` or
`make deploy ENV=staging`, each reading `.env.<env>` and calling the same commands; the tag is one more argument.

**Coder templates.** Knob: a template `variable` plus each workspace's values; bump the template revision instead
of forking a template per environment. A flag reaching a workspace belongs in every template copy the repo renders.

Write promotion as pasteable commands: dev, merge, stable, against one ref or tag. Delete an environment branch only
in Phase 4, once its content is provably elsewhere.
Exit: one value home per environment, promotion block written, no deploy path takes a branch name.

## Phase 3 -- Lightweight feature flags

Climb as far as the need reaches, then stop. A flag service, SDK, or database table needs an explicit operator
request.

1. **Env var plus dotenv sample.** The default answer: read at one seam, document the key in `.env.example` with
   its off default.
2. **Compose `profiles:`** hides a whole service: `profiles: ["experimental"]`, opted into with
   `--profile experimental`, so a plain `up` stays clean.
3. **A checked-in `config/flags.yaml`**, once a reviewer cannot hold the switches or one tree runs differently per
   environment. Most target repos have none, so create it on this schema:

```yaml
# Checked in, so no secret belongs here: a secret goes in the GitHub Environment or the env file the deploy
# reads. Precedence, highest first: process environment, then stacks.<deploy-target-name>.<FLAG>, then
# flags.<FLAG>.environments.<env>, then flags.<FLAG>.default.
version: 1
flags:
  FEATURE_EXPERIMENTAL_INDEXER:
    default: false
    owner: search-team
    description: "Run the experimental indexer sidecar. Incomplete: no backfill."
    expires: 2027-03-31
    compose_profile: experimental
    environments:
      dev: true
      staging: false
      production: false
```

4. **The platform's parameter surface** when the flag selects infrastructure: Coder template variables, Terraform
   variables, Helm values, Ansible vars.

Every flag: named exactly as the process reads it, so grep audits completely; off by default on trunk, since an
on-by-default flag is an unfinished feature that became load-bearing; owned, with an expiry (a date, or a condition
a human can check); read at one seam and branched there, so retiring is one edit and a grep; deleted with its
off-path and any branch still carrying it, in one later `chore:` pull request. Both states are real code: run the
plain gate, then the gate and your smoke command with `FEATURE_EXPERIMENTAL_INDEXER=1`, quoting all three.
Exit: every flag declared with owner, expiry, false default, one reader, on/off output quoted.

## Phase 4 -- Branch cleanup and preservation

One verdict per non-trunk branch, from the Phase 0 inventory.

| Verdict | Test | Action |
| --- | --- | --- |
| merged | `rev-list --count` is `0`, or `git cherry` marks every commit `-` | list for deletion |
| superseded | its files exist on trunk in another form | list, citing the superseder |
| port | small, complete, still wanted | re-adapt on a new short-lived branch, pull request |
| preserve | valuable, incomplete | port behind a flag that defaults off, pull request |
| dead | no value, or abandoned | list for deletion with the evidence |
| release-bearing | carries a version nobody tagged | tag the tip, push it, then list it |

Porting is re-adaptation, not cherry-pick archaeology. Run `git switch -c feat/<slug>-port "origin/$TRUNK"`, then
`git checkout "origin/$BRANCH" -- <paths>`, read every file, and delete what trunk does better; use
`git cherry-pick -x <first-sha>..<last-sha>` only for a coherent run you want verbatim. Wire anything unfinished
behind a flag and run the gate before opening the pull request.

Deletion is a human action. Record `git rev-parse origin/<branch>` per proposed branch first: a recorded SHA
survives until garbage collection, an unrecorded one does not. Present the table (branch, age, author, unique
commits, verdict, evidence, recovery SHA) with `git push origin --delete <branch>` and
`git fetch --all --prune`, then wait for explicit confirmation: hand the commands over, do not run them. When the
real trunk is a rename (work lives on `development`), converge content first, then propose the rename as its own
confirmed step.
Exit: every branch has a verdict and a recorded tip SHA, nothing deleted without a yes, each port has its pull
request open.

## Phase 5 -- Verification and docs polish

1. Re-run all 9 criteria; keep each proof.
2. Exercise every new flag off and on; quote both runs.
3. Confirm no environment branch remains (`git ls-remote --heads origin`) and that
   `grep -rn -w "<retired-branch>" docs/ CONTRIBUTING.md AGENTS.md` finds only the retirement note; fix every
   relative link you added and give every code fence a language.
4. Confirm no secret landed: the criterion 8 grep, then `git diff --name-only "$TRUNK"`, then read each new file
   looking for a real value.

Exit: each criterion passes or is reported unmet with its reason, gates quoted green, `git status --short` empty.

## Stack adaptation notes

Phase 0 discovers the specifics; these four named users are orientation, not fact, and the checkout outranks the
note. A branch `0` ahead is a cleanup with a confirmation in front of it; hundreds ahead is a porting programme.

- **`toxicoder/evo-t1-coder-stack`** (Bazel, trunk `main`): confirm the gate labels (`//:test-fast`, `//:lint`,
  `//:test-all`) from `BUILD.bazel` and CI before quoting them. Environment branches are already forbidden
  there, so expect merged branches waiting on a confirmed delete; a flag reaching a workspace belongs in every
  template copy the repo renders.
- **`toxicoder/nvidia-dgx-spark-lab`** (branch `development`; Compose-shaped): check first for one compose file per
  subsystem and for hardcoded published ports, which block two environments on one host, and for any existing
  overlay or inventory home before inventing one. Expect `development` to hold real work: budget slices behind
  flags.
- **`toxicoder/ez-comfy-stack`** (branch `development`; image and model heavy): the published image tag is the
  promotion lever, so confirm the publish workflow and its tag format first, and check where weights and model
  caches live and whether they are ignored; a committed artifact is a different problem from code.
- **`toxicoder/inkorporated`** (branch `development`; JS/TS app with a dev server): confirm the test and lint
  scripts from `package.json` and whether the dev server reads config from the environment, which is where flags
  go. With infrastructure directories beside the app, the gate may be a build-system target rather than `npm test`.

## Safety constraints

- No force-push, no rewriting a shared branch, no moving the trunk ref, no merging your own pull request unless
  the operator asks.
- No remote branch deleted without explicit confirmation: deliver the table and the commands.
- No secret in a committed file, the flags file included; samples carry key names and inert defaults. Never read
  `.env` or `.env.*`: name the CLI that prints the value, or ask the operator.
- Prefer extending a script, target, or gate that exists: no new CI system, platform, or dependency; no Kubernetes
  where there is none; no flag service.
- One logical change per branch and pull request; docs and tests move with the behaviour.
- Keep the repo's existing gates green throughout; name them as Phase 0 found them, never invent one.
- If the tree is dirty when you arrive, say so and work around it; report an incomplete step with its reason.

## Required output when the run ends

Print exactly these sections, in order, quoting command output rather than paraphrasing it.

    ## Summary            <repo, trunk, one paragraph; the gate command with its summary line>
    ## Changes made       <file by file, with its commit, or "none" under --dry-run>
    ## Branch decisions   | Branch | Age | Author | Unique commits | Verdict | Evidence | Recovery SHA |
    ## Promotion commands <dev -> trunk -> stable, one pasteable block against one ref or tag, per environment>
    ## Flags introduced   | Flag | Default | Guards | Owner | Expiry | Where declared | Where read | On/off proof |
    ## Deletions pending confirmation  <exact commands for the operator to run, or "None.">
    ## Next manual steps  1. <numbered handoffs: GitHub UI clicks, secrets to move into Environments,
                             protections to set, any default-branch rename still owed, flags to retire and when>
