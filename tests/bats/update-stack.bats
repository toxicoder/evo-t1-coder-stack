#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## update-stack.bats - hermetic coverage for scripts/update-stack.sh
#
# What this suite pins is the deploy contract, because that is the whole reason
# the target exists:
#
#   - the ORDER. The env reconcile lands before the template push (the templates
#     read their wiring out of the live .env), the env reconcile lands before the
#     containers are recreated (compose interpolates ${VAR} at parse time), and
#     the workspace reseed lands last, from the tree now deployed;
#   - the restart decision. A payload edit under litellm/, homepage/, searxng/,
#     proxy/ or hermes/ restarts exactly the services that mount it, because
#     `compose up -d` sees no config delta and would keep the old process; a
#     change to docker-compose.yml or an env file stops the project first, since
#     `up -d` never removes an orphan; a docs-only pull restarts nothing;
#   - the refusals. A dirty tree, a detached HEAD, and an unknown --stack value
#     stop the run before anything touches the network or a container.
#
# The siblings the script shells out to are replaced by recording fakes, so a
# green run proves which scripts ran with which argv. git is replaced by a shim
# whose answers a test sets (the shared tool_stubs/git cannot tell
# `rev-parse --abbrev-ref HEAD` from `rev-parse HEAD`, which is the one thing
# this script decides on), and docker resolves to tests/bats/tool_stubs/.
#
# Usage: bazelisk test //tests:bats_update_stack_test   (from any cwd)
#
# Safety: stub only. No daemon, no remote, no network, no volume.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/update-stack.sh"
  if [ ! -f "${SCRIPT}" ]; then
    skip "scripts/update-stack.sh is not in the tree"
  fi
  use_stubs docker git
  export STUB_DOCKER_EXEC_RUN=0
  # The script warns when it sees a workspace vantage; these tests are not one.
  unset CODER_WORKSPACE_ID
  export SIBLING_LOG="${BATS_TEST_TMPDIR?}/siblings.log"
  : >"${SIBLING_LOG}"
}

# fake_root - print a throwaway checkout holding the script under test, the real
# scripts/lib/ it sources, the docker-compose.yml marker resolve_checkout
# proves, and recording fakes for every sibling it shells out to.
fake_root() {
  local root="${BATS_TEST_TMPDIR?}/root"
  local sibling
  mkdir -p "${root}/scripts/lib"
  : >"${root}/.env"
  : >"${root}/docker-compose.yml"
  cp "${SCRIPT}" "${root}/scripts/update-stack.sh"
  cp "${REPO_ROOT}/scripts/lib/"*.sh "${root}/scripts/lib/"
  for sibling in setup-host update-configs push-template refresh-configs \
    prod-stack dev-stack; do
    cat >"${root}/scripts/${sibling}.sh" <<EOF
#!/usr/bin/env bash
printf '%s | %s\n' '${sibling}' "\$*" >>"${SIBLING_LOG}"
exit 0
EOF
  done
  printf '%s' "${root}"
}

# git_shim - replace the git stub with one whose answers a test chooses. HEAD
# answers STUB_HEAD_BEFORE on its first call and STUB_HEAD_AFTER on every call
# after it, which is how a test makes a pull look like a pull.
git_shim() {
  cat >"${BATS_TEST_TMPDIR?}/bin/git" <<'SHIM'
#!/usr/bin/env bash
set -u
counter="${BATS_TEST_TMPDIR?}/head.count"
printf 'git %s\n' "$*" >>"${STUB_LOG}/git.log"
if [ "$#" -ge 3 ] && [ "$1" = "-C" ]; then shift 2; fi
case "${1:-}" in
  status)
    printf '%s\n' "${STUB_STATUS_OUT:-}" | grep -v '^$' || true
    ;;
  rev-parse)
    shift
    case "$*" in
      *--abbrev-ref*) printf '%s\n' "${STUB_BRANCH:-main}" ;;
      *)
        if [ -f "${counter}" ]; then
          printf '%s\n' "${STUB_HEAD_AFTER:-after1234567}"
        else
          printf 'x\n' >"${counter}"
          printf '%s\n' "${STUB_HEAD_BEFORE:-before1234567}"
        fi
        ;;
    esac
    ;;
  diff)
    printf '%s\n' "${STUB_DIFF_OUT:-}" | grep -v '^$' || true
    ;;
  pull)
    printf '%s\n' "${STUB_PULL_OUT:-Updating before1..after1}"
    exit "${STUB_PULL_RC:-0}"
    ;;
  checkout) exit "${STUB_CHECKOUT_RC:-0}" ;;
