#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## push-template.bats — hermetic coverage for scripts/push-template.sh
#
# Hermetic by construction: docker, timeout, curl, psql and coder resolve to the
# tests/bats/tool_stubs/ copies (use_stubs), and every run happens inside a
# throwaway root built by fake_root (its own .env, its own template tree), so
# neither the checkout's real .env nor a live compose stack is consulted. The
# docker stub's `exec` passthrough (STUB_DOCKER_EXEC_RUN=1, the default)
# drives the whole CLI chain: the exec'd `coder` resolves through the same
# shadowed PATH, so the push, the versions list and the description edit all
# answer from the coder stub. STUB_DOCKER_EXEC_RUN=0 with STUB_DOCKER_EXEC_RC and
# STUB_DOCKER_EXEC_OUT is the "the daemon answered, and it said No" case.
#
# Seeding psql: tool_stubs/psql prints a fixed body, and this script only walks
# off the token mint when that body equals the api_keys id it just minted
# (random per run), so the chain cases swap in
# fixtures/push-template/psql-token — a psql that echoes the id back out of the
# statement, the way `returning id` answers on a real server.
#
# Usage: bazelisk test //tests:bats_push_template_test   (from any cwd)
#
# Safety: stub only. Nothing here needs a daemon, a database or a network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
ACTIVE_ID="d162f0a4-1111-4444-8888-121212121212"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  use_stubs docker timeout curl psql coder
  # bazelisk run exports BUILD_WORKSPACE_DIRECTORY; a leaked value would make
  # fake_root resolve the real checkout instead of the throwaway tree.
  unset BUILD_WORKSPACE_DIRECTORY GITHUB_WORKSPACE REPO_ROOT || true
  REPO_ROOT="$(bats_canonical_repo_root)"
}

# The payload files every template's main.tf reads from the staged copy;
# template_push_one names exactly these.
COMMON_PAYLOADS=(
  GROK_BUILD_AGENTS.md
  vscode-alt.svg
  notes-setup.sh
  tmux.conf
  grok-build-terminal.sh
  vscode-terminal-tmux.sh
  grok-build-delegation.SKILL.md
  ez-learn.SKILL.md
  ez-skillify.SKILL.md
  ez-create-skill.SKILL.md
  ez-bazel-first.SKILL.md
  ez-bazel-first.owned_files_check.py
  ez-bazel-first.glob_budget.py
  ez-strong-types.SKILL.md
  ez-strong-types.type_baseline.py
  ez-trunk-based-repo.SKILL.md
  ez-micro-plan.SKILL.md
  ez-micro-plan.plan_check.py
  stack-repo-commands.SKILL.md
  reflect-and-evolve.SKILL.md
  reflect-and-evolve.session_signals.py
  reflect-and-evolve.checklist.md
  reflect-and-evolve-repo.SKILL.md
  reflect-and-evolve-repo.checklist.md
  trunk-refactor.SKILL.md
  explorer.AGENT.md
  architect.AGENT.md
  implementer.AGENT.md
  tester.AGENT.md
  reviewer.AGENT.md
  security-auditor.AGENT.md
  thorough-researcher.PERSONA.toml
  senior-implementer.PERSONA.toml
  skeptical-reviewer.PERSONA.toml
  feature-implementation.SKILL.md
  skeptical-review.SKILL.md
  security-audit.SKILL.md
  bug-hunt.SKILL.md
  documenter.SKILL.md
  documenter.AGENT.md
  performance-optimizer.SKILL.md
  debugger.SKILL.md
  migrator.SKILL.md
  ez-code-index.SKILL.md
  ez-code-index.code_index.py
  hooks.evo-t1-hooks.json
  hooks.deny-patterns.txt
  hooks.secret-guard.sh
  hooks.dangerous-command-guard.sh
  hooks.post-edit-format.sh
  hooks.selective-test-runner.sh
  coder-agents.md
  mcp-cache-proxy.json
  gh-token-refresh.sh.tftpl
  infisical-secrets.sh.tftpl
  agents-seed.sh.tftpl
  stack-skills.sh.tftpl
  boot-log.lib.sh
  terminal-launchers.sh.tftpl
  stack-repo-skills.sh.tftpl
  trunk-refactor-seed.sh.tftpl
  stack-advisors.sh.tftpl
  stack-hooks.sh.tftpl
  stack-fleet.sh.tftpl
)

# write_common_payloads <dir> — stub each required common/ file so a throwaway
# tree satisfies template_push_one's missing-payload guard.
write_common_payloads() {
  local dest="$1"
  mkdir -p "${dest}"
  printf '%s\n' '# Role' >"${dest}/GROK_BUILD_AGENTS.md"
  printf '%s\n' '<svg/>' >"${dest}/vscode-alt.svg"
  printf '%s\n' '# notes library' >"${dest}/notes-setup.sh"
  printf '%s\n' 'set -g mouse on' >"${dest}/tmux.conf"
  printf '%s\n' '#!/bin/bash' >"${dest}/grok-build-terminal.sh"
  printf '%s\n' '#!/bin/bash' >"${dest}/vscode-terminal-tmux.sh"
  printf '%s\n' '# skill' >"${dest}/grok-build-delegation.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/ez-learn.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/ez-skillify.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/ez-create-skill.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/ez-bazel-first.SKILL.md"
  printf '%s\n' 'pass' >"${dest}/ez-bazel-first.owned_files_check.py"
  printf '%s\n' 'pass' >"${dest}/ez-bazel-first.glob_budget.py"
  printf '%s\n' '# skill' >"${dest}/ez-strong-types.SKILL.md"
  printf '%s\n' 'pass' >"${dest}/ez-strong-types.type_baseline.py"
  printf '%s\n' '# skill' >"${dest}/ez-trunk-based-repo.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/ez-micro-plan.SKILL.md"
  printf '%s\n' 'pass' >"${dest}/ez-micro-plan.plan_check.py"
  printf '%s\n' 'recipes' >"${dest}/stack-repo-commands.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/reflect-and-evolve.SKILL.md"
  printf '%s\n' 'pass' >"${dest}/reflect-and-evolve.session_signals.py"
  printf '%s\n' '# checklist' >"${dest}/reflect-and-evolve.checklist.md"
  printf '%s\n' '# skill' >"${dest}/reflect-and-evolve-repo.SKILL.md"
  printf '%s\n' '# checklist' >"${dest}/reflect-and-evolve-repo.checklist.md"
  printf '%s\n' '# skill' >"${dest}/trunk-refactor.SKILL.md"
  printf '%s\n' '# agent' >"${dest}/explorer.AGENT.md"
  printf '%s\n' '# agent' >"${dest}/architect.AGENT.md"
  printf '%s\n' '# agent' >"${dest}/implementer.AGENT.md"
  printf '%s\n' '# agent' >"${dest}/tester.AGENT.md"
  printf '%s\n' '# agent' >"${dest}/reviewer.AGENT.md"
  printf '%s\n' '# agent' >"${dest}/security-auditor.AGENT.md"
  printf '%s\n' '# persona' >"${dest}/thorough-researcher.PERSONA.toml"
  printf '%s\n' '# persona' >"${dest}/senior-implementer.PERSONA.toml"
  printf '%s\n' '# persona' >"${dest}/skeptical-reviewer.PERSONA.toml"
  printf '%s\n' '# skill' >"${dest}/feature-implementation.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/skeptical-review.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/security-audit.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/bug-hunt.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/documenter.SKILL.md"
  printf '%s\n' '# agent' >"${dest}/documenter.AGENT.md"
  printf '%s\n' '# skill' >"${dest}/performance-optimizer.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/debugger.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/migrator.SKILL.md"
  printf '%s\n' '# skill' >"${dest}/ez-code-index.SKILL.md"
  printf '%s\n' 'pass' >"${dest}/ez-code-index.code_index.py"
  printf '%s\n' '{}' >"${dest}/hooks.evo-t1-hooks.json"
  printf '%s\n' '# deny list' >"${dest}/hooks.deny-patterns.txt"
  printf '%s\n' '#!/bin/sh' >"${dest}/hooks.secret-guard.sh"
  printf '%s\n' '#!/bin/sh' >"${dest}/hooks.dangerous-command-guard.sh"
  printf '%s\n' '#!/bin/sh' >"${dest}/hooks.post-edit-format.sh"
  printf '%s\n' '#!/bin/sh' >"${dest}/hooks.selective-test-runner.sh"
  printf '%s\n' '# agents' >"${dest}/coder-agents.md"
  printf '%s\n' '{}' >"${dest}/mcp-cache-proxy.json"
  printf '%s\n' '#!/bin/bash' >"${dest}/gh-token-refresh.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/infisical-secrets.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/agents-seed.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/stack-skills.sh.tftpl"
  printf '%s\n' '#!/bin/sh' >"${dest}/boot-log.lib.sh"
  printf '%s\n' '#!/bin/sh' >"${dest}/terminal-launchers.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/stack-repo-skills.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/trunk-refactor-seed.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/stack-advisors.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/stack-hooks.sh.tftpl"
  printf '%s\n' '#!/bin/bash' >"${dest}/stack-fleet.sh.tftpl"
}

