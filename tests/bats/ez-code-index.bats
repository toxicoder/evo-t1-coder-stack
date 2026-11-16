#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## ez-code-index.bats - the local code index files its pair beside the notes
# file, and every number and path it prints is true.
#
# templates/common/ez-code-index.code_index.py turns one clone into two artifacts
# under <home>/.grok/notes/<host>/<owner>/<repo>/: code-index.json for a program
# and code-index.md for a person, the pair the ez-code-index runbook tells the
# next session to read instead of grepping the tree again. Both are seeded onto
# the shared profile volume every one of that owner's workspaces mounts, so a map
# written to the wrong path is a map nobody ever loads, and a wrong number inside
# it is worse than no map: a parent reads the digest, writes a brief from it, and
# a child edits the file the index claimed the symbol was in.
#
# None of it fails loudly. A pair written inside the clone dirties git status in
# every workspace and needs an ignore rule nobody added. A second run that
# appended instead of replacing would grow the page forever under a sha banner
# naming a commit the rows did not come from, which is the one thing the runbook
# tells a reader to price the index against. A cap that dropped rows silently
# reads exactly like a tree that small. An excluded path coming back is one grep
# of glob order away -- the program comments on ripgrep being last-rule-wins --
# and would put vendored code into the map a fleet then trusts. And a recorded
# line that does not hold the symbol it names breaks the only check the runbook
# asks of a skeptic, so it is checked here the same way: against the file.
#
# Usage: bazelisk test //tests:bats_ez_code_index_test   (from any cwd)
# Safety: hermetic. Each test builds its own throwaway clone and its own scratch
# profile home under BATS_TEST_TMPDIR, exports GIT_CONFIG_GLOBAL,
# GIT_CONFIG_SYSTEM and a fixture identity, and points --home at that scratch
# home, so nothing is read from or written to the real $HOME or the real git
# config. No network, no docker, no Bazel. The fixture plants one dotenv file
# only to prove the indexer never reads it: no test here opens it.

bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper'

  REPO_ROOT="$(bats_canonical_repo_root)" || return 1
  COMMON="${REPO_ROOT}/templates/common"
  PY="${COMMON}/ez-code-index.code_index.py"
  SKILL="${COMMON}/ez-code-index.SKILL.md"

  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
  command -v git >/dev/null 2>&1 || skip "git is not installed"
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"

  # Nothing in a fixture may read or write this machine's git identity or config.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=bats GIT_AUTHOR_EMAIL=bats@example.invalid
  export GIT_COMMITTER_NAME=bats GIT_COMMITTER_EMAIL=bats@example.invalid

  HOME_DIR="${BATS_TEST_TMPDIR}/home"
  STDERR_FILE="${BATS_TEST_TMPDIR}/stderr.txt"
  KEY="github.com/example/fixture"
  mkdir -p "${HOME_DIR}"

  FIXTURE="$(fixture_repo clone)" || return 1
  git_init_repo "${FIXTURE}" https://github.com/example/fixture.git || return 1
  git_commit_tree "${FIXTURE}" || return 1
}

# The dotenv file the fixture plants. Its name is assembled rather than written
# out: the agent deny rule that shields an operator's real dotenv files matches
# that path form in a command line, and a fixture has no business tripping it.
# The indexer skips the same shape by basename, which is what the skip test
# asserts, so the literal never has to appear here.
DOTENV_NAME="$(printf '.%s' 'env')"

# fixture_repo <name> -- write one throwaway tree under this test's scratch dir
# and print its path. It holds one file per language the indexer claims, plus the
# four paths its skip list is supposed to keep out. No git yet: the exit-1 arms
# each need a directory in one of the three states that is not indexable.
fixture_repo() {
  local dir="${BATS_TEST_TMPDIR}/$1"
  mkdir -p "${dir}/app" "${dir}/scripts/lib" "${dir}/pkg" \
    "${dir}/node_modules/pack" "${dir}/__pycache__" "${dir}/assets" || return 1

  cat >"${dir}/app/models.py" <<'FIX_PY'
"""One module of the fixture clone."""
class IndexRecord:
    pass


def build_record():
    return 1


class _Helper:
    pass
FIX_PY

  cat >"${dir}/scripts/lib/tools.sh" <<'FIX_SH'
#!/usr/bin/env bash
# @function fixture_helper_fn
fixture_helper_fn() {
  printf 'x\n'
}

plain_shell_fn() {
  :
}
FIX_SH

  cat >"${dir}/pkg/BUILD.bazel" <<'FIX_BZ'
filegroup(
    name = "fixture_data",
)

py_library(
    name = "fixture_lib",
)
FIX_BZ

  printf '# the fixture clone\n' >"${dir}/README.md"
  printf 'INDEXER_FIXTURE_MARKER=1\n' >"${dir}/${DOTENV_NAME}"
  printf 'export const packedThing = 1\n' >"${dir}/node_modules/pack/index.js"
  printf 'class CompiledCacheStub:\n    pass\n' >"${dir}/__pycache__/generated.py"
  printf 'export const minifiedThing = 1\n' >"${dir}/assets/tiny.min.js"
  printf '%s' "${dir}"
}