esac
exit 0
SHIM
  chmod 755 "${BATS_TEST_TMPDIR?}/bin/git"
}

# run_cli [env assignments...] -- run the CLI with every Bazel candidate cleared
# so the root it resolves is the fake one, and with no inherited re-exec state.
run_cli() {
  local -a extra=() argv=()
  while [ "$#" -gt 0 ]; do
    # An assignment is anything that starts with a name and an =; no flag or
    # flag value this CLI takes has an = in it.
    if [[ "$1" == [A-Za-z_][A-Za-z0-9_]*=* ]]; then
      extra+=("$1")
    else
      argv+=("$1")
    fi
    shift
  done
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= \
    BUILD_WORKSPACE_DIRECTORY= GITHUB_WORKSPACE= \
    EVO_T1_UPDATE_STACK_REEXEC= EVO_T1_UPDATE_STACK_CHANGED= \
    ${extra[@]+"${extra[@]}"} \
    bash "${ROOT_FAKE}/scripts/update-stack.sh" ${argv[@]+"${argv[@]}"}
}

ROOT_FAKE=""

# prepare [git-answers...] - build the fake checkout and the git shim, and export
# any STUB_* answers a test needs.
prepare() {
  ROOT_FAKE="$(fake_root)"
  git_shim
  while [ "$#" -gt 0 ]; do
    export "$1"
    shift
  done
}

# ── Pure decisions ───────────────────────────────────────────────────────────

load_fn() {
  # The functions under test report through the common.sh helpers, which the
  # production script sources; load one function and source the helpers it calls.
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  load_shell_function "${REPO_ROOT}/$1" "$2"
}

@test "stack_project names the compose project of each flavour" {
  load_fn scripts/update-stack.sh stack_project
  STACK_FLAVOUR=prod
  assert_eq "prod project" "evo-t1-prod" "$(stack_project)"
  STACK_FLAVOUR=dev
  assert_eq "dev project" "evo-t1-dev" "$(stack_project)"
}

@test "stack_env_file gives only the dev project its own env file" {
  load_fn scripts/update-stack.sh stack_env_file
  ROOT_DIR="${BATS_TEST_TMPDIR?}"
  STACK_FLAVOUR=prod
  assert_eq "prod reads the compose .env" "" "$(stack_env_file)"
  : >"${ROOT_DIR}/dev-stack.env"
  STACK_FLAVOUR=dev
  assert_eq "dev takes dev-stack.env" "${ROOT_DIR}/dev-stack.env" "$(stack_env_file)"
  rm -f "${ROOT_DIR}/dev-stack.env"
  assert_eq "no file, no env-file arg" "" "$(stack_env_file)"
}

@test "services_for_path maps each payload directory to its own services" {
  load_fn scripts/update-stack.sh services_for_path
  assert_eq "litellm config" "litellm" "$(services_for_path litellm/config.yaml)"
  assert_eq "searxng settings" "searxng" "$(services_for_path searxng/settings.yml)"
  assert_eq "homepage yaml" "homepage" "$(services_for_path homepage/config/services.yaml)"
  assert_eq "proxy vhost" "router homepage-proxy" "$(services_for_path proxy/homepage.conf)"
  assert_eq "hermes payload" "hermes" "$(services_for_path hermes/config.yaml)"
  # The router and the homepage proxy both terminate TLS, and coder holds its
  # own copy of the cert, so a cert change reaches three services.
  assert_eq "certs" "router homepage-proxy coder" "$(services_for_path proxy/certs/coder.crt)"
  assert_eq "docs reach nothing" "" "$(services_for_path README.md)"
  assert_eq "scripts reach nothing" "" "$(services_for_path scripts/update-stack.sh)"
}

