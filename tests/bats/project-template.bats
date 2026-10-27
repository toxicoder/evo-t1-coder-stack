#!/usr/bin/env bats
#
# ## project-template.bats - hermetic self-check of the scaffold payload
#
# project-template/ is source that is never executed here: a CLI copies it, renames
# files inside it and substitutes tokens before any of it runs. That leaves a whole
# class of defect that no other suite in this repo can see - a placeholder nobody
# substitutes, a lane overlay with no metadata, a pin a script asks for that the pin
# file never defines, a gate that reports green while doing nothing. Each test below
# pins one of those.
#
# Usage: bazelisk test //tests:bats_project_template_test   (from any cwd)
# Safety: reads project-template/ and scripts/new-repo.sh; writes nothing outside the
# per-test scratch tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
TPL=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  TPL="${REPO_ROOT}/project-template"
  if [ ! -d "${TPL}" ]; then
    skip "project-template/ is not in the tree"
  fi
}

# ---- structure ---------------------------------------------------------------

@test "payload carries every file that is always rendered" {
  local -a required=(
    README.md AGENTS.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md
    LICENSE template.yml Makefile Dockerfile Dockerfile.test tool-versions.env
    env.example .editorconfig .gitattributes .gitignore .gitleaks.toml
    .pre-commit-config.yaml .yamllint.yml
    .github/CODEOWNERS .github/dependabot.yml .github/PULL_REQUEST_TEMPLATE.md
    .github/ISSUE_TEMPLATE/bug_report.md .github/ISSUE_TEMPLATE/feature_request.md
    .github/ISSUE_TEMPLATE/config.yml
    .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/security.yml
    docs/README.md src/README.md tests/run.sh
  )
  local -a missing=()
  local f
  for f in "${required[@]}"; do
    [ -f "${TPL}/${f}" ] || missing+=("${f}")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    fail "project-template is missing: ${missing[*]}"
  fi
}

@test "every render token in the payload is one the CLI substitutes" {
  # A typo'd token survives rendering as literal text in the customer's new repo, so
  # the only tokens allowed here are the seven the CLI knows plus python/bazel dunder
  # names that merely look like placeholders. Both spellings are checked: a markdown
  # file cannot hold the canonical form outside a code span, because prettier reads
  # __NAME__ as strong emphasis and rewrites it to **NAME**, which is why the CLI
  # substitutes that alias too.
  local unknown
  unknown="$(grep -RhoE '__[A-Za-z_][A-Za-z0-9_]*__' "${TPL}" \
    | grep -vE '^__PROJECT_(NAME|SLUG|MODULE|DESCRIPTION|OWNER|LICENSE_HOLDER|YEAR)__' \
    | grep -vE '^__(version|pycache|main|name|future|init|all|pkg|builtins|doc|file|class|module|dict)__' \
    | sort -u)"
  [ -z "${unknown}" ] || fail "tokens the renderer will never substitute: $(echo "${unknown}" | tr '\n' ' ')"

  unknown="$(grep -RhoE '\*\*PROJECT_[A-Z_]+\*\*' "${TPL}" \
    | grep -vE '^\*\*PROJECT_(NAME|SLUG|MODULE|DESCRIPTION|OWNER|LICENSE_HOLDER|YEAR)\*\*$' \
    | sort -u)"
  [ -z "${unknown}" ] ||
    fail "markdown token spellings the renderer will never substitute: $(echo "${unknown}" | tr '\n' ' ')"
}

@test "the lanes on disk are exactly the lanes the CLI offers" {
  local offered
  offered="$(sed -n 's/^readonly NEW_REPO_LANES=(\(.*\))$/\1/p' "${REPO_ROOT}/scripts/new-repo.sh")"
  [ -n "${offered}" ] || fail "scripts/new-repo.sh no longer declares NEW_REPO_LANES in the shape this suite reads"

  local -a on_disk=()
  local d
  for d in "${TPL}/.evo-lanes"/*/; do
    [ -d "${d}" ] || continue
    on_disk+=("$(basename "${d}")")
  done
  [ "${#on_disk[@]}" -gt 0 ] || fail "no lane directory under project-template/.evo-lanes"

  local want got
  want="$(printf '%s\n' ${offered} | sort)"
  got="$(printf '%s\n' "${on_disk[@]}" | sort)"
  [ "${want}" = "${got}" ] || fail "CLI offers [$(echo "${want}" | tr '\n' ' ')] but .evo-lanes holds [$(echo "${got}" | tr '\n' ' ')]"
}

@test "each lane ships the metadata pair the renderer strips" {
  local lane
  for lane in "${TPL}/.evo-lanes"/*/; do
    [ -d "${lane}" ] || continue
    local name
    name="$(basename "${lane}")"
    [ -f "${lane}LANE.md" ] || fail "lane ${name} has no LANE.md, so the operator cannot see what it installs"
    [ -f "${lane}gitignore.fragment" ] || fail "lane ${name} has no gitignore.fragment, so its build junk lands in git"
  done
}

