#!/usr/bin/env bats
#
# ## new-repo.bats - hermetic coverage for scripts/new-repo.sh
#
# The contract pinned here: the scaffold is fetched, never vendored (a clone that
# fails is an exit 1 naming the URL and the ref, and it leaves no scratch directory
# behind), the render is the only other part that may fail hard (a placeholder that
# survives, an existing destination, a bad name, a lane the scaffold does not ship is
# an exit 1), every GitHub step is advisory (refused means warning plus a permission
# hint, never a failed run), the credential ladder retries once with the environment
# pair cleared and says so, and the Coder Task is a convenience that never fails the
# run. Nothing here touches the network: gh, git and coder are recording PATH stubs
# that answer from environment knobs, so an absent call is as loud an assertion as a
# present one, and every render is driven from the canned scaffold under
# tests/bats/fixtures/ezrepo-template through --template-dir or from a seeded clone
# the git stub builds out of that same tree.
#
# The render is driven end to end rather than unit by unit: render_tree is what every
# green test above exercises, together with the helpers it calls in order -
# fetch_template, discover_lanes, validate_lane, overlay_lanes,
# append_ignore_fragments, rename_env_template, substitute_tokens and
# assert_no_tokens. Each of those is also pinned on its own where its contract is
# specific enough to break separately. Two of those contracts are pinned as a pair,
# because they have to agree: substitute_tokens renames a path holding any declared
# token (a suffix-anchored pattern left `__PROJECT_OWNER__.md` in place and the render
# then died on its own output), and assert_no_tokens fails a leak the passes cannot
# fill, which is what a value carrying an already-consumed token produces.
#
# Usage: bazelisk test //tests:bats_new_repo_test   (from any cwd)
# Safety: reads scripts/new-repo.sh, scripts/lib/common.sh and the canned scaffold
# fixture; writes only under the per-test scratch tree. No test opens a socket: the
# only fetches are git-stub clones built from that fixture, and the credential slots
# are empty from the first line of setup.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
TEMPLATE=""
STUB_BIN=""
SAVED_PATH=""

# The scaffold the CLI would clone without --template-dir, spelled once so the
# default-URL assertions name one source of truth.
DEFAULT_TEMPLATE_URL="https://github.com/toxicoder/ezrepo.git"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no marker)"
  SCRIPT="${REPO_ROOT}/scripts/new-repo.sh"
  TEMPLATE="${REPO_ROOT}/tests/bats/fixtures/ezrepo-template"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${TEMPLATE}/template.yml" ]; then
    skip "new-repo or its canned scaffold fixture is not in the tree"
  fi

  SAVED_PATH="${PATH}"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"
  STUB_LOG="${BATS_TEST_TMPDIR}/stub-logs"
  mkdir -p "${STUB_LOG}"
  export STUB_LOG
  # The CLI puts the scratch scaffold clone under TMPDIR, so the "a failed fetch
  # cleans up after itself" assertion has a directory it can count.
  TMPDIR="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${TMPDIR}"
  export TMPDIR
  PATH="${STUB_BIN}:${PATH}"
  export PATH

  # No test may reach a real credential, a real Coder server, a real scaffold
  # repository, or a checkout other than the one the runner names. The EZREPO_*
  # slots matter as much as the token pair: they outrank the built-in scaffold
  # default this suite asserts on.
  unset GH_TOKEN GITHUB_TOKEN GH_HOST BUILD_WORKSPACE_DIRECTORY GITHUB_WORKSPACE
  unset EZREPO_URL EZREPO_REF EZREPO_DIR
  export HOME="${BATS_TEST_TMPDIR}"

  # Shadowed from the first line of the first test, not per test: a render that
  # reached a real git or gh is a broken suite, not a slower one.
  write_gh_stub
  stub_bin git coder >/dev/null

  # A function loaded on its own does not carry the script's readonly globals, so
  # the direct-call tests need the lane directory the CLI would have read.
  NEW_REPO_LANE_DIR="$(declared_lane_dir)"
}

teardown() {
  PATH="${SAVED_PATH}"
  export PATH
}

# write_gh_stub - a recording gh whose behaviour a test steers with env knobs:
# STUB_GH_OWNER answers `api user`, STUB_GH_RC is the exit status, and
# STUB_GH_FAIL_ONCE fails exactly the first call (the marker file is the memory) and
# answers it the way gh really does, with the error body on stdout. Every call appends
# its argv to gh.log and its credential state to gh-env.log, so "was gh called, and with
# which pair" is answerable after the fact.
write_gh_stub() {
  cat >"${STUB_BIN}/gh" <<'NEW_REPO_GH_STUB'
#!/usr/bin/env bash
set -u
printf 'gh %s\n' "$*" >>"${STUB_LOG:?}/gh.log"
printf 'GH_TOKEN=%s|GITHUB_TOKEN=%s\n' "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" >>"${STUB_LOG}/gh-env.log"
if [ -n "${STUB_GH_FAIL_ONCE:-}" ] && [ ! -e "${STUB_GH_FAIL_ONCE}" ]; then
  : >"${STUB_GH_FAIL_ONCE}"
  # Real gh answers a refused call with the API's error body ON STDOUT, so a caller
  # that kept a refused attempt's stdout would use that body as its value.
  printf '%s\n' '{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}'
  printf '%s\n' "gh: Bad credentials" >&2
  exit 1
fi
case "$*" in
  api\ user*)
    if [ -n "${STUB_GH_OWNER:-}" ]; then printf '%s\n' "${STUB_GH_OWNER}"; fi
    ;;
esac
exit "${STUB_GH_RC:-0}"
NEW_REPO_GH_STUB
  chmod 755 "${STUB_BIN}/gh"
}

# run_cli <args...> - run the operator CLI the way a human does, with the credential
# and scaffold-source slots empty and the stub PATH in front.
run_cli() {
  run env -u GH_TOKEN -u GITHUB_TOKEN -u BUILD_WORKSPACE_DIRECTORY \
    -u EZREPO_URL -u EZREPO_REF -u EZREPO_DIR \
    REPO_ROOT="${REPO_ROOT}" HOME="${BATS_TEST_TMPDIR}" \
    bash "${SCRIPT}" "$@"
}

# call_fn <file> <fn> [args...] - call a loaded function in THIS shell (so the
# SUMMARY_ counters it writes are the ones the test reads) with stdout and stderr
# captured into <file>.
call_fn() {
  local file="$1"
  shift
  "$@" >"${file}" 2>&1
}

# declared_tokens - the render token names the CLI declares, read out of the CLI so
# this suite can never drift from it.
declared_tokens() {
  sed -n '/^readonly NEW_REPO_TOKENS=(/,/^)/p' "${SCRIPT}" | grep -oE '__PROJECT_[A-Z_]+__'
}

# declared_lane_dir - the lane directory name the renderer reads, parsed out of the
# CLI so a direct call to overlay_lanes asks the same question the CLI asks.
declared_lane_dir() {
  sed -n '/^readonly NEW_REPO_LANE_DIR=/p' "${SCRIPT}" | sed -E 's/^[^=]*="//; s/".*$//'
}

# declared_lane_meta - the reserved lane file names the renderer strips.
declared_lane_meta() {
  sed -n '/^readonly NEW_REPO_LANE_META=/p' "${SCRIPT}" |
    grep -oE '[A-Za-z0-9._-]+\.(md|fragment)'
}

# declared_template_meta - the generator-owned paths stripped from every render.
declared_template_meta() {
  sed -n '/^readonly NEW_REPO_TEMPLATE_META=/p' "${SCRIPT}" |
    sed -E 's/^[^(]*\(//; s/\).*//' | tr ' \t' '\n\n' | grep -E '^\.'
}

