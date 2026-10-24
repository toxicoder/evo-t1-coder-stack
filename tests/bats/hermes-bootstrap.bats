#!/usr/bin/env bats
#
# ## hermes-bootstrap.bats — hermetic coverage for scripts/hermes-bootstrap.sh.
#
# The seeding contract pinned here, in the order the script has to honour it:
# a file that is absent gets copied and is reported "seeded"; a file that is
# already there is left byte-for-byte alone and is reported "left (already
# present)"; --force is the only way an existing file is overwritten, and then
# it says "re-seeded"; exactly two names (config.yaml, SOUL.md) are copied, so
# the skills tree that compose bind-mounts at /opt/stack-skills is never
# duplicated into the volume; the seed side is trusted and the data side is
# created; and every bad invocation — no --data on the host, an unknown flag,
# a flag with no value, a seed file that is not there — answers exit 1 without
# writing a partial volume.
#
# Hermetic by construction. Nothing here opens a socket, talks to a daemon, or
# reads the stack's own hermes/ tree: every run is handed a seed directory and
# a data directory under BATS_TEST_TMPDIR, and the "checkout" a host run
# resolves is a fake root this suite builds and points REPO_ROOT at. No docker,
# curl or compose stub is installed because the script shells out to none of
# them — a suite that shadowed tools this script never calls would be testing
# a PATH no operator has ever run on.
#
# The whole suite skips while scripts/hermes-bootstrap.sh is absent: a suite
# for a script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_hermes_bootstrap_test   (from any cwd)
# Safety: scratch directories only. No Docker, no daemon, no network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
SCRATCH=""

# setup - resolve the checkout, refuse the suite while the script or its lib is
# absent, and lay out this test's scratch tree (BATS removes BATS_TEST_TMPDIR
# after each test, so nothing here outlives the test).
# Globals:
#   REPO_ROOT, SCRIPT, LIB, SCRATCH
# Arguments:
#   None
# Outputs:
#   One scratch directory under BATS_TEST_TMPDIR
# Returns:
#   0, or a skip when the script, its lib or the repo root is not available
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/hermes-bootstrap.sh"
  LIB="${REPO_ROOT}/scripts/lib/common.sh"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${LIB}" ]; then
    skip "scripts/hermes-bootstrap.sh or its lib is not in the tree"
  fi
  SCRATCH="$(make_scratch)"
}

# make_seed <dir> — build a seed tree with the two files this script copies
# plus a skills tree it must never copy, so "only the two names" is an
# assertion against a tree that really does hold more than two names.
make_seed() {
  local dir="${1}"
  mkdir -p "${dir}/skills/demo"
  printf 'model:\n  lane: agent\n' >"${dir}/config.yaml"
  printf 'You are the host assistant.\n' >"${dir}/SOUL.md"
  printf '# a bound skill\n' >"${dir}/skills/demo/SKILL.md"
  printf '%s' "${dir}"
}

# make_fake_root <dir> — build a directory that passes the repo-root marker
# probe and carries a hermes/ seed tree, so a host run resolves a checkout
# this suite owns instead of the stack's real one.
make_fake_root() {
  local dir="${1}"
  mkdir -p "${dir}"
  : >"${dir}/docker-compose.yml"
  make_seed "${dir}/hermes" >/dev/null
  printf '%s' "${dir}"
}

@test "hermes-bootstrap: --help answers the usage block and writes nothing" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "usage names its own target" 'bazelisk run //scripts:hermes-bootstrap --' "${output}"
  assert_match "usage documents --in-container" '--in-container' "${output}"
  assert_match "usage documents --force" '--force' "${output}"
  assert_match "usage documents --seed" '--seed DIR' "${output}"
  assert_match "usage documents --data" '--data DIR' "${output}"
  assert_match "usage states the exit codes" 'Exit codes: 0' "${output}"
  assert_file_not_exists "no data directory appeared" "${SCRATCH}/data"
}

@test "hermes-bootstrap: usage prints every flag the CLI contract names" {
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" usage

  run usage
  [ "${status}" -eq 0 ]
  for flag in --in-container --force --seed --data --help; do
    assert_match "usage lists ${flag}" "${flag}" "${output}"
  done
  # The three per-file answers are the contract an operator reads back.
  assert_match "seeded answer named" 'seeded <name>' "${output}"
  assert_match "left answer named" 'left <name> \(already present\)' "${output}"
  assert_match "re-seeded answer named" 're-seeded <name>' "${output}"
}

@test "hermes-bootstrap: a host run with no --data dies before writing anything" {
  # A host cannot know which volume backs the service, so guessing a
  # destination is worse than stopping: this is the one flag the host mode
  # demands, and it has to be demanded before a single file is copied.
  local seed
  seed="$(make_seed "${SCRATCH}/seed")"

  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --seed "${seed}"
  [ "${status}" -eq 1 ]
  assert_match "the missing flag is named" '--data is required on the host' "${stderr}"
  assert_file_not_exists "nothing was seeded anywhere" "${SCRATCH}/data"
}