# fake_root <script> [env-line...] — print a throwaway repo root holding the
# script under test, scripts/lib/ (the seams it sources after its own repo-root
# cd), a private .env, and the template tree: both template dirs plus their
# sibling common/ dir with the seed payloads every push stages. main.tf has to
# exist in a dir for that template to be selectable, the lockfile keeps the
# "missing lockfile" note out of the way unless a test wants it, and the
# common/ files have to exist because template_push_one refuses to push
# without each of them.
fake_root() {
  local root="${BATS_TEST_TMPDIR?}/root" script="${1}"
  shift
  mkdir -p "${root}/scripts/lib" "${root}/templates/workspace" "${root}/templates/devcontainer"
  mkdir -p "${root}/templates/common"
  : >"${root}/docker-compose.yml"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"${root}/.env"
  else
    : >"${root}/.env"
  fi
  printf '%s\n' 'resource "coder_workspace_preset" "x" {' '  name = "x"' '  description = "short"' \
    >"${root}/templates/workspace/main.tf"
  printf '%s\n' 'resource "coder_workspace_preset" "y" {' '  name = "y"' '  description = "short"' \
    >"${root}/templates/devcontainer/main.tf"
  : >"${root}/templates/workspace/.terraform.lock.hcl"
  : >"${root}/templates/devcontainer/.terraform.lock.hcl"
  write_common_payloads "${root}/templates/common"
  cp "${REPO_ROOT}/scripts/${script}" "${root}/scripts/"
  cp "${REPO_ROOT}/scripts/lib/"*.sh "${root}/scripts/lib/"
  cp "${REPO_ROOT}/scripts/lib/"*.awk "${root}/scripts/lib/"
  printf '%s' "${root}"
}

# psql_token_variant — swap the copied psql stub for the fixture that answers the
# api_keys INSERT with its `returning id` value, so the run reaches the push.
psql_token_variant() {
  cp "${BATS_TEST_DIRNAME?}/fixtures/push-template/psql-token" "${BATS_TEST_TMPDIR?}/bin/psql"
  chmod 755 "${BATS_TEST_TMPDIR?}/bin/psql"
}

# running_stack — answer the daemon-wide `docker ps` probe with both services
# (the "service|container" shape stack_ps prints), let the buildinfo probe answer
# (empty body, rc 0) and pretend the dev image exists, so a failing
# `docker image inspect` does not add its note to every expected output.
running_stack() {
  export STUB_COMPOSE_PS=$'db|stack-db-1\ncoder|stack-coder-1'
  export STUB_COMPOSE_PS_RC=0
  export STUB_CURL_RC=0
  export STUB_DOCKER_INSPECT=1
}

# versions_answer <file> — feed the coder stub the table that `templates versions
# list --column id --column active` prints. The header row repeats the word
# ACTIVE, which is why the second row has to be spelled out too.
versions_answer() {
  printf '%s\n' 'ID                                    ACTIVE' "${ACTIVE_ID} Active" >"${1}"
  export STUB_CODER_OUT="${1}"
}

# logs_absent <regex> [log-file...] - fail unless no argv log line matches.
# A bare `! grep` cannot fail a bats test, so the negation lives in the helper.
logs_absent() {
  local pattern="$1"
  shift
  local f scanned=0
  for f in "$@"; do
    [ -e "${f}" ] || continue
    scanned=1
    if grep -qE -- "${pattern}" "${f}"; then
      printf 'leak: %s matches /%s/\n' "${f}" "${pattern}" >&2
      return 1
    fi
  done
  [ "${scanned}" -eq 1 ]
}

@test "push-template: skips when no service is running (empty daemon ps body)" {
  root="$(fake_root push-template.sh)"
  export STUB_COMPOSE_PS=''
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the coder service is not running yet (start the stack with: bazelisk run //scripts:prod-stack -- up)" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: skips on a failed daemon ps probe (docker access, exit 22)" {
  root="$(fake_root push-template.sh)"
  export STUB_COMPOSE_PS='coder'
  export STUB_COMPOSE_PS_RC=22
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "skipped: could not query the stack (coder) — this script needs docker access; run it with sudo, or add your user to the docker group" ]
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: skips when only coder runs (no db means no push token)" {
  root="$(fake_root push-template.sh)"
  export STUB_COMPOSE_PS='coder|stack-coder-1'
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skipped: the db service is not running, so no push token can be minted (start the stack with: bazelisk run //scripts:prod-stack -- up)" ]
}

@test "push-template: an unanswered buildinfo probe is a hard failure (curl 22)" {
  root="$(fake_root push-template.sh)"
  running_stack
  export STUB_CURL_RC=22
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container ()"* ]]
  [ "$(stub_log_last timeout)" = "timeout -k 2 20 docker exec -i stack-coder-1 curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last docker)" = "docker exec -i stack-coder-1 curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
  [ "$(stub_log_last curl)" = "curl -fsS -m 5 http://127.0.0.1:3000/api/v2/buildinfo" ]
}

@test "push-template: an unknown name is a user error and lists the known ones" {
  root="$(fake_root push-template.sh)"
  running_stack
  run --separate-stderr bash "${root}/scripts/push-template.sh" nope
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: unknown template 'nope' (known: workspace, devcontainer)" ]
  # Names are validated before anything touches docker.
  [ "$(stub_log_count docker)" -eq 0 ]
}

@test "push-template: --dry-run is not a flag here (arguments are names)" {
  root="$(fake_root push-template.sh)"
  running_stack
  run --separate-stderr bash "${root}/scripts/push-template.sh" --dry-run
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: unknown template '--dry-run' (known: workspace, devcontainer)" ]
}

@test "push-template: a missing main.tf stops the run (never a silent skip)" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  rm -f "${root}/templates/workspace/main.tf" "${root}/templates/devcontainer/main.tf"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [ "${stderr}" = "error: templates/workspace/main.tf not found (run this from the repo root)" ]
}

@test "push-template: a tree without the seed payload pushes nothing" {
  # Same never-a-silent-skip rule one level deeper: the seed payload is not
  # read by the CLI but by the server AFTER the push, so a tree that loses
  # templates/common/GROK_BUILD_AGENTS.md must fail locally instead of
  # shipping a copy whose Terraform apply dies on the missing file().
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  rm -f "${root}/templates/common/GROK_BUILD_AGENTS.md"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"GROK_BUILD_AGENTS.md is missing"* ]]
  [[ ${stderr} == *"2 of 2 template(s) did not reach an active version"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
}

@test "push-template: a tree without the ez-learn skill payload pushes nothing" {
  # Same never-a-silent-skip rule for the /ez-learn payload: main.tf reads it with
  # ez_learn_skill = chomp(file(...)), so a tree that lost
  # templates/common/ez-learn.SKILL.md has to fail locally by name rather than
  # ship a copy whose apply dies on the missing file().
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  rm -f "${root}/templates/common/ez-learn.SKILL.md"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"ez-learn.SKILL.md is missing"* ]]
  [[ ${stderr} == *"2 of 2 template(s) did not reach an active version"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
}

@test "push-template: a too-large vscode-alt.svg fails before templates push" {
  # Coder v2.36 stores workspace_apps.icon as varchar(256). A 5 KB SVG used
  # to survive every local check and die inside the provisioner with
  # pq: value too long. The guard has to fire before the CLI runs.
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  printf 'x%.0s' {1..200} >"${root}/templates/common/vscode-alt.svg"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"varchar(256)"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
}

@test "push-template: a missing lockfile is a note, and the push still happens" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  rm -f "${root}/templates/workspace/.terraform.lock.hcl"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 0 ]
  [[ ${output} == *"note: templates/workspace/.terraform.lock.hcl is missing — regenerate it with:"* ]]
  [[ ${output} == *"      terraform -chdir=templates/workspace init -backend=false"* ]]
  [[ ${output} == *"template workspace pushed; active version ${ACTIVE_ID}"* ]]
}