# discovered_lanes - the lane ids the canned scaffold offers, derived from its tree
# the same way the CLI derives them, so no lane list is duplicated here.
discovered_lanes() {
  local dir="${TEMPLATE}/.template-lanes" entry
  [ -d "${dir}" ] || return 0
  for entry in "${dir}"/*/; do
    [ -d "${entry}" ] || continue
    basename "${entry%/}"
  done
  return 0
}

# dotted_twin <dest> - print the rendered env twin by its dotted name, matched with a
# bracket so this file never carries the dotted spelling itself.
dotted_twin() {
  find "$1" -maxdepth 1 -name '.env.[e]xample' -print | head -n 1
}

# render_dry <parent> [args...] - a dry-run render of the canned scaffold into
# <parent> and nothing else. Every render in this suite names its scaffold source
# explicitly: a render that fetched would be a suite that needed the network.
render_dry() {
  local parent="$1"
  shift
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --holder "Test Holder" --year 2026 --lane shell "$@"
}

# load_common - the house vocabulary the CLI reports through; common.sh is documented
# as side-effect free to source, and it defines its own skip, so call this only after
# every guard that still wants the bats builtin.
load_common() {
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
}

# ---------------------------------------------------------------------------
# Arguments and usage
# ---------------------------------------------------------------------------

@test "new-repo: --help and -h print the usage block and exit 0" {
  local flag
  for flag in --help -h; do
    run bash "${SCRIPT}" "${flag}"
    [ "${status}" -eq 0 ] || fail "${flag} must exit 0, got ${status}"
    assert_match "usage heading" '^Usage \(Bazel is the entry point' "${output}"
    assert_match "the runnable example" 'bazelisk run //scripts:new-repo -- --dry-run demo-tool' "${output}"
    assert_match "the options heading" '^Options:' "${output}"
    assert_match "the lane option" '^ *--lane <id>' "${output}"
    assert_match "the dry-run option" '^ *--dry-run ' "${output}"
    assert_match "the scaffold url option" '^ *--template-url <url>' "${output}"
    assert_match "the scaffold ref option" '^ *--template-ref <ref>' "${output}"
    assert_match "the local scaffold option" '^ *--template-dir <dir>' "${output}"
    assert_match "the exit code contract" '^Exit codes: 0 when the render succeeded' "${output}"
    assert_not_match "the retired checkout code is unadvertised" 'exit code 5' "${output}"
  done
}

@test "new-repo: an unknown option is refused with error: and a non-zero exit" {
  run bash "${SCRIPT}" --bogus demo-tool
  [ "${status}" -ne 0 ]
  assert_match "names the option" '^error: unknown option: --bogus' "${output}"
  assert_match "points at the help" 'try --help' "${output}"
  assert_not_match "it rendered nothing" 'ok: rendered' "${output}"
}

@test "new-repo: an option that lost its value is refused" {
  local flag
  for flag in --out --description --owner --holder --year --lane --topic --task-template \
    --branch --template-url --template-ref --template-dir; do
    run bash "${SCRIPT}" demo-tool "${flag}"
    [ "${status}" -ne 0 ] || fail "${flag} with no value must fail, got 0"
    assert_match "${flag} says what it needs" "error: ${flag} needs" "${output}"
  done
}

@test "new-repo: a missing or doubled repository name is refused" {
  run bash "${SCRIPT}" --dry-run
  [ "${status}" -ne 0 ]
  assert_match "demands a name" 'a repository name is required' "${output}"

  run bash "${SCRIPT}" --dry-run ""
  [ "${status}" -ne 0 ]
  assert_match "an empty name is no name" 'a repository name is required' "${output}"

  run bash "${SCRIPT}" --dry-run first-name second-name
  [ "${status}" -ne 0 ]
  assert_match "refuses the second name" 'one repository name only' "${output}"
}

@test "new-repo: an invalid repository name is refused before anything is written" {
  local parent bad
  parent="$(make_scratch)"
  for bad in "bad name" "org/repo" "no spaces/tabs	here"; do
    run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" --owner testowner "${bad}"
    [ "${status}" -ne 0 ] || fail "name [${bad}] must be refused, got 0"
    assert_match "names the name" 'invalid repository name' "${output}"
    assert_match "states the alphabet" 'letters, digits, dot, dash, underscore' "${output}"
  done

  # 101 characters is one over the GitHub limit the CLI pins.
  local long="a"
  while [ "${#long}" -lt 101 ]; do long="${long}a"; done
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" --owner testowner "${long}"
  [ "${status}" -ne 0 ]
  assert_match "the over-long name is refused" 'invalid repository name' "${output}"
  assert_eq "nothing was rendered into --out" "0" \
    "$(find "${parent}" -mindepth 1 | wc -l | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# Fetching the scaffold: the CLI owns the network, and only through git
# ---------------------------------------------------------------------------

@test "new-repo: with no local tree it shallow-clones the default scaffold and records it" {
  local parent logged
  parent="$(make_scratch)"
  export STUB_GIT_CLONE=success
  export STUB_GIT_CLONE_SEED="${TEMPLATE}"
  export STUB_GIT_LS_OUT="deadbeef"
  run_cli --no-remote --out "${parent}" --owner testowner --lane shell demo-tool
  [ "${status}" -eq 0 ] || fail "a stubbed fetch must succeed, got ${status}: ${output}"
  [ -d "${parent}/demo-tool" ] || fail "the render must land"

  logged="$(stub_log git)"
  assert_match "it cloned" ' clone ' "${logged}"
  assert_match "from the default repository" "${DEFAULT_TEMPLATE_URL//./\\.}" "${logged}"
  assert_match "shallowly" -- '--depth 1' "${logged}"
  assert_match "one branch only" -- '--single-branch' "${logged}"
  assert_match "at the default ref" -- '--branch main' "${logged}"

  # The revision the render came from is written into the first commit, so a
  # project can always say which scaffold it started from.
  assert_match "the provenance names the url and the sha" \
    'Scaffold: https://github.com/toxicoder/ezrepo\.git@deadbeef' "${logged}"
  assert_match "the fetch is reported" '^ok: fetched scaffold deadbeef$' "${output}"
  assert_eq "the stub cloned exactly once" "1" "$(printf '%s\n' "${logged}" | grep -c ' clone ')"
}

@test "new-repo: --template-url and --template-ref reach the clone argv" {
  local parent logged
  parent="$(make_scratch)"
  export STUB_GIT_CLONE=success
  export STUB_GIT_CLONE_SEED="${TEMPLATE}"
  run_cli --no-remote --out "${parent}" --owner testowner --lane shell \
    --template-url https://mirror.example.invalid/ezrepo.git --template-ref v9 demo-tool
  [ "${status}" -eq 0 ] || fail "a mirrored fetch must succeed, got ${status}: ${output}"
  logged="$(stub_log git)"
  assert_match "the mirror is what got cloned" 'https://mirror\.example\.invalid/ezrepo\.git' "${logged}"
  assert_match "the ref rides the clone" -- '--branch v9' "${logged}"
  assert_not_match "the default repository was not touched" 'github\.com/toxicoder/ezrepo' "${logged}"
  assert_match "the plan shows what was asked for" \
    '^scaffold: https://mirror\.example\.invalid/ezrepo\.git@v9$' "${output}"
}

@test "new-repo: --template-dir renders the local tree and clones nothing" {
  local parent logged
  parent="$(make_scratch)"
  run_cli --no-remote --out "${parent}" --owner testowner --lane shell \
    --template-dir "${TEMPLATE}" demo-tool
  [ "${status}" -eq 0 ] || fail "a local render must succeed, got ${status}: ${output}"

  # The render still needs git for init/add/commit, so the assertion is about the
  # absence of a clone in a log that is not empty.
  logged="$(stub_log git)"
  assert_match "git was still used to commit" ' commit ' "${logged}"
  assert_eq "and no clone line was ever recorded" "0" "$(printf '%s\n' "${logged}" | grep -c ' clone ')"
  assert_match "the local tree is announced" '^-> using the local scaffold ' "${output}"
  assert_match "and the ref is called out as inert" \
    'a local tree is rendered as it stands: --template-ref has no effect' "${output}"
  assert_eq "no scratch clone directory was made" "0" \
    "$(find "${TMPDIR}" -maxdepth 1 -name 'new-repo-scaffold.*' | wc -l | tr -d ' ')"
}

@test "new-repo: a failed fetch fails the run, names the remedy, and cleans up" {
  local parent
  parent="$(make_scratch)"
  # The git stub refuses clone with rc 128 unless a test says otherwise, which is
  # exactly the unreachable-or-renamed repository this branch exists for.
  run_cli --dry-run --out "${parent}" --owner testowner \
    --template-url https://example.invalid/no-scaffold.git --template-ref v9 demo-tool
  [ "${status}" -ne 0 ] || fail "an unfetchable scaffold must fail the run, got 0"
  assert_match "it names the url and the ref" \
    'error: cannot fetch the scaffold from https://example\.invalid/no-scaffold\.git at v9' "${output}"
  assert_match "it says what to check" 'check the network and the ref' "${output}"
  assert_match "and offers the offline route" \
    'render a tree you already hold with --template-dir' "${output}"
  assert_match "the run says it could not obtain the scaffold" \
    'cannot obtain the scaffold' "${output}"
  assert_eq "the scratch clone is gone, not left in TMPDIR" "0" \
    "$(find "${TMPDIR}" -maxdepth 1 -name 'new-repo-scaffold.*' | wc -l | tr -d ' ')"
  assert_eq "and nothing was rendered" "0" "$(find "${parent}" -mindepth 1 | wc -l | tr -d ' ')"
}

@test "new-repo: a tree without a scaffold manifest is refused by name" {
  local parent missing empty
  parent="$(make_scratch)"
  missing="${parent}/not-a-scaffold"
  mkdir -p "${missing}/src"
  run_cli --dry-run --out "${parent}" --owner testowner --template-dir "${missing}" demo-tool
  [ "${status}" -ne 0 ] || fail "a tree with no manifest must fail, got 0"
  assert_match "it names the manifest it looked for" \
    "no scaffold manifest at ${missing}/template\.yml" "${output}"
  assert_match "and says who owns that file" \
    'the scaffold repository owns template\.yml; pick a ref that has it' "${output}"

  empty="${parent}/gone"
  run_cli --dry-run --out "${parent}" --owner testowner --template-dir "${empty}" demo-tool
  [ "${status}" -ne 0 ] || fail "a --template-dir that is not there must fail, got 0"
  assert_match "a missing directory is named as such" \
    "no scaffold at --template-dir: ${empty}" "${output}"
  assert_eq "neither case rendered anything" "0" \
    "$(find "${parent}" -mindepth 1 -name 'demo-tool' | wc -l | tr -d ' ')"
}

@test "new-repo: generator-owned paths from the clone never reach the render" {
  local parent dest meta stripped=0
  parent="$(make_scratch)"
  export STUB_GIT_CLONE=success
  export STUB_GIT_CLONE_SEED="${TEMPLATE}"
  export STUB_GIT_CLONE_EXTRA=".self-check/run.sh:.self-check/self-check.bats"
  run_cli --no-remote --out "${parent}" --owner testowner --lane shell demo-tool
  [ "${status}" -eq 0 ] || fail "the render must succeed, got ${status}: ${output}"
  dest="${parent}/demo-tool"

  for meta in $(declared_template_meta); do
    if [ -e "${dest}/${meta}" ]; then
      printf 'generator-owned path shipped into the render: %s\n' "${meta}" >&2
      stripped=$((stripped + 1))
    fi
  done
  assert_eq "no .self-check, no .template-lanes, no .git in the render" "0" "${stripped}"
  assert_match "the strip is reported with every name" \
    'stripped scaffold-only paths: \.template-lanes \.self-check \.git' "${output}"
  # Stripping is not the same as losing: the project's own files came along.
  assert_file_exists "the core survived the strip" "${dest}/template.yml"
  assert_file_exists "and the lane overlaid after it" "${dest}/src/main.sh"
}

@test "new-repo: fetch_template resolves a local tree and cleanup_template removes a clone" {
  load_common
  load_shell_function "${SCRIPT}" fetch_template
  load_shell_function "${SCRIPT}" cleanup_template
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  local out="${BATS_TEST_TMPDIR}/fetch.out" rc=0

  TEMPLATE_DIR="${TEMPLATE}"
  TEMPLATE_URL="${DEFAULT_TEMPLATE_URL}"
  TEMPLATE_REF="main"
  TEMPLATE_TMP=""
  TEMPLATE_SRC=""
  TEMPLATE_PROVENANCE=""
  rc=0
  call_fn "${out}" fetch_template || rc=$?
  assert_eq "a local tree is accepted" "0" "${rc}"
  assert_eq "and it is the tree named" "${TEMPLATE}" "${TEMPLATE_SRC}"
  assert_eq "the provenance says where it came from" "local tree ${TEMPLATE}" \
    "${TEMPLATE_PROVENANCE}"
  assert_contains_file "the phase names the tree" "${out}" "^-> using the local scaffold "

  # A scratch clone is the trap's business, and the trap runs whether the render
  # succeeded or not.
  TEMPLATE_TMP="${BATS_TEST_TMPDIR}/scratch-clone"
  mkdir -p "${TEMPLATE_TMP}/scaffold"
  cleanup_template
  assert_file_not_exists "the scratch clone is gone" "${TEMPLATE_TMP}"
  TEMPLATE_TMP="${BATS_TEST_TMPDIR}/never-made"
  rc=0
  cleanup_template || rc=$?
  assert_eq "cleaning a clone that was never made is not a failure" "0" "${rc}"

  TEMPLATE_DIR="${BATS_TEST_TMPDIR}/no-such-tree"
  rc=0
  call_fn "${out}" fetch_template || rc=$?
  assert_eq "a directory that is not there fails" "1" "${rc}"
  assert_contains_file "and it names the path" "${out}" 'no scaffold at --template-dir: '
}

# ---------------------------------------------------------------------------
# Lane discovery: the scaffold owns the lane list
# ---------------------------------------------------------------------------

@test "new-repo: discover_lanes lists what the scaffold ships and tolerates one that has none" {
  load_shell_function "${SCRIPT}" discover_lanes
  local -a found=() lane count=0
  while IFS= read -r lane; do found+=("${lane}"); done < <(discover_lanes "${TEMPLATE}")
  assert_eq "the canned scaffold ships two lanes" "2" "${#found[@]}"
  for lane in shell python; do
    printf '%s\n' "${found[@]}" | grep -qxF -- "${lane}" ||
      fail "the scaffold ships ${lane}, so discovery must report it"
  done

  local bare="${BATS_TEST_TMPDIR}/bare-scaffold"
  mkdir -p "${bare}"
  assert_eq "a scaffold with no lane tree lists nothing" "" "$(discover_lanes "${bare}")"

  local empty="${BATS_TEST_TMPDIR}/empty-lanes"
  mkdir -p "${empty}/.template-lanes"
  assert_eq "an empty lane directory lists nothing" "" "$(discover_lanes "${empty}")"
  for lane in $(discovered_lanes); do count=$((count + 1)); done
  assert_eq "the suite's own derivation agrees with the CLI's" "${#found[@]}" "${count}"
}

@test "new-repo: every lane the scaffold ships, and the none sentinel, validate" {
  load_shell_function "${SCRIPT}" discover_lanes
  load_shell_function "${SCRIPT}" validate_lane
  local lanes=() lane
  while IFS= read -r lane; do lanes+=("${lane}"); done < <(discover_lanes "${TEMPLATE}")
  assert_eq "the fixture keeps the suite honest about its lane count" "2" "${#lanes[@]}"
  KNOWN_LANES=("${lanes[@]}")
  for lane in "${lanes[@]}" none; do
    validate_lane "${lane}" || fail "lane ${lane} is offered, so it must validate"
  done
  if validate_lane "rust"; then fail "a lane the scaffold does not ship must not validate"; fi
  if validate_lane ""; then fail "an empty lane must not validate"; fi
}

@test "new-repo: discovery drives acceptance, and an unknown lane names what is offered" {
  local parent dest lane
  parent="$(make_scratch)"
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --year 2026 --lane python demo-tool
  [ "${status}" -eq 0 ] || fail "the python lane must render, got ${status}: ${output}"
  dest="${parent}/demo-tool"
  assert_file_exists "the python package came along" "${dest}/src/demo_tool/__init__.py"
  assert_file_exists "its module came along" "${dest}/src/demo_tool/cli.py"
  assert_file_exists "and its pytest suite came along" "${dest}/tests/python/test_cli.py"
  assert_not_match "the shell lane did not ride along" 'ok: lane shell' "${output}"
  assert_match "the plan lists what the scaffold offers" \
    '^scaffold lanes available: python shell$' "${output}"

  parent="$(make_scratch)"
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane rust demo-tool
  [ "${status}" -ne 0 ] || fail "a lane the scaffold lacks must be refused, got 0"
  assert_match "names the bad lane" 'unknown lane: rust' "${output}"
  assert_match "offers the no-lane spelling" 'or none' "${output}"
  for lane in $(discovered_lanes); do
    assert_match "names the offered lane ${lane}" "offers: [^)]*${lane}" "${output}"
  done
  assert_eq "and the refused lane rendered nothing" "0" \
    "$(find "${parent}" -mindepth 1 | wc -l | tr -d ' ')"
}

@test "new-repo: a lane id that is not a plain slug is refused before it becomes a path" {
  load_shell_function "${SCRIPT}" discover_lanes
  load_shell_function "${SCRIPT}" validate_lane
  local bad parent
  KNOWN_LANES=()
  local lane
  while IFS= read -r lane; do KNOWN_LANES+=("${lane}"); done < <(discover_lanes "${TEMPLATE}")
  for bad in '../etc' 'A B' 'Shell' '9lives' '' \
    "$(printf 'a%.0s' {1..33})"; do
    if validate_lane "${bad}"; then fail "lane id [${bad}] is not a plain slug and must be refused"; fi
  done
  validate_lane "${KNOWN_LANES[0]}" ||
    fail "an offered, well-shaped id must validate on shape before the lookup"

  parent="$(make_scratch)"
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane '../etc' demo-tool
  [ "${status}" -ne 0 ] || fail "--lane ../etc must be refused, got 0"
  assert_match "the refusal names the id" 'unknown lane: \.\./etc' "${output}"
  assert_eq "nothing escaped the output directory" "0" \
    "$(find "${parent}" -mindepth 1 | wc -l | tr -d ' ')"

  parent="$(make_scratch)"
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane 'A B' demo-tool
  [ "${status}" -ne 0 ] || fail "--lane 'A B' must be refused, got 0"
  assert_match "a spaced id is refused too" 'unknown lane: A B' "${output}"
}

# ---------------------------------------------------------------------------
# The render
# ---------------------------------------------------------------------------

@test "new-repo: --dry-run substitutes all seven tokens and calls nothing" {
  local parent dest hits names lic twin
  parent="$(make_scratch)"
  render_dry "${parent}" --description "Renders  the | thing" Demo.Tool
  [ "${status}" -eq 0 ] || fail "a dry run must succeed, got ${status}: ${output}"
  dest="${parent}/Demo.Tool"
  [ -d "${dest}" ] || fail "the render must land at ${dest}"

  hits="$(grep -rlE -- '__PROJECT_[A-Z_]+__' "${dest}" | wc -l | tr -d ' ')"
  assert_eq "no placeholder survives in file contents" "0" "${hits}"
  names="$(find "${dest}" -name '*__PROJECT_*__' | wc -l | tr -d ' ')"
  assert_eq "no placeholder survives in a path" "0" "${names}"

  # Each value has to show where the scaffold asked for it, or a token could be
  # substituted with the wrong one and still leave no placeholder behind.
  lic="$(find "${dest}" -maxdepth 1 -name 'LICE[N]SE' -print | head -n 1)"
  assert_file_exists "the license is rendered" "${lic}"
  assert_contains_file "year and holder landed in the license" "${lic}" \
    'Copyright \(c\) 2026 Test Holder'
  twin="$(dotted_twin "${dest}")"
  assert_contains_file "the name landed in the env twin" "${twin}" '^APP_NAME=Demo\.Tool$'
  assert_contains_file "the module id landed in the env twin" "${twin}" \
    '^DB_URL=sqlite:///./demo_tool\.db$'
  assert_contains_file "the slug landed in the readme" "${dest}/README.md" \
    'https://github\.com/testowner/demo-tool'
  assert_contains_file "the owner landed in the readme link" "${dest}/README.md" \
    '^Repository: \[testowner/demo-tool\]'
  assert_contains_file "the alias slug landed in the guide" "${dest}/CONTRIBUTING.md" \
    'docker build -t demo-tool-dev'
  assert_contains_file "the module id landed in the guide" "${dest}/CONTRIBUTING.md" \
    'src/demo_tool/'
  assert_contains_file "the owner landed in the security policy" "${dest}/SECURITY.md" \
    'security@testowner\.example\.com'
  assert_contains_file "the description is one sed-safe line" "${dest}/template.yml" \
    '^description: "?Renders the [|] thing"?$'
  assert_contains_file "the name landed in the decision record body" \
    "${dest}/docs/adr/0001-Demo.Tool.md" '^The first decision of Demo\.Tool'

  # A dry run plans; it never dials.
  assert_eq "gh was never invoked" "0" "$(stub_log_count gh)"
  assert_eq "git was never invoked" "0" "$(stub_log_count git)"
  assert_eq "coder was never invoked" "0" "$(stub_log_count coder)"
  assert_match "the remote step is only planned" \
    'would run: gh api -X POST /user/repos name=Demo.Tool private=false' "${output}"
  assert_match "the push is only planned" \
    'would run: git init -b main && git add -A && git commit' "${output}"
}

@test "new-repo: a successful dry run closes with a well-formed summary and next line" {
  local parent ok_count summary
  parent="$(make_scratch)"
  render_dry "${parent}" Demo.Tool
  [ "${status}" -eq 0 ] || fail "a dry run must succeed, got ${status}: ${output}"
  assert_match "the plan section opens the run" '^== Plan ==$' "${output}"
  assert_match "the plan names the lanes" '^lanes: shell$' "${output}"
  assert_match "the plan names the scaffold" "^scaffold: local ${TEMPLATE}\$" "${output}"
  assert_match "the plan lists the offered lanes" '^scaffold lanes available: python shell$' \
    "${output}"
  assert_match "the plan says public by default" '^visibility: public$' "${output}"
  assert_match "the copy step announces itself" '^-> copy ' "${output}"
  assert_match "the handoff section closes the run" '^== Next ==$' "${output}"

  # No --description was passed, so the default is the CLI's own sentence, and it
  # has to survive the YAML quoting in the rendered manifest.
  assert_contains_file "the default description is the ezrepo sentence" \
    "${parent}/Demo.Tool/template.yml" \
    '^description: "?Demo.Tool: a new project built from the ezrepo scaffold\.\.?"?$'

  summary="$(printf '%s\n' "${output}" | grep '^summary: ')"
  assert_match "the summary has all three counters" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, 0 failed$' "${summary}"
  ok_count="$(printf '%s\n' "${output}" | grep -c '^ok: ')"
  assert_eq "the summary counts what it printed" "${ok_count}" \
    "$(printf '%s' "${summary}" | sed -E 's/^summary: ([0-9]+) ok.*/\1/')"
  assert_match "the next line hands off to new-workspace" \
    '^next: bazelisk run //scripts:new-workspace -- https://github.com/testowner/Demo.Tool.git$' \
    "${output}"
}

