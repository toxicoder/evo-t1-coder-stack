# Contributing

## Issues

- For bugs, include `docker compose ps`, the relevant
  `docker compose logs <service>` excerpt, and the non-secret parts of your
  `.env`.
- For hardware questions, state the machine: this stack targets the GMKtec
  EVO-T1 (Ultra 9 285H / Arc 140T / 96 GB DDR5). IPEX-LLM behavior varies
  between Intel iGPUs.

## Branching

Trunk-based, GitHub-Flow shaped; `docs/branching.md` is the rule and this is the
summary. `main` is the only long-lived branch and it stays green and deployable —
`main` is what a machine is built from, so a merge to `main` is by definition
deployable to the stack host.

- Cut a short-lived branch per change from the current tip of `main`: `feat/…`,
  `fix/…`, `refactor/…` (also `docs/…`, `test/…`, `chore/…`, `ci/…`), and delete it
  the moment it merges.
- Integrate by pull request into `main` and nowhere else. There are no
  environment branches — no `dev`, `staging`, `prod`, `uat` or `development` to
  merge forward through. Every environment deploys *from* `main` (or from a tag
  cut on `main`), which is also why a hotfix branches from `main` and lands on
  `main` first: there is no `staging` copy of the fix to write and then remember
  to cherry-pick.
- `fix/…` means a defect that is already on `main`.

GitHub is where that is enforced, and it is configured in two layers. Branch
protection on `main` is what keeps those rules honest: it is set to require a pull
request before a push, and to require the two Bazel status checks
(`bazelisk test //:test-fast` and `bazelisk test //:lint --test_tag_filters=manual`)
to pass before the merge button unlocks — the same two commands CI runs, with
`--config=ci`, and `bazelisk run //:validate` is that gate one step earlier, on
your machine.
`development`, `staging` and `production` are GitHub *Environments*, not branches:
each one is where a future protected secret and its protection rules would live,
and `production` stays restricted to `main` (or to tags cut on it) with required
reviewers, so it can only ever deploy what `main` already proved. Nothing in this
repo declares an environment or a deploy job today, so an environment branch would
buy nothing and cost a re-test.

## Pull requests

- Keep diffs small and focused; keep the architecture (Coder + LiteLLM +
  IPEX-LLM Ollama + Kasm) unless the change needs a real reason to diverge.
- No model weights, no `.env`, no real passwords / API keys / LAN IPs in any
  file.
- No CI that downloads models: this repo has no pipeline that pulls
  multi-gigabyte weights.
- Test a stack-affecting change on the **dev stack** before opening the PR:
  `bazelisk run //scripts:dev-stack -- up` (README "Two stacks on one box"). It is a
  second compose project with its own name, volumes and host ports, so the stable
  instance keeps running while you test. `--project-name evo-t1-coder-stack` addresses
  the production one instead, and `dev-stack` then names no env file, leaving that run
  on the `.env` beside the compose file.
- Test against the **stable** stack with `bazelisk run //scripts:prod-stack -- up`,
  which addresses the `evo-t1-prod` project by default (`PROD_PROJECT` on the `make`
  shim, or `--project-name`, names another; `evo-t1-coder-stack` is the project a
  stable stack brought up by hand lives under). With both stacks up, the
  container-level CLIs (`pull-models`, `push-template`, `coder-agents`,
  `dashboard-password`) address the oldest matching container, so stop the dev stack
  first when a check has to run against it.
- A workspace takes ONE repository by default. `--additional-repos` on
  `//scripts:new-workspace` (and the `additional_repos` template parameter it fills)
  exists for the case where a workspace genuinely needs siblings beside the primary
  clone; a change that adds another repository to a workspace without being asked
  for is a defect, not a convenience.
- Validate locally before opening. Bazelisk is the ingress:

  ```sh
  bazelisk test //:test-fast
  bazelisk test //:lint --test_tag_filters=manual
  bazelisk run //:validate
  ```

  `//:validate` runs the suite above and then:

  ```sh
  docker compose config -q
  cmp .env.sample .env.example            # .env.example is a copy — keep them identical
  terraform -chdir=templates/workspace fmt -check
  terraform -chdir=templates/devcontainer fmt -check
  python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('homepage/config/*.yaml')+['litellm/config.yaml']]"
  ```

  `terraform validate` still needs a local init with the provider cache; run it when a template changes. Shell functions need a `# @function` block and a Bats test (`docs/project-conventions.md`).

## Changing version pins

`images/dev/tool-versions.env` is the single source of truth for the workspace
image. `scripts/build-dev-image.sh` refuses to build if a pin has no matching
`ARG` in `images/dev/Dockerfile`, so add both sides of a new pin together.

- Confirm the upstream asset exists before you commit a new version. A wrong
  download URL now fails the build (`curl -f`), which is the point — earlier
  revisions of the Dockerfile could swallow a 404 mid-`&&`-chain and ship an
  image with tools quietly missing, so keep every fetch `-fsSL --fail` and keep
  the version-print smoke checks at the end of each layer.
- GitHub release URLs are inconsistent about the leading `v` in the tag versus
  the asset name. Check the release's asset list rather than guessing:
  `gh release view <tag> -R <owner>/<repo>`.
- The same inconsistency applies to the **arch** in the asset name. The three
  Docker client pins (`DOCKER_CLI_VERSION`, `BUILDX_VERSION`, `COMPOSE_VERSION`)
  mix two upstream spellings in one layer: download.docker.com and compose name
  their assets `x86_64`/`aarch64`, buildx uses `amd64`/`arm64`. The Dockerfile
  normalises `TARGETARCH` into both, so check each asset list rather than
  reusing one spelling across the three URLs — a wrong one is a 404 that aborts
  the layer, not a value you can spot in `docker --version` output.
- `go install` wants the version as a suffix of the full package path
  (`…/cmd/protoc-gen-go@v1.36.12`). `module@version/cmd/tool` is rejected as a
  disallowed version string.
- The Docker client layer must stay **client-only**: the smoke checks end with
  `test ! -x /usr/local/bin/dockerd` (plus `containerd`, `runc`,
  `docker-proxy`) because the static tarball ships all of them and unpacking it
  wholesale passes every positive check while putting a daemon in the image.
  The daemon belongs to the per-workspace `docker:29.8.1-dind` sidecar; keep
  those `test ! -x` guards when touching that layer, and bump
  `DOCKER_CLI_VERSION` together with the `dind_image` tag in
  `templates/workspace/main.tf` and `templates/devcontainer/main.tf` — they are the
  same engine line.
- After editing pins, `bazelisk run //scripts:build-dev-image` and then
  `docker image inspect evo-t1-dev:latest` — the script proves the tag is in the
  local store, which is what the Coder docker provider needs to avoid a pull.