@test "push-template: the full chain reaches an ACTIVE version for both templates" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"template workspace pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template devcontainer pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template workspace: description set (chat-agent routing hint)"* ]]
  [[ ${output} == *"autostop default set to disabled"* ]]
  [[ ${output} == *"litellm_key not passed (LITELLM_MASTER_KEY in .env is empty or still the sample placeholder)"* ]]
  # Every CLI line the seams build, with the token kept out of argv: the
  # passthrough resolves `coder` to the stub, so argv is the whole proof.
  grep -Fq -- 'coder templates push workspace --directory - --yes --var image=evo-t1-dev:latest' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var github_auth_id=github' "${STUB_LOG}/docker.log"
  [[ ${output} == *"github_auth_id=github"* ]]
  grep -Fq -- 'coder templates versions list workspace --column id --column active' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder templates edit workspace --description' "${STUB_LOG}/docker.log"
  # Autostop is pinned off on both templates, so a new workspace starts with no deadline.
  grep -Fq -- 'coder templates edit workspace --default-ttl 0 --activity-bump 0' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder templates edit devcontainer --default-ttl 0 --activity-bump 0' "${STUB_LOG}/docker.log"
  grep -Fq -- 'coder whoami' "${STUB_LOG}/docker.log"
  grep -Fq -- '-e CODER_SESSION_TOKEN' "${STUB_LOG}/docker.log"
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}"/*.log
  # The whole chain addresses the daemon directly: not one call may resolve a
  # compose project from the cwd (the class of bug this shape exists to kill).
  logs_absent 'docker compose' "${STUB_LOG}/docker.log"
}