@test "new-repo: an existing destination is refused rather than clobbered" {
  local parent dest
  parent="$(make_scratch)"
  dest="${parent}/demo-tool"
  mkdir -p "${dest}"
  printf 'keep me\n' >"${dest}/keep.txt"

  render_dry "${parent}" demo-tool
  [ "${status}" -ne 0 ] || fail "an existing destination must be refused, got 0"
  assert_match "refuses to overwrite" 'refusing to render over an existing path' "${output}"
  assert_match "names the path" "${dest}" "${output}"
  assert_contains_file "the existing tree is untouched" "${dest}/keep.txt" 'keep me'
  assert_eq "and --out still holds exactly one tree" "1" \
    "$(find "${parent}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
}

@test "new-repo: the chosen lane lands and its reserved metadata is stripped" {
  local parent dest src rel missing=0 meta probe
  parent="$(make_scratch)"
  src="${TEMPLATE}/.template-lanes/shell"
  render_dry "${parent}" demo-tool
  [ "${status}" -eq 0 ] || fail "a lane render must succeed, got ${status}: ${output}"
  dest="${parent}/demo-tool"

  local file skip_meta lane_files=0
  # -L, not a bare find: under hermetic runfiles the lane tree is a forest of
  # symlinks, and `find -type f` matches none of them, which would make this loop
  # assert nothing at all.
  while IFS= read -r -d '' file; do
    lane_files=$((lane_files + 1))
    rel="${file#"${src}/"}"
    # The reserved names are read and then stripped, so they never land.
    skip_meta=false
    for meta in $(declared_lane_meta); do
      [ "${rel}" = "${meta}" ] && skip_meta=true
    done
    [ "${skip_meta}" = true ] && continue
    if [ ! -e "${dest}/${rel}" ]; then
      printf 'lane file never landed: %s\n' "${rel}" >&2
      missing=$((missing + 1))
    fi
  done < <(find -L "${src}" -type f -print0)
  [ "${lane_files}" -gt 0 ] || fail "the shell lane tree ships no file to assert on"
  assert_eq "every shell lane file landed at the render root" "0" "${missing}"

  for meta in $(declared_lane_meta); do
    assert_file_not_exists "lane metadata ${meta} is stripped" "${dest}/${meta}"
  done
  assert_file_not_exists "the lane tree itself is gone" "${dest}/.template-lanes"
  assert_match "the lane is reported" '^ok: lane shell$' "${output}"
  assert_match "the lane count is in the render line" '^ok: rendered 1 lane\(s\) into ' "${output}"

  probe="$(grep -vE '^[[:space:]]*(#|$)' "${src}/gitignore.fragment" | head -n 1)"
  [ -n "${probe}" ] || fail "the shell fragment carries no entry to assert on"
  grep -Fq -- "${probe}" "${dest}/.gitignore" ||
    fail "fragment entry ${probe} was not appended to .gitignore"
  assert_contains_file "the appended block names its lane" "${dest}/.gitignore" \
    '^# --- lane: shell ---$'
  assert_match "the append is reported" '^note: appended shell gitignore.fragment$' "${output}"
}

