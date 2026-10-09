#!/usr/bin/env bash
#
# ## doc_coverage
#
# Fail unless every scripts/**/*.sh file has a `# ##` header and every function
# has a `# @function` block with Globals, Arguments, Outputs, and Returns.
#
# Usage:
#   bash tests/doc_coverage.sh
#   bazelisk test //tests:doc_coverage

set -euo pipefail

# shellcheck source=repo_root.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo_root.sh"
ROOT="$(tests_repo_root)"
cd "${ROOT}"

# @function main
# Scan scripts/ and print one violation per missing header or docstring.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Violations on stderr
# Returns:
#   0 when clean, 1 otherwise
main() {
  local file rel lines i name window violations=0
  while IFS= read -r file; do
    rel="${file#./}"
    if ! grep -qE '^#[[:space:]]*##[[:space:]]+\S' "${file}"; then
      echo "${rel}: missing file-level # ## header" >&2
      violations=$((violations + 1))
    fi
    mapfile -t lines <"${file}"
    for i in "${!lines[@]}"; do
      if [[ ${lines[$i]} =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{? ]]; then
        name="${BASH_REMATCH[1]}"
        window="$(printf '%s\n' "${lines[@]:$((i > 30 ? i - 30 : 0)):30}")"
        if ! grep -qE "^#[[:space:]]*@function[[:space:]]+${name}[[:space:]]*$" <<<"${window}"; then
          echo "${rel}: function '${name}' missing # @function marker" >&2
          violations=$((violations + 1))
          continue
        fi
        for section in Globals Arguments Outputs Returns; do
          if ! grep -q "^#[[:space:]]*${section}:" <<<"${window}"; then
            echo "${rel}: function '${name}' missing ${section}:" >&2
            violations=$((violations + 1))
          fi
        done
      fi
    done
  done < <(find scripts -name '*.sh' -type f | sort)
  if [[ ${violations} -ne 0 ]]; then
    echo "doc_coverage: ${violations} violation(s)" >&2
    return 1
  fi
  echo "doc_coverage: every scripts/**/*.sh function is documented."
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