# git_init_repo <dir> <url> -- make it a clone with the origin the key comes from.
git_init_repo() {
  git init -q "$1" >/dev/null 2>&1 || { printf 'FAIL: git init failed in %s\n' "$1" >&2; return 1; }
  git -C "$1" remote add origin "$2" || { printf 'FAIL: git remote add failed in %s\n' "$1" >&2; return 1; }
}

# git_commit_tree <dir> -- one commit, so rev-parse HEAD answers with a sha.
git_commit_tree() {
  git -C "$1" add -A >/dev/null 2>&1 || { printf 'FAIL: git add failed in %s\n' "$1" >&2; return 1; }
  git -C "$1" commit -qm 'fixture: seed the tree' >/dev/null 2>&1 ||
    { printf 'FAIL: git commit failed in %s\n' "$1" >&2; return 1; }
}

# run_index <args...> -- one run. stdout in index_out, stderr in index_err, status
# in index_rc. The exit code is a result here, not a failure, so it is folded into
# the assignment: under 1.5.0 a command substitution that returns non-zero ends
# the test before the assertion that reads the status can run.
run_index() {
  index_out="$(python3 "${PY}" "$@" 2>"${STDERR_FILE}")" && index_rc=0 || index_rc=$?
  index_err="$(cat "${STDERR_FILE}")"
  return 0
}

# run_index_path <bin dir> <args...> -- the same run with <bin dir> first on
# PATH, which is how a test shadows rg without touching anything else.
run_index_path() {
  local bin="$1"
  shift
  index_out="$(env PATH="${bin}:${PATH}" python3 "${PY}" "$@" 2>"${STDERR_FILE}")" &&
    index_rc=0 || index_rc=$?
  index_err="$(cat "${STDERR_FILE}")"
  return 0
}

# notes_dir <home> [key] / json_of / md_of -- where the pair lands for one key.
notes_dir() {
  printf '%s' "${1}/.grok/notes/${2:-${KEY}}"
}

json_of() {
  printf '%s' "$(notes_dir "$1" "${2:-${KEY}}")/code-index.json"
}

md_of() {
  printf '%s' "$(notes_dir "$1" "${2:-${KEY}}")/code-index.md"
}

# has_line <haystack> <needle> -- fixed-string membership, so a caller can name
# the thing that is missing in its own failure line.
has_line() {
  printf '%s\n' "$1" | grep -qF -- "$2"
}

# listed_paths <json> -- the file map, one path per line. Guarded because the
# substitution is an assignment: a jq failure there would end the test before the
# caller got to say which file it could not read.
listed_paths() {
  local out
  out="$(jq -r '.files[].path' "$1" 2>/dev/null | LC_ALL=C sort || true)"
  printf '%s' "${out}"
}

# count_of <json> <jq filter> -- one number out of the record, or empty.
count_of() {
  local out
  out="$(jq -r "$2" "$1" 2>/dev/null || true)"
  printf '%s' "${out}"
}

# rows_of <json> -- every symbol row as name, path, line, tab separated.
rows_of() {
  local out
  out="$(jq -r '.symbols[] | "\(.name)\t\(.path)\t\(.line)"' "$1" 2>/dev/null || true)"
  printf '%s' "${out}"
}

# expect_indexable_error <label> <dir> -- the clone is not indexable: exit 1, a
# reason on stderr, and no pair written into the home.
expect_indexable_error() {
  run_index --repo "$2" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 1 ] || {
    printf 'FAIL: %s exited %s, and the contract says 1: %s\n' \
      "$1" "${index_rc}" "${index_err}" >&2
    return 1; }
  has_line "${index_err}" "error:" || {
    printf 'FAIL: %s exited 1 without naming its reason on stderr\n' "$1" >&2
    return 1; }
  [ ! -e "${HOME_DIR}/.grok" ] || {
    printf 'FAIL: %s exited 1 and still wrote a notes tree into the home\n' "$1" >&2
    return 1; }
}

# expect_usage_error <label> <args...> -- a broken command line, which the exit
# codes have to keep distinct from an unindexable clone.
expect_usage_error() {
  local label="$1"
  shift
  run_index "$@"
  [ "${index_rc}" -eq 2 ] || {
    printf 'FAIL: %s exited %s, and the contract says 2 for a usage error: %s\n' \
      "${label}" "${index_rc}" "${index_err}" >&2
    return 1; }
  [ -n "${index_err}" ] || {
    printf 'FAIL: %s exited 2 in silence; a caller cannot tell the four arms apart\n' "${label}" >&2
    return 1; }
}