@test "new-repo: no lane renders the neutral core and says so" {
  local parent dest meta
  parent="$(make_scratch)"
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane none demo-tool
  [ "${status}" -eq 0 ] || fail "--lane none must succeed, got ${status}: ${output}"
  dest="${parent}/demo-tool"
  assert_match "the neutral core is announced" \
    'note: no lane selected: rendered the language-neutral core' "${output}"
  assert_match "and the test-lane gap is called out" \
    'the neutral core ships no test lane' "${output}"
  assert_match "the plan records no lanes" '^lanes: none$' "${output}"
  for meta in $(declared_lane_meta); do
    assert_file_not_exists "no ${meta} without a lane" "${dest}/${meta}"
  done
  assert_file_not_exists "the lane dispatcher's shell lane did not ride along" \
    "${dest}/src/main.sh"
  # Nothing was appended to the ignore file: it is still the core copy byte for byte.
  cmp -s "${dest}/.gitignore" "${TEMPLATE}/.gitignore" ||
    fail "the no-lane render changed .gitignore"
  # The dispatcher's machine-readable answer for the neutral core is the empty
  # string, and it is still an exit 0.
  run bash "${dest}/tests/run.sh" --lanes
  assert_eq "the dispatcher finds no lane in the neutral core" "0" "${status}"
  assert_eq "and prints nothing" "" "${output}"
}

@test "new-repo: env.example is written out as the dotted twin" {
  local parent dest twin
  parent="$(make_scratch)"
  render_dry "${parent}" demo-tool
  [ "${status}" -eq 0 ] || fail "the render must succeed, got ${status}: ${output}"
  dest="${parent}/demo-tool"
  assert_file_not_exists "the undotted name does not ship" "${dest}/env.example"
  twin="$(dotted_twin "${dest}")"
  assert_file_exists "the dotted twin ships" "${twin}"
  assert_contains_file "the twin kept its body" "${twin}" '^APP_NAME=demo-tool$'
  assert_match "the rename is reported" 'note: wrote env.example as .env.[e]xample' "${output}"
}

@test "new-repo: tokens in directory and file names are renamed" {
  local parent dest
  parent="$(make_scratch)"
  run_cli --dry-run --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane python demo-tool
  [ "${status}" -eq 0 ] || fail "the python lane render must succeed, got ${status}"
  dest="${parent}/demo-tool"
  [ -d "${dest}/src/demo_tool" ] || fail "the package directory did not take the module id"
  assert_file_exists "and its package came along" "${dest}/src/demo_tool/__init__.py"
  assert_file_exists "and its module came along" "${dest}/src/demo_tool/cli.py"
  assert_file_exists "the decision record took the name" "${dest}/docs/adr/0001-demo-tool.md"
  assert_eq "no token-named path is left" "0" \
    "$(find "${dest}" -name '*__PROJECT_*__' | wc -l | tr -d ' ')"
}

@test "new-repo: the canned scaffold exercises every token the CLI declares" {
  # A token the canned scaffold never uses would make "no token survived the
  # render" vacuous, and a token the scaffold uses that the CLI does not declare
  # ships showing in the new repository.
  local expected declared token missing=0 unexpected=0
  expected="$(printf '%s\n' __PROJECT_DESCRIPTION__ __PROJECT_LICENSE_HOLDER__ \
    __PROJECT_MODULE__ __PROJECT_NAME__ __PROJECT_OWNER__ __PROJECT_SLUG__ __PROJECT_YEAR__ |
    sort)"
  declared="$(declared_tokens | sort -u)"
  assert_eq "the token contract is the seven names" "${expected}" "${declared}"

  for token in ${declared}; do
    grep -RlqF -- "${token}" "${TEMPLATE}" ||
      find "${TEMPLATE}" -name "*${token}*" -print -quit | grep -q . || {
      printf 'the fixture never uses the declared token: %s\n' "${token}" >&2
      missing=$((missing + 1))
    }
  done
  assert_eq "the fixture uses every token the CLI declares" "0" "${missing}"

  # The markdown alias folds back to the canonical name before the comparison,
  # since that is the spelling a .md file actually stores. -R, not -r: under
  # hermetic runfiles the fixture tree is a forest of symlinks, and grep -r
  # silently reads none of them.
  for token in $({
    grep -RoE '__PROJECT_[A-Z_]+__' "${TEMPLATE}" | sed 's/^[^:]*://'
    grep -RoE '\*\*PROJECT_[A-Z_]+\*\*' "${TEMPLATE}" |
      sed 's/^[^:]*://; s/^\*\*/__/; s/\*\*$/__/'
  } | sort -u); do
    if ! printf '%s\n' "${declared}" | grep -qxF -- "${token}"; then
      printf 'undeclared token in the fixture: %s\n' "${token}" >&2
      unexpected=$((unexpected + 1))
    fi
  done
  assert_eq "the fixture uses no token the CLI does not declare" "0" "${unexpected}"

  # And the alias spelling really is present, which is what gives the renderer's
  # second sed expression something to do.
  for token in PROJECT_NAME PROJECT_DESCRIPTION; do
    grep -RlqE -- "\*\*${token}\*\*" "${TEMPLATE}" ||
      fail "the fixture ships no markdown alias spelling of ${token}"
  done
}

# ---------------------------------------------------------------------------
# Publish: git, remote, settings, topics, alerts
# ---------------------------------------------------------------------------