@test "push-template: the guards measure the real twin with no ambient REPO_ROOT" {
  root="$(fake_root push-template.sh)"
  # The throwaway main.tf above has no templatefile() bodies, which is how the size
  # guard's templates/common branch went unexercised here while a real
  # `bazelisk run //scripts:push-template` aborted under the script's own
  # `set -euo pipefail` on a variable nothing in scripts/ ever sets - after Preflight
  # and Variables had already printed, so the failure looked like a template problem.
  # Copy in the twin production actually measures.
  cp "${REPO_ROOT}/templates/workspace/main.tf" "${root}/templates/workspace/"
  cp "${REPO_ROOT}"/templates/workspace/*.tftpl "${root}/templates/workspace/"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} != *"unbound variable"* ]] ||
    fail "a guard aborted on a variable the script never sets: ${stderr}"
  # Reaching the push line means all three guards, size guard included, said nothing.
  [[ ${output} == *"pushing templates/workspace as template workspace"* ]] ||
    fail "never reached the push phase: ${stderr}"
  [ "${status}" -eq 0 ] || fail "the run failed: ${stderr}"
  [[ ${output} == *"template workspace pushed; active version ${ACTIVE_ID}"* ]]
}

@test "push-template: coder.env CODER_EXTERNAL_AUTH_0_ID is forwarded as github_auth_id" {
  root="$(fake_root push-template.sh)"
  printf '%s\n' 'CODER_EXTERNAL_AUTH_0_ID=primary-github' 'CODER_EXTERNAL_AUTH_0_CLIENT_SECRET=s3cret' >"${root}/coder.env"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 0 ]
  [[ ${output} == *"github_auth_id=primary-github"* ]]
  [[ ${output} != *"s3cret"* ]]
  grep -Fq -- '--var github_auth_id=primary-github' "${STUB_LOG}/docker.log"
  logs_absent 's3cret' "${STUB_LOG}"/*.log
}

@test "push-template: an empty CODER_EXTERNAL_AUTH_0_ID still declares github" {
  root="$(fake_root push-template.sh)"
  printf '%s\n' 'CODER_EXTERNAL_AUTH_0_ID=' >"${root}/coder.env"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 0 ]
  grep -Fq -- '--var github_auth_id=github' "${STUB_LOG}/docker.log"
}

@test "push-template: a garbage CODER_EXTERNAL_AUTH_0_ID fails before templates push" {
  root="$(fake_root push-template.sh)"
  printf '%s\n' 'CODER_EXTERNAL_AUTH_0_ID=not a valid id' >"${root}/coder.env"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"not a Coder provider id"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
}

@test "push-template: no ACTIVE row counts both templates as failed (exit 1)" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  printf '%s\n' 'ID                                    ACTIVE' "${ACTIVE_ID}" >"${BATS_TEST_TMPDIR}/versions.txt"
  export STUB_CODER_OUT="${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"error: pushed workspace but it has no active version"* ]]
  [[ ${stderr} == *"error: pushed devcontainer but it has no active version"* ]]
  [[ ${stderr} == *"2 of 2 template(s) did not reach an active version"* ]]
}

@test "push-template: a docker-exec that does not answer stops the whole run" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  export STUB_DOCKER_EXEC_RUN=0
  export STUB_DOCKER_EXEC_RC=1
  export STUB_DOCKER_EXEC_OUT='Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?'
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 1 ]
  # The stack probe answers (running_stack), so the first refused call is the
  # buildinfo exec: a daemon that will not answer the in-container calls reads
  # as an unreachable API — and nothing is pushed.
  [[ ${stderr} == *"Cannot connect to the Docker daemon at unix:///var/run/docker.sock"* ]]
  # shellcheck disable=SC2154 # $stderr is set by `run --separate-stderr`
  [[ ${stderr} == "error: the Coder API at http://127.0.0.1:3000 is not answering inside the coder container"* ]]
  [[ "$(stub_log docker)" == *"exec -i"* ]]
  logs_absent 'templates push' "${STUB_LOG}/docker.log"
  [ "$(stub_log_count psql)" -eq 0 ]
}

@test "push-template: a name filter pushes once, in TEMPLATES_DEFAULT order" {
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" devcontainer workspace devcontainer
  [ "${status}" -eq 0 ]
  # Three names, two pushes, and workspace first despite being named second.
  [ "$(grep -Fc 'coder templates push' <<<"$(stub_log docker)")" -eq 2 ]
  [[ "$(grep -F 'coder templates push' <<<"$(stub_log docker)")" == *"templates push workspace --directory"*"templates push devcontainer"* ]]
  [[ ${output} == *"template workspace pushed; active version ${ACTIVE_ID}"* ]]
  [[ ${output} == *"template devcontainer pushed; active version ${ACTIVE_ID}"* ]]
}

@test "push-template: the placeholder LiteLLM key is not passed and never printed" {
  root="$(fake_root push-template.sh 'LITELLM_MASTER_KEY=change-me-litellm-zzz9')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  if [ "${status}" -ne 0 ]; then
    printf 'status=%s\nstdout<<%s>>\nstderr<<%s>>\n' "${status}" "${output}" "${stderr}"
  fi
  [ "${status}" -eq 0 ]
  [[ ${output} == *"litellm_key not passed (LITELLM_MASTER_KEY in .env is empty or still the sample placeholder)"* ]]
  logs_absent 'change-me-litellm-zzz9' "${STUB_LOG}/docker.log"
  logs_absent 'change-me-litellm-zzz9' "${STUB_LOG}/coder.log"
}

@test "push-template: a real LiteLLM key travels as a --var and is never printed" {
  root="$(fake_root push-template.sh 'LITELLM_MASTER_KEY=sk-real-looking-0123456789abcdef')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"litellm_key passed from LITELLM_MASTER_KEY (value not shown)"* ]]
  [[ ${output} != *"sk-real-looking-0123456789abcdef"* ]]
  [[ ${stderr} != *"sk-real-looking-0123456789abcdef"* ]]
  # The key is a --var by design (visible in that one process's argv, inside the
  # container, for the length of the push). The session token never is.
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}"/*.log
  grep -Fq -- '-e CODER_SESSION_TOKEN' "${STUB_LOG}/docker.log"
}

@test "push-template: resolve_repo_root only accepts a directory holding docker-compose.yml" {
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" resolve_repo_root

  local nowhere="${BATS_TEST_TMPDIR}/nowhere"
  local proven="${BATS_TEST_TMPDIR}/proven"
  mkdir -p "${nowhere}" "${proven}/scripts"
  printf 'x\n' >"${proven}/docker-compose.yml"

  REPO_ROOT=""
  GITHUB_WORKSPACE=""
  BUILD_WORKSPACE_DIRECTORY=""
  SELF_DIR="${nowhere}"
  cd "${nowhere}"

  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 5 ]
  [[ ${stderr} == *"unresolvable repo root"* ]]
  [[ ${stderr} == *"need docker-compose.yml"* ]]

  cd "${proven}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${proven}" ]

  cd "${nowhere}"
  REPO_ROOT="${proven}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${proven}" ]

  SELF_DIR="${proven}/scripts"
  REPO_ROOT=""
  cd "${nowhere}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${proven}/scripts/.." ]
}

@test "push-template: resolve_repo_root prefers the script tree over PWD" {
  # bazelisk test sets cwd to a runfiles tree that also has docker-compose.yml.
  # Whole-script tests launch bash /fake-root/scripts/push-template.sh from
  # there and must still resolve the fake root, not the harness cwd.
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" resolve_repo_root
  script_tree="$(make_scratch)/script-tree"
  harness_cwd="$(make_scratch)/harness-cwd"
  mkdir -p "${script_tree}/scripts" "${harness_cwd}"
  printf 'x\n' >"${script_tree}/docker-compose.yml"
  printf 'x\n' >"${harness_cwd}/docker-compose.yml"
  REPO_ROOT=""
  unset GITHUB_WORKSPACE
  BUILD_WORKSPACE_DIRECTORY=""
  SELF_DIR="${script_tree}/scripts"
  cd "${harness_cwd}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${script_tree}/scripts/.." ]
}

@test "push-template: resolve_repo_root prefers BUILD_WORKSPACE_DIRECTORY over PWD" {
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" resolve_repo_root
  workspace="$(make_scratch)/workspace"
  runfiles="$(make_scratch)/runfiles"
  mkdir -p "${workspace}" "${runfiles}/scripts"
  printf 'x\n' >"${workspace}/docker-compose.yml"
  printf 'x\n' >"${runfiles}/docker-compose.yml"
  REPO_ROOT=""
  unset GITHUB_WORKSPACE
  BUILD_WORKSPACE_DIRECTORY="${workspace}"
  cd "${runfiles}"
  SELF_DIR="${runfiles}/scripts"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 0 ]
  [ "${output}" = "${workspace}" ]
}

@test "push-template: BUILD_WORKSPACE_DIRECTORY .env beats the script copy" {
  # bazelisk run launches the runfiles copy of the script; the live .env
  # lives in the checkout named by BUILD_WORKSPACE_DIRECTORY.
  root="$(fake_root push-template.sh 'LITELLM_MASTER_KEY=change-me-from-runfiles')"
  checkout="$(make_scratch)/checkout"
  mkdir -p "${checkout}/scripts/lib" "${checkout}/templates/workspace" \
    "${checkout}/templates/devcontainer" "${checkout}/templates/common"
  : >"${checkout}/docker-compose.yml"
  printf '%s\n' 'LITELLM_MASTER_KEY=sk-from-checkout-0123456789abcdef' >"${checkout}/.env"
  cp -R "${root}/templates/." "${checkout}/templates/"
  : >"${checkout}/templates/workspace/.terraform.lock.hcl"
  : >"${checkout}/templates/devcontainer/.terraform.lock.hcl"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  export BUILD_WORKSPACE_DIRECTORY="${checkout}"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"litellm_key passed from LITELLM_MASTER_KEY (value not shown)"* ]]
  [[ ${output} != *"sk-from-checkout-0123456789abcdef"* ]]
  grep -Fq -- '--var litellm_key=sk-from-checkout-0123456789abcdef' "${STUB_LOG}/docker.log"
}

@test "push-template: SEARCH_MCP=false passes --var search_mcp=false for both templates" {
  root="$(fake_root push-template.sh 'SEARCH_MCP=false')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"search_mcp=false passed from SEARCH_MCP"* ]]
  grep -Fq -- '--var search_mcp=false' "${STUB_LOG}/docker.log"
  # One vars array serves both pushes, so the off switch cannot reach one template
  # only; the port still travels with it because searxng_url is always passed.
  [ "$(grep -cF -- '--var search_mcp=false' "${STUB_LOG}/docker.log")" -eq 2 ]
  grep -Fq -- '--var searxng_url=http://host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: SEARCH_MCP=true or unset passes no search_mcp var and keeps the default port" {
  # Default-ON polarity: the template declares search_mcp = true, so anything other
  # than an explicit false must push nothing at all.
  root="$(fake_root push-template.sh 'SEARCH_MCP=true')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"search_mcp"* ]]
  # A push did happen, so the absence below proves the script passed nothing.
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'search_mcp' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var searxng_url=http://host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: STACK_SEARCH_PORT=18181 pushes the remapped search port" {
  # The dev stack may publish SearXNG somewhere other than 8181; the pushed URL has
  # to name that port or every workspace dials a port nothing listens on.
  root="$(fake_root push-template.sh 'STACK_SEARCH_PORT=18181')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"searxng_url=http://host.docker.internal:18181 passed from STACK_SEARCH_PORT in .env"* ]]
  grep -Fq -- '--var searxng_url=http://host.docker.internal:18181' "${STUB_LOG}/docker.log"
  logs_absent 'host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: a blank or non-numeric STACK_SEARCH_PORT falls back to 8181" {
  root="$(fake_root push-template.sh 'STACK_SEARCH_PORT=')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"searxng_url=http://host.docker.internal:8181 passed from the default"* ]]
  grep -Fq -- '--var searxng_url=http://host.docker.internal:8181' "${STUB_LOG}/docker.log"
}

@test "push-template: GITHUB_MCP=false passes --var github_mcp=false for both templates" {
  # Default-ON polarity, same shape as SEARCH_MCP: the templates declare
  # github_mcp = true, so only an explicit false has to say anything.
  root="$(fake_root push-template.sh 'GITHUB_MCP=false')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"github_mcp=false passed from GITHUB_MCP"* ]]
  grep -Fq -- '--var github_mcp=false' "${STUB_LOG}/docker.log"
  # One vars array serves both pushes, so the github server cannot be turned off
  # for one template only.
  [ "$(grep -cF -- '--var github_mcp=false' "${STUB_LOG}/docker.log")" -eq 2 ]
  # The toggle is the only thing that travels: the GitHub credential comes from
  # the External Auth provider, so no token-shaped var may ever ride the push.
  logs_absent '--var [Gg][Hh]_?[Tt]oken' "${STUB_LOG}/docker.log"
}

@test "push-template: GITHUB_MCP=true or unset passes no github_mcp var" {
  # Default-ON polarity: the template declares github_mcp = true, so anything other
  # than an explicit false must push nothing at all rather than a redundant on
  # switch (which would also be the one way to ask for a token the script must not
  # carry).
  root="$(fake_root push-template.sh 'GITHUB_MCP=true')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"github_mcp"* ]]
  # A push did happen, so the absence below proves the script passed nothing.
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'github_mcp' "${STUB_LOG}/docker.log"
}

@test "push-template: CONTEXT7_MCP=false passes --var context7_mcp=false for both templates" {
  root="$(fake_root push-template.sh 'CONTEXT7_MCP=false')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"context7_mcp=false passed from CONTEXT7_MCP"* ]]
  grep -Fq -- '--var context7_mcp=false' "${STUB_LOG}/docker.log"
  # One vars array serves both pushes, so the cached context7 server cannot be
  # turned off for one template only.
  [ "$(grep -cF -- '--var context7_mcp=false' "${STUB_LOG}/docker.log")" -eq 2 ]
}

@test "push-template: CONTEXT7_MCP=true or unset passes no context7_mcp var and keeps the default" {
  # Default-ON polarity: the templates declare context7_mcp = true, so anything
  # other than an explicit false must push nothing at all; true (like unset) leaves
  # the default untouched rather than pushing a redundant on switch. The key is
  # separate and stays empty here, which is the supported default shape.
  root="$(fake_root push-template.sh 'CONTEXT7_MCP=true')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"context7_mcp"* ]]
  # A push did happen, so the absence below proves the script passed nothing.
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'context7_mcp' "${STUB_LOG}/docker.log"
}

@test "push-template: a Context7 key travels as a --var and is never printed" {
  root="$(fake_root push-template.sh 'CONTEXT7_API_KEY=ctx7-secret-test-0123456789abcdef')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"context7_api_key passed from CONTEXT7_API_KEY (value not shown)"* ]]
  [[ ${output} != *"ctx7-secret-test-0123456789abcdef"* ]]
  [[ ${stderr} != *"ctx7-secret-test-0123456789abcdef"* ]]
  # The key is a --var by design (visible in that one process's argv, inside the
  # container, for the length of the push). The session token never is.
  grep -Fq -- '--var context7_api_key=ctx7-secret-test-0123456789abcdef' "${STUB_LOG}/docker.log"
  logs_absent 'CODER_SESSION_TOKEN=|[0-9a-f]{10}-[0-9a-f]{22}' "${STUB_LOG}"/*.log
}

@test "push-template: an empty Context7 key is not passed and never printed" {
  # A blank line in .env must not override the empty template default, and the
  # whole context7_api_key var must stay out of the push.
  root="$(fake_root push-template.sh 'CONTEXT7_API_KEY=')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"context7_api_key"* ]]
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'context7_api_key' "${STUB_LOG}/docker.log"
}

# --- the Infisical vault vars -----------------------------------------------
#
# Seven template variables (infisical_enabled plus the six values a workspace's boot
# fetch dials the vault with) are declared in both coder.tf twins, so each is either
# forwarded from .env or left to the template's own default. The flag defaults OFF -
# the deliberate inverse of OBSERVABILITY_ENABLED - so the shipped state must hand
# the word "infisical" to the CLI exactly zero times.

# Real .env bodies for the six values, each distinctive enough that an assertion
# about one cannot be satisfied by another word the script prints.
VAULT_ENV=(
  'INFISICAL_URL=http://vault.internal:18182'
  'INFISICAL_PORT=18182'
  'INFISICAL_PROJECT_ID=proj-aaaa-bbbb'
  'INFISICAL_MACHINE_IDENTITY_ID=mach-cccc-dddd'
  'INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=ci-eeee-ffff'
  'INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=cs-gggg-hhhh'
  'INFISICAL_ENVIRONMENT=staging-vault'
)

# The same six still carrying their .env.example bodies.
VAULT_PLACEHOLDER_ENV=(
  'INFISICAL_URL=change-me-infisical-url'
  'INFISICAL_PROJECT_ID=change-me-infisical-project'
  'INFISICAL_MACHINE_IDENTITY_ID=change-me-infisical-machine'
  'INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=change-me-infisical-client-id'
  'INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=change-me-infisical-client-secret'
  'INFISICAL_ENVIRONMENT=change-me-infisical-environment'
)

@test "push-template: env_get_forwardable accepts a real value and refuses a blank or placeholder one" {
  # The one rule the six vault values share, pinned at the seam itself rather than
  # six times through the whole CLI: a real body is printed and the key accepted,
  # while a blank line and a change-me* body print nothing and return non-zero,
  # which is what leaves their --var unpushed instead of pushing over a template
  # default. A key .env never carries reads the same as a blank one.
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" env_get
  load_shell_function "${REPO_ROOT}/scripts/push-template.sh" env_get_forwardable
  local dir="${BATS_TEST_TMPDIR}/forwardable"
  mkdir -p "${dir}"
  printf '%s\n' 'REAL_KEY=http://vault.internal:18182' 'BLANK_KEY=' \
    'PLACEHOLDER_KEY=change-me-infisical-machine' >"${dir}/.env"
  cd "${dir}"

  run --separate-stderr env_get_forwardable REAL_KEY
  [ "${status}" -eq 0 ]
  [ "${output}" = "http://vault.internal:18182" ]

  run --separate-stderr env_get_forwardable BLANK_KEY
  [ "${status}" -eq 1 ]
  [ "${output}" = "" ]

  run --separate-stderr env_get_forwardable PLACEHOLDER_KEY
  [ "${status}" -eq 1 ]
  [ "${output}" = "" ]

  run --separate-stderr env_get_forwardable ABSENT_KEY
  [ "${status}" -eq 1 ]
  [ "${output}" = "" ]

  # A placeholder only reads as a placeholder from the front: a real value that
  # happens to contain the word further along is still forwarded.
  printf '%s\n' 'MIDDLE_KEY=https://change-me.vault.internal:18182' >"${dir}/.env"
  run --separate-stderr env_get_forwardable MIDDLE_KEY
  [ "${status}" -eq 0 ]
  [ "${output}" = "https://change-me.vault.internal:18182" ]
}

@test "push-template: no INFISICAL_ENABLED in .env pushes no infisical var at all" {
  # Off is the shipped state: not one --var may name an infisical variable, so every
  # template default (false, "", "prod") stands untouched.
  root="$(fake_root push-template.sh)"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} != *"infisical"* ]]
  # A push did happen, so the absence below proves the script passed nothing.
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'infisical' "${STUB_LOG}/docker.log"
  logs_absent 'infisical' "${STUB_LOG}/coder.log"
}

@test "push-template: every INFISICAL_ENABLED spelling but a truthy one pushes nothing" {
  # Default-OFF polarity: only what common.sh's truthy() accepts is worth saying, so
  # false, 0, no, off, blank and garbage are all off and must push nothing rather
  # than a redundant switch the template already carries as its default.
  local spelling n=0
  for spelling in false FALSE 0 no off '' 'not-a-flag'; do
    n=$((n + 1))
    rm -rf "${BATS_TEST_TMPDIR}/root"
    root="$(fake_root push-template.sh "INFISICAL_ENABLED=${spelling}")"
    running_stack
    psql_token_variant
    versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
    run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
    if [ "${status}" -ne 0 ]; then
      printf 'FAIL: INFISICAL_ENABLED=%s exited %s: %s\n' \
        "${spelling}" "${status}" "${stderr}" >&2
      return 1
    fi
    if [[ ${output} == *"infisical"* ]]; then
      printf 'FAIL: INFISICAL_ENABLED=%s was read as on\n' "${spelling}" >&2
      return 1
    fi
    # A push ran every iteration, so the count below cannot be an empty log.
    if [ "$(grep -cF -- 'coder templates push workspace' "${STUB_LOG}/docker.log")" -ne "${n}" ]; then
      printf 'FAIL: INFISICAL_ENABLED=%s did not reach the push\n' "${spelling}" >&2
      return 1
    fi
    if grep -qF -- 'infisical' "${STUB_LOG}/docker.log"; then
      printf 'FAIL: INFISICAL_ENABLED=%s reached the push argv\n' "${spelling}" >&2
      return 1
    fi
  done
}

@test "push-template: a truthy INFISICAL_ENABLED pushes --var infisical_enabled=true on both templates" {
  # One vars array serves both pushes, so the vault cannot be switched on for one
  # template only. Every truthy spelling is normalised to the literal true, so
  # Terraform is handed a bool and not whichever of them .env happened to carry.
  local spelling n=0 both
  for spelling in true TRUE on 1 yes; do
    n=$((n + 1))
    both=$((2 * n))
    rm -rf "${BATS_TEST_TMPDIR}/root"
    root="$(fake_root push-template.sh "INFISICAL_ENABLED=${spelling}")"
    running_stack
    psql_token_variant
    versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
    run --separate-stderr bash "${root}/scripts/push-template.sh"
    if [ "${status}" -ne 0 ]; then
      printf 'FAIL: INFISICAL_ENABLED=%s exited %s: %s\n' \
        "${spelling}" "${status}" "${stderr}" >&2
      return 1
    fi
    [[ ${output} == *"infisical_enabled=true passed from INFISICAL_ENABLED"* ]] ||
      fail "INFISICAL_ENABLED=${spelling} passed the var without saying so: ${output}"
    # Two pushes per iteration, every one of them carrying the normalised bool and
    # none carrying the raw spelling: equal counts, and both equal to 2n.
    if [ "$(grep -cF -- '--var infisical_enabled=' "${STUB_LOG}/docker.log")" -ne "${both}" ]; then
      printf 'FAIL: INFISICAL_ENABLED=%s did not push the toggle exactly twice\n' \
        "${spelling}" >&2
      return 1
    fi
    if [ "$(grep -cF -- '--var infisical_enabled=true' "${STUB_LOG}/docker.log")" -ne "${both}" ]; then
      printf 'FAIL: INFISICAL_ENABLED=%s was pushed verbatim instead of as true\n' \
        "${spelling}" >&2
      return 1
    fi
  done
}

@test "push-template: the pull-on-start gate is forwarded only under the vault flag" {
  # Two gates, and the second is meaningless without the first: an off vault pushes
  # neither word, an on vault with the gate off pushes only the first, and only an on
  # vault with the gate on pushes both. A pushed --var infisical_pull_on_start=false
  # would be the same shape as a pushed true once Terraform has it, so the off cases
  # have to be *absent*, not present-and-false - that is what leaves each template's
  # own `default = false` standing.
  local case want_enabled want_pulled pulled enabled
  for case in "off" "vault-only" "both"; do
    rm -rf "${BATS_TEST_TMPDIR}/root"
    case "${case}" in
      off)
        root="$(fake_root push-template.sh "INFISICAL_PULL_ON_START=true")"
        want_enabled=0
        want_pulled=0
        ;;
      vault-only)
        root="$(fake_root push-template.sh "INFISICAL_ENABLED=true" "INFISICAL_PULL_ON_START=false")"
        want_enabled=2
        want_pulled=0
        ;;
      both)
        root="$(fake_root push-template.sh "INFISICAL_ENABLED=true" "INFISICAL_PULL_ON_START=on")"
        want_enabled=4
        want_pulled=2
        ;;
    esac
    running_stack
    psql_token_variant
    versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
    run --separate-stderr bash "${root}/scripts/push-template.sh"
    [ "${status}" -eq 0 ] || fail "${case} exited ${status}: ${stderr}"
    # The stub log is one file per test and fake_root does not clear it, so these
    # counts are cumulative across the three cases: 0, then 2, then 4 pushes of the
    # vault flag, and 2 pushes of the gate from the last case alone.
    pulled="$(grep -oF -- '--var infisical_pull_on_start' "${STUB_LOG}/docker.log" | wc -l)"
    [ "${pulled}" -eq "${want_pulled}" ] ||
      fail "${case}: expected ${want_pulled} pushes of the gate, saw ${pulled}"
    if [ "${case}" = "both" ]; then
      # The truthy spelling normalises to the one literal Terraform wants.
      [ "$(grep -oF -- '--var infisical_pull_on_start=true' "${STUB_LOG}/docker.log" | wc -l)" -eq 2 ] ||
        fail "${case}: the spelling was pushed verbatim instead of as true"
      [[ ${output} == *"infisical_pull_on_start=true passed from INFISICAL_PULL_ON_START"* ]] ||
        fail "${case}: passed the gate without saying so: ${output}"
    else
      [[ ${output} != *"infisical_pull_on_start"* ]] ||
        fail "${case}: talked about a gate it did not push: ${output}"
    fi
    # The primary flag keeps its own shape in every case: absent while the vault is
    # off, the literal true once it is on.
    enabled="$(grep -oF -- '--var infisical_enabled=true' "${STUB_LOG}/docker.log" | wc -l)"
    [ "${enabled}" -eq "${want_enabled}" ] ||
      fail "${case}: expected ${want_enabled} pushes of the vault flag, saw ${enabled}"
  done
}

@test "push-template: the six vault values are forwarded when .env carries real ones" {
  # The values travel whether or not the flag is on, so turning the vault on later is
  # one more push rather than a re-config of six keys. Note the name shift on the
  # Universal Auth pair: .env spells them the way the Infisical CLI reads them and
  # the templates spell them the way the workspace sees them.
  root="$(fake_root push-template.sh "${VAULT_ENV[@]}")"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  grep -Fq -- '--var infisical_project_id=proj-aaaa-bbbb' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var infisical_machine_identity_id=mach-cccc-dddd' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var infisical_client_id=ci-eeee-ffff' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var infisical_client_secret=cs-gggg-hhhh' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var infisical_environment=staging-vault' "${STUB_LOG}/docker.log"
  # Five values, one vars array, both templates: ten --var words across the two
  # recorded push lines (grep -o, not -c, because both words of a pair sit on one
  # line and a line count would read 2 however many vars rode it). The sixth,
  # infisical_url, is composed inside the flag gate rather than forwarded here, so a
  # stack that never opted in still pushes no vault word at all.
  [ "$(grep -oF -- '--var infisical_' "${STUB_LOG}/docker.log" | wc -l)" -eq 10 ]
  [[ $(grep -cF -- '--var infisical_url=' "${STUB_LOG}/docker.log" || true) -eq 0 ]]
  # None of the six values is echoed: each forward names the .env key it came from
  # and stops there, the way litellm_key and context7_api_key already do.
  [[ ${output} == *"infisical_environment passed from INFISICAL_ENVIRONMENT in .env (value not shown)"* ]]
  [[ ${output} != *"http://vault.internal:18182"* ]]
  [[ ${output} != *"proj-aaaa-bbbb"* ]]
  [[ ${output} != *"mach-cccc-dddd"* ]]
  [[ ${output} != *"ci-eeee-ffff"* ]]
  [[ ${output} != *"cs-gggg-hhhh"* ]]
  [[ ${output} != *"staging-vault"* ]]
  [[ ${stderr} != *"cs-gggg-hhhh"* ]]
}

@test "push-template: blank vault values are not forwarded" {
  # A blank line in .env must not override a template default - above all the
  # environment's "prod", which an empty INFISICAL_ENVIRONMENT= would otherwise
  # replace with nothing at all.
  root="$(fake_root push-template.sh 'INFISICAL_ENABLED=true' 'INFISICAL_URL=' \
    'INFISICAL_PROJECT_ID=' 'INFISICAL_MACHINE_IDENTITY_ID=' \
    'INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=' 'INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=' \
    'INFISICAL_ENVIRONMENT=')"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  # The flag is on and the URL is composed from a port this fixture never set, so two
  # infisical vars reach the CLI on each push: the flag and the host-gateway URL at the
  # published default. A blank INFISICAL_URL must not reach the CLI as an empty origin.
  [ "$(grep -oF -- '--var infisical_' "${STUB_LOG}/docker.log" | wc -l)" -eq 4 ]
  grep -Fq -- '--var infisical_enabled=true' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var infisical_url=http://host.docker.internal:8182' "${STUB_LOG}/docker.log"
  logs_absent 'infisical_url=http=$|infisical_project_id|infisical_machine_identity_id' "${STUB_LOG}/docker.log"
  logs_absent 'infisical_client_id|infisical_client_secret|infisical_environment' "${STUB_LOG}/docker.log"
}

@test "push-template: a change-me vault placeholder is never forwarded" {
  # .env.example ships change-me* bodies; pushing one verbatim would put a public
  # constant into every workspace, so it reads as unset and the default stands.
  root="$(fake_root push-template.sh "${VAULT_PLACEHOLDER_ENV[@]}")"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  grep -Fq -- 'coder templates push workspace --directory - --yes' "${STUB_LOG}/docker.log"
  logs_absent 'infisical' "${STUB_LOG}/docker.log"
  logs_absent 'change-me' "${STUB_LOG}/docker.log"
}

@test "push-template: a workspace dials the vault through the host gateway, never the host's own origin" {
  # INFISICAL_URL is the operator CLI's origin on the stack host, where
  # 127.0.0.1:8182 reaches the published port. Handed to a workspace unchanged, the
  # same spelling dials that container's own loopback and every Universal Auth login
  # fails against a dead address - so the workspace gets the host gateway, with the
  # port taken from INFISICAL_PORT so a stack on a non-default port still resolves.
  root="$(fake_root push-template.sh 'INFISICAL_ENABLED=true' "${VAULT_ENV[@]}")"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  grep -Fq -- '--var infisical_url=http://host.docker.internal:18182' "${STUB_LOG}/docker.log"
  # The host's own origin never travels, in the argv or in what the run printed.
  [[ $(grep -cF -- 'vault.internal' "${STUB_LOG}/docker.log" || true) -eq 0 ]]
  [[ ${output} != *'vault.internal'* ]]
  [[ ${stderr} != *'vault.internal'* ]]
  [[ ${output} == *'infisical_url=http://host.docker.internal:18182 passed from INFISICAL_PORT in .env'* ]]
}

@test "push-template: the vault client secret is forwarded and its value is never printed" {
  root="$(fake_root push-template.sh 'INFISICAL_ENABLED=true' "${VAULT_ENV[@]}")"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh"
  [ "${status}" -eq 0 ]
  [[ ${output} == *"infisical_client_secret passed from INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET in .env (value not shown)"* ]]
  # The value is not in anything the CLI printed, in either stream.
  [[ ${output} != *"cs-gggg-hhhh"* ]] || fail "the vault client secret was printed on stdout"
  [[ ${stderr} != *"cs-gggg-hhhh"* ]] || fail "the vault client secret was printed on stderr"
  # The secret is a --var by design: it reaches the CLI as an argument, so it is in
  # that one process's argv (recorded on the docker line and the coder line, visible
  # inside the container for the length of the push). Every log that carries no argv
  # must hold nothing of it, and neither stream the CLI printed may name it.
  grep -Fq -- '--var infisical_client_secret=cs-gggg-hhhh' "${STUB_LOG}/docker.log"
  grep -Fq -- '--var infisical_client_secret=cs-gggg-hhhh' "${STUB_LOG}/coder.log"
  logs_absent 'cs-gggg-hhhh' "${STUB_LOG}/psql.log" "${STUB_LOG}/curl.log"
}

@test "push-template: the vault vars ride the same --var bundle and each keeps its own value" {
  # Every --var must be followed by its own name=value word: a value that reached the
  # CLI as a bare word would let the flag after it (-f, --file, --directory) be read
  # as that value and swallow the rest of the bundle. The stub records argv
  # space-joined, so walking the words after the first --var is the whole proof.
  root="$(fake_root push-template.sh 'INFISICAL_ENABLED=true' "${VAULT_ENV[@]}")"
  running_stack
  psql_token_variant
  versions_answer "${BATS_TEST_TMPDIR}/versions.txt"
  run --separate-stderr bash "${root}/scripts/push-template.sh" workspace
  [ "${status}" -eq 0 ]
  local -a argv=()
  read -r -a argv <<<"$(grep -F 'coder templates push workspace' <<<"$(stub_log docker)")"
  [ "${#argv[@]}" -gt 0 ] || fail "no push argv was recorded"
  local i first=-1 pairs=0 saw_vault=0 value_word
  for ((i = 0; i < ${#argv[@]}; i++)); do
    if [ "${argv[i]}" = "--var" ]; then
      first=${i}
      break
    fi
  done
  [ "${first}" -ge 0 ] || fail "the push argv carries no --var at all"
  # The bundle runs to the very end of argv, so it is one contiguous --var/word run
  # and an odd length can only mean a value was dropped or split off its --var.
  [ $(((${#argv[@]} - first) % 2)) -eq 0 ] ||
    fail "the --var bundle is odd-length, so a value was dropped or split: ${argv[*]}"
  for ((i = first; i < ${#argv[@]}; i += 2)); do
    [ "${argv[i]}" = "--var" ] ||
      fail "bundle word ${i} is '${argv[i]}' where --var belongs"
    value_word="${argv[i + 1]}"
    case "${value_word}" in
      '' | -* | *=)
        printf 'FAIL: bundle word %s is %s: --var must be followed by a name=value pair\n' \
          "$((i + 1))" "'${value_word}'" >&2
        return 1
        ;;
      *=*) ;;
      *)
        printf 'FAIL: bundle word %s is %s: no =, so a value reached the CLI bare\n' \
          "$((i + 1))" "'${value_word}'" >&2
        return 1
        ;;
    esac
    case "${value_word}" in
      infisical_*) saw_vault=1 ;;
    esac
    pairs=$((pairs + 1))
  done
  # image, github_auth_id and searxng_url are always passed; the seven vault vars
  # joined them in the one array, so the bundle is exactly ten pairs.
  [ "${pairs}" -eq 10 ] || fail "expected 10 --var pairs in one bundle, saw ${pairs}"
  [ "${saw_vault}" -eq 1 ] || fail "no infisical_* pair rode the bundle"
  # Contiguous from --yes onward: nothing but --var pairs follows it.
  [[ ${argv[*]} == *'--yes --var image=evo-t1-dev:latest'* ]]
  logs_absent '(^|[[:space:]])-f([[:space:]]|$)|--file' "${STUB_LOG}/docker.log"
}

# ── template-push.sh (moved from lib.bats; keep these assertions) ──────────

# The payload files every template's main.tf reads from the staged copy; the
# template_push_one guard has to name exactly these and nothing else.
payloads=("${COMMON_PAYLOADS[@]}")

source_libs() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/coder_api.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/template-push.sh"
}

@test "template-push: template_push_one streams the dir and passes --var args through" {
  source_libs
  mkdir -p "${BATS_TEST_TMPDIR}/tpl/.terraform" "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' 'resource "coder_script" "x" {}' > "${BATS_TEST_TMPDIR}/tpl/main.tf"
  printf 'junk' > "${BATS_TEST_TMPDIR}/tpl/.terraform/provider.cache"
  write_common_payloads "${BATS_TEST_TMPDIR}/common"
  export CONTAINER_API_URL="http://coder:3002"
  export session_token="kid-secret"
  export CODER_CONTAINER=stack-coder-1
  run --separate-stderr template_push_one tpl1 "${BATS_TEST_TMPDIR}/tpl" --var image=tag
  [ "${status}" -eq 0 ]
  [[ "$(stub_log_last docker)" == *"coder templates push tpl1 --directory - --yes --var image=tag"* ]]
  [[ "$(stub_log_last docker)" != *kid-secret* ]]
}

@test "template-push: an unresolved CODER_CONTAINER refuses before anything runs" {
  source_libs
  # A run that never resolved a container (daemon down, wrong service name)
  # must fail locally with a named cause — never stream a tar at nothing.
  mkdir -p "${BATS_TEST_TMPDIR}/tpl-nopc" "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' 'resource "coder_script" "w" {}' > "${BATS_TEST_TMPDIR}/tpl-nopc/main.tf"
  write_common_payloads "${BATS_TEST_TMPDIR}/common"
  export CONTAINER_API_URL="http://coder:3002"
  export session_token="kid-secret"
  run --separate-stderr template_push_one tpl4 "${BATS_TEST_TMPDIR}/tpl-nopc"
  [ "${status}" -eq 1 ]
  [[ ${stderr} == *"no coder container was resolved (CODER_CONTAINER is empty) - nothing was pushed"* ]]
  [ -z "$(stub_log docker)" ]
  [ -z "$(stub_log coder)" ]
}

@test "template-push: the seed payloads ride inside the pushed tar" {
  source_libs
  # The server-side Terraform reads GROK_BUILD_AGENTS.md (file(), into the
  # startup script), notes-setup.sh (file(), into the same script) and
  # vscode-alt.svg (filebase64(), into the editor icon) from inside the pushed
  # copy, so the staging must drop all three common copies into the tar and
  # .terraform/ must stay out. The sink DOCKER_BIN stands in
  # for `docker exec -i`: it drains stdin into a file instead of
  # exec'ing the coder stub, which is how the tar stream becomes inspectable.
  mkdir -p "${BATS_TEST_TMPDIR}/tpl/.terraform" "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' 'resource "coder_script" "x" {}' > "${BATS_TEST_TMPDIR}/tpl/main.tf"
  printf 'junk' > "${BATS_TEST_TMPDIR}/tpl/.terraform/provider.cache"
  write_common_payloads "${BATS_TEST_TMPDIR}/common"
  printf '%s\n' '#!/usr/bin/env bash' 'cat > "${STUB_LOG}/push.tar"' > "${BATS_TEST_TMPDIR}/bin/tar-sink"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/tar-sink"
  export DOCKER_BIN=tar-sink
  export CODER_CONTAINER=stack-coder-1
  template_push_one tpl1 "${BATS_TEST_TMPDIR}/tpl"
  if [ ! -f "${STUB_LOG}/push.tar" ]; then
    printf 'FAIL: no tar stream reached the sink\n' >&2
    return 1
  fi
  tar -tf "${STUB_LOG}/push.tar" > "${BATS_TEST_TMPDIR}/members.txt"
  grep -Fxq './main.tf' "${BATS_TEST_TMPDIR}/members.txt"
  local payload
  for payload in "${payloads[@]}"; do
    grep -Fxq "./${payload}" "${BATS_TEST_TMPDIR}/members.txt"
  done
  if grep -qF '.terraform' "${BATS_TEST_TMPDIR}/members.txt"; then
    printf 'leak: .terraform reached the pushed tar\n' >&2
    return 1
  fi
}

@test "template-push: runfiles symlinks land as regular files in the tar" {
  source_libs
  # bazelisk run materializes templates/** as symlinks into the execroot.
  # Coder unpacks the archive in an empty workdir and does not follow those
  # host paths, so a stored symlink plans as "No configuration files".
  mkdir -p "${BATS_TEST_TMPDIR}/real" "${BATS_TEST_TMPDIR}/runfiles/tpl" \
    "${BATS_TEST_TMPDIR}/runfiles/common"
  printf '%s\n' 'resource "coder_script" "x" {}' >"${BATS_TEST_TMPDIR}/real/main.tf"
  printf '%s\n' 'startup-body' >"${BATS_TEST_TMPDIR}/real/startup.sh.tftpl"
  write_common_payloads "${BATS_TEST_TMPDIR}/real"
  printf '%s\n' 'notes_materialize() { :; }' >"${BATS_TEST_TMPDIR}/real/notes-setup.sh"
  ln -s "${BATS_TEST_TMPDIR}/real/main.tf" "${BATS_TEST_TMPDIR}/runfiles/tpl/main.tf"
  ln -s "${BATS_TEST_TMPDIR}/real/startup.sh.tftpl" "${BATS_TEST_TMPDIR}/runfiles/tpl/startup.sh.tftpl"
  local payload
  for payload in "${payloads[@]}"; do
    ln -s "${BATS_TEST_TMPDIR}/real/${payload}" "${BATS_TEST_TMPDIR}/runfiles/common/${payload}"
  done
  printf '%s\n' '#!/usr/bin/env bash' 'cat > "${STUB_LOG}/push.tar"' >"${BATS_TEST_TMPDIR}/bin/tar-sink"
  chmod 755 "${BATS_TEST_TMPDIR}/bin/tar-sink"
  export DOCKER_BIN=tar-sink
  export CODER_CONTAINER=stack-coder-1
  template_push_one tpl-runfiles "${BATS_TEST_TMPDIR}/runfiles/tpl"
  if [ ! -f "${STUB_LOG}/push.tar" ]; then
    printf 'FAIL: no tar stream reached the sink\n' >&2
    return 1
  fi
  tar -tvf "${STUB_LOG}/push.tar" >"${BATS_TEST_TMPDIR}/listing.txt"
  # One alternation over every staged name, built from the same array the guard
  # test counts, so a payload added there cannot pass this check unnamed.
  local symlink_re='main\.tf|startup\.sh\.tftpl'
  for payload in "${payloads[@]}"; do
    symlink_re+='|'"${payload//./\\.}"
  done
  if grep -E "${symlink_re}" "${BATS_TEST_TMPDIR}/listing.txt" | grep -q ' -> '; then
    printf 'FAIL: archive stored a symlink instead of file contents:\n%s\n' "$(cat "${BATS_TEST_TMPDIR}/listing.txt")" >&2
    return 1
  fi
  mkdir -p "${BATS_TEST_TMPDIR}/extracted"
  tar -xf "${STUB_LOG}/push.tar" -C "${BATS_TEST_TMPDIR}/extracted"
  [ -f "${BATS_TEST_TMPDIR}/extracted/main.tf" ]
  [ ! -L "${BATS_TEST_TMPDIR}/extracted/main.tf" ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/main.tf")" = 'resource "coder_script" "x" {}' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/startup.sh.tftpl")" = 'startup-body' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/GROK_BUILD_AGENTS.md")" = '# Role' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/vscode-alt.svg")" = '<svg/>' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/notes-setup.sh")" = 'notes_materialize() { :; }' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/tmux.conf")" = 'set -g mouse on' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/ez-skillify.SKILL.md")" = '# skill' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/ez-create-skill.SKILL.md")" = '# skill' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/stack-skills.sh.tftpl")" = '#!/bin/bash' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/agents-seed.sh.tftpl")" = '#!/bin/bash' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/stack-fleet.sh.tftpl")" = '#!/bin/bash' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/explorer.AGENT.md")" = '# agent' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/thorough-researcher.PERSONA.toml")" = '# persona' ]
  [ "$(cat "${BATS_TEST_TMPDIR}/extracted/bug-hunt.SKILL.md")" = '# skill' ]
}

@test "template-push: a tree without the seed payload is refused before the CLI runs" {
  source_libs
  # Without the seed the server-side Terraform would die on main.tf's file()
  # reference anyway; the point of the guard is that it fails locally, loudly,
  # and before the CLI runs, so the operator sees the missing file by name.
  mkdir -p "${BATS_TEST_TMPDIR}/tpl-noseed"
  printf '%s\n' 'resource "coder_script" "y" {}' > "${BATS_TEST_TMPDIR}/tpl-noseed/main.tf"
  export CODER_CONTAINER=stack-coder-1
  run --separate-stderr template_push_one tpl2 "${BATS_TEST_TMPDIR}/tpl-noseed"
  [ "${status}" -eq 1 ]
  local payload
  for payload in "${payloads[@]}"; do
    [[ ${stderr} == *"common/${payload} is missing"* ]]
  done
  [ "$(grep -c ' is missing' <<<"${stderr}")" -eq "${#payloads[@]}" ]
  [ -z "$(stub_log docker)" ]
  [ -z "$(stub_log coder)" ]
}

@test "template-push: a common dir missing one payload names only that payload" {
  source_libs
  # The guard lists the payloads, not the directory. For each payload in turn the
  # ones that are present must stay unnamed and the one that is gone must be
  # named - and every run must still refuse before the CLI runs.
  local gone keep
  for gone in "${payloads[@]}"; do
    rm -rf "${BATS_TEST_TMPDIR}/tpl-one" "${BATS_TEST_TMPDIR}/common"
    mkdir -p "${BATS_TEST_TMPDIR}/tpl-one" "${BATS_TEST_TMPDIR}/common"
    printf '%s\n' 'resource "coder_script" "z" {}' >"${BATS_TEST_TMPDIR}/tpl-one/main.tf"
    for keep in "${payloads[@]}"; do
      if [ "${keep}" != "${gone}" ]; then
        printf '%s\n' "payload ${keep}" >"${BATS_TEST_TMPDIR}/common/${keep}"
      fi
    done
    export CODER_CONTAINER=stack-coder-1
    run --separate-stderr template_push_one tpl-fold "${BATS_TEST_TMPDIR}/tpl-one"
    if [ "${status}" -ne 1 ]; then
      printf 'FAIL: a common dir without %s was pushed anyway\n' "${gone}" >&2
      return 1
    fi
    if [[ ${stderr} != *"common/${gone} is missing"* ]]; then
      printf 'FAIL: %s went unnamed; stderr:\n%s\n' "${gone}" "${stderr}" >&2
      return 1
    fi
    # Exactly one name in the output, so the payloads that are present stayed
    # unnamed without walking the list a second time.
    [ "$(grep -c ' is missing' <<<"${stderr}")" -eq 1 ]
    [ -z "$(stub_log docker)" ]
    [ -z "$(stub_log coder)" ]
  done
}

@test "template-push: the three payload lists name the same files" {
  # Three hand-written lists describe one set: template_push_one's refusal loop, this
  # suite's COMMON_PAYLOADS, which drives the probes above, and write_common_payloads,
  # which builds the throwaway common dir they read. Add a payload to the script and
  # forget the suite and every test here still passes while a real
  # `bazelisk run //scripts:push-template` refuses - which is exactly what happened
  # when the terminal launchers moved into their own coder_script body.
  local script_list stub_list
  script_list="$(sed -n '/^  for payload in/,/; do$/p' "${REPO_ROOT}/scripts/lib/template-push.sh" |
    sed -e 's/^  for payload in//' -e 's/; do$//' -e 's/\\$//' \
      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u)"
  stub_list="$(sed -n '/^write_common_payloads()/,/^}/p' "${BASH_SOURCE[0]}" |
    grep -oE '\$\{dest\}/[^"]+' | sed 's|.*/||' | sort -u)"

  [ -n "${script_list}" ] || {
    echo "the payload list in scripts/lib/template-push.sh reads as empty;" >&2
    echo "the extraction is what this test depends on, so fix it before trusting anything below" >&2
    return 1
  }
  [ "${script_list}" = "$(printf '%s\n' "${payloads[@]}" | sort -u)" ] || {
    echo "scripts/lib/template-push.sh and this suite's COMMON_PAYLOADS disagree (< suite, > script):" >&2
    diff <(printf '%s\n' "${payloads[@]}" | sort -u) <(printf '%s\n' "${script_list}") >&2
    return 1
  }
  [ "${stub_list}" = "${script_list}" ] || {
    echo "write_common_payloads and scripts/lib/template-push.sh disagree (< stub, > script):" >&2
    diff <(printf '%s\n' "${script_list}") <(printf '%s\n' "${stub_list}") >&2
    return 1
  }
}