# The id prefixes a cloud provider answers to. LiteLLM over the local boxes is the
# only transport this stack has, so one of these in a seeded payload names a lane
# no box serves.
CLOUD_TOKENS=(gpt- claude gemini mistral ollama/ openai/ anthropic)

# ---------------------------------------------------------------------------
# The two payloads themselves.
# ---------------------------------------------------------------------------

@test "payloads: the program and the runbook ship, stay ASCII, and carry the marker" {
  # The runbook is what makes a person run the program, and the program is what
  # makes the runbook true; either one missing leaves a slash command that
  # promises an index nobody builds. The marker is provenance: a seeded copy that
  # lost it is treated as operator-owned and never refreshed again. And every
  # consumer reads both as text a parser reads, so a curly quote or an en dash
  # survives into the seeded file as mojibake and breaks a byte-wise comparison.
  local path stray
  for path in "${PY}" "${SKILL}"; do
    assert_file_exists "the payload ships" "${path}"
    [ -s "${path}" ] || { printf 'FAIL: %s exists but is empty\n' "${path}" >&2; return 1; }
    assert_contains_file "the payload carries the stack marker" "${path}" \
      'managed-by: evo-t1-coder-stack'
    stray="$(LC_ALL=C grep -n '[^ -~]' "${path}" || true)"
    [ -z "${stray}" ] || { printf 'FAIL: %s holds a non-ASCII or control byte:\n%s\n' "${path}" "${stray}" >&2; return 1; }
  done

  # A program that does not parse is an index that never gets built, and the
  # failure is a traceback in a session that expected a map.
  run python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "${PY}"
  [ "${status}" -eq 0 ] || { printf 'FAIL: %s does not parse as Python: %s\n' "${PY}" "${output}" >&2; return 1; }
}

@test "payloads: neither names a cloud model id" {
  # The helper runs everything locally, and the runbook is read by a parent that
  # would paste whatever id it found straight into a spawn. An id the alias table
  # does not serve is not a boot failure: the fan-out simply dies mid-run.
  local path token n
  for path in "${PY}" "${SKILL}"; do
    for token in "${CLOUD_TOKENS[@]}"; do
      n="$(grep -cF -- "${token}" "${path}" || true)"
      assert_eq "$(basename "${path}") names no ${token} model id" "0" "${n}"
    done
  done
}

@test "skill: the runbook names exactly the flags the program declares" {
  # The prose is the interface a person reads. A flag the runbook documents that
  # argparse never declared teaches a command line that dies on exit 2, and a flag
  # the program takes that the runbook dropped is a capability no session ever
  # uses -- --home above all, because every gate here depends on it existing.
  local declared found
  declared="$(grep -oE 'add_argument\("--[a-z][a-z-]*"' "${PY}" |
    sed -E 's/.*"--([a-z-]+)".*/--\1/' | LC_ALL=C sort -u || true)"
  [ -n "${declared}" ] || { printf 'FAIL: %s declares no --flag argument, so its parser is unreadable\n' "${PY}" >&2; return 1; }

  while IFS= read -r found; do
    [ -n "${found}" ] || continue
    grep -qF -- "${found}" "${SKILL}" || {
      printf 'FAIL: %s takes %s but the runbook never names it\n' "${PY}" "${found}" >&2
      return 1; }
  done <<<"${declared}"

  while IFS= read -r found; do
    [ -n "${found}" ] || continue
    printf '%s\n' "${declared}" | grep -qxF -- "${found}" || {
      printf 'FAIL: %s documents %s, which the program does not accept\n' "${SKILL}" "${found}" >&2
      return 1; }
  done < <(grep -oE -- '--[a-z][a-z-]*' "${SKILL}" | LC_ALL=C sort -u || true)
}

# ---------------------------------------------------------------------------
# A clean run: what it prints, and above all where it puts the two files.
# ---------------------------------------------------------------------------

@test "index: a clean run prints one summary line and nothing else on stdout" {
  # A session pipes this into something else, so stdout is machine-owned: the one
  # ok: line and no prose. And the path it names has to be the real md path, or
  # the reader goes looking for an index that was never written there.
  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: a well-formed clone exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }
  assert_match "stdout is the one ok line" '^ok: [0-9]+ files, [0-9]+ symbols -> .*code-index\.md$' "${index_out}"

  local nlines
  nlines="$(printf '%s\n' "${index_out}" | wc -l | tr -d ' ' || true)"
  [ "${nlines}" = "1" ] || {
    printf 'FAIL: stdout carries %s lines, and everything after the first is prose a pipe swallows:\n%s\n' \
      "${nlines}" "${index_out}" >&2
    return 1; }
  has_line "${index_out}" "$(md_of "${HOME_DIR}")" || {
    printf 'FAIL: the summary names a path that is not the one written: %s\n' "${index_out}" >&2
    return 1; }
}