@test "services_to_restart collapses a pull's paths into one unique service list" {
  load_fn scripts/update-stack.sh services_for_path
  load_fn scripts/update-stack.sh services_to_restart
  CHANGED_PATHS=$'litellm/config.yaml\nlitellm/models.yml\nREADME.md'
  assert_eq "one service twice is one service" "litellm" "$(services_to_restart)"
  CHANGED_PATHS=$'proxy/router.conf\nhomepage/config/settings.yaml\nproxy/homepage.conf'
  assert_eq "first order wins" "router homepage-proxy homepage" "$(services_to_restart)"
  CHANGED_PATHS=""
  assert_eq "nothing changed" "" "$(services_to_restart)"
}

@test "changed_paths_match reports what the pull actually touched" {
  load_fn scripts/update-stack.sh changed_paths_match
  CHANGED_PATHS=$'docker-compose.yml\ndocs/index.md'
  changed_paths_match 'docker-compose.yml'
  changed_paths_match 'docs/*'
  ! changed_paths_match 'litellm/*'
  CHANGED_PATHS=""
  ! changed_paths_match 'docker-compose.yml'
}

@test "compose_cli falls back to docker-compose when docker has no compose plugin" {
  load_fn scripts/update-stack.sh compose_cli
  printf '#!/usr/bin/env bash\nexit 0\n' >"${BATS_TEST_TMPDIR?}/bin/docker-compose"
  chmod 755 "${BATS_TEST_TMPDIR?}/bin/docker-compose"
  docker() { return 1; }
  assert_eq "fallback" "docker-compose" "$(compose_cli)"
  docker() { return 0; }
  assert_eq "plugin" "docker compose" "$(compose_cli)"
}

@test "stack_compose stops in a dry run without calling compose" {
  load_fn scripts/update-stack.sh stack_compose
  ROOT_DIR="${BATS_TEST_TMPDIR?}"
  STACK_FLAVOUR=prod
  DRY_RUN=1
  local out
  out="$(stack_compose restart litellm)"
  assert_eq "no compose in a dry run" "" "$(stub_log docker)"
  assert_match "plans the call" 'would run compose restart litellm' "${out}"
}

@test "run_sibling reports a missing script and returns 1" {
  load_fn scripts/update-stack.sh run_sibling
  ROOT_DIR="${BATS_TEST_TMPDIR?}"
  DRY_RUN=0
  local rc=0
  run_sibling "nothing" "scripts/nope.sh" || rc=$?
  assert_eq "missing sibling fails the step" "1" "${rc}"
}

@test "run_sibling runs a sibling, counts it, and passes its argv through" {
  load_fn scripts/update-stack.sh run_sibling
  ROOT_DIR="${BATS_TEST_TMPDIR?}"
  DRY_RUN=0
  local argv="${BATS_TEST_TMPDIR?}/sibling-argv"
  mkdir -p "${ROOT_DIR}/scripts"
  cat >"${ROOT_DIR}/scripts/echo-sibling.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"${argv}"
EOF
  local rc=0
  run_sibling "echo" "scripts/echo-sibling.sh" --apply --wait 5 || rc=$?
  assert_eq "sibling ran" "0" "${rc}"
  assert_eq "argv forwarded" "--apply --wait 5" "$(cat "${argv}")"
}

@test "recreate_needed asks for a stop only for compose and env files" {
  load_fn scripts/update-stack.sh changed_paths_match
  load_fn scripts/update-stack.sh recreate_needed
  CHANGED_PATHS='docker-compose.yml'
  recreate_needed
  CHANGED_PATHS='.env'
  recreate_needed
  CHANGED_PATHS='dev-stack.env'
  recreate_needed
  CHANGED_PATHS=$'litellm/config.yaml\nREADME.md'
  ! recreate_needed
  CHANGED_PATHS='proxy/router.conf'
  ! recreate_needed
}

