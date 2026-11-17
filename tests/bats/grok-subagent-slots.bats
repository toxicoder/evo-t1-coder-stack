#!/usr/bin/env bats
#
# ## grok-subagent-slots.bats - hermetic coverage for the fan-out seam
#
# Three things decide whether a fan-out on this stack is parallel at all, and all
# three are text in a template someone can edit: every subagent type a session can
# spawn has to ride a lane, each role on the alias that suits the work (a named type
# with no entry inherits the parent's model, which is how a swarm wave ends up
# queued behind one box anyway), the width has to come from the fleet's own
# grok_swarm_width on every lane rather than follow the default lane, the operator
# docs have to keep teaching that rule, and the rulebook has to tell the parent to
# fill
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
FANOUT_DOCS=()
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
  FANOUT_DOCS=("${REPO_ROOT}/README.md"
    "${REPO_ROOT}/docs/coder-templates.md"
    "${REPO_ROOT}/docs/grok-build-and-agents.md"
    "${REPO_ROOT}/docs/litellm-routing.md"
    "${REPO_ROOT}/docs/config-updates.md")
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
      'documenter ${grok_subagents_lane}' \
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
    # And the derived half: the list above is a claim about which roles exist, so
    # a seventh definition added to templates/common/ slips past it unpinned and
    # inherits the parent's model - which is the exact failure the block exists to
    # prevent. Enumerate the definitions from the tree and require each one's own
    # line, so an unpinned role is a red gate rather than a fleet queued behind
    # the box that spawned it.
    local def stem
    for def in "${REPO_ROOT}"/templates/common/*.AGENT.md; do
      [ -e "${def}" ] || continue
      stem="$(basename "${def}" .AGENT.md)"
      run grep -E "^${stem} = \"\\\$\{grok_[a-z_]*lane\}\"" "${file}"
      [ "${status}" -eq 0 ] || {
        echo "${file} defines no [subagents.models] pin for the ${stem} role" >&2
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

@test "subagents config: both twins take the nesting depth from the template variable" {
  # The width caps one parent's own children; the depth says how far below it the
  # tree may grow. Both are rendered numbers, so neither may be a literal here:
  # a hardcoded depth is a knob the operator cannot turn back to 1.
  local file
  for file in "${CONFIG_TWINS[@]}"; do
    run grep -F 'max_depth = ${grok_subagent_max_depth}' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} hardcodes the nesting depth" >&2
      return 1
    }
  done
}

@test "subagents config: both twins let the parent steer a live child" {
  # Without this the only way to redirect a running child is to kill it and
  # respawn it, which throws away everything it had already gathered. Assert it
  # inside [features], where a dropped key would silently render as false.
  local file block
  for file in "${CONFIG_TWINS[@]}"; do
    block="$(awk '/^\[features\]/{f=1;next} /^\[/{f=0} f' "${file}")"
    [[ "${block}" == *'active_agent_messages = true'* ]] || {
      echo "${file} does not set active_agent_messages = true in [features]" >&2
      return 1
    }
  done
}

@test "subagent depth: both coder.tf twins declare it and bound it at 1..3" {
  # 1 is the no-nesting rollback, 2 is the shipped default that lets a child spawn
  # read-only mappers, 3 the operator's experiment ceiling - the same bounded-knob
  # shape the width variable uses. Assert inside the variable block: each twin
  # carries other default     = 2 lines a file-wide grep cannot tell apart.
  local file block
  for file in "${CODER_TWINS[@]}"; do
    block="$(awk '/^variable "grok_subagent_max_depth" \{/,/^\}/' "${file}")"
    [[ -n "${block}" ]] || {
      echo "${file} has no grok_subagent_max_depth variable, so the depth is a literal" >&2
      return 1
    }
    [[ "${block}" == *'default     = 2'* ]] || {
      echo "${file} does not ship depth 2, the depth that lets a child spawn mappers" >&2
      return 1
    }
    [[ "${block}" == *'var.grok_subagent_max_depth >= 1 && var.grok_subagent_max_depth <= 3'* ]] || {
      echo "${file} renders the depth without bounding it at 1..3" >&2
      return 1
    }
  done
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

@test "subagent lane: both coder.tf twins default the writers to the swarm lane" {
  # This default is the routing every workspace that passes no --var gets, and the
  # width is derived from it, so a re-hardcoded "agent" here quietly puts the whole
  # fleet behind one box again. Assert it inside the variable block: each twin
  # carries two other default     = "agent" lines (grok_default_model,
  # grok_plan_lane) that a file-wide grep cannot tell apart from this one.
  #
  # Pin those two neighbours in the same pass. A blanket flip to agent-swarm would take
  # the session model and the planner with it, and only this test can see that it did:
  # the session model decides which lane the parent conversation runs on, and the planner
  # stays pinned on purpose because one planner steers every wave after it.
  local file block
  for file in "${CODER_TWINS[@]}"; do
    block="$(awk '/^variable "grok_subagents_lane" \{/,/^\}/' "${file}")"
    [[ "${block}" == *'default     = "agent-swarm"'* ]] || {
      echo "${file} does not default grok_subagents_lane to agent-swarm" >&2
      return 1
    }
    block="$(awk '/^variable "grok_default_model" \{/,/^\}/' "${file}")"
    [[ "${block}" == *'default     = "agent"'* ]] || {
      echo "${file} does not default grok_default_model to agent" >&2
      return 1
    }
    block="$(awk '/^variable "grok_plan_lane" \{/,/^\}/' "${file}")"
    [[ "${block}" == *'default     = "agent"'* ]] || {
      echo "${file} does not default grok_plan_lane to agent" >&2
      return 1
    }
  done
}

@test "subagent width: both main.tf twins default to the fleet width on every lane" {
  # The width used to follow the lane: 15 on agent-swarm, 4 on a pinned one. That
  # was right only while the lane was a workspace-wide decision, and it is not:
  # the agent-swarm model block is ungated, so a session whose default lane is
  # pinned can still name the swarm lane on any spawn. A config sized at one box's
  # PARALLEL then caps a swarm the user was one argument away from, which is the
  # failure this assertion now forbids. An explicit --var still overrides.
  local file
  for file in "${MAIN_TWINS[@]}"; do
    run grep -F 'var.grok_subagent_max_concurrent != null ? var.grok_subagent_max_concurrent' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} feeds the raw variable, so the operator override is dead" >&2
      return 1
    }
    run grep -F ': var.grok_swarm_width' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} does not fall back to the fleet width" >&2
      return 1
    }
    if grep -qF 'var.grok_subagents_lane == "agent-swarm" ? 15 : 4' "${file}"; then
      echo "${file} re-tied the width to the default lane, capping a swarm the user can still choose" >&2
      return 1
    fi
  done
}

@test "subagent depth: both main.tf twins pass it into the render" {
  # The variable is dead unless it reaches the same templatefile() vars map that
  # carries the width, so an operator --var that renders nothing is worse than no
  # knob at all.
  local file
  for file in "${MAIN_TWINS[@]}"; do
    run grep -F 'grok_subagent_max_depth = var.grok_subagent_max_depth' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} renders the config without the operator's depth" >&2
      return 1
    }
  done
}

@test "subagent width: both coder.tf twins declare the fleet width as a validated variable" {
  local file block
  for file in "${CODER_TWINS[@]}"; do
    block="$(awk '/^variable "grok_swarm_width" \{/,/^\}/' "${file}")"
    [[ -n "${block}" ]] || {
      echo "${file} has no grok_swarm_width variable, so the fleet width is a literal" >&2
      return 1
    }
    [[ "${block}" == *'default     = 15'* ]] || {
      echo "${file} does not default grok_swarm_width to the fleet's 15 streams" >&2
      return 1
    }
    [[ "${block}" == *'var.grok_swarm_width >= 1 && var.grok_swarm_width <= 32'* ]] || {
      echo "${file} renders grok_swarm_width without validating the count" >&2
      return 1
    }
  done
}

@test "swarm lane: every generated config can reach agent-swarm whatever the default lane" {
  # The whole point of sizing every config at the fleet width. If the alias block
  # ever sits behind a %{if} gate, or the width is the only swarm-sized thing in
  # the file, then "the user can choose the swarm" is a sentence about a lane that
  # is not always there. Assert it in both twins and in the contributor seed.
  local file block
  for file in "${CONFIG_TWINS[@]}"; do
    run grep -F '[model."agent-swarm"]' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} has no agent-swarm alias block at all" >&2
      return 1
    }
    # Ungated: no %{if ...} may open between the file start and that header
    # without a matching endif before it.
    block="$(sed -n '1,/\[model\."agent-swarm"\]/p' "${file}" | grep -c '^%{if' || true)"
    [ "${block}" -eq 0 ] || {
      echo "${file} opens ${block} gate(s) before [model.\"agent-swarm\"]; the swarm lane must always render" >&2
      return 1
    }
    run grep -F 'enabled = true' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} can ship with [subagents] disabled" >&2
      return 1
    }
  done
  # The seed renders the same template, so it has to carry the swarm alias in its
  # own default rather than drop it: an unpinned seed home would lose the lane.
  run grep -F 'GROK_SUBAGENTS_LANE:-agent-swarm' "${REPO_ROOT}/scripts/seed-dev-env.sh"
  [ "${status}" -eq 0 ] || {
    echo "seed-dev-env.sh no longer defaults a contributor home onto the swarm lane" >&2
    return 1
  }
}

@test "contributor seed: the lane and the width are variables, not literals" {
  local seed="${REPO_ROOT}/scripts/seed-dev-env.sh"
  [ -f "${seed}" ] || skip "no scripts/seed-dev-env.sh in the checkout"
  run grep -F 'GROK_SUBAGENTS_LANE' "${seed}"
  [ "${status}" -eq 0 ]
  run grep -F 'GROK_SUBAGENT_MAX_CONCURRENT' "${seed}"
  [ "${status}" -eq 0 ]
  # The seed's own fallback is the fleet width, not a lane-conditional 4: a
  # contributor home that sized itself at one box could not run the swarm a
  # session there can name on any spawn.
  run grep -F 'GROK_SUBAGENT_MAX_CONCURRENT:-${GROK_SWARM_WIDTH:-15}' "${seed}"
  [ "${status}" -eq 0 ] || {
    echo "seed-dev-env.sh no longer defaults a contributor home to the fleet width" >&2
    return 1
  }
  if grep -qF 'slots="4"' "${seed}"; then
    echo "seed-dev-env.sh re-introduced the pinned-lane width of 4" >&2
    return 1
  fi
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

@test "contributor seed: the nesting depth is a variable, not a literal" {
  local seed="${REPO_ROOT}/scripts/seed-dev-env.sh"
  [ -f "${seed}" ] || skip "no scripts/seed-dev-env.sh in the checkout"
  # The seed's own fallback is the shipped default, so a contributor home that
  # passes no env nests the way a workspace that passes no --var does.
  run grep -F 'GROK_SUBAGENT_MAX_DEPTH:-2' "${seed}"
  [ "${status}" -eq 0 ] || {
    echo "seed-dev-env.sh no longer defaults a contributor home to depth 2" >&2
    return 1
  }
  # And the token is substituted from that read, the way the width token is: a
  # re-hardcoded literal here is how a contributor home drifts from a render.
  run grep -F "s|\\\${grok_subagent_max_depth}|\${depth}|g" "${seed}"
  [ "${status}" -eq 0 ] || {
    echo "seed-dev-env.sh no longer substitutes the depth from a variable" >&2
    return 1
  }
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

@test "rulebook: the parent is taught the tree budget and the review panel" {
  # The width caps one parent's own children; nothing in the file says what a child
  # that spawns costs the fleet, so an agent filling its slots can still over-admit
  # streams. And the review phase has to read as a wave dispatched in one turn, or
  # the parent queues its skeptics one at a time. Both are arithmetic the parent can
  # only obey if it can see it. And the file has to say which layer enforces which
  # half of the nesting rule: a parent that reads the tools list as the whole guard
  # will let a spawner ship a file, since `tester` keeps `write` for its test.
  local phrase
  for phrase in \
    '1 + spawns' \
    'sum the in-flight' \
    'at or below the fleet' \
    'panel of three angles sent in one turn' \
    'who may spawn at all' \
    'holds a spawner to shipping nothing'; do
    run grep -F -- "${phrase}" "${RULEBOOK}"
    [ "${status}" -eq 0 ] || {
      echo "the seed dropped: ${phrase}" >&2
      return 1
    }
  done
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

@test "fan-out docs: no operator doc re-ties the width to the default lane" {
  # The width used to follow grok_subagents_lane: 15 on agent-swarm, 4 on a pinned
  # one. main.tf has taken it from grok_swarm_width on every lane since, but four
  # operator docs kept teaching the old rule because nothing read them -- the stale
  # terraform ternary was still printed verbatim in the agents guide. This refuses
  # the retired wording and requires the variable that actually supplies the width
  # to be named, so the prose cannot drift from main.tf again unnoticed.
  local file flat pattern
  local -a banned=(
    'width.{0,60}follows? the (lane|writers)'
    'width.{0,60}(deriv[ey]|derived|derives|derivation|taken|comes|set).{0,15}(from|by|off) the lane'
    'asks the lane'
    '4 on a pinned (one|lane)'
    '15 on the unpinned.{0,40}lane'
    '15 : 4'
    'stays at 4'
    'where 4 comes from'
  )
  for file in "${FANOUT_DOCS[@]}"; do
    # A missing page is a failure here, not a skip: the setup probe skips the
    # whole file, and a suite that skips reads identical to one that passes.
    [ -f "${file}" ] || {
      echo "${file} is not in the runfiles: add its filegroup to this suite's _SUITE_PAYLOAD entry" >&2
      return 1
    }
    # Match sentences, not lines. This prose is hard-wrapped, and the stale
    # sentence this gate was written for ran across three source lines, so a
    # per-line grep walked straight past it and reported the page clean.
    flat="$(tr '\n' ' ' <"${file}" | tr -s ' ')"
    # A sentence that calls itself history, or denies the retired rule, may keep
    # the old wording. The gate exists to stop the current rule being wrong, not
    # to forbid documenting what was retired or stating the negative.
    flat="$(printf '%s' "${flat}" \
      | sed -E "s/[^.]*\b(retired|used to|no longer|historical|formerly|does not|doesn't|never|independent of)\b[^.]*\.//Ig")"
    for pattern in "${banned[@]}"; do
      if printf '%s' "${flat}" | grep -qiE -- "${pattern}"; then
        echo "${file} still teaches the retired width rule (${pattern})" >&2
        printf '%s' "${flat}" | grep -oiE -- ".{0,50}${pattern}.{0,50}" | head -1 >&2
        return 1
      fi
    done
    run grep -F 'grok_swarm_width' "${file}"
    [ "${status}" -eq 0 ] || {
      echo "${file} never names grok_swarm_width, the variable that supplies the width" >&2
      return 1
    }
  done
}