@test "index: the pair lands under the notes path and nothing lands in the clone" {
  # This is the whole design. The notes volume is shared across every workspace of
  # one owner, which is what lets one build serve all of them; a pair written
  # beside the code instead is invisible to the next session, dirties git status,
  # and needs an ignore rule in every repository this stack deploys.
  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  local dir strays dirty
  dir="$(notes_dir "${HOME_DIR}")"
  assert_file_exists "the JSON lands beside the notes file" "${dir}/code-index.json"
  assert_file_exists "the markdown lands beside the notes file" "${dir}/code-index.md"

  strays="$(find "${FIXTURE}" -name 'code-index.*' -o -name '*.tmp' | LC_ALL=C sort || true)"
  [ -z "${strays}" ] || { printf 'FAIL: the index wrote into the clone:\n%s\n' "${strays}" >&2; return 1; }
  assert_file_not_exists "the clone holds no notes tree of its own" "${FIXTURE}/.grok"
  dirty="$(git -C "${FIXTURE}" status --porcelain || true)"
  [ -z "${dirty}" ] || { printf 'FAIL: the clone is dirty after one index run:\n%s\n' "${dirty}" >&2; return 1; }
}

@test "index: the JSON carries every pinned key and its counts match its lists" {
  # A parent builds a dispatch table out of these numbers. counts.files
  # disagreeing with the length of files is a map that says it holds more than it
  # does, and a dropped top-level key is a reader that falls back to grepping the
  # whole tree, which is the cost the artifact exists to remove.
  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  local json
  json="$(json_of "${HOME_DIR}")"
  jq -e . "${json}" >/dev/null || { printf 'FAIL: %s is not parseable JSON\n' "${json}" >&2; return 1; }

  jq -e 'has("schema") and has("repo_key") and has("sha") and has("generated") and
         has("tool") and has("tool_version") and has("scanned_with") and
         has("key_source") and has("counts") and has("files") and has("symbols")' \
    "${json}" >/dev/null || {
    printf 'FAIL: %s is missing a pinned top-level key; it holds: %s\n' \
      "${json}" "$(count_of "${json}" 'keys | join(",")')" >&2
    return 1; }

  jq -e '(.schema == 1) and (.tool == "ez-code-index v1") and (.tool_version == "1") and
         (.repo_key == "github.com/example/fixture") and
         (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    "${json}" >/dev/null || {
    printf 'FAIL: %s does not state the pinned schema, tool, key, or a UTC generated stamp\n' "${json}" >&2
    return 1; }

  jq -e '(.counts.files == (.files | length)) and (.counts.symbols == (.symbols | length)) and
         (([.files[].symbols] | add) == (.symbols | length)) and
         (.counts.file_cap == 200) and ((.counts.symbols_capped | type) == "boolean")' \
    "${json}" >/dev/null || {
    printf 'FAIL: %s: counts disagree with the lists they describe: %s\n' \
      "${json}" "$(count_of "${json}" '.counts | @json')" >&2
    return 1; }

  # Every symbol has to belong to a listed file, and each file has to carry its own
  # symbol count, or the per-directory tables and the digests built from them lie.
  jq -e '(([.symbols[].path] - [.files[].path]) | length) == 0' "${json}" >/dev/null || {
    printf 'FAIL: %s lists a symbol in a file the map does not carry\n' "${json}" >&2
    return 1; }
  jq -e '. as $r | [ $r.files[] | . as $f |
        ($f.symbols == ([ $r.symbols[] | select(.path == $f.path) ] | length)) ] | all' \
    "${json}" >/dev/null || {
    printf 'FAIL: %s: a per-file symbol count disagrees with the symbol list\n' "${json}" >&2
    return 1; }

  # The three indexable fixture files, and nothing else, each labelled with the
  # language it was indexed as.
  local listed want
  listed="$(listed_paths "${json}")"
  for want in app/models.py pkg/BUILD.bazel scripts/lib/tools.sh; do
    has_line "${listed}" "${want}" || {
      printf 'FAIL: %s does not index %s; it holds: %s\n' "${json}" "${want}" \
        "$(printf '%s' "${listed}" | tr '\n' ' ')" >&2
      return 1; }
  done
  assert_eq "the map holds exactly the three indexable files" "app/models.py