@test "current_branch and head_revision read the tree git reports" {
  load_fn scripts/update-stack.sh current_branch
  load_fn scripts/update-stack.sh head_revision
  ROOT_FAKE="$(fake_root)"
  git_shim
  ROOT_DIR="${ROOT_FAKE}"
  export STUB_BRANCH='main' STUB_HEAD_BEFORE='deadbeef1234' STUB_LOG="${STUB_LOG}"
  assert_eq "branch" "main" "$(current_branch)"
  assert_eq "revision" "deadbeef1234" "$(head_revision)"
  export STUB_BRANCH='HEAD'
  assert_eq "detached prints no branch" "" "$(current_branch)"
}

@test "refuse_unsafe_checkout stops on a dirty tree and a detached HEAD" {
  load_fn scripts/update-stack.sh current_branch
  load_fn scripts/update-stack.sh refuse_unsafe_checkout
  ROOT_FAKE="$(fake_root)"
  git_shim
  ROOT_DIR="${ROOT_FAKE}"
  ALLOW_DIRTY=0
  DRY_RUN=0
  STUB_LOG="${STUB_LOG}"

  export STUB_STATUS_OUT=' M litellm/config.yaml' STUB_BRANCH='main'
  ! refuse_unsafe_checkout
  ALLOW_DIRTY=1
  refuse_unsafe_checkout
  ALLOW_DIRTY=0

  export STUB_STATUS_OUT='' STUB_BRANCH='HEAD'
  ! refuse_unsafe_checkout
  export STUB_BRANCH='main'
  refuse_unsafe_checkout
}

@test "pull_checkout records the move and the files it brought in" {
  load_fn scripts/update-stack.sh head_revision
  load_fn scripts/update-stack.sh pull_checkout
  ROOT_FAKE="$(fake_root)"
  git_shim
  ROOT_DIR="${ROOT_FAKE}"
  DRY_RUN=0
  STUB_LOG="${STUB_LOG}"
  export STUB_HEAD_BEFORE='before1234567' STUB_HEAD_AFTER='after1234567'
  export STUB_DIFF_OUT=$'litellm/config.yaml\ndocs/index.md'
  pull_checkout
  assert_eq "moved" "1" "${HEAD_MOVED}"
  assert_eq "files carried" $'litellm/config.yaml\ndocs/index.md' "${CHANGED_PATHS}"

  # A second call finds HEAD unchanged, which is the "already up to date" path.
  HEAD_MOVED=0
  CHANGED_PATHS=""
  pull_checkout
  assert_eq "no move" "0" "${HEAD_MOVED}"
  assert_eq "no files" "" "${CHANGED_PATHS}"

  export STUB_PULL_RC=1 STUB_PULL_OUT='fatal: no tracking information for the current branch'
  ! pull_checkout
}

@test "checkout_branch switches only when the tree is elsewhere" {
  load_fn scripts/update-stack.sh current_branch
  load_fn scripts/update-stack.sh checkout_branch
  ROOT_FAKE="$(fake_root)"
  git_shim
  ROOT_DIR="${ROOT_FAKE}"
  DRY_RUN=0
  STUB_LOG="${STUB_LOG}"
  TARGET_BRANCH='main'
  export STUB_BRANCH='main'
  checkout_branch
  assert_eq "no switch needed" "" "$(grep ' checkout ' <<<"$(stub_log git)" || true)"

  TARGET_BRANCH='release'
  DRY_RUN=1
  checkout_branch
  assert_eq "a dry run does not switch" "" "$(grep ' checkout ' <<<"$(stub_log git)" || true)"
}

@test "carry_deploy_state restores what the pull learned before the hop" {
  load_fn scripts/update-stack.sh carry_deploy_state
  local carry="${BATS_TEST_TMPDIR?}/carried"
  printf '%s\n' 'litellm/config.yaml' >"${carry}"
  REENTERED_FROM='after1234567'
  CARRIED_PATHS="${carry}"
  HEAD_MOVED=0
  CHANGED_PATHS=""
  carry_deploy_state
  assert_eq "still reports the move" "1" "${HEAD_MOVED}"
  assert_eq "knows the commit" "after1234567" "${PULLED_TO}"
  assert_eq "file list restored" "litellm/config.yaml" "${CHANGED_PATHS}"
  assert_file_not_exists "carry file consumed" "${carry}"

  # Without a re-entry there is nothing to restore.
  REENTERED_FROM=""
  CHANGED_PATHS=""
  carry_deploy_state
  assert_eq "untouched" "" "${CHANGED_PATHS}"
}