@test "the env twin is stored undotted and renders dotted" {
  # The agent policy in this stack denies edits matching **/.env.*, which also denies a
  # template twin, so the payload spells the file env.example and new-repo.sh renames it.
  [ -f "${TPL}/env.example" ] || fail "env.example is absent; the renderer's rename has nothing to rename"
  [ ! -e "${TPL}/.env.example" ] || fail ".env.example must not be tracked here: the CLI renames env.example into that name"
}

@test "no build artifact is committed into the payload" {
  local junk
  junk="$(find -L "${TPL}" \( -name '__pycache__' -o -name '*.pyc' -o -name 'node_modules' \
    -o -name 'package-lock.json' -o -name '.pytest_cache' -o -name '.ruff_cache' \
    -o -name '.mypy_cache' -o -name 'coverage' -o -name 'coverage.out' \) -print | sort)"
  [ -z "${junk}" ] || fail "derived artifacts in a template tree: ${junk}"
}

# ---- executable sources ------------------------------------------------------

@test "every shell source in the payload parses" {
  local -a broken=()
  local f
  while IFS= read -r f; do
    bash -n "${f}" 2>/dev/null || broken+=("${f#"${TPL}/"}")
  done < <(find -L "${TPL}" -type f -name '*.sh' | sort)
  [ "${#broken[@]}" -eq 0 ] || fail "bash -n rejects: ${broken[*]}"
}

@test "no shell source in the payload can swallow a failing check" {
  # `|| exit 0` is the one idiom that turns a gate green without running it. Scoped to
  # the files where it would actually execute, with comment lines dropped, because the
  # house style rules name the literal in order to forbid it.
  local hits
  hits="$(find -L "${TPL}" -type f \( -name '*.sh' -o -name 'Dockerfile*' -o -name 'Makefile' \) -print0 \
    | xargs -0 grep -nE '\|\|[[:space:]]*exit 0' 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  [ -z "${hits}" ] || fail "a check that can silently pass: ${hits}"
}

@test "no dependency or action reference floats" {
  # A moving tag is the other way a gate stops checking: today's green is tomorrow's
  # different green. Pinned at the three places a float can hide in this payload.
  local -a floats=()
  local f
  while IFS= read -r f; do
    grep -nE '^[[:space:]]*(FROM|Image)[[:space:]]+[^ ]+:latest' "${f}" >/dev/null 2>&1 \
      && floats+=("${f#"${TPL}/"}: FROM :latest")
    grep -nE '^[[:space:]]*-?[[:space:]]*(uses|image):[[:space:]]*[^ ]*@latest' "${f}" >/dev/null 2>&1 \
      && floats+=("${f#"${TPL}/"}: uses @latest")
  done < <(find -L "${TPL}" -type f \( -name 'Dockerfile*' -o -name '*.yml' -o -name '*.yaml' \) | sort)

  # devDependencies must be exact: the drift between package.json and
  # tool-versions.env is the bug this template exists to prevent.
  local drift
  drift="$(python3 - "${TPL}/.evo-lanes/typescript/package.json" <<'PY'
import json, re, sys
try:
    deps = json.load(open(sys.argv[1])).get("devDependencies", {})
except FileNotFoundError:
    sys.exit(0)
exact = re.compile(r"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$")
print(" ".join("%s=%s" % kv for kv in deps.items() if not exact.match(kv[1])))
PY
)"
  [ -n "${drift}" ] && floats+=("typescript devDependencies not exact: ${drift}")

  [ "${#floats[@]}" -eq 0 ] || fail "$(printf '%s; ' "${floats[@]}")"
}

# ---- declarative files -------------------------------------------------------