pkg/BUILD.bazel
scripts/lib/tools.sh" "${listed}"
  assert_eq "a Python file is labelled python" "python" "$(count_of "${json}" '.files[] | select(.path == "app/models.py") | .lang')"
  assert_eq "a BUILD file is labelled bazel" "bazel" "$(count_of "${json}" '.files[] | select(.path == "pkg/BUILD.bazel") | .lang')"
}

@test "index: every recorded path:line holds the symbol it names" {
  # The runbook tells a reader to trust a row only after re-reading it at
  # path:line, and tells a skeptic to do exactly that before it keeps a claim. So
  # every row has to be true against the file, not merely present in the JSON.
  # This is also the only check that the anchored patterns still land on the
  # definition rather than on the line under it.
  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  local json rows n name path line text
  json="$(json_of "${HOME_DIR}")"
  rows="$(rows_of "${json}")"
  n="$(printf '%s\n' "${rows}" | grep -c . || true)"
  [ "${n}" -ge 8 ] || {
    printf 'FAIL: only %s symbols for a fixture holding a class, a def, a tagged function, a plain function, and two targets\n' "${n}" >&2
    return 1; }

  while IFS=$'\t' read -r name path line; do
    [ -n "${name}" ] || continue
    [ -f "${FIXTURE}/${path}" ] || {
      printf 'FAIL: the index points at %s, which is not a file in the clone\n' "${path}" >&2
      return 1; }
    if [ -z "${line}" ] || [ "${line}" -lt 1 ] 2>/dev/null; then
      printf 'FAIL: the row for %s carries no usable line number: [%s]\n' "${name}" "${line}" >&2
      return 1
    fi
    text="$(sed -n "${line}p" "${FIXTURE}/${path}")"
    case "${text}" in
      *"${name}"*) ;;
      *) printf 'FAIL: %s:%s says %s, and that line reads: %s\n' \
        "${path}" "${line}" "${name}" "${text}" >&2
        return 1 ;;
    esac
  done <<<"${rows}"

  # The three spellings the runbook promises by name: a Python class, the shell
  # # @function tag this repo family documents its functions with, and a BUILD
  # target, which is the symbol worth having in this repo family in particular.
  assert_eq "the Python class is a class row" "class app/models.py 2" \
    "$(count_of "${json}" '.symbols[] | select(.name == "IndexRecord") | "\(.kind) \(.path) \(.line)"')"
  assert_eq "the tagged shell function is an @function row" "@function scripts/lib/tools.sh 2" \
    "$(count_of "${json}" '.symbols[] | select(.kind == "@function") | "\(.kind) \(.path) \(.line)"')"
  assert_eq "the BUILD target is a target row" "target pkg/BUILD.bazel 2" \
    "$(count_of "${json}" '.symbols[] | select(.name == "fixture_data") | "\(.kind) \(.path) \(.line)"')"
}

@test "index: the markdown banner records the sha a reader compares with HEAD" {
  # The page is a snapshot, and the sha is the only thing that says how old it is:
  # the runbook pairs the sha row with git rev-parse HEAD and calls the map a hint
  # when they differ. A banner that lost the row, or that recorded a sha which is
  # not HEAD, leaves every later session reading a stale map it cannot price.
  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  local md sha
  md="$(md_of "${HOME_DIR}")"
  sha="$(git -C "${FIXTURE}" rev-parse HEAD || true)"
  [ -n "${sha}" ] || { printf 'FAIL: the fixture has no HEAD for the banner to be compared against\n' >&2; return 1; }

  assert_eq "the page opens with the version banner" "<!-- ez-code-index v1 -->" "$(head -n 1 "${md}")"
  assert_contains_file "the page titles itself with the repo key" "${md}" \
    '^# Code index: github\.com/example/fixture$'
  assert_contains_file "the banner records the commit the index was built at" "${md}" \
    "^- sha: ${sha}\$"
  assert_contains_file "the banner records what it counted" "${md}" '^- files: 3$'
  assert_contains_file "the banner records where the key came from" "${md}" '^- key_source: '
  assert_contains_file "the banner records how the tree was read" "${md}" '^- scanned_with: '
  assert_contains_file "the page tells the reader to price the sha" "${md}" \
    'git rev-parse HEAD'

  # The same sha in both artifacts, or the page and the record disagree about which
  # commit the rows came from and only one of them can be right.
  assert_eq "the JSON records the same sha as the page" "${sha}" \
    "$(count_of "$(json_of "${HOME_DIR}")" '.sha')"
}

