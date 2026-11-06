#!/usr/bin/env bats
#
# ## tf-types.bats — every Terraform input declares a type, and none of them is `any`
#
# A `variable` block is the only place Terraform lets a template declare what an
# input is, and an undeclared one takes whatever HCL guessed: `search_mcp = "flase"`
# then reaches a `== "true"` comparison and reads as false with no diagnostic
# anywhere, which is a wrong workspace rather than a failed plan. //:validate holds
# both template twins to that rule through scripts/lib/tf_types.awk; this suite is
# the assertion side, so the gate cannot be relaxed by deleting its teeth.
#
# The shipped-tree test is the one that matters day to day. The fixture tests are
# here so a future edit to the awk program that stops reporting a broad type fails
# loudly instead of silently widening what the gate accepts.
#
# Usage: bazelisk test //tests:bats_tf_types_test   (from any cwd)
# Safety: no daemon, no network; writes only under the bats temp directory.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
AWK_PROG=""
TEMPLATES=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  AWK_PROG="${REPO_ROOT}/scripts/lib/tf_types.awk"
  TEMPLATES="${REPO_ROOT}/templates"
  [ -f "${AWK_PROG}" ]
}

# tf_fixture <name> — write one HCL file under the bats temp dir and print its path.
tf_fixture() {
  local dir="${BATS_TEST_TMPDIR}/tf"
  mkdir -p "${dir}"
  printf '%s\n' "${dir}/$1"
}

# tf_scan <file...> — run the shipped program the way validate.sh runs it.
tf_scan() {
  run awk -f "${AWK_PROG}" "$@"
  [ "${status}" -eq 0 ]
}

# ── the shipped tree ────────────────────────────────────────────────────────

@test "tf_types: both template twins declare a type on every variable" {
  tf_scan \
    "${TEMPLATES}/workspace/main.tf" \
    "${TEMPLATES}/workspace/coder.tf" \
    "${TEMPLATES}/devcontainer/main.tf" \
    "${TEMPLATES}/devcontainer/coder.tf"
  [ -z "${output}" ]
}

@test "tf_types: the shipped templates use no broad type anywhere" {
  # A second, independent look: the gate's own rule stated in grep, so a change
  # that broke the awk program AND the gate's expectations still shows up here.
  run grep -nE '^[[:space:]]*type[[:space:]]*=[[:space:]]*(any|list\(any\)|set\(any\)|map\(any\)|list|set|map)([[:space:]]|$|[,)])' \
    "${TEMPLATES}/workspace/main.tf" \
    "${TEMPLATES}/workspace/coder.tf" \
    "${TEMPLATES}/devcontainer/main.tf" \
    "${TEMPLATES}/devcontainer/coder.tf"
  [ "${status}" -ne 0 ]
}

@test "validate.sh runs the variable-type gate over all four template files" {
  local vf="${REPO_ROOT}/scripts/validate.sh"
  assert_contains_file "validate.sh names the awk program" "${vf}" 'tf_types.awk'
  assert_contains_file "validate.sh reads the workspace twin" "${vf}" 'templates/workspace/main.tf'
  assert_contains_file "validate.sh reads the devcontainer twin" "${vf}" 'templates/devcontainer/coder.tf'
  # Findings are tab-separated and a non-empty result must fail the run.
  assert_contains_file "a finding fails the gate" "${vf}" 'return 1'
}

# ── missing-type ────────────────────────────────────────────────────────────

@test "tf_types: a variable with no type attribute is a missing-type finding" {
  local f
  f="$(tf_fixture untyped.tf)"
  printf '%s\n' \
    'variable "search_mcp" {' \
    '  description = "whether the search lane is declared"' \
    '  default     = "true"' \
    '}' >"${f}"

  tf_scan "${f}"
  [ "$(wc -l <<<"${output}")" -eq 1 ]
  [[ "${output}" == *"untyped.tf	1	missing-type	variable \"search_mcp\" declares no type constraint"* ]]
}