@test "every yaml in the payload parses" {
  local -a bad=()
  local f
  while IFS= read -r f; do
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "${f}" 2>/dev/null \
      || bad+=("${f#"${TPL}/"}")
  done < <(find -L "${TPL}" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
  [ "${#bad[@]}" -eq 0 ] || fail "yaml.safe_load rejects: ${bad[*]}"
}

@test "every workflow declares its permissions and cannot self-approve a failure" {
  local -a workflows=()
  local f
  while IFS= read -r f; do workflows+=("${f}"); done < <(find -L "${TPL}" -type f -path '*/.github/workflows/*.yml' | sort)
  [ "${#workflows[@]}" -ge 4 ] || fail "expected the three core workflows plus at least one lane workflow, found ${#workflows[@]}"
  local -a problems=()
  for f in "${workflows[@]}"; do
    grep -qE '^permissions:' "${f}" || problems+=("${f#"${TPL}/"}: no top-level permissions")
    grep -qE 'continue-on-error:[[:space:]]*true' "${f}" && problems+=("${f#"${TPL}/"}: continue-on-error true")
    grep -qE 'pull_request_target' "${f}" && problems+=("${f#"${TPL}/"}: pull_request_target runs fork code with write tokens")
  done
  [ "${#problems[@]}" -eq 0 ] || fail "$(printf '%s; ' "${problems[@]}")"
}

@test "template.yml is valid and every param offers concrete values" {
  python3 - "${TPL}/template.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert isinstance(doc, dict), "template.yml is not a mapping"
for key in ("name", "description", "params"):
    assert key in doc, "template.yml has no %s" % key
assert isinstance(doc["params"], dict) and doc["params"], "template.yml has no params"
for pid, spec in doc["params"].items():
    values = spec.get("values") if isinstance(spec, dict) else None
    assert isinstance(values, list) and values, "param %s has no values list" % pid
    for v in values:
        assert isinstance(v, str) and v.strip(), "param %s carries an empty example" % pid
PY
}

@test "the secret scanner keeps its upstream rule set" {
  local cfg="${TPL}/.gitleaks.toml"
  grep -qE '^[[:space:]]*useDefault[[:space:]]*=[[:space:]]*true' "${cfg}" \
    || fail ".gitleaks.toml no longer extends the default rules, so the scan checks nothing new"
  ! grep -qE 'regexes[[:space:]]*=[[:space:]]*\[[[:space:]]*"\.\*"' "${cfg}" \
    || fail ".gitleaks.toml allowlists everything with .*"
  grep -qE 'change-me-not-a-real-key' "${TPL}/env.example" \
    || fail "env.example lost the documented placeholder that .gitleaks.toml allowlists"
}

@test "LICENSE carries the holder and year tokens" {
  grep -q '__PROJECT_LICENSE_HOLDER__' "${TPL}/LICENSE" || fail "LICENSE has no holder token to substitute"
  grep -q '__PROJECT_YEAR__' "${TPL}/LICENSE" || fail "LICENSE has no year token to substitute"
}

# ---- pins --------------------------------------------------------------------

@test "every pin the payload asks for is defined in tool-versions.env" {
  # The lookup shapes in this payload: pin_value KEY, require_module mod pkg KEY,
  # $(call NEED,bin,KEY), the devcontainer's required="..." list, and ${KEY:?...}.
  local -a wanted=()
  local key
  while IFS= read -r key; do
    [ -n "${key}" ] && wanted+=("${key}")
  done < <(
    {
      grep -RhoE '\bpin_value +[A-Z0-9_]+(_VERSION)\b' "${TPL}" | awk '{print $2}'
      grep -RhoE '\brequire_module +[A-Za-z0-9_.-]+ +[A-Za-z0-9_.-]+ +[A-Z0-9_]+(_VERSION)\b' "${TPL}" | awk '{print $4}'
      grep -RhoE 'NEED,[a-z0-9-]+,[A-Z0-9_]+(_VERSION)' "${TPL}" | cut -d, -f3
      grep -RhoE 'required="[A-Z0-9_ ]+"' "${TPL}" | sed 's/required="//; s/"//' | tr ' ' '\n'
      grep -RhoE '\$\{[A-Z0-9_]+(_VERSION):[?]' "${TPL}" | sed 's/^\${//; s/[:?]$//'
    } | grep -E '_VERSION$' | sort -u
  )
  [ "${#wanted[@]}" -gt 0 ] || fail "this suite found no pin lookups, so it has stopped testing anything"

  local -a undef=()
  for key in "${wanted[@]}"; do
    grep -qE "^${key}=" "${TPL}/tool-versions.env" || undef+=("${key}")
  done
  [ "${#undef[@]}" -eq 0 ] || fail "asked for but not defined in tool-versions.env: ${undef[*]}"
}

@test "every defined pin is read by something" {
  local -a dead=()
  local key
  while IFS= read -r key; do
    [ -n "${key}" ] || continue
    # A pin nobody reads is a version that silently rots. The key has to appear
    # somewhere other than its own definition line.
    if ! grep -RqE "\b${key}\b" "${TPL}" --exclude=tool-versions.env; then
      dead+=("${key}")
    fi
  done < <(grep -oE '^[A-Z0-9_]+_VERSION' "${TPL}/tool-versions.env")
  [ "${#dead[@]}" -eq 0 ] || fail "defined in tool-versions.env but read by nothing: ${dead[*]}"
}

@test "every pin is a version and not a moving tag" {
  local -a bad=()
  while IFS='=' read -r key value; do
    [[ "${key}" =~ ^[A-Z0-9_]+_VERSION$ ]] || continue
    [[ "${value}" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || bad+=("${key}=${value}")
  done < <(grep -E '^[A-Z0-9_]+=' "${TPL}/tool-versions.env")
  [ "${#bad[@]}" -eq 0 ] || fail "not a plain version string: ${bad[*]}"
}

# ---- prose -------------------------------------------------------------------

@test "relative links in the payload docs resolve" {
  local -a broken=()
  local f target base
  while IFS= read -r f; do
    base="$(dirname "${f}")"
    while IFS= read -r target; do
      [ -n "${target}" ] || continue
      target="${target%%#*}"
      [ -n "${target}" ] || continue
      case "${target}" in
        http://*|https://*|mailto:*|\#*|/*) continue ;;
      esac
      # Angle-bracket and title syntax leftovers, plus tokens that are paths only
      # after rendering.
      [[ "${target}" == *__* ]] && continue
      [ -e "${base}/${target}" ] || broken+=("${f#"${TPL}/"} -> ${target}")
    done < <(grep -ohE '\]\(\.[^)]+\)' "${f}" 2>/dev/null | sed 's/^\](//; s/\)$//')
  done < <(find -L "${TPL}" -type f -name '*.md' | sort)
  [ "${#broken[@]}" -eq 0 ] || fail "dangling relative links: $(printf '%s; ' "${broken[@]}")"
}

@test "the dispatcher lists present lanes without failing on an empty tree" {
  # tests/run.sh --lanes is what make doctor asks for when it decides which pins this
  # checkout may demand. An empty answer has to be a success: an empty tree is a
  # legitimate answer there, unlike in the run path, where it is a failure.
  local scratch="${BATS_TEST_TMPDIR}/lanes"
  mkdir -p "${scratch}/tests"
  cp "${TPL}/tests/run.sh" "${scratch}/tests/run.sh"

  run bash "${scratch}/tests/run.sh" --lanes
  [ "${status}" -eq 0 ] || fail "--lanes must exit 0 on a tree with no lane, got ${status}"
  assert_eq "an empty tree reports no lanes" "" "${output}"

  printf 'module example.com/x\n' >"${scratch}/go.mod"
  printf '{"name":"x"}\n' >"${scratch}/package.json"
  printf '[tool.pytest.ini_options]\n' >"${scratch}/pyproject.toml"
  mkdir -p "${scratch}/tests/python"
  run bash "${scratch}/tests/run.sh" --lanes
  [ "${status}" -eq 0 ]
  assert_eq "each manifest turns its lane on, in KNOWN_LANES order" \
    "$(printf 'python\ntypescript\ngo')" "${output}"

  run bash "${scratch}/tests/run.sh" --lanes --bogus
  [ "${status}" -ne 0 ] || fail "--lanes must still refuse an unknown flag"
}

@test "the doctor demands only the pins of lanes this checkout has" {
  # A shell-only project that cannot start without golangci-lint is a template bug, not
  # a toolchain bug: the doctor scopes each pin by the `# -- <Lane> lane` heading it
  # sits under and skips one whose lane is absent.
  grep -qE -- '--lanes' "${TPL}/Makefile" \
    || fail "the doctor no longer asks tests/run.sh which lanes are present"
  grep -qE "not required" "${TPL}/Makefile" \
    || fail "the doctor lost its skip line for an absent lane's pin"

  # Every lane heading has to name a lane the CLI can render, or the pin under it is
  # unsatisfiable: no render can ever produce that lane's manifest.
  local offered heading lane
  offered="$(sed -n 's/^readonly NEW_REPO_LANES=(\(.*\))$/\1/p' "${REPO_ROOT}/scripts/new-repo.sh")"
  [ -n "${offered}" ] || fail "scripts/new-repo.sh no longer declares NEW_REPO_LANES"
  local -a unknown=()
  while IFS= read -r heading; do
    lane="${heading% lane}"
    lane="$(printf '%s' "${lane}" | tr '[:upper:]' '[:lower:]')"
    if ! printf '%s\n' ${offered} | grep -qxF -- "${lane}"; then
      unknown+=("${heading}")
    fi
  done < <(grep -oE '^# -- [A-Za-z]+ lane' "${TPL}/tool-versions.env" | sed 's/^# -- //')
  [ "${#unknown[@]}" -eq 0 ] ||
    fail "pins are tagged with lanes the CLI cannot render: ${unknown[*]}"

  # And each lane the CLI offers must have a heading, or its pins land under a
  # non-lane heading and every project is made to install them.
  local missing=()
  for lane in ${offered}; do
    grep -qiE "^# -- ${lane} lane" "${TPL}/tool-versions.env" || missing+=("${lane}")
  done
  [ "${#missing[@]}" -eq 0 ] ||
    fail "these lanes have no pin heading, so their tools are always required: ${missing[*]}"
}