@test "index: a second run replaces the pair instead of appending to it" {
  # The helper runs once per session and again whenever a map reads as stale, so
  # re-running is the normal path, not an edge. Written by append, the page grows
  # without bound and carries rows from two commits under one sha banner; written
  # by temp-then-rename it is the same page rebuilt. A leftover temp file is the
  # half of that seam that failed: a reader would then hold two candidate indexes.
  local md json first second leftovers
  md="$(md_of "${HOME_DIR}")"
  json="$(json_of "${HOME_DIR}")"

  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: first run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }
  first="$(grep -v '^- generated:' "${md}" || true)"

  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: second run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }
  second="$(grep -v '^- generated:' "${md}" || true)"
  assert_eq "the rebuilt page is the page, not the page twice" "${first}" "${second}"

  local rows
  rows="$(grep -c 'ez-code-index v1 -->' "${md}" || true)"
  assert_eq "one banner in the page" "1" "${rows}"
  rows="$(grep -c '^- sha:' "${md}" || true)"
  assert_eq "one sha row in the page" "1" "${rows}"

  jq -e '(.counts.files == 3) and (.counts.files == (.files | length)) and
         (.counts.symbols == (.symbols | length))' "${json}" >/dev/null || {
    printf 'FAIL: the rebuilt JSON disagrees with its own lists: %s\n' \
      "$(count_of "${json}" '.counts | @json')" >&2
    return 1; }

  leftovers="$(find "$(notes_dir "${HOME_DIR}")" -name '*.tmp' | LC_ALL=C sort || true)"
  [ -z "${leftovers}" ] || { printf 'FAIL: the atomic write left a temp file beside the pair:\n%s\n' "${leftovers}" >&2; return 1; }
}

@test "index: --json prints the record on stdout and keeps its prose on stderr" {
  # A caller piping this into jq gets a parse error or, worse, silently truncated
  # input the moment a note is printed into the stream. So stdout is JSON and
  # nothing else, and the note the run has to report still reaches a human.
  run_index --repo "${FIXTURE}" --home "${HOME_DIR}" --json
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: --json exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  printf '%s' "${index_out}" | jq -e . >/dev/null || {
    printf 'FAIL: stdout of --json is not parseable JSON: %s\n' "${index_out}" >&2
    return 1; }
  assert_not_match "stdout of --json carries no note line" '^note:' "${index_out}"
  assert_not_match "stdout of --json carries no error line" '^error:' "${index_out}"
  assert_not_match "stdout of --json carries no summary line" '^ok:' "${index_out}"
  has_line "${index_err}" "keying from the origin remote parsed here" || {
    printf 'FAIL: the note about deriving the key never reached stderr: %s\n' "${index_err}" >&2
    return 1; }

  # What was printed is what was written: one record, two channels, no drift.
  assert_eq "--json prints the record the JSON file holds" \
    "$(jq -S . "$(json_of "${HOME_DIR}")")" "$(printf '%s' "${index_out}" | jq -S .)"
}

@test "index: the skip list keeps vendored, generated, dotenv, and minified files out" {
  # With one positive glob present, ripgrep re-admits a file an exclusion named
  # earlier -- the program comments on last-rule-wins and on the glob order being
  # load-bearing. The day an exclusion moves above an inclusion, node_modules and
  # a minified bundle come back into the map and a fleet reads vendored code as
  # the project. The dotenv file is the path the agent is denied outright: an
  # index that listed it would put its contents one read away.
  command -v rg >/dev/null 2>&1 || skip "rg is not on PATH, so the glob order under test is not exercised"

  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  local json listed plant
  json="$(json_of "${HOME_DIR}")"
  assert_eq "rg listed the tree" "rg" "$(count_of "${json}" '.scanned_with')"
  listed="$(listed_paths "${json}")"
  for plant in "${DOTENV_NAME}" node_modules/pack/index.js __pycache__/generated.py \
    assets/tiny.min.js; do
    if has_line "${listed}" "${plant}"; then
      printf 'FAIL: %s indexed %s, which the skip list exists to exclude\n' "${json}" "${plant}" >&2
      return 1
    fi
  done
  if printf '%s' "${listed}" | grep -qF -- 'assets'; then
    printf 'FAIL: %s indexed anything under assets; the minified bundle came back\n' "${json}" >&2
    return 1
  fi
}