@test "new-repo: render_tree builds the tree, overlays the lane, and checks the tokens" {
  load_common
  local name
  for name in normalize escape_replacement substitute_tokens assert_no_tokens overlay_lanes \
    append_ignore_fragments rename_env_template render_tree; do
    load_shell_function "${SCRIPT}" "${name}"
  done
  NEW_REPO_TOKENS=()
  NEW_REPO_LANE_META=()
  NEW_REPO_TEMPLATE_META=()
  local token meta
  while IFS= read -r token; do NEW_REPO_TOKENS+=("${token}"); done < <(declared_tokens)
  while IFS= read -r meta; do NEW_REPO_LANE_META+=("${meta}"); done < <(declared_lane_meta)
  while IFS= read -r meta; do NEW_REPO_TEMPLATE_META+=("${meta}"); done < <(declared_template_meta)
  assert_eq "the strip set is the three paths the renderer names" "3" \
    "${#NEW_REPO_TEMPLATE_META[@]}"
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  REPO_NAME="demo-tool"
  DESCRIPTION="A tool for the thing"
  OWNER="testowner"
  HOLDER="Test Holder"
  YEAR="2026"
  LANES=(shell)

  local dest="${BATS_TEST_TMPDIR}/built" rc=0 lane_file rel
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/render.out" render_tree "${TEMPLATE}" "${dest}" || rc=$?
  assert_eq "the render succeeds" "0" "${rc}"
  assert_file_exists "the core came along" "${dest}/template.yml"
  assert_file_not_exists "the lane tree is not shipped" "${dest}/.template-lanes"

  lane_file="$(find -L "${TEMPLATE}/.template-lanes/shell" -type f \
    ! -name 'LANE.md' ! -name 'gitignore.fragment' -print | head -n 1)"
  [ -n "${lane_file}" ] || fail "the shell lane ships no file to assert on"
  rel="${lane_file#"${TEMPLATE}/.template-lanes/shell/"}"
  assert_file_exists "the lane was overlaid at the root" "${dest}/${rel}"

  assert_contains_file "the copy step is announced" "${BATS_TEST_TMPDIR}/render.out" \
    '^-> copy '
  assert_contains_file "the lane is reported" "${BATS_TEST_TMPDIR}/render.out" '^ok: lane shell$'
  assert_contains_file "and the render line counts it" "${BATS_TEST_TMPDIR}/render.out" \
    '^ok: rendered 1 lane\(s\) into '
  assert_eq "no placeholder survives the render" "0" \
    "$(grep -rlE -- '__PROJECT_[A-Z_]+__' "${dest}" | wc -l | tr -d ' ')"
  assert_eq "the counters saw two ok items" "2" "${SUMMARY_OK}"
}

@test "new-repo: the first commit message records where the scaffold came from" {
  local parent logged
  parent="$(make_scratch)"
  run_cli --no-remote --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --year 2026 --lane shell --lane python demo-tool
  [ "${status}" -eq 0 ] || fail "the render and commit must succeed, got ${status}: ${output}"
  logged="$(stub_log git)"
  assert_match "the commit is the bootstrap commit" \
    'chore: bootstrap demo-tool from the project template' "${logged}"
  assert_match "the body names the local scaffold it came from" \
    "- Scaffold: local tree ${TEMPLATE}." "${logged}"
  assert_match "the body names both lanes" '- Lanes: shell python.' "${logged}"
  assert_match "the body says why the gate ships early" \
    'The initial commit carries the full quality gate' "${logged}"
  assert_eq "the run committed once" "1" "$(printf '%s\n' "${logged}" | grep -c ' commit ')"
}

@test "new-repo: --no-remote renders and commits locally with no API call at all" {
  local parent
  parent="$(make_scratch)"
  run_cli --no-remote --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane shell demo-tool
  [ "${status}" -eq 0 ] || fail "--no-remote must succeed, got ${status}: ${output}"
  [ -d "${parent}/demo-tool" ] || fail "the render must land"
  assert_eq "no gh call of any kind" "0" "$(stub_log_count gh)"
  assert_eq "no push happened" "0" "$(stub_log git | grep -c 'push')"
  assert_match "the commit happened" '^ok: committed on main$' "${output}"
  assert_match "the push was declined on request" 'note: push skipped by request' "${output}"
  assert_not_match "no remote section ran" '^== Remote ==$' "${output}"
  assert_not_match "no settings section ran" '^== Settings ==$' "${output}"
  assert_match "the summary still closes the run" '^summary: [0-9]+ ok, 0 warnings, 0 failed$' \
    "${output}"
}

@test "new-repo: --no-push runs the GitHub steps but never pushes" {
  local parent
  parent="$(make_scratch)"
  run_cli --no-push --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane shell demo-tool
  [ "${status}" -eq 0 ] || fail "--no-push must succeed, got ${status}: ${output}"
  assert_eq "nothing was pushed" "0" "$(stub_log git | grep -c 'push')"
  assert_match "the render was committed" '^ok: committed on main$' "${output}"
  assert_match "push was skipped by request" 'note: push skipped by request' "${output}"
  assert_match "the repository was still created" 'ok: created testowner/demo-tool' "${output}"
  assert_match "the create call was posted" 'gh api -X POST /user/repos' "$(stub_log gh)"
}

@test "new-repo: create_remote posts the repository body and honours --private" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  load_shell_function "${SCRIPT}" create_remote
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  OWNER="testowner" REPO_NAME="demo-tool" DESCRIPTION="Does the thing" \
    PRIVATE=true DRY_RUN=false
  call_fn "${BATS_TEST_TMPDIR}/create.out" create_remote
  assert_eq "one create call" "1" "$(stub_log_count gh)"
  local logged
  logged="$(stub_log gh)"
  assert_match "it posts to /user/repos" 'gh api -X POST /user/repos' "${logged}"
  assert_match "the name is posted" 'name=demo-tool' "${logged}"
  assert_match "private rides the flag" 'private=true' "${logged}"
  assert_match "issues are turned on" 'has_issues=true' "${logged}"
  assert_match "no empty README commit" 'auto_init=false' "${logged}"
  assert_contains_file "and it counted as ok" "${BATS_TEST_TMPDIR}/create.out" \
    '^ok: created testowner/demo-tool$'
  assert_eq "the ok counter moved" "1" "${SUMMARY_OK}"
}

@test "new-repo: a refused create reports the failure, the hint and the manual route" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  load_shell_function "${SCRIPT}" permission_hint
  load_shell_function "${SCRIPT}" create_remote
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  OWNER="testowner" REPO_NAME="demo-tool" DESCRIPTION="" PRIVATE=false DRY_RUN=false
  export STUB_GH_RC=1
  local rc=0 out
  call_fn "${BATS_TEST_TMPDIR}/refused.out" create_remote || rc=$?
  unset STUB_GH_RC
  out="$(cat "${BATS_TEST_TMPDIR}/refused.out")"
  assert_eq "a refused create fails the run" "1" "${rc}"
  assert_match "it says what failed" 'error: create testowner/demo-tool' "${out}"
  assert_match "it names the permission to grant" \
    'Administration:write \(or Repository creation:write\)' "${out}"
  assert_match "it names the re-mint command" 'coder external-auth access-token github' "${out}"
  assert_match "it prints the manual route" \
    'manual route: gh repo create testowner/demo-tool' "${out}"
  assert_match "it probed for an existing repository" \
    'gh api repos/testowner/demo-tool --jq .full_name' "$(stub_log gh)"
  assert_eq "the failure is counted" "1" "${SUMMARY_FAIL}"
}

@test "new-repo: apply_settings posts branch hygiene and the template flag" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  load_shell_function "${SCRIPT}" permission_hint
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  OWNER="testowner" REPO_NAME="demo-tool" AS_TEMPLATE=true DRY_RUN=false
  load_shell_function "${SCRIPT}" apply_settings
  call_fn "${BATS_TEST_TMPDIR}/settings.out" apply_settings
  local logged
  logged="$(stub_log gh)"
  assert_match "it patches the repository" 'gh api -X PATCH repos/testowner/demo-tool' "${logged}"
  assert_match "wiki is off" 'has_wiki=false' "${logged}"
  assert_match "merged branches are deleted" 'delete_branch_on_merge=true' "${logged}"
  assert_match "merge commits are off" 'allow_merge_commit=false' "${logged}"
  assert_match "squash is on" 'allow_squash_merge=true' "${logged}"
  assert_match "the template flag rides --as-template" 'is_template=true' "${logged}"
  assert_contains_file "the step is reported" "${BATS_TEST_TMPDIR}/settings.out" \
    '^ok: settings applied$'

  # A refusal is advisory: the run keeps going with a warning and a hint.
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0
  export STUB_GH_RC=1
  call_fn "${BATS_TEST_TMPDIR}/refused.out" apply_settings
  unset STUB_GH_RC
  assert_contains_file "a refusal is a warning" "${BATS_TEST_TMPDIR}/refused.out" \
    '^warning: settings refused'
  assert_contains_file "with the permission to grant" "${BATS_TEST_TMPDIR}/refused.out" \
    'hint: repository settings, topics and alerts are Administration:write'
  assert_eq "and never a failure" "0" "${SUMMARY_FAIL}"
  assert_eq "counted as one warning" "1" "${SUMMARY_WARN}"
}

@test "new-repo: apply_topics posts the base, lane, extra and template topics" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  load_shell_function "${SCRIPT}" permission_hint
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  OWNER="testowner" REPO_NAME="demo-tool" AS_TEMPLATE=true DRY_RUN=false
  LANES=(shell python)
  EXTRA_TOPICS=(cli)
  load_shell_function "${SCRIPT}" apply_topics
  call_fn "${BATS_TEST_TMPDIR}/topics.out" apply_topics
  local logged topic
  logged="$(stub_log gh)"
  assert_match "it replaces the topic list" \
    'gh api -X PUT repos/testowner/demo-tool/topics' "${logged}"
  for topic in coder evo-t1 shell python cli template starter; do
    assert_match "the ${topic} topic is posted" "names\[\]=${topic}([^a-z]|$)" "${logged}"
  done
  assert_contains_file "the count is reported" "${BATS_TEST_TMPDIR}/topics.out" \
    '^ok: topics set \(7\)$'
}

@test "new-repo: enable_vulnerability_alerts turns alerts on or warns with the route" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  load_shell_function "${SCRIPT}" permission_hint
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  OWNER="testowner" REPO_NAME="demo-tool" DRY_RUN=false
  load_shell_function "${SCRIPT}" enable_vulnerability_alerts
  call_fn "${BATS_TEST_TMPDIR}/alerts.out" enable_vulnerability_alerts
  assert_match "it puts the alerts endpoint" \
    'gh api -X PUT repos/testowner/demo-tool/vulnerability-alerts' "$(stub_log gh)"
  assert_contains_file "success is reported" "${BATS_TEST_TMPDIR}/alerts.out" \
    '^ok: vulnerability alerts on$'

  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0
  export STUB_GH_RC=1
  call_fn "${BATS_TEST_TMPDIR}/refused.out" enable_vulnerability_alerts
  unset STUB_GH_RC
  assert_contains_file "a refusal is a warning" "${BATS_TEST_TMPDIR}/refused.out" \
    'vulnerability alerts refused'
  assert_contains_file "and says where to do it by hand" "${BATS_TEST_TMPDIR}/refused.out" \
    'Settings > Code security'
  assert_contains_file "with the permission hint" "${BATS_TEST_TMPDIR}/refused.out" \
    'dependency alerts need Administration:write'
  assert_eq "it is never a failure" "0" "${SUMMARY_FAIL}"
}