@test "tf_types: a typed variable beside an untyped one is the only finding" {
  local f
  f="$(tf_fixture mixed.tf)"
  printf '%s\n' \
    'variable "typed" {' \
    '  description = "fine"' \
    '  type        = string' \
    '  default     = "x"' \
    '}' \
    '' \
    'variable "untyped" {' \
    '  description = "no type"' \
    '}' >"${f}"

  tf_scan "${f}"
  [ "$(wc -l <<<"${output}")" -eq 1 ]
  [[ "${output}" == *'"untyped" declares no type constraint'* ]]
}

@test "tf_types: a variable block left open at end of file is still reported" {
  local f
  f="$(tf_fixture truncated.tf)"
  # No closing brace at all: the END flush owes this one, or a truncated file
  # would read as clean.
  printf '%s\n' \
    'variable "truncated" {' \
    '  description = "no closer"' >"${f}"

  tf_scan "${f}"
  [ "$(wc -l <<<"${output}")" -eq 1 ]
  [[ "${output}" == *'variable "truncated" declares no type constraint'* ]]
}

# ── broad-any ───────────────────────────────────────────────────────────────

@test "tf_types: type = any is a broad-any finding" {
  local f
  f="$(tf_fixture any.tf)"
  printf '%s\n' \
    'variable "anything" {' \
    '  description = "the broad type"' \
    '  type        = any' \
    '}' >"${f}"

  tf_scan "${f}"
  [ "$(wc -l <<<"${output}")" -eq 1 ]
  [[ "${output}" == *"	any"* ]]
}

@test "tf_types: list(any) and map(any) are broad-any findings" {
  local f
  f="$(tf_fixture anylist.tf)"
  printf '%s\n' \
    'variable "loose_list" {' \
    '  type = list(any)' \
    '}' \
    '' \
    'variable "loose_map" {' \
    '  type = map(any)' \
    '}' >"${f}"

  tf_scan "${f}"
  [ "$(wc -l <<<"${output}")" -eq 2 ]
  [[ "${output}" == *'loose_list type = list(any)'* ]]
  [[ "${output}" == *'loose_map type = map(any)'* ]]
}

@test "tf_types: an any hiding in a multi-line object type is still found" {
  local f
  f="$(tf_fixture anyobject.tf)"
  printf '%s\n' \
    'variable "preset" {' \
    '  type = object({' \
    '    url  = string' \
    '    name = any' \
    '  })' \
    '  default = {' \
    '    url  = "https://example"' \
    '    name = "many companies"' \
    '  }' \
    '}' >"${f}"

  tf_scan "${f}"
  [ "$(wc -l <<<"${output}")" -eq 1 ]
  [[ "${output}" == *"	broad-any	preset type = object({"* ]]
}

# ── bare-container ──────────────────────────────────────────────────────────

@test "tf_types: a bare list, set, or map is a bare-container finding" {
  local f
  f="$(tf_fixture bare.tf)"
  printf '%s\n' \
    'variable "l" {' \
    '  type = list' \
    '}' \
    '' \
    'variable "s" {' \
    '  type = set' \
    '}' \
    '' \
    'variable "m" {' \
    '  type = map' \
    '}' >"${f}"

  tf_scan "${f}"
  [ "$(wc -l <<<"${output}")" -eq 3 ]
  [[ "${output}" == *"bare-container	l type = list declares no element type"* ]]
  [[ "${output}" == *"bare-container	s type = set declares no element type"* ]]
  [[ "${output}" == *"bare-container	m type = map declares no element type"* ]]
}

# ── what must NOT be reported ───────────────────────────────────────────────