@test "index: a failing rg falls back to the walk and still indexes the tree" {
  # rg is in the golden image and nowhere else is it promised, so the os.walk path
  # is not dead code: it is the path a laptop and a bare box take. If the two
  # agreed on nothing else they would at least have to agree on this tree, or the
  # same clone maps differently per machine; and if the fallback failed outright,
  # the runbook would be an instruction that only works on one image.
  local bin="${BATS_TEST_TMPDIR}/stubbin"
  mkdir -p "${bin}"
  printf '#!/bin/sh\nexit 2\n' >"${bin}/rg"
  chmod 755 "${bin}/rg"

  run_index_path "${bin}" --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: with rg failing the run exited %s instead of walking: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  local json how
  json="$(json_of "${HOME_DIR}")"
  how="$(count_of "${json}" '.scanned_with')"
  case "${how}" in
    "os.walk fallback"*) ;;
    *) printf 'FAIL: with rg exiting 2 the map claims it was scanned by: %s\n' "${how}" >&2; return 1 ;;
  esac
  has_line "${index_err}" "os.walk" || {
    printf 'FAIL: the fallback ran without saying so on stderr: %s\n' "${index_err}" >&2
    return 1; }
  assert_eq "the walk indexes the same three files" "3" "$(count_of "${json}" '.counts.files')"
  assert_eq "the walk finds the Python class" "IndexRecord" \
    "$(count_of "${json}" '[.symbols[] | select(.kind == "class") | .name] | sort | .[0]')"
}

@test "index: --limit caps the symbol list, says so, and records the cap" {
  # The caps are the point of the artifact, and a cap that dropped rows quietly is
  # how a partial map starts reading as the whole tree. The run has to say it
  # capped -- on stderr, in the page, and in counts -- or a parent dispatches off
  # half a map it believes complete.
  run_index --repo "${FIXTURE}" --home "${HOME_DIR}" --limit 3
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: --limit 3 exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }
  has_line "${index_err}" "capped the symbol list at 3 of " || {
    printf 'FAIL: a run that capped never said so on stderr: %s\n' "${index_err}" >&2
    return 1; }

  local json
  json="$(json_of "${HOME_DIR}")"
  assert_eq "the cap honoured the number it was given" "3" "$(count_of "${json}" '.symbols | length')"
  assert_eq "counts.symbols reports the capped length" "3" "$(count_of "${json}" '.counts.symbols')"
  assert_eq "counts keeps the cap that bit" "3" "$(count_of "${json}" '.counts.symbol_cap')"
  assert_eq "counts says the symbol list was capped" "true" "$(count_of "${json}" '.counts.symbols_capped')"
  assert_contains_file "the page states the cap" "$(md_of "${HOME_DIR}")" \
    '^- symbols: 3 indexed \(cap 3\)$'
}

@test "index: the file map caps at 200 and spreads the kept rows over the top dirs" {
  # Two claims in one, because they fail together. The file cap is a constant and
  # not a flag, so nothing else ever prints that note; and the kept 200 have to be
  # interleaved across the top directories, because a plain sort spends the whole
  # budget on whichever directory sorts first and hands the reader a map of one
  # corner of the tree.
  local big="${BATS_TEST_TMPDIR}/big" d i
  mkdir -p "${big}"
  for d in 01 02 03 04 05 06 07 08; do
    mkdir -p "${big}/d${d}"
    for i in $(seq -w 1 30); do
      printf 'def fn_%s_%s():\n    return 1\n' "${d}" "${i}" >"${big}/d${d}/f${i}.py"
    done
  done
  git_init_repo "${big}" https://github.com/example/big.git || return 1
  git_commit_tree "${big}" || return 1

  run_index --repo "${big}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: the wide clone exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }
  has_line "${index_err}" "capped the file map at 200 of 240 indexable files" || {
    printf 'FAIL: a run that dropped 40 files never said so on stderr: %s\n' "${index_err}" >&2
    return 1; }

  local json dirs_hit
  json="$(json_of "${HOME_DIR}" github.com/example/big)"
  assert_eq "the file map stops at the cap" "200" "$(count_of "${json}" '.counts.files')"
  assert_eq "counts says the file map was capped" "true" "$(count_of "${json}" '.counts.files_capped')"
  dirs_hit="$(jq -r '.files[].path' "${json}" 2>/dev/null | cut -d/ -f1 | LC_ALL=C sort -u | tr '\n' ' ' || true)"
  assert_eq "the cap kept a slice of every top directory" \
    "d01 d02 d03 d04 d05 d06 d07 d08 " "${dirs_hit}"
  assert_contains_file "the page states the file cap" \
    "$(md_of "${HOME_DIR}" github.com/example/big)" '^- files: 200 indexed \(cap 200\)$'
}

@test "index: --home moves the pair to another profile home" {
  # Every home-derived path goes through this flag and never the environment,
  # which is what lets a gate like this one run at all -- and what lets an
  # operator index for a profile other than the one the shell booted with. If the
  # flag were ignored, a test run would drop its pair into the real notes volume.
  local other="${BATS_TEST_TMPDIR}/other"
  mkdir -p "${other}"

  run_index --repo "${FIXTURE}" --home "${HOME_DIR}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  run_index --repo "${FIXTURE}" --home "${other}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run against the second home exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  assert_file_exists "the second home holds the JSON" "$(json_of "${other}")"
  assert_file_exists "the second home holds the page" "$(md_of "${other}")"
  has_line "${index_out}" "$(md_of "${other}")" || {
    printf 'FAIL: the summary still names the first home: %s\n' "${index_out}" >&2
    return 1; }
  assert_file_exists "the first home keeps its own copy" "$(md_of "${HOME_DIR}")"
}