@test "new-repo: init_and_push commits on the chosen branch and pushes origin" {
  load_common
  load_shell_function "${SCRIPT}" init_and_push
  load_shell_function "${SCRIPT}" permission_hint
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  local dest rc=0 out
  dest="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${dest}"
  printf 'x\n' >"${dest}/README.md"
  REPO_NAME="demo-tool" OWNER="testowner" BRANCH="trunk" PRIVATE=false \
    DRY_RUN=false NO_REMOTE=false NO_PUSH=false LANES=(shell)
  TEMPLATE_PROVENANCE="${DEFAULT_TEMPLATE_URL}@deadbeef"
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/push.out" init_and_push "${dest}" || rc=$?
  assert_eq "a clean git run succeeds" "0" "${rc}"
  out="$(cat "${BATS_TEST_TMPDIR}/push.out")"
  assert_match "the commit is reported" '^ok: committed on trunk$' "${out}"
  assert_match "the push is reported" '^ok: pushed trunk$' "${out}"
  local logged
  logged="$(stub_log git)"
  assert_match "it inits the branch" 'init -q -b trunk' "${logged}"
  assert_match "it stages everything" 'add -A' "${logged}"
  assert_match "it commits the bootstrap message" \
    'chore: bootstrap demo-tool from the project template' "${logged}"
  assert_match "it records the scaffold revision in the body" \
    '- Scaffold: https://github.com/toxicoder/ezrepo\.git@deadbeef.' "${logged}"
  assert_match "it adds the origin" \
    'remote add origin https://github.com/testowner/demo-tool.git' "${logged}"
  assert_match "it pushes upstream" 'push -q -u origin trunk' "${logged}"
  assert_eq "commit and push both counted" "2" "${SUMMARY_OK}"
}

@test "new-repo: a git that cannot init is a failure, not a silent success" {
  load_common
  load_shell_function "${SCRIPT}" init_and_push
  load_shell_function "${SCRIPT}" permission_hint
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  local dest rc=0
  dest="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${dest}"
  REPO_NAME="demo-tool" OWNER="testowner" BRANCH="main" PRIVATE=false \
    DRY_RUN=false NO_REMOTE=true NO_PUSH=false LANES=()
  TEMPLATE_PROVENANCE="local tree ${TEMPLATE}"
  export STUB_GIT_RC=128
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/gitfail.out" init_and_push "${dest}" || rc=$?
  unset STUB_GIT_RC
  assert_eq "a failed init fails the run" "1" "${rc}"
  assert_contains_file "it says which step failed" "${BATS_TEST_TMPDIR}/gitfail.out" \
    '^error: git init$'
  assert_eq "the failure is counted" "1" "${SUMMARY_FAIL}"
  assert_eq "and nothing was pushed" "0" "$(stub_log git | grep -c 'push')"
}

# ---------------------------------------------------------------------------
# The credential ladder
# ---------------------------------------------------------------------------

@test "new-repo: gh_api retries once with the env pair cleared and warns about it" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  local rc=0 out first second
  export GH_TOKEN="ghp_expired_from_a_stale_refresh" GITHUB_TOKEN="ghp_expired_too"
  # The refusal this ladder exists for: the env pair is the one that fails.
  export STUB_GH_FAIL_ONCE="${BATS_TEST_TMPDIR}/gh-first-failed"
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/gh.out" gh_api -X GET /user/repos || rc=$?
  assert_eq "the retry carries the call" "0" "${rc}"
  assert_eq "gh was called exactly twice" "2" "$(stub_log_count gh)"
  out="$(cat "${BATS_TEST_TMPDIR}/gh.out")"
  assert_match "the warning names the pair it cleared" \
    'retrying with GH_TOKEN/GITHUB_TOKEN unset' "${out}"
  assert_match "the warning says why" 'shadows the gh stored login' "${out}"
  first="$(sed -n '1p' "${STUB_LOG}/gh-env.log")"
  second="$(sed -n '2p' "${STUB_LOG}/gh-env.log")"
  assert_eq "the first attempt carried the environment pair" \
    "GH_TOKEN=ghp_expired_from_a_stale_refresh|GITHUB_TOKEN=ghp_expired_too" "${first}"
  assert_eq "the retry cleared both halves of the pair" "GH_TOKEN=|GITHUB_TOKEN=" "${second}"
  assert_not_match "the token value is never printed" 'ghp_expired_from_a_stale_refresh' "${out}"
}

@test "new-repo: gh_api without the env pair retries silently and reports the failure" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  local rc=0
  unset GH_TOKEN GITHUB_TOKEN
  export STUB_GH_RC=1
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/gh.out" gh_api -X GET /user/repos || rc=$?
  unset STUB_GH_RC
  assert_eq "a refused call still fails" "1" "${rc}"
  assert_eq "it still retried once" "2" "$(stub_log_count gh)"
  assert_not_match "no shadow warning without a pair to shadow" 'shadows the gh stored login' \
    "$(cat "${BATS_TEST_TMPDIR}/gh.out")"
  assert_eq "both attempts saw no pair" "GH_TOKEN=unset|GITHUB_TOKEN=unset" \
    "$(sed -n '2p' "${STUB_LOG}/gh-env.log")"
}

@test "new-repo: a first-refused call is retried by the CLI, not the stub" {
  load_common
  load_shell_function "${SCRIPT}" gh_api
  write_gh_stub
  local marker="${BATS_TEST_TMPDIR}/first-failed" rc=0
  export STUB_GH_FAIL_ONCE="${marker}"
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/once.out" gh_api repos/testowner/demo-tool --jq .full_name || rc=$?
  unset STUB_GH_FAIL_ONCE
  assert_eq "the retry turns the refusal into a success" "0" "${rc}"
  assert_eq "the stub failed exactly once, so the retry did the work" "2" "$(stub_log_count gh)"
  assert_eq "and the same call was made both times" "2" \
    "$(grep -c 'gh api repos/testowner/demo-tool --jq .full_name' <<<"$(stub_log gh)")"
}

@test "new-repo: gh_api prints only the attempt whose status it returns" {
  # gh answers a refused call with the error body on stdout. If a discarded attempt's
  # stdout leaked to the caller, `OWNER="$(gh_api user --jq .login)"` would become two
  # lines and every later repos/${OWNER}/... path would be nonsense.
  load_common
  load_shell_function "${SCRIPT}" gh_api
  write_gh_stub
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  local rc=0
  export GH_TOKEN="ghp_expired_from_a_stale_refresh" GITHUB_TOKEN="ghp_expired_too"
  export STUB_GH_OWNER="testowner"
  export STUB_GH_FAIL_ONCE="${BATS_TEST_TMPDIR}/body-on-stdout"
  rc=0
  gh_api user --jq .login >"${BATS_TEST_TMPDIR}/one.out" 2>"${BATS_TEST_TMPDIR}/one.err" || rc=$?
  unset STUB_GH_FAIL_ONCE
  assert_eq "the retry carries the call" "0" "${rc}"
  assert_eq "stdout is the login and nothing else" "testowner" \
    "$(cat "${BATS_TEST_TMPDIR}/one.out")"
  assert_not_match "the refused attempt's body never reaches the caller" 'Bad credentials' \
    "$(cat "${BATS_TEST_TMPDIR}/one.out")"
  assert_not_match "and neither does its stderr" 'Bad credentials' \
    "$(cat "${BATS_TEST_TMPDIR}/one.err")"
}

@test "new-repo: a refused env pair still yields one clean owner in the report" {
  export STUB_GH_OWNER="octocat"
  export STUB_GH_FAIL_ONCE="${BATS_TEST_TMPDIR}/pair-refused"
  local parent
  parent="$(make_scratch)"
  run env -u BUILD_WORKSPACE_DIRECTORY -u EZREPO_URL -u EZREPO_REF -u EZREPO_DIR \
    GH_TOKEN="ghp_expired_from_a_stale_refresh" GITHUB_TOKEN="ghp_expired_too" \
    REPO_ROOT="${REPO_ROOT}" HOME="${BATS_TEST_TMPDIR}" PATH="${STUB_BIN}:${PATH}" \
    bash "${SCRIPT}" --no-remote --out "${parent}" --template-dir "${TEMPLATE}" demo-tool
  unset STUB_GH_FAIL_ONCE
  [ "${status}" -eq 0 ] || fail "the run must succeed, got ${status}: ${output}"
  assert_match "the owner line holds a login and nothing else" '^owner: octocat$' "${output}"
  assert_match "the remote is built from a single login" \
    'remote: https://github.com/octocat/demo-tool.git' "${output}"
  assert_not_match "no error body was printed as the owner" 'Bad credentials' "${output}"
  assert_not_match "no warning was captured into the value" 'credential refused' "${output}"
}

@test "new-repo: the owner comes from gh when --owner is absent" {
  export STUB_GH_OWNER="octocat"
  local parent
  parent="$(make_scratch)"
  run_cli --no-remote --out "${parent}" --template-dir "${TEMPLATE}" demo-tool
  [ "${status}" -eq 0 ] || fail "the run must succeed, got ${status}: ${output}"
  assert_match "the probed login is the owner" '^owner: octocat$' "${output}"
  assert_match "and the remote is built from it" \
    'remote: https://github.com/octocat/demo-tool.git' "${output}"
  assert_match "the probe was the api call it claims" 'gh api user --jq .login' "$(stub_log gh)"
}