@test "hermes-bootstrap: seed_one_file copies when missing, leaves when present, overwrites with force" {
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" seed_one_file

  local seed="${SCRATCH}/seed" data="${SCRATCH}/data"
  mkdir -p "${seed}"
  printf 'config v1\n' >"${seed}/config.yaml"

  run seed_one_file "${seed}" "${data}" config.yaml 0
  [ "${status}" -eq 0 ]
  assert_eq "an absent file is seeded" "seeded config.yaml" "${output}"
  assert_eq "the copy is byte-identical" "config v1" "$(cat "${data}/config.yaml")"

  # The operator edits the volume, the seed tree moves on, and the second run
  # must change nothing: this is the rule that keeps a re-create from silently
  # discarding a hand edit.
  printf 'operator edit\n' >"${data}/config.yaml"
  printf 'config v2\n' >"${seed}/config.yaml"

  run seed_one_file "${seed}" "${data}" config.yaml 0
  [ "${status}" -eq 0 ]
  assert_eq "a present file is left alone" "left config.yaml (already present)" "${output}"
  assert_eq "the edit survived" "operator edit" "$(cat "${data}/config.yaml")"

  run seed_one_file "${seed}" "${data}" config.yaml 1
  [ "${status}" -eq 0 ]
  assert_eq "--force overwrites and says so" "re-seeded config.yaml" "${output}"
  assert_eq "the seed won" "config v2" "$(cat "${data}/config.yaml")"
}

@test "hermes-bootstrap: seed_one_file dies when the seed file is missing" {
  # The seed tree is repo payload, not user data: a name missing there is a
  # broken checkout and must be an error, not a silent skip that leaves
  # Hermes booting on its shipped defaults.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" seed_one_file

  local seed="${SCRATCH}/empty-seed" data="${SCRATCH}/data"
  mkdir -p "${seed}"

  run --separate-stderr seed_one_file "${seed}" "${data}" SOUL.md 0
  [ "${status}" -eq 1 ]
  assert_match "the missing seed file is named" 'SOUL.md is missing' "${stderr}"
}

@test "hermes-bootstrap: hermes_seed_files names exactly the two files Hermes reads" {
  # The list is the whole scope of the copy, so it is pinned here rather than
  # inferred from a run: config.yaml and SOUL.md, in that order, nothing else.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" hermes_seed_files

  assert_eq "two names, one per line" "config.yaml
SOUL.md" "$(hermes_seed_files)"
  assert_not_match "no skills entry" 'skill' "$(hermes_seed_files)"
}

@test "hermes-bootstrap: seed_hermes_data copies exactly the two names and never the skills tree" {
  # Skills are bind-mounted at /opt/stack-skills by compose, so a copy here
  # would be a second source of truth that drifts from the checkout the
  # moment anyone edits one side. The seed tree here really does carry a
  # skills/ subtree, so this fails if the copy ever widens past two names.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" hermes_seed_files
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" seed_one_file
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" seed_hermes_data

  local seed data
  seed="$(make_seed "${SCRATCH}/seed")"
  data="${SCRATCH}/data"

  run seed_hermes_data "${seed}" "${data}" 0
  [ "${status}" -eq 0 ]
  assert_match "config seeded" '^seeded config.yaml$' "${output}"
  assert_match "SOUL seeded" '^seeded SOUL.md$' "${output}"
  assert_file_exists "config in place" "${data}/config.yaml"
  assert_file_exists "SOUL in place" "${data}/SOUL.md"
  assert_contains_file "config content" "${data}/config.yaml" 'lane: agent'
  assert_contains_file "SOUL content" "${data}/SOUL.md" 'host assistant'
  assert_file_not_exists "no skills tree copied" "${data}/skills"
  assert_eq "exactly two files, nothing else" "2" \
    "$(find "${data}" -type f | wc -l | tr -d '[:space:]')"

  # A second run with the same arguments changes nothing and says so twice.
  run seed_hermes_data "${seed}" "${data}" 0
  [ "${status}" -eq 0 ]
  assert_match "config left" '^left config.yaml \(already present\)$' "${output}"
  assert_match "SOUL left" '^left SOUL.md \(already present\)$' "${output}"
}

@test "hermes-bootstrap: seed_hermes_data dies when the seed directory is not a directory" {
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" seed_hermes_data

  run --separate-stderr seed_hermes_data "${SCRATCH}/nowhere" "${SCRATCH}/data" 0
  [ "${status}" -eq 1 ]
  assert_match "the bad seed path is named" 'nowhere is not a directory' "${stderr}"
}