@test "index: notes_repo_key in notes-setup.sh files the pair beside the notes" {
  # The key is not this program invention: notes_repo_key is the rule of record
  # for where an owner notes file lives, and the index has to land next to it. Ask
  # it wrong, and the map is filed where the next session never looks while the
  # notes file sits alone with no map beside it.
  local keyed="${BATS_TEST_TMPDIR}/keyed"
  mkdir -p "${keyed}/.grok"
  cat >"${keyed}/.grok/notes-setup.sh" <<'FIX_SETUP'
# shellcheck shell=bash
notes_repo_key() {
  printf '%s\n' "acme/tools/thing"
}
FIX_SETUP

  run_index --repo "${FIXTURE}" --home "${keyed}"
  [ "${index_rc}" -eq 0 ] || { printf 'FAIL: run exited %s: %s\n' "${index_rc}" "${index_err}" >&2; return 1; }

  assert_file_exists "the pair follows the notes key into acme/tools/thing" \
    "$(json_of "${keyed}" acme/tools/thing)"
  assert_file_exists "the page follows it too" "$(md_of "${keyed}" acme/tools/thing)"
  assert_eq "the key came from notes-setup.sh" "acme/tools/thing" \
    "$(count_of "$(json_of "${keyed}" acme/tools/thing)" '.repo_key')"
  assert_contains_file "the banner names notes-setup.sh as the key source" \
    "$(md_of "${keyed}" acme/tools/thing)" '^- key_source: .*notes-setup\.sh'
  assert_not_match "a run that asked notes-setup.sh says nothing about deriving the key" \
    'keying from the origin remote parsed here' "${index_err}"
}

@test "index: exit 1 when the clone is not indexable, and it writes nothing" {
  # The three states mean one thing: there is no sha to price the map against or no
  # remote to take the key from, so an artifact written anyway would be a map filed
  # under a made-up key. Exit 1 with its reason is a finding to report; a
  # half-written pair is a map someone then trusts.
  local plain="${BATS_TEST_TMPDIR}/plain" noc="${BATS_TEST_TMPDIR}/no-commit" \
    noremote="${BATS_TEST_TMPDIR}/no-remote" dir
  mkdir -p "${plain}" "${noc}" "${noremote}"
  printf 'def plain_fn():\n    return 1\n' >"${plain}/plain.py"
  if [ "$(git -C "${plain}" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ]; then
    skip "the scratch dir sits inside a git work tree, so a plain directory is not one here"
  fi

  for dir in "${noc}" "${noremote}"; do
    printf 'def fn():\n    return 1\n' >"${dir}/one.py"
    git init -q "${dir}" >/dev/null 2>&1 || { printf 'FAIL: git init failed in %s\n' "${dir}" >&2; return 1; }
  done
  # Only the no-commit arm gets the remote: it has to fail for want of a sha and
  # nothing else. The no-remote arm keeps no origin, which is the state under test.
  git -C "${noc}" remote add origin https://github.com/example/later.git || {
    printf 'FAIL: git remote add failed in %s\n' "${noc}" >&2
    return 1; }
  git_commit_tree "${noremote}" || return 1

  expect_indexable_error "a directory that is not a git tree" "${plain}"
  expect_indexable_error "a git tree with no commit yet" "${noc}"
  expect_indexable_error "a clone with no origin remote" "${noremote}"
}

@test "index: exit 2 on a usage error" {
  # A usage error is not a clone that cannot be indexed, and a caller that cannot
  # tell the two apart reports a broken repository when it has a broken command
  # line. Missing --repo, a path that is not a directory, a cap below 1, and a
  # home that does not exist are the four ways to get there.
  expect_usage_error "no --repo at all" --home "${HOME_DIR}"
  expect_usage_error "a clone path that is no directory" --repo "${BATS_TEST_TMPDIR}/absent" --home "${HOME_DIR}"
  expect_usage_error "a cap below 1" --repo "${FIXTURE}" --home "${HOME_DIR}" --limit 0
  expect_usage_error "a home that does not exist" --repo "${FIXTURE}" --home "${BATS_TEST_TMPDIR}/absent-home"

  # The missing-flag arm has to name the flag, or exit 2 says nothing useful.
  run_index --home "${HOME_DIR}"
  has_line "${index_err}" "--repo" || {
    printf 'FAIL: a run with no --repo did not say which flag was missing: %s\n' "${index_err}" >&2
    return 1; }
}