@test "tf_types: real constraints across the scalar and container types are silent" {
  local f
  f="$(tf_fixture good.tf)"
  printf '%s\n' \
    'variable "a" {' \
    '  type    = string' \
    '}' \
    '' \
    'variable "b" {' \
    '  type    = bool' \
    '}' \
    '' \
    'variable "c" {' \
    '  type    = number' \
    '}' \
    '' \
    'variable "d" {' \
    '  type    = list(string)' \
    '}' \
    '' \
    'variable "e" {' \
    '  type    = map(string)' \
    '}' \
    '' \
    'variable "f" {' \
    '  type    = optional(string, "github")' \
    '}' \
    '' \
    'variable "g" {' \
    '  type = object({' \
    '    url = string' \
    '    on  = bool' \
    '  })' \
    '}' >"${f}"

  tf_scan "${f}"
  [ -z "${output}" ]
}

@test "tf_types: the word any inside a name or a value is not a finding" {
  local f
  f="$(tf_fixture many.tf)"
  printf '%s\n' \
    'variable "company_mcp" {' \
    '  description = "many companies, any colour you like"' \
    '  type        = bool' \
    '  default     = true' \
    '}' >"${f}"

  tf_scan "${f}"
  [ -z "${output}" ]
}

@test "tf_types: a type key inside a default body is not the constraint" {
  local f
  f="$(tf_fixture defaultbody.tf)"
  # The nested `type = "bind"` sits inside default, so the block is typed once by
  # the real constraint above it and the nested one must not be read as a second
  # constraint of its own.
  printf '%s\n' \
    'variable "volumes" {' \
    '  type = list(object({' \
    '    host      = string' \
    '    container = string' \
    '  }))' \
    '  default = [' \
    '    {' \
    '      type = "bind"' \
    '    },' \
    '  ]' \
    '}' >"${f}"

  tf_scan "${f}"
  [ -z "${output}" ]
}

@test "tf_types: a validation block does not contribute findings" {
  local f
  f="$(tf_fixture validation.tf)"
  printf '%s\n' \
    'variable "grok_profile_mode" {' \
    '  type        = string' \
    '  default     = "shared"' \
    '  validation {' \
    '    condition     = contains(["shared", "private"], var.grok_profile_mode)' \
    '    error_message = "any other value is a mistake"' \
    '  }' \
    '}' >"${f}"

  tf_scan "${f}"
  [ -z "${output}" ]
}

@test "tf_types: only a top-level variable block is an input declaration" {
  local f
  f="$(tf_fixture decoy.tf)"
  # A resource argument named `type`, and a string that merely contains a
  # variable block, are both HCL content rather than an input.
  printf '%s\n' \
    'locals {' \
    '  note = "variable \"decoy\" { default = 1 }"' \
    '}' \
    '' \
    'resource "docker_container" "c" {' \
    '  variable = "not a declaration"' \
    '  type     = "should be ignored"' \
    '}' >"${f}"

  tf_scan "${f}"
  [ -z "${output}" ]
}

@test "tf_types: a file with no variable block at all is legal and silent" {
  local f
  f="$(tf_fixture provider.tf)"
  printf '%s\n' \
    'terraform {' \
    '  required_providers {' \
    '    coder = {' \
    '      source  = "coder/coder"' \
    '      version = "~> 2.18"' \
    '    }' \
    '  }' \
    '}' >"${f}"

  tf_scan "${f}"
  [ -z "${output}" ]
}

@test "tf_types: one call over several files labels each finding with its own file" {
  # //:validate passes all four twins on one command line, so a finding has to
  # name the file it came from or the operator cannot act on it.
  local a b
  a="$(tf_fixture first.tf)"
  b="$(tf_fixture second.tf)"
  printf '%s\n' 'variable "one" {' '}' >"${a}"
  printf '%s\n' 'variable "two" {' '}' >"${b}"

  tf_scan "${a}" "${b}"
  [ "$(wc -l <<<"${output}")" -eq 2 ]
  [[ "${lines[0]}" == */first.tf* ]]
  [[ "${lines[1]}" == */second.tf* ]]
}