@test "template-push: template_verify_active reads the ACTIVE row and fails without one" {
  source_libs
  export CODER_CONTAINER=stack-coder-1
  printf 'ID ACTIVE\ndeadbeef-1234-4abc-9999-aabbccddeeff Active\n' > "${BATS_TEST_TMPDIR}/out1.txt"
  export STUB_CODER_OUT="${BATS_TEST_TMPDIR}/out1.txt"
  id="$(template_verify_active tpl1)"
  [ "${id}" = "deadbeef-1234-4abc-9999-aabbccddeeff" ]

  printf 'ID ACTIVE\nnone-active-here\n' > "${BATS_TEST_TMPDIR}/out2.txt"
  export STUB_CODER_OUT="${BATS_TEST_TMPDIR}/out2.txt"
  rc=0
  template_verify_active tpl1 > "${BATS_TEST_TMPDIR}/got.txt" 2> "${BATS_TEST_TMPDIR}/got.err" || rc=$?
  [ "${rc}" -ne 0 ]
  grep -q "no active version" "${BATS_TEST_TMPDIR}/got.err"
}

@test "template-push: template_set_description skips empty text and pushes real text" {
  source_libs
  export CODER_CONTAINER=stack-coder-1
  template_set_description tpl1 ""
  [ "$(stub_log_count coder)" -eq 0 ]
  template_set_description tpl1 "General dev workspace"
  [ "$(stub_log_last coder)" = "coder templates edit tpl1 --description General dev workspace" ]
}

@test "template-push: template_set_autostop_off pins the default TTL and the activity bump" {
  source_libs
  export CODER_CONTAINER=stack-coder-1
  # Both halves of the pair travel on one `templates edit`: the default TTL is what
  # decides whether a new workspace starts with an autostop deadline, and the activity
  # bump only ever extends one.
  template_set_autostop_off tpl1
  [ "$(stub_log_last coder)" = "coder templates edit tpl1 --default-ttl 0 --activity-bump 0" ]
}