@test "hermes-bootstrap: driving the script seeds once, is idempotent, and re-seeds on --force" {
  # The entry point as compose's hermes-init and an operator both meet it:
  # argv in, one line per file out, and the volume right afterwards.
  local seed data
  seed="$(make_seed "${SCRATCH}/seed")"
  data="${SCRATCH}/data"

  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --seed "${seed}" --data "${data}"
  [ "${status}" -eq 0 ]
  assert_match "first run seeds both" 'seeded config.yaml' "${output}"
  assert_match "first run seeds both files" 'seeded SOUL.md' "${output}"
  assert_contains_file "config written" "${data}/config.yaml" 'lane: agent'

  printf 'operator edit\n' >"${data}/config.yaml"

  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --seed "${seed}" --data "${data}"
  [ "${status}" -eq 0 ]
  assert_match "second run leaves config" 'left config.yaml \(already present\)' "${output}"
  assert_match "second run leaves SOUL" 'left SOUL.md \(already present\)' "${output}"
  assert_eq "the edit survived a re-create" "operator edit" "$(cat "${data}/config.yaml")"

  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --seed "${seed}" --data "${data}" --force
  [ "${status}" -eq 0 ]
  assert_match "--force re-seeds config" 're-seeded config.yaml' "${output}"
  assert_match "--force re-seeds SOUL" 're-seeded SOUL.md' "${output}"
  assert_contains_file "the seed won again" "${data}/config.yaml" 'lane: agent'

  # The entry line is the dispatch, not a body of top-level code: that is what
  # lets this suite eval the functions above without running a seed.
  assert_contains_file "the file dispatches through main" "${SCRIPT}" '^main "\$@"$'
}

@test "hermes-bootstrap: host mode seeds <root>/hermes when --seed is not given" {
  # The host default is the checkout's seed tree, which is why the host mode
  # resolves a root at all. The root is a fake this suite builds, so the
  # stack's real hermes/ payload is never involved.
  local root data
  root="$(make_fake_root "${SCRATCH}/fake-root")"
  data="${SCRATCH}/data"

  run --separate-stderr env REPO_ROOT="${root}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --data "${data}"
  [ "${status}" -eq 0 ]
  assert_match "seeded from the checkout" 'seeded config.yaml' "${output}"
  assert_contains_file "the fake seed was the source" "${data}/SOUL.md" 'host assistant'
  assert_file_not_exists "no skills copied from the checkout" "${data}/skills"
}

@test "hermes-bootstrap: --in-container needs no checkout and dies when /seed is absent" {
  # The init container carries the scripts mount and nothing else, so the
  # repo-root probe must not run here: a run from a directory with no
  # docker-compose.yml has to fail on the missing seed, never on the missing
  # checkout. The two errors are distinguishable, and this asserts which one
  # fires.
  local nowhere="${SCRATCH}/nowhere"
  mkdir -p "${nowhere}"
  cd "${nowhere}"

  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    bash "${SCRIPT}" --in-container
  [ "${status}" -eq 1 ]
  assert_not_match "no repo-root probe ran" 'unresolvable repo root' "${stderr}"
  assert_match "the in-container seed default is named" '/seed is not a directory' "${stderr}"
}

@test "hermes-bootstrap: --in-container still honours --seed and --data over its defaults" {
  # The in-container defaults are a convenience for compose, not an
  # assumption: a test host has no /seed and must not have /opt written to,
  # and both paths still have to be overridable while --in-container is set.
  local seed data
  seed="${SCRATCH}/empty-seed"
  data="${SCRATCH}/data"
  mkdir -p "${seed}"

  run --separate-stderr env -u REPO_ROOT -u GITHUB_WORKSPACE \
    bash "${SCRIPT}" --in-container --seed "${seed}" --data "${data}"
  [ "${status}" -eq 1 ]
  assert_match "--seed overrode /seed" "${seed}/config.yaml is missing" "${stderr}"
  # The directory the run created is the one argv named, not /opt/data: that
  # is the proof the second default was overridden as well.
  [ -d "${data}" ]
  assert_not_match "no answer mentions /opt/data" '/opt/data' "${stderr}"

  # The default it overrode is still the compose volume mountpoint.
  assert_match "in-container defaults data to the volume" '/opt/data' "$(cat "${SCRIPT}")"
}

@test "hermes-bootstrap: an unknown flag dies with the usage block and writes nothing" {
  local seed
  seed="$(make_seed "${SCRATCH}/seed")"

  # The good flags sit before the typo on purpose: argv is parsed to the end
  # before anything is copied, so a typo cannot be paid for with a seeded
  # directory.
  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --seed "${seed}" --data "${SCRATCH}/data" --bogus
  [ "${status}" -eq 1 ]
  assert_match "the typo is named" "unknown argument '--bogus'" "${stderr}"
  assert_match "the usage block comes with it" 'usage: bazelisk run //scripts:hermes-bootstrap' "${output}"
  assert_file_not_exists "nothing was written" "${SCRATCH}/data"
}

