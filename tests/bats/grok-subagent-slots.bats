#!/usr/bin/env bats
#
# ## grok-subagent-slots.bats - hermetic coverage for the fan-out seam
#
# Three things decide whether a fan-out on this stack is parallel at all, and all
# three are text in a template someone can edit: every subagent type a session can
# spawn has to ride a lane, each role on the alias that suits the work (a named type
# with no entry inherits the parent's model, which is how a swarm wave ends up
# queued behind one box anyway), the width has to be derived from the lane rather
# than one number for both lanes, and the rulebook has to tell the parent to fill
# the slots it was
# given. Each is pinned for both template twins, and the seed body's own literals
# are pinned so a re-hardcoded default cannot sneak back in.
#
# Usage: bazelisk test //tests:bats_grok_subagent_slots_test   (from any cwd)
# Safety: reads the checkout only; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CONFIG_TWINS=()
CODER_TWINS=()
MAIN_TWINS=()
RULEBOOK=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CONFIG_TWINS=("${REPO_ROOT}/templates/workspace/grok-config.toml.tftpl"
    "${REPO_ROOT}/templates/devcontainer/grok-config.toml.tftpl")
  CODER_TWINS=("${REPO_ROOT}/templates/workspace/coder.tf"
    "${REPO_ROOT}/templates/devcontainer/coder.tf")
  MAIN_TWINS=("${REPO_ROOT}/templates/workspace/main.tf"
    "${REPO_ROOT}/templates/devcontainer/main.tf")
  RULEBOOK="${REPO_ROOT}/templates/common/GROK_BUILD_AGENTS.md"
  local file
  for file in "${CONFIG_TWINS[@]}" "${CODER_TWINS[@]}" "${MAIN_TWINS[@]}" "${RULEBOOK}"; do
    [ -f "${file}" ] || skip "no ${file} in the checkout"
  done
}

# subagents_block <file> - the rendered [subagents] and [subagents.models] text,
# comments dropped so a rewording cannot pass or fail a structural assertion.
subagents_block() {
  sed -n '/^\[subagents\]/,/^\[mcp_servers\./p' "$1" | grep -v '^#' | sed '/^$/d'
}

@test "subagents config: both twins take the width from the template variable" {
  local file block
  for file in "${CONFIG_TWINS[@]}"; do
    run grep -F 'max_concurrent = ${grok_subagent_max_concurrent}' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} hardcodes the fan-out width" >&2
      return 1
    }
    run grep -F 'limit_behavior = "queue"' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} fails a spawn that overflows the cap" >&2
      return 1
    }
    # sampling_limit is deliberately absent from the block: it defaults to
    # max_concurrent, and pinning both lets the two caps drift apart. Read the
    # comment-stripped block, since the prose explains the omission by naming it.
    block="$(subagents_block "${file}")"
    [[ "${block}" != *sampling_limit* ]] || {
      echo "${file} pins sampling_limit beside max_concurrent" >&2
      return 1
    }
  done
}

@test "subagents config: every subagent type rides a lane, each role on its own" {
  # One knob per role, and no type left unpinned: a named type with no entry
  # inherits the parent's model, which is how a fleet ends up queued behind the
  # box that spawned it. The writers follow the fan-out knob; the readers, the
  # planner and the skeptic each have their own, so a cheap alias serves the
  # evidence-gathering half of a wave and a deep one serves the review.
  local file type var entry
  for file in "${CONFIG_TWINS[@]}"; do
    for entry in \
      'general-purpose ${grok_subagents_lane}' \
      'implementer ${grok_subagents_lane}' \
      'tester ${grok_subagents_lane}' \
      'explore ${grok_explore_lane}' \
      'explorer ${grok_explore_lane}' \
      'plan ${grok_plan_lane}' \
      'architect ${grok_plan_lane}' \
      'reviewer ${grok_review_lane}' \
      'security-auditor ${grok_review_lane}'; do
      read -r type var <<<"${entry}"
      run grep -F "${type} = \"${var}\"" "${file}"
      [ "${status}" -eq 0 ] || {
        echo "${file} leaves ${type} off ${var}" >&2
        return 1
      }
    done
  done
}

@test "subagents config: the two twins agree on the block byte for byte" {
  local left right
  left="$(subagents_block "${CONFIG_TWINS[0]}")"
  right="$(subagents_block "${CONFIG_TWINS[1]}")"
  assert_eq "twins agree on [subagents]" "${left}" "${right}"
}

@test "subagent width: both coder.tf twins derive it and validate the override" {
  local file
  for file in "${CODER_TWINS[@]}"; do
    run grep -F 'variable "grok_subagent_max_concurrent"' "${file}"
    [ "${status}" -eq 0 ]
    # null, not 4: a literal default is what made the swarm lane no wider than a
    # pinned one, so the fleet sat half idle with the knob untouched.
    run grep -F 'default     = null' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} defaults the width instead of deriving it from the lane" >&2
      return 1
    }
    run grep -F 'var.grok_subagent_max_concurrent == null ||' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} lost the validation that keeps the override a sane count" >&2
      return 1
    }
    # The lane variable has to name all three types, or the description is the
    # only place a reader learns the writers ride it too.
    run grep -F 'general-purpose, explore, plan' "${file}"
    [ "${status}" -eq 0 ]
    # Each role lane is a declared variable with its own default and its own
    # validator: the default is what makes the routing the shipped behaviour, and
    # the regex is what keeps a typo out of a rendered model id.
    local role
    for role in grok_explore_lane grok_plan_lane grok_review_lane; do
      run grep -F "variable \"${role}\"" "${file}"
      [ "${status}" -eq 0 ] || {
        echo "${file} has no ${role} variable, so the role cannot be rolled back alone" >&2
        return 1
      }
      run grep -F "can(regex(\"^[a-z0-9._-]+\$\", var.${role}))" "${file}"
      [ "${status}" -eq 0 ] || {
        echo "${file} renders ${role} without validating it is a model id" >&2
        return 1
      }
    done
  done
}