@test "reexec_after_pull stays put when there is nothing to re-enter" {
  load_fn scripts/update-stack.sh reexec_after_pull
  SELF_DIR="${BATS_TEST_TMPDIR?}"
  DRY_RUN=0
  # Nothing moved, so no hop.
  HEAD_MOVED=0
  REENTERED_FROM=""
  reexec_after_pull
  # Already re-entered, so never a second hop (this is what stops a loop).
  HEAD_MOVED=1
  REENTERED_FROM='after1234567'
  reexec_after_pull
  # A checkout that lost the script falls back to the loaded copy with a warning.
  REENTERED_FROM=""
  reexec_after_pull
}

@test "the deploy steps exist as named functions" {
  # converge_stack and restart_changed_services are driven by every full CLI run
  # above; this pins that the sequence stays split into those two steps.
  local body fn
  body="$(cat "${SCRIPT}")"
  for fn in converge_stack restart_changed_services; do
    assert_match "defines ${fn}" "^${fn}\(\) \{" "${body}"
  done
}

# ── Refusals ─────────────────────────────────────────────────────────────────

@test "a dirty tree is refused before anything reaches git pull" {
  prepare
  run_cli STUB_STATUS_OUT=' M litellm/config.yaml'
  [ "${status}" -eq 1 ]
  assert_match "names the cause" 'uncommitted changes' "${stderr}"
  assert_match "offers the way past" '--allow-dirty' "${stderr}"
  assert_eq "no step ran" "" "$(cat "${SIBLING_LOG}")"
  assert_eq "no pull happened" "" "$(grep 'pull --ff-only' <<<"$(stub_log git)" || true)"
}

@test "--allow-dirty deploys a tree with uncommitted changes" {
  prepare
  run_cli --allow-dirty STUB_STATUS_OUT=' M local-edit.sh' STUB_DIFF_OUT='README.md'
  [ "${status}" -eq 0 ]
  assert_match "still pushed templates" 'push-template \|' "$(cat "${SIBLING_LOG}")"
}

@test "a detached HEAD is refused, since there is no branch to fast-forward" {
  prepare
  run_cli STUB_BRANCH='HEAD'
  [ "${status}" -eq 1 ]
  assert_match "names the cause" 'detached' "${stderr}"
  assert_eq "no step ran" "" "$(cat "${SIBLING_LOG}")"
}

@test "a failed pull names the repair for a host that cannot resolve github.com" {
  prepare
  run_cli STUB_PULL_RC=1 \
    STUB_PULL_OUT='fatal: unable to access: Could not resolve host: github.com'
  [ "${status}" -eq 1 ]
  assert_match "points at the DNS repair" 'setup-host.sh --repair' "${stderr}"
  assert_eq "no step ran" "" "$(cat "${SIBLING_LOG}")"
}

@test "a diverged pull says to reconcile by hand" {
  prepare
  run_cli STUB_PULL_RC=1 \
    STUB_PULL_OUT='fatal: Not possible to fast-forward, aborting.'
  [ "${status}" -eq 1 ]
  assert_match "says reconcile" 'diverged' "${stderr}"
}

@test "--stack names only prod or dev" {
  prepare
  run_cli --stack staging
  [ "${status}" -eq 2 ]
  assert_match "names the two" 'prod or dev' "${stderr}"
}

@test "an unknown option and a bare word are usage errors" {
  prepare
  run_cli --nope
  [ "${status}" -eq 1 ]
  assert_match "unknown option" 'unknown option' "${stderr}"
  run_cli deploy
  [ "${status}" -eq 1 ]
  assert_match "bare word refused" 'not an option' "${stderr}"
}