@test "hermes-bootstrap: a flag with no value dies instead of eating argv" {
  # Each of the two path flags has to fail on its own, before any seeding,
  # so a truncated command line is never read as "seed the default".
  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --seed
  [ "${status}" -eq 1 ]
  assert_match "--seed demands a value" '--seed needs a directory' "${stderr}"

  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --data
  [ "${status}" -eq 1 ]
  assert_match "--data demands a value" '--data needs a directory' "${stderr}"
}

@test "hermes-bootstrap: a missing source file dies and names it" {
  # Half a seed tree is a broken checkout, and the run stops at the name that
  # is not there. The file that was already seeded stays seeded: re-running
  # after fixing the tree finishes the job, which is what makes the failure
  # recoverable instead of half-written.
  local seed data
  seed="${SCRATCH}/partial-seed"
  mkdir -p "${seed}"
  printf 'lane: agent\n' >"${seed}/config.yaml"
  data="${SCRATCH}/data"

  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" GITHUB_WORKSPACE="" \
    bash "${SCRIPT}" --seed "${seed}" --data "${data}"
  [ "${status}" -eq 1 ]
  assert_match "the missing name is reported" 'SOUL.md is missing' "${stderr}"
  assert_match "the file that was there got seeded" 'seeded config.yaml' "${output}"
  assert_contains_file "the seeded file is real" "${data}/config.yaml" 'lane: agent'
  assert_file_not_exists "the missing one was not invented" "${data}/SOUL.md"
}

@test "hermes-bootstrap: resolve_repo_root probes for the marker and reports an unresolvable root" {
  # A Bazel sandbox holds a COPY of the tree, so the root is found by a marker
  # file and never by a cwd assumption.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" resolve_repo_root

  local nowhere="${SCRATCH}/nowhere"
  mkdir -p "${nowhere}"
  # Shadowed, not exported: these are what the helper probes, and a leftover
  # value from the harness would answer the question for it.
  local REPO_ROOT=""
  local GITHUB_WORKSPACE=""
  local SELF_DIR="${nowhere}"
  cd "${nowhere}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 5 ]
  assert_match "an unresolvable root is reported" 'unresolvable repo root' "${stderr}"

  # The env candidates win over the path candidates, in the documented order.
  local marked="${SCRATCH}/marked"
  mkdir -p "${marked}"
  : >"${marked}/docker-compose.yml"
  REPO_ROOT="${marked}"
  assert_eq "REPO_ROOT answers the probe" "${marked}" "$(resolve_repo_root)"

  GITHUB_WORKSPACE="${SCRATCH}/ws-root"
  mkdir -p "${GITHUB_WORKSPACE}"
  : >"${GITHUB_WORKSPACE}/docker-compose.yml"
  assert_eq "REPO_ROOT outranks GITHUB_WORKSPACE" "${marked}" "$(resolve_repo_root)"

  REPO_ROOT=""
  assert_eq "GITHUB_WORKSPACE is the second probe" "${SCRATCH}/ws-root" "$(resolve_repo_root)"
}

@test "hermes-bootstrap: find_common_lib finds the lib beside the script or under the root" {
  # Under `bazelisk run` both the runfiles copy and the checkout are reachable;
  # under --in-container only the copy beside the script is, which is why the
  # SELF_DIR probe exists and why the root probe may be empty.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" find_common_lib

  local copy="${SCRATCH}/copy"
  mkdir -p "${copy}/scripts/lib"
  cp "${LIB}" "${copy}/scripts/lib/common.sh"
  SELF_DIR="${copy}/scripts"
  assert_eq "found beside the script, wherever it sits" \
    "${copy}/scripts/lib/common.sh" "$(find_common_lib common.sh "")"

  local root="${SCRATCH}/root-with-lib"
  mkdir -p "${root}/scripts/lib"
  printf '# a different common.sh\n' >"${root}/scripts/lib/common.sh"
  assert_eq "the resolved root is tried first" \
    "${root}/scripts/lib/common.sh" "$(find_common_lib common.sh "${root}")"

  # Neither candidate holds it: no root, and no lib beside the script.
  SELF_DIR="${SCRATCH}/no-lib-here"
  mkdir -p "${SELF_DIR}"
  run --separate-stderr find_common_lib common.sh "${SCRATCH}/no-such-root"
  [ "${status}" -eq 1 ]
  assert_match "a lib with no home is reported, not guessed" 'common.sh is not reachable' "${stderr}"
}