@test "new-repo: no gh login and no --owner stops the run with a remedy" {
  local parent
  parent="$(make_scratch)"
  run_cli --no-remote --out "${parent}" --template-dir "${TEMPLATE}" demo-tool
  [ "${status}" -ne 0 ]
  assert_match "it says it could not find an owner" 'cannot determine the GitHub owner' "${output}"
  assert_match "and names the flag to pass" 'pass --owner' "${output}"
  assert_eq "nothing was rendered" "0" "$(find "${parent}" -mindepth 1 | wc -l | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# The Coder Task step
# ---------------------------------------------------------------------------

@test "new-repo: no --task means no coder call and no task section" {
  write_gh_stub
  local parent
  parent="$(make_scratch)"
  run_cli --no-remote --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner demo-tool
  [ "${status}" -eq 0 ] || fail "the run must succeed, got ${status}: ${output}"
  assert_eq "the coder CLI was never run" "0" "$(stub_log_count coder)"
  assert_not_match "the section never opened" '^== Coder Task ==$' "${output}"
}

@test "new-repo: --task creates the bootstrap task against the chosen template" {
  write_gh_stub
  local parent logged
  parent="$(make_scratch)"
  run_cli --no-remote --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --task --task-template base demo-tool
  [ "${status}" -eq 0 ] || fail "the run must succeed, got ${status}: ${output}"
  assert_match "the task section ran" '^== Coder Task ==$' "${output}"
  assert_match "the task is reported" '^ok: created Coder task demo-tool-bootstrap$' "${output}"
  logged="$(stub_log coder)"
  assert_match "it names the task" 'coder task create --name demo-tool-bootstrap' "${logged}"
  assert_match "it passes the template" '\-\-template base' "${logged}"
  assert_match "it carries the bootstrap prompt" 'read AGENTS.md, run make doctor and make test' \
    "${logged}"
  assert_match "and the decision record" 'docs/adr/' "${logged}"
}

@test "new-repo: --task with a dry run only prints the coder command" {
  local parent
  parent="$(make_scratch)"
  render_dry "${parent}" --task demo-tool
  [ "${status}" -eq 0 ] || fail "the dry run must succeed, got ${status}: ${output}"
  assert_eq "no coder call" "0" "$(stub_log_count coder)"
  assert_match "the command is printed instead" \
    'would run: coder task create --name demo-tool-bootstrap' "${output}"
}

@test "new-repo: a task without the coder CLI on PATH is a warning with the route" {
  load_common
  load_shell_function "${SCRIPT}" create_coder_task
  SUMMARY_OK=0 SUMMARY_WARN=0 SUMMARY_FAIL=0 SUMMARY_FAIL_ITEMS=""
  MAKE_TASK=true
  REPO_NAME="demo-tool"
  OWNER="testowner"
  TASK_TEMPLATE=""
  DRY_RUN=false
  local empty="${BATS_TEST_TMPDIR}/empty-bin"
  mkdir -p "${empty}"
  # Call the function in this shell with coder hidden from PATH.
  local saved="${PATH}"
  PATH="${empty}"
  create_coder_task >"${BATS_TEST_TMPDIR}/task.out" 2>&1
  PATH="${saved}"
  assert_contains_file "the missing CLI is a warning" "${BATS_TEST_TMPDIR}/task.out" \
    'coder CLI is not on PATH here'
  assert_contains_file "and the operator gets the command line" "${BATS_TEST_TMPDIR}/task.out" \
    'manual route: coder task create --name demo-tool-bootstrap'
  assert_eq "a missing task is never a failure" "0" "${SUMMARY_FAIL}"
  assert_eq "counted as one warning" "1" "${SUMMARY_WARN}"
}

# ---------------------------------------------------------------------------
# The pieces the CLI is built from, tested where they are defined
# ---------------------------------------------------------------------------

@test "new-repo: normalize folds a name into a slug and a module identifier" {
  load_shell_function "${SCRIPT}" normalize
  assert_eq "case and punctuation fold to the separator" "demo-tool" "$(normalize 'Demo.Tool')"
  assert_eq "runs of separators collapse" "demo-tool" "$(normalize '  Demo --  Tool  ')"
  assert_eq "the module fold uses underscores" "demo_tool" "$(normalize 'Demo.Tool' _)"
  assert_eq "digits need no separator to survive" "demotool2x" "$(normalize 'DemoTool2x' -)"
  assert_eq "an empty value stays empty" "" "$(normalize '')"
}

@test "new-repo: sanitize_line makes prose sed-safe and one-line" {
  load_shell_function "${SCRIPT}" sanitize_line
  assert_eq "tabs and runs of spaces collapse" "a b c" "$(sanitize_line $'a\t b\n c\n')"
  assert_eq "a CR is dropped" "ab" "$(sanitize_line $'a\rb')"
  assert_eq "leading and trailing space go" "abc" "$(sanitize_line '  abc  ')"
  assert_eq "the lines are joined into one" "firstsecond" "$(sanitize_line $'first\nsecond')"
  assert_eq "an empty value stays empty" "" "$(sanitize_line '')"
}

@test "new-repo: escape_replacement quotes what sed would otherwise act on" {
  load_shell_function "${SCRIPT}" escape_replacement
  assert_eq "an ampersand is escaped" 'a\&b' "$(escape_replacement 'a&b')"
  assert_eq "a pipe is escaped" 'a\|b' "$(escape_replacement 'a|b')"
  assert_eq "a backslash is escaped" 'a\\b' "$(escape_replacement 'a\b')"
  assert_eq "plain text is untouched" 'plain text 1.0' "$(escape_replacement 'plain text 1.0')"
}

@test "new-repo: substitute_tokens rewrites contents, file names, and directory names" {
  load_shell_function "${SCRIPT}" escape_replacement
  load_shell_function "${SCRIPT}" substitute_tokens
  NEW_REPO_TOKENS=()
  local token
  while IFS= read -r token; do NEW_REPO_TOKENS+=("${token}"); done < <(declared_tokens)
  assert_eq "the token array came from the CLI" "7" "${#NEW_REPO_TOKENS[@]}"

  local tree="${BATS_TEST_TMPDIR}/tree" root
  root="${tree}/__PROJECT_NAME__"
  mkdir -p "${root}"
  printf 'name __PROJECT_NAME__, slug __PROJECT_SLUG__, mod __PROJECT_MODULE__\n' >"${root}/a.txt"
  printf 'desc __PROJECT_DESCRIPTION__, owner __PROJECT_OWNER__\n' >"${root}/__PROJECT_SLUG__"
  printf 'holder __PROJECT_LICENSE_HOLDER__ year __PROJECT_YEAR__\n' >"${root}/keep.txt"

  substitute_tokens "${tree}" demo-tool demo-tool demo_tool \
    'The | description' testowner 'Test Holder' 2026
  local base="${tree}/demo-tool"
  assert_file_exists "the directory token became the slug" "${base}/keep.txt"
  assert_contains_file "contents were substituted" "${base}/a.txt" \
    'name demo-tool, slug demo-tool, mod demo_tool'
  assert_file_exists "the file named by a token took the slug" "${base}/demo-tool"
  assert_contains_file "and its body was substituted too" "${base}/demo-tool" \
    'desc The [|] description, owner testowner'
  assert_contains_file "holder and year landed" "${base}/keep.txt" \
    'holder Test Holder year 2026'
}

@test "new-repo: a placeholder the render cannot fill fails the render and is named" {
  load_common
  load_shell_function "${SCRIPT}" assert_no_tokens
  NEW_REPO_TOKENS=()
  local token
  while IFS= read -r token; do NEW_REPO_TOKENS+=("${token}"); done < <(declared_tokens)
  assert_eq "the token array came from the CLI" "7" "${#NEW_REPO_TOKENS[@]}"

  local clean="${BATS_TEST_TMPDIR}/clean" rc=0
  mkdir -p "${clean}"
  : >"${clean}/fine.txt"
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/clean.out" assert_no_tokens "${clean}" || rc=$?
  assert_eq "a clean tree passes" "0" "${rc}"

  printf 'still __PROJECT_NAME__ here\n' >"${clean}/leak.txt"
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/leak.out" assert_no_tokens "${clean}" || rc=$?
  assert_eq "a leak in a body is a failure" "1" "${rc}"
  assert_contains_file "and it names the file" "${BATS_TEST_TMPDIR}/leak.out" 'leak\.txt'

  # A token in a path is as much a leak as one in a body.
  : >"${clean}/__PROJECT_OWNER__.md"
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/path.out" assert_no_tokens "${clean}" || rc=$?
  assert_eq "a leak in a path is a failure" "1" "${rc}"
  assert_contains_file "and it names the path" "${BATS_TEST_TMPDIR}/path.out" \
    '__PROJECT_OWNER__\.md'

  # The same check through the CLI. The seven tokens always have a value, so the
  # reachable leak is a value that carries a token the pass already consumed: sed
  # applies one expression per token in NEW_REPO_TOKENS order, so a __PROJECT_NAME__
  # written into the description survives (the name pass ran before the description
  # inserted it) and reaches the check as a leak. The guard fails the render and names
  # the file rather than publishing the placeholder.
  local root="${BATS_TEST_TMPDIR}/leaky" parent
  mkdir -p "${root}"
  printf 'name: __PROJECT_NAME__\ndescription: __PROJECT_DESCRIPTION__\n' \
    >"${root}/template.yml"
  parent="$(make_scratch)"
  run_cli --dry-run --out "${parent}" --template-dir "${root}" --owner testowner \
    --lane none --description 'ships __PROJECT_NAME__ today' demo
  [ "${status}" -eq 1 ] || fail "an unsubstituted token must fail the render, got ${status}"
  assert_match "the run names the leak" 'unsubstituted token in:' "${output}"
  assert_match "and the file that carries it" 'template\.yml' "${output}"
  assert_match "one failure is counted" '^summary: [0-9]+ ok, 0 warnings, 1 failed$' "${output}"
  assert_match "the failed item is listed" \
    '^  failed: unsubstituted token in: template\.yml$' "${output}"
}

@test "new-repo: a token anywhere in a path is renamed, not left to fail the check" {
  load_common
  # The rename pass and the token check have to agree: a file named __PROJECT_OWNER__.md
  # (a token that does not sit at both ends of the name) used to be renamed by neither the
  # suffix-anchored find nor nothing else, so the render died on its own output. A lane
  # that ships such a path has to render, with the token filled in.
  local root="${BATS_TEST_TMPDIR}/midname" parent
  mkdir -p "${root}/docs"
  printf 'name: __PROJECT_NAME__\n' >"${root}/template.yml"
  printf '# __PROJECT_DESCRIPTION__\n' >"${root}/README.md"
  printf 'owner\n' >"${root}/__PROJECT_OWNER__.md"
  printf 'mod\n' >"${root}/docs/__PROJECT_MODULE__-config.md"

  parent="$(make_scratch)"
  run_cli --dry-run --no-remote --out "${parent}" --template-dir "${root}" \
    --owner testowner --lane none demo-tool
  [ "${status}" -eq 0 ] || fail "the render must succeed, got ${status}: ${output}"

  local dest="${parent}/demo-tool"
  [ -f "${dest}/testowner.md" ] || fail "the suffix-adjacent token path was not renamed"
  [ ! -e "${dest}/__PROJECT_OWNER__.md" ] || fail "the placeholder path survived"
  [ -f "${dest}/docs/demo_tool-config.md" ] || fail "a mid-name token path was not renamed"
  [ ! -e "${dest}/docs/__PROJECT_MODULE__-config.md" ] ||
    fail "the mid-name placeholder path survived"
  assert_match "the summary is clean" '^summary: [0-9]+ ok, 0 warnings, 0 failed$' "${output}"
}

@test "new-repo: a markdown token the formatter rewrote is still substituted" {
  load_common
  # A markdown formatter reads the canonical __NAME__ as strong emphasis and leaves
  # **NAME** behind, which is the spelling the canned scaffold's markdown actually
  # carries. A renderer that only knew the canonical form would publish the placeholder
  # into the new repository's README.
  local root="${BATS_TEST_TMPDIR}/mdalias" parent
  mkdir -p "${root}"
  printf 'name: x\n' >"${root}/template.yml"
  printf '%s\n' '# **PROJECT_NAME**' '' \
    '**PROJECT_DESCRIPTION** by **PROJECT_OWNER**/**PROJECT_SLUG**, (c) **PROJECT_YEAR** **PROJECT_LICENSE_HOLDER**.' \
    >"${root}/README.md"

  parent="$(make_scratch)"
  run_cli --dry-run --no-remote --out "${parent}" --template-dir "${root}" \
    --owner testowner --holder 'Acme Corp' --year 2026 --lane none \
    --description 'does the thing' demo-tool
  [ "${status}" -eq 0 ] || fail "the render must succeed, got ${status}: ${output}"

  local body
  body="$(cat "${parent}/demo-tool/README.md")"
  assert_eq "the whole file is substituted" \
    '# demo-tool

does the thing by testowner/demo-tool, (c) 2026 Acme Corp.' "${body}"
  assert_match "the summary is clean" '^summary: [0-9]+ ok, 0 warnings, 0 failed$' "${output}"

  # And the same pass over the canned scaffold: its README ships the alias spelling,
  # so a render of it must not leave one asterisk pair behind.
  parent="$(make_scratch)"
  render_dry "${parent}" --no-remote --holder 'Acme Corp' demo-tool
  [ "${status}" -eq 0 ] || fail "the fixture render must succeed, got ${status}: ${output}"
  assert_eq "no alias placeholder survives the fixture render" "0" \
    "$(grep -rlE -- '\*\*PROJECT_[A-Z_]+\*\*' "${parent}/demo-tool" | wc -l | tr -d ' ')"
}

@test "new-repo: overlay_lanes copies the lane and errors when a lane has no directory" {
  load_common
  load_shell_function "${SCRIPT}" overlay_lanes
  NEW_REPO_LANE_META=()
  local meta
  while IFS= read -r meta; do NEW_REPO_LANE_META+=("${meta}"); done < <(declared_lane_meta)
  assert_eq "the reserved set is the two names the renderer reads" "2" \
    "${#NEW_REPO_LANE_META[@]}"

  local src="${BATS_TEST_TMPDIR}/tpl" dest="${BATS_TEST_TMPDIR}/out" rc=0
  mkdir -p "${src}/.template-lanes/demo/scripts" "${dest}"
  printf 'lane script\n' >"${src}/.template-lanes/demo/scripts/run.sh"
  printf 'lane readme\n' >"${src}/.template-lanes/demo/LANE.md"
  printf '*.tmp\n' >"${src}/.template-lanes/demo/gitignore.fragment"
  printf 'core\n' >"${dest}/core.txt"

  call_fn "${BATS_TEST_TMPDIR}/overlay.out" overlay_lanes "${src}" "${dest}" demo
  assert_contains_file "the lane file landed" "${dest}/scripts/run.sh" 'lane script'
  assert_contains_file "the core survived the overlay" "${dest}/core.txt" 'core'
  for meta in "${NEW_REPO_LANE_META[@]}"; do
    assert_file_not_exists "${meta} was stripped" "${dest}/${meta}"
  done
  assert_contains_file "the lane is reported" "${BATS_TEST_TMPDIR}/overlay.out" '^ok: lane demo$'

  rc=0
  call_fn "${BATS_TEST_TMPDIR}/missing.out" overlay_lanes "${src}" "${dest}" nosuch || rc=$?
  assert_eq "a lane with no directory fails" "1" "${rc}"
  assert_contains_file "and says which lane and where" "${BATS_TEST_TMPDIR}/missing.out" \
    'lane has no directory: nosuch \(.*\.template-lanes/nosuch\)'
}

@test "new-repo: append_ignore_fragments appends one named block per lane" {
  load_common
  load_shell_function "${SCRIPT}" append_ignore_fragments
  local src="${BATS_TEST_TMPDIR}/tpl" dest="${BATS_TEST_TMPDIR}/out" text
  mkdir -p "${src}/.template-lanes/one" "${src}/.template-lanes/two" "${dest}"
  printf '*.one\n' >"${src}/.template-lanes/one/gitignore.fragment"
  printf 'core-ignore\n' >"${dest}/.gitignore"

  call_fn "${BATS_TEST_TMPDIR}/frag.out" append_ignore_fragments "${src}" "${dest}" one two
  text="$(cat "${dest}/.gitignore")"
  assert_contains_file "the core entry is still there" "${dest}/.gitignore" 'core-ignore'
  assert_contains_file "the first lane block is named" "${dest}/.gitignore" \
    '^# --- lane: one ---$'
  assert_contains_file "its content was appended" "${dest}/.gitignore" '\*\.one'
  assert_eq "a lane with no fragment adds no block" "1" \
    "$(printf '%s\n' "${text}" | grep -c '^# --- lane: ')"
  assert_not_match "the lane without a fragment is not mentioned" 'lane: two' "${text}"
  assert_contains_file "the append is reported" "${BATS_TEST_TMPDIR}/frag.out" \
    '^note: appended one gitignore.fragment$'
}

@test "new-repo: rename_env_template is quiet when the twin is absent" {
  load_common
  load_shell_function "${SCRIPT}" rename_env_template
  local dest="${BATS_TEST_TMPDIR}/bare" rc=0 twin
  mkdir -p "${dest}"
  rc=0
  call_fn "${BATS_TEST_TMPDIR}/bare.out" rename_env_template "${dest}" || rc=$?
  assert_eq "an absent twin is not a failure" "0" "${rc}"
  assert_eq "and it says nothing" "" "$(cat "${BATS_TEST_TMPDIR}/bare.out")"

  printf 'A=1\n' >"${dest}/env.example"
  call_fn "${BATS_TEST_TMPDIR}/renamed.out" rename_env_template "${dest}"
  assert_file_not_exists "the undotted name is gone" "${dest}/env.example"
  twin="$(dotted_twin "${dest}")"
  assert_contains_file "the dotted twin carries the body" "${twin}" '^A=1$'
  assert_contains_file "the rename is reported" "${BATS_TEST_TMPDIR}/renamed.out" \
    'note: wrote env.example as .env.[e]xample'
}

@test "new-repo: permission_hint names a runnable remedy for each refused family" {
  load_common
  load_shell_function "${SCRIPT}" permission_hint
  local family out
  for family in create settings alerts mystery; do
    call_fn "${BATS_TEST_TMPDIR}/hint.out" permission_hint "${family}"
    out="$(cat "${BATS_TEST_TMPDIR}/hint.out")"
    assert_match "${family} prints a hint" '^error: hint: ' "${out}"
    assert_match "${family} closes with the re-mint route" \
      'coder external-auth access-token github re-mints' "${out}"
  done
  call_fn "${BATS_TEST_TMPDIR}/create.out" permission_hint create
  assert_contains_file "create asks for Administration:write" "${BATS_TEST_TMPDIR}/create.out" \
    'Administration:write'
  call_fn "${BATS_TEST_TMPDIR}/alerts.out" permission_hint alerts
  assert_contains_file "alerts mentions Dependabot being refused for an App" \
    "${BATS_TEST_TMPDIR}/alerts.out" 'Dependabot secrets'
  call_fn "${BATS_TEST_TMPDIR}/mystery.out" permission_hint mystery
  assert_contains_file "an unknown family still names itself" "${BATS_TEST_TMPDIR}/mystery.out" \
    'missing a permission for mystery'
}

@test "new-repo: the render holds real files, never runfiles symlinks" {
  load_common
  # A scaffold delivered through Bazel runfiles is a tree of symlinks. A copy that
  # preserves them ships a repository whose lane files point into a directory that is
  # gone when the build ends, and discovery breaks first: tests/run.sh finds a lane with
  # `find -type f`, which never matches a symlink.
  local parent dest links
  parent="$(make_scratch)"
  run_cli --dry-run --no-remote --out "${parent}" --template-dir "${TEMPLATE}" \
    --owner testowner --lane shell --lane python demo
  [ "${status}" -eq 0 ] || fail "the render must succeed, got ${status}: ${output}"

  dest="${parent}/demo"
  links="$(find "${dest}" -type l | wc -l | tr -d ' ')"
  assert_eq "no symlink survives the render" "0" "${links}"
  [ -f "${dest}/tests/python/test_cli.py" ] || fail "the python lane did not land as a file"
  [ -L "${dest}/tests/python/test_cli.py" ] && fail "the lane file is a symlink"
  run bash "${dest}/tests/run.sh" --lanes
  assert_eq "both lanes are discoverable" "$(printf 'shell\npython')" "${output}"
}

@test "new-repo: the rendered dispatcher reports exactly the lanes that were rendered" {
  local parent dest
  for lane in shell python; do
    parent="$(make_scratch)"
    run_cli --dry-run --no-remote --out "${parent}" --template-dir "${TEMPLATE}" \
      --owner testowner --lane "${lane}" demo-tool
    [ "${status}" -eq 0 ] || fail "the ${lane} render must succeed, got ${status}: ${output}"
    dest="${parent}/demo-tool"
    run bash "${dest}/tests/run.sh" --lanes
    assert_eq "a ${lane}-only render reports one lane" "${lane}" "${output}"
  done
}