@test "--help prints the usage and exits 0" {
  prepare
  run_cli --help
  [ "${status}" -eq 0 ]
  assert_match "usage line" 'usage: bazelisk run //scripts:update-stack' "${output}"
  assert_match "documents the image pull" '--pull-images' "${output}"
}

# ── The sequence ─────────────────────────────────────────────────────────────

@test "a clean run applies the steps in the order that makes them work" {
  prepare STUB_DIFF_OUT='README.md'
  run_cli
  [ "${status}" -eq 0 ]

  # Each step must follow the one it depends on, so compare line positions.
  local env_at up_at push_at reseed_at
  env_at="$(grep -n 'update-configs | env' "${SIBLING_LOG}" | cut -d: -f1)"
  up_at="$(grep -n 'prod-stack | up' "${SIBLING_LOG}" | cut -d: -f1)"
  push_at="$(grep -n 'push-template |' "${SIBLING_LOG}" | cut -d: -f1)"
  reseed_at="$(grep -n 'refresh-configs |' "${SIBLING_LOG}" | cut -d: -f1)"
  [ "${env_at}" -lt "${up_at}" ]
  [ "${env_at}" -lt "${push_at}" ]
  [ "${push_at}" -lt "${reseed_at}" ]

  # The whole sequence runs exactly once, not once per re-entered process.
  assert_eq "one sequence" \
    "$(printf 'setup-host\nupdate-configs\nprod-stack\npush-template\nrefresh-configs\nprod-stack')" \
    "$(grep -oE '^[a-z-]+ \|' "${SIBLING_LOG}" | tr -d ' |')"

  # The env pass runs non-interactively, so the target can never hang on a prompt.
  assert_match "env pass never prompts" 'update-configs \| env --non-interactive' "$(cat "${SIBLING_LOG}")"
  assert_match "summary closes the run" 'summary: .*0 failed' "${output}"
}

@test "--dry-run plans every step and touches nothing" {
  prepare
  run_cli --dry-run
  [ "${status}" -eq 0 ]
  assert_match "plans the pull" 'would run git pull --ff-only' "${output}"
  assert_match "plans the push" 'would run bash scripts/push-template.sh' "${output}"
  assert_match "plans the reseed" 'would run bash scripts/refresh-configs.sh' "${output}"
  assert_eq "nothing executed" "" "$(cat "${SIBLING_LOG}")"
  assert_eq "no compose call" "0" "$(stub_log_count docker)"
}