@test "subagents config: the role defaults are local Spark aliases" {
  # A role default is the routing most workspaces get, so it has to name a Spark
  # group in litellm/config.yaml. The agent- prefix pin is what keeps a cloud
  # model id from ever arriving in a rendered lane.
  local file
  for file in "${CODER_TWINS[@]}"; do
    run grep -F 'default     = "agent-explore"' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} has no agent-explore default for the reader lane" >&2
      return 1
    }
    run grep -F 'default     = "agent-review"' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} has no agent-review default for the skeptic lane" >&2
      return 1
    }
  done
}

@test "subagent width: both main.tf twins derive 8 on the swarm lane and 4 pinned" {
  local file
  for file in "${MAIN_TWINS[@]}"; do
    run grep -F 'var.grok_subagent_max_concurrent != null ? var.grok_subagent_max_concurrent' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} feeds the raw variable, so the lane cannot set the width" >&2
      return 1
    }
    run grep -F 'var.grok_subagents_lane == "agent-swarm" ? 8 : 4' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} lost the per-lane widths" >&2
      return 1
    }
  done
}

@test "contributor seed: the lane and the width are variables, not literals" {
  local seed="${REPO_ROOT}/scripts/seed-dev-env.sh"
  [ -f "${seed}" ] || skip "no scripts/seed-dev-env.sh in the checkout"
  run grep -F 'GROK_SUBAGENTS_LANE' "${seed}"
  [ "${status}" -eq 0 ]
  run grep -F 'GROK_SUBAGENT_MAX_CONCURRENT' "${seed}"
  [ "${status}" -eq 0 ]
  run grep -F 'GROK_EXPLORE_LANE' "${seed}"
  [ "${status}" -eq 0 ]
  run grep -F 'GROK_REVIEW_LANE' "${seed}"
  [ "${status}" -eq 0 ]
  # The two tokens must be substituted from those reads. A re-hardcoded literal
  # here is how a contributor home drifts from what a template --var renders.
  run grep -F "s|\\\${grok_subagents_lane}|\${lane}|g" "${seed}"
  [ "${status}" -eq 0 ] || {
    echo "seed-dev-env.sh no longer substitutes the lane from a variable" >&2
    return 1
  }
  run grep -F "s|\\\${grok_subagent_max_concurrent}|\${slots}|g" "${seed}"
  [ "${status}" -eq 0 ] || {
    echo "seed-dev-env.sh no longer substitutes the width from a variable" >&2
    return 1
  }
  # A contributor home gets the same role routing a workspace does, so the three
  # role tokens are substituted too.
  local role
  for role in grok_explore_lane grok_plan_lane grok_review_lane; do
    run grep -F "s|\\\${${role}}|" "${seed}"
    [ "${status}" -eq 0 ] || {
      echo "seed-dev-env.sh leaves \${${role}} unsubstituted" >&2
      return 1
    }
  done
}

@test "rulebook: the parent is told to fill the slots and to prove the wave" {
  local phrase
  for phrase in \
    '[subagents] max_concurrent' \
    'fill every slot' \
    'agent-swarm' \
    'plan_check.py .grok/plans/' \
    'ctx/L0.md' \
    'Promotion is your job' \
    'a task that wants more is two tasks' \
    'Mandatory independent review' \
    'Any wave of three or more independent children rides `agent-swarm`' \
    'ends with an independent skeptic on `agent-review`' \
    'wrote none of the change reviewed it'; do
    run grep -F -- "${phrase}" "${RULEBOOK}"
    [ "${status}" -eq 0 ] || {
      echo "the seed dropped: ${phrase}" >&2
      return 1
    }
  done
  # The negative pin is the point: the old literal cap is what kept a swarm
  # session at a quarter of the fleet it was given, and an agent obeys the
  # number it can see.
  run grep -F 'max 4 in-flight subagents' "${RULEBOOK}"
  [ "${status}" -ne 0 ] || {
    echo "the seed re-adopted a hard-coded in-flight cap" >&2
    return 1
  }
}

@test "micro-plan skill: the seed names a checker that exists in the payload" {
  local skill="${REPO_ROOT}/templates/common/ez-micro-plan.SKILL.md"
  local checker="${REPO_ROOT}/templates/common/ez-micro-plan.plan_check.py"
  [ -f "${skill}" ] || skip "no ez-micro-plan.SKILL.md payload in the checkout"
  [ -f "${checker}" ] || {
    echo "ez-micro-plan.SKILL.md is seeded without its checker" >&2
    return 1
  }
  run grep -F 'ez-micro-plan/scripts/plan_check.py' "${skill}"
  [ "${status}" -eq 0 ] || {
    echo "the skill names a checker path the seed does not write" >&2
    return 1
  }
  # The format the checker parses and the format the skill teaches have to be the
  # same document: every section heading the checker requires is in the body.
  local section
  for section in '## Goal' '## Dispatch' '## Lanes' '## Tasks' '## Ledger'; do
    run grep -F -- "${section}" "${skill}"
    [ "${status}" -eq 0 ] || {
      echo "the skill stopped teaching ${section}" >&2
      return 1
    }
  done
  run grep -F 'ez-micro-plan v1' "${skill}"
  [ "${status}" -eq 0 ]
  run grep -F 'ez-micro-plan v1' "${checker}"
  [ "${status}" -eq 0 ]
}