@test "--skip-* flags drop exactly their own step" {
  prepare STUB_DIFF_OUT='README.md'
  run_cli --skip-pull --skip-repair --skip-configs --skip-templates --skip-workspaces
  [ "${status}" -eq 0 ]
  assert_eq "only the stack ran" "prod-stack" \
    "$(grep -oE '^[a-z-]+' "${SIBLING_LOG}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

@test "SKIP_TEMPLATE_PUSH=1 drops the template push" {
  prepare STUB_DIFF_OUT='README.md'
  export SKIP_TEMPLATE_PUSH=1
  run_cli
  [ "${status}" -eq 0 ]
  assert_eq "no push" "" "$(grep -c 'push-template |' "${SIBLING_LOG}" | grep -v '^0$' || true)"
}

@test "--stack dev drives the dev project and its own env file" {
  # A payload change, so a restart actually reaches compose and the project
  # name and env file the restart carries can be observed.
  prepare STUB_DIFF_OUT='litellm/config.yaml'
  : >"${ROOT_FAKE}/dev-stack.env"
  run_cli --stack dev
  [ "${status}" -eq 0 ]
  assert_match "dev runner" 'dev-stack \| up' "$(cat "${SIBLING_LOG}")"
  assert_eq "prod runner untouched" "" "$(grep 'prod-stack |' "${SIBLING_LOG}" || true)"
  # The restart goes to compose carrying the dev project name and its env file.
  assert_match "dev project" '-p evo-t1-dev' "$(stub_log docker)"
  assert_match "dev env file" "--env-file ${ROOT_FAKE}/dev-stack.env" "$(stub_log docker)"
}

@test "--litellm-url is forwarded to the workspace reseed" {
  prepare STUB_DIFF_OUT='README.md'
  run_cli --litellm-url 'http://host.docker.internal:4100/v1'
  [ "${status}" -eq 0 ]
  assert_match "forwarded" \
    'refresh-configs \| --litellm-url http://host.docker.internal:4100/v1' \
    "$(cat "${SIBLING_LOG}")"
}

# ── The restart decision ─────────────────────────────────────────────────────

@test "a payload change restarts exactly the services that mount it" {
  prepare STUB_DIFF_OUT=$'litellm/config.yaml\nREADME.md'
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "litellm restarted" 'restart litellm' "$(stub_log docker)"
  assert_eq "nothing else restarted" "" \
    "$(grep -E 'restart (homepage-proxy|coder|searxng|homepage|router|hermes)' <<<"$(stub_log docker)" || true)"
  # A payload-only change never stops the project.
  assert_eq "no down" "" "$(grep 'prod-stack | down' "${SIBLING_LOG}" || true)"
}

@test "a proxy cert change reaches the router, the homepage proxy, and coder" {
  prepare STUB_DIFF_OUT='proxy/certs/coder.crt'
  run_cli
  [ "${status}" -eq 0 ]
  local log
  log="$(stub_log docker)"
  assert_match "router" 'restart router' "${log}"
  assert_match "homepage proxy" 'restart homepage-proxy' "${log}"
  assert_match "coder" 'restart coder' "${log}"
}

@test "a docs-only pull restarts nothing" {
  prepare STUB_DIFF_OUT=$'README.md\ndocs/index.md'
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "says so" 'nothing to restart' "${output}"
  assert_eq "compose never called" "0" "$(stub_log_count docker)"
}

@test "a changed compose file comes up from a stopped project" {
  prepare STUB_DIFF_OUT='docker-compose.yml'
  run_cli
  [ "${status}" -eq 0 ]
  local down_at up_at
  down_at="$(grep -n 'prod-stack | down' "${SIBLING_LOG}" | cut -d: -f1)"
  up_at="$(grep -n 'prod-stack | up' "${SIBLING_LOG}" | cut -d: -f1)"
  [ "${down_at}" -lt "${up_at}" ]
}

@test "a changed env file also comes up from a stopped project" {
  prepare STUB_DIFF_OUT='.env'
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "stopped first" 'prod-stack \| down' "$(cat "${SIBLING_LOG}")"
}

@test "--restart stops the project even when the pull changed no payload" {
  prepare STUB_DIFF_OUT='README.md'
  run_cli --restart
  [ "${status}" -eq 0 ]
  assert_match "stopped first" 'prod-stack \| down' "$(cat "${SIBLING_LOG}")"
}

@test "--no-restart converges with up alone" {
  prepare STUB_DIFF_OUT=$'litellm/config.yaml\nproxy/router.conf'
  run_cli --no-restart
  [ "${status}" -eq 0 ]
  assert_eq "compose never called" "0" "$(stub_log_count docker)"
  assert_match "still converged" 'prod-stack \| up' "$(cat "${SIBLING_LOG}")"
}

@test "--pull-images asks compose for the pinned tags, and only when asked" {
  prepare STUB_DIFF_OUT='README.md'
  run_cli
  [ "${status}" -eq 0 ]
  assert_eq "no pull by default" "" "$(grep -- ' pull' <<<"$(stub_log docker)" || true)"

  prepare STUB_DIFF_OUT='README.md'
  run_cli --pull-images
  [ "${status}" -eq 0 ]
  assert_match "pull requested" 'pull --quiet' "$(stub_log docker)"
}

# ── The pull ─────────────────────────────────────────────────────────────────

@test "a pull that moved HEAD re-enters the updated checkout exactly once" {
  prepare STUB_DIFF_OUT=$'litellm/config.yaml\nREADME.md'
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "reports the move" 'updated before1 to after1' "${output}"
  assert_match "re-enters" 're-enter the updated checkout' "${output}"
  assert_match "says where it landed" 're-entered the updated checkout at after12' "${output}"
  # One hop only: the pull ran once across both processes.
  assert_eq "one pull" "1" "$(grep -c 'pull --ff-only' <<<"$(stub_log git)")"
  # The file list crossed the hop, which is what makes the restart still fire.
  assert_match "restart survived the hop" 'restart litellm' "$(stub_log docker)"
}

@test "an unchanged HEAD does not re-enter and reports nothing to deploy" {
  prepare STUB_HEAD_AFTER='before1234567'
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "up to date" 'already up to date' "${output}"
  assert_match "nothing to deploy" 'nothing to deploy' "${output}"
  assert_eq "no re-entry" "" "$(grep 're-enter the updated checkout' <<<"${output}" || true)"
}

@test "--skip-pull deploys the tree as it stands with no git traffic" {
  prepare
  run_cli --skip-pull
  [ "${status}" -eq 0 ]
  assert_match "says so" 'skipping the pull' "${output}"
  assert_eq "no git calls" "0" "$(stub_log_count git)"
  assert_match "still converged" 'prod-stack \| up' "$(cat "${SIBLING_LOG}")"
}

@test "--branch switches only when the checkout is not already there" {
  prepare STUB_DIFF_OUT='README.md' STUB_BRANCH='main'
  run_cli --branch main
  [ "${status}" -eq 0 ]
  assert_match "already there" 'already on main' "${output}"
  assert_eq "no checkout call" "" "$(grep 'checkout' <<<"$(stub_log git)" || true)"

  prepare STUB_DIFF_OUT='README.md' STUB_BRANCH='main'
  run_cli --branch release
  [ "${status}" -eq 0 ]
  assert_match "switched" 'checkout release' "$(stub_log git)"
}

# ── Failure handling ─────────────────────────────────────────────────────────

@test "one failing step is recorded and the rest of the run still happens" {
  prepare STUB_DIFF_OUT='README.md'
  cat >"${ROOT_FAKE}/scripts/push-template.sh" <<'EOF'
#!/usr/bin/env bash
printf 'push-template | %s\n' "$*" >>"${SIBLING_LOG}"
exit 1
EOF
  run_cli
  [ "${status}" -eq 1 ]
  assert_match "counts one failure" 'summary: .*1 failed' "${output}"
  assert_match "quotes the retry" 'bazelisk run //scripts:push-template' "${stderr}"
  # The steps after the failed one still ran, which is what the summary claims.
  assert_match "reseed still ran" 'refresh-configs |' "$(cat "${SIBLING_LOG}")"
  assert_match "status still ran" 'prod-stack | status' "$(cat "${SIBLING_LOG}")"
}

@test "a sibling missing from the checkout fails the run" {
  prepare STUB_DIFF_OUT='README.md'
  rm -f "${ROOT_FAKE}/scripts/push-template.sh"
  run_cli
  [ "${status}" -eq 1 ]
  assert_match "names the missing file" 'push-template.sh is missing' "${stderr}"
}

@test "a tree that is not a checkout exits 5 before any step" {
  local root="${BATS_TEST_TMPDIR?}/unproven"
  mkdir -p "${root}/scripts/lib"
  cp "${SCRIPT}" "${root}/scripts/"
  cp "${REPO_ROOT}/scripts/lib/"*.sh "${root}/scripts/lib/"
  run --separate-stderr env -C "${BATS_TEST_TMPDIR?}" REPO_ROOT= \
    BUILD_WORKSPACE_DIRECTORY= GITHUB_WORKSPACE= \
    EVO_T1_UPDATE_STACK_REEXEC= EVO_T1_UPDATE_STACK_CHANGED= \
    bash "${root}/scripts/update-stack.sh"
  [ "${status}" -eq 5 ]
  assert_eq "no step ran" "" "$(cat "${SIBLING_LOG}")"
}

@test "inside a workspace the run warns about the daemon it is addressing" {
  prepare STUB_DIFF_OUT='README.md'
  export CODER_WORKSPACE_ID='9d62a19c-d5b1-4a0d'
  run_cli
  [ "${status}" -eq 0 ]
  assert_match "warns about the vantage" 'inside a Coder workspace' "${output}"
  assert_match "counts the warning" '1 warnings' "${output}"
}
