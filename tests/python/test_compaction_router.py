#!/usr/bin/env python3
"""Unit tests for litellm/compaction_router.py, the proxy's compaction hop.

Run: bazelisk test //tests:py_coverage
(or: python3 -m unittest discover -s tests/python -p 'test_*.py' -t .)

litellm/config.yaml registers ``compaction_router.proxy_handler_instance``, so the
contract under test is the one the proxy sees: the four arguments it hands the hook,
the model it rewrites, the three keys the hop drops, and the None that means "carry on
exactly as the caller sent it". tests/bats/litellm-config.bats pins the routing payload
around this; nothing here opens that config or reaches the network.

Two things about the import are load-bearing:

  seeding sys.modules  the module imports its runtime base from
      litellm.integrations.custom_logger. The repo's own litellm/ payload directory is
      a namespace package the moment the checkout root joins sys.path -- which
      ``python3 -m`` does from the cwd -- so it shadows any installed litellm and the
      real base cannot be imported here. Three stub modules are seeded before the
      loader runs, the last carrying a CustomLogger that takes **kwargs.

  a fresh dict per call  the hook mutates the body in place and returns it, so every
      case hands it ``dict(body)`` and keeps the pristine literal to diff against; a
      shared dict would make one case's rewrite the next case's evidence.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import pathlib
import sys
import types
import unittest
from collections.abc import Callable
from typing import Final, Protocol, cast
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "litellm" / "compaction_router.py"

# The instruction the CLI appends, pinned here rather than read back from the module:
# the sentence the shipped matcher matches is a fact about the CLI, so a reworded
# constant has to fail a test rather than quietly unarm the hop.
MARKER: Final = "produce a faithful, concise summary of the conversation so far"
# The other ask the CLI appends, the one /compact wraps in a <summary_request> tag
# (crates/codegen/xai-grok-shell/src/session/helpers/session_compact.rs). Pinned here in
# full and in its own clause, so a matcher that only ever knew the first ask fails a
# test rather than leaving manual compaction on the extra-high lane forever.
MANUAL_ASK: Final = (
    "<summary_request>\n"
    "Please summarize the conversation so far. This summary (everything after your\n"
    "thinking) will be provided to another AI assistant to continue working on the\n"
    "task. The other assistant will only see the user's original query and your\n"
    "summary, it will not have access to any tool calls or tool outputs from this\n"
    "conversation. The purpose of the summary is to compress the conversation\n"
    "context while preserving the essential information needed to seamlessly\n"
    "continue. Useful things to include: the user's requests, what you've done so\n"
    "far, relevant file paths and code details, any errors encountered and how\n"
    "they were resolved, and what remains to be done. DO NOT call any tools in\n"
    "your response.\n"
    "</summary_request>"
)
MANUAL_MARKER: Final = "summarize the conversation so far"
TARGET: Final = "compaction-fast"
# The second tier: the Spark group an oversized summary goes to, so it keeps a window
# wide enough to read the whole conversation and only loses the thinking level.
SPARK_TARGET: Final = "agent-low"
DROPPED_KEYS: Final = ("tools", "tool_choice", "reasoning_effort")
FAST_LANES: Final = ("agent-xhigh-fast", "agent-swarm-fast")
ORDINARY_LANES: Final = ("agent-xhigh", "agent-swarm", "agent", "coder", "chat")
DISABLED_VALUES: Final = ("0", "false", "off", "no")
# Every knob the module reads, so one case cannot inherit a developer's export and
# report a policy the shipped default never had.
KNOBS: Final = (
    "EVO_T1_FAST_COMPACTION",
    "EVO_T1_FAST_COMPACTION_LANES",
    "EVO_T1_FAST_COMPACTION_TARGET",
    "EVO_T1_FAST_COMPACTION_SPARK_TARGET",
    "EVO_T1_FAST_COMPACTION_INPUT_LIMIT",
)


class StubCustomLogger:
    """Stands in for the LiteLLM callback base the router subclasses.

    Only its shape matters from here: a concrete class whose ``__init__`` accepts
    kwargs, so the module-level instantiation the proxy relies on still runs.
    """

    enforces_request_content: bool

    def __init__(self, **kwargs: object) -> None:
        self.kwargs: dict[str, object] = dict(kwargs)


class StubCustomLoggerModule(types.ModuleType):
    """The module the router's runtime import resolves to."""

    def __init__(self) -> None:
        super().__init__("litellm.integrations.custom_logger")
        self.CustomLogger = StubCustomLogger


class StubIntegrationsPackage(types.ModuleType):
    """litellm.integrations, holding the one submodule the import walks."""

    def __init__(self, custom_logger: StubCustomLoggerModule) -> None:
        super().__init__("litellm.integrations")
        self.custom_logger = custom_logger


class StubLitellmPackage(types.ModuleType):
    """litellm itself, so the dotted import resolves without the real package."""

    def __init__(self, integrations: StubIntegrationsPackage) -> None:
        super().__init__("litellm")
        self.integrations = integrations


def load_module() -> types.ModuleType:
    """Import litellm/compaction_router.py by path with its base class stubbed."""
    custom_logger = StubCustomLoggerModule()
    integrations = StubIntegrationsPackage(custom_logger)
    sys.modules["litellm.integrations.custom_logger"] = custom_logger
    sys.modules["litellm.integrations"] = integrations
    sys.modules["litellm"] = StubLitellmPackage(integrations)
    spec = importlib.util.spec_from_file_location(
        "evo_t1_compaction_router", MODULE_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load %s" % MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ROUTER = load_module()
HANDLER: Final = ROUTER.proxy_handler_instance


class PreCallHook(Protocol):
    """The hook exactly as ProxyLogging calls it: four positional arguments."""

    async def async_pre_call_hook(
        self,
        user_api_key_dict: object,
        cache: object,
        data: dict[str, object],
        call_type: str,
    ) -> dict[str, object] | None: ...


HOOK: Final = cast(PreCallHook, HANDLER)
should_retarget: Final = cast(
    "Callable[[dict[str, object]], bool]", ROUTER.should_retarget
)
retarget_target: Final = cast(
    "Callable[[dict[str, object]], str]", ROUTER.retarget_target
)
declared_model_groups: Final = cast(
    "Callable[[], frozenset[str]]", ROUTER.declared_model_groups
)
estimate_input_tokens: Final = cast(
    "Callable[[dict[str, object]], int]", ROUTER.estimate_input_tokens
)
max_compaction_input_tokens: Final = cast(
    "Callable[[], int]", ROUTER.max_compaction_input_tokens
)


def summary_body(model: str) -> dict[str, object]:
    """The call the CLI makes when a session nears its window.

    Prose out, with the three things this hop exists to stop paying for still riding
    along: the tool schemas, the tool-choice hint, and the baked thinking level.
    """
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are the Grok Build coding agent."},
            {"role": "user", "content": "Read tests/python and add the missing suite."},
            {"role": "assistant", "content": "I read the tree and wrote the suite."},
            {"role": "user", "content": "%s, then stop." % MARKER},
        ],
        "tools": [
            {
                "type": "function",
                "function": {
                    "name": "run_terminal_command",
                    "description": "Run a command and return its output.",
                },
            }
        ],
        "tool_choice": "auto",
        "reasoning_effort": "xhigh",
        "stream": True,
    }


def chat_body(model: str) -> dict[str, object]:
    """An ordinary turn on the same lane: the same call without the ask."""
    body = summary_body(model)
    messages = cast("list[dict[str, object]]", body["messages"])
    body["messages"] = messages[:-1]
    return body


class RouterCase(unittest.TestCase):
    """Shared harness: a known environment per case, and the proxy's own call shape."""

    def setUp(self) -> None:
        saved = {name: os.environ.get(name) for name in KNOBS}
        for name in KNOBS:
            os.environ.pop(name, None)
        self.addCleanup(self._restore, saved)

    @staticmethod
    def _restore(saved: dict[str, str | None]) -> None:
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def set_knobs(self, **values: str) -> None:
        """Set compaction knobs for this case only; every other one reads its default."""
        os.environ.update(values)

    def call(
        self, body: dict[str, object]
    ) -> tuple[dict[str, object], dict[str, object] | None]:
        """Hand the hook a fresh copy of the body; return that copy and its answer."""
        handed = dict(body)
        return handed, asyncio.run(
            HOOK.async_pre_call_hook(None, None, handed, "completion")
        )

    def assert_hops(
        self, body: dict[str, object], target: str = TARGET
    ) -> dict[str, object]:
        """The call must move: the same dict back, retargeted, with the extras dropped."""
        for key in DROPPED_KEYS:
            self.assertIn(key, body, "the case must send what a hop is meant to drop")
        messages = body["messages"]
        handed, result = self.call(body)
        self.assertIs(result, handed, "the hook must return the dict it mutated")
        self.assertEqual(target, handed.get("model"))
        for key in DROPPED_KEYS:
            self.assertNotIn(key, handed)
        # Everything the summary itself needs still rides along.
        self.assertIs(messages, handed["messages"])
        self.assertIs(True, handed.get("stream"))
        return handed

    def assert_stays_put(self, body: dict[str, object]) -> None:
        """The call must not move: None back, and not one key of the body changed."""
        handed, result = self.call(body)
        self.assertIsNone(result)
        self.assertEqual(
            body, handed, "the hook mutated a request it was told to leave"
        )


class ShouldRetargetTest(RouterCase):
    """should_retarget() is the whole decision, kept apart from the mutation."""

    def test_a_summary_on_each_fast_lane_hops(self) -> None:
        for lane in FAST_LANES:
            with self.subTest(model=lane):
                self.assertIs(True, should_retarget(summary_body(lane)))

    def test_the_same_summary_on_an_ordinary_lane_does_not_hop(self) -> None:
        for lane in ORDINARY_LANES:
            with self.subTest(model=lane):
                self.assertIs(False, should_retarget(summary_body(lane)))

    def test_a_body_that_is_not_a_summary_does_not_hop(self) -> None:
        for lane in FAST_LANES:
            with self.subTest(model=lane):
                self.assertIs(False, should_retarget(chat_body(lane)))

    def test_a_rulebook_that_quotes_the_ask_moves_no_ordinary_turn(self) -> None:
        # The system prompt is the same text on every turn of the session, so matching
        # the ask there would move a whole conversation onto the summary target the
        # moment an operator pasted the sentence docs/litellm-routing.md prints into a
        # workspace rulebook. The ask has to be in the trailing turn.
        body = chat_body("agent-swarm-fast")
        body["messages"] = [
            {"role": "system", "content": "You must %s, in under 400 words." % MARKER},
            {
                "role": "user",
                "content": "Rename build() to compile() and run the gate.",
            },
        ]
        self.assertIs(False, should_retarget(body))
        self.assert_stays_put(body)

    def test_the_ask_in_a_trailing_user_turn_hops(self) -> None:
        body = summary_body("agent-swarm-fast")
        self.assertIs(True, should_retarget(body))

    def test_the_manual_compact_ask_hops(self) -> None:
        for lane in FAST_LANES:
            with self.subTest(model=lane):
                body = chat_body(lane)
                messages = cast("list[dict[str, object]]", body["messages"])
                messages.append({"role": "user", "content": MANUAL_ASK})
                self.assertIs(True, should_retarget(body))
                self.assertIn(MANUAL_MARKER, MANUAL_ASK)

    def test_a_turn_longer_than_either_ask_is_the_talk_about_summaries(self) -> None:
        # Both instructions are the whole turn, so a trailing turn that carries the
        # sentence inside a wall of other text is conversation, not the CLI asking.
        body = chat_body("agent-xhigh-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {"role": "user", "content": "%s\n%s" % (MARKER, "filler " * 2000)}
        )
        self.assertGreater(len(MARKER) + len("filler " * 2000), ROUTER.MAX_ASK_CHARS)
        self.assertIs(False, should_retarget(body))

    def test_a_responses_api_body_hops(self) -> None:
        # api_backend = "responses" puts the turns under `input` instead of `messages`.
        # A classifier that only read `messages` would leave that session compacting on
        # the extra-high lane with nothing in the log to say why.
        body = {
            "model": "agent-xhigh-fast",
            "instructions": "You are the Grok Build coding agent.",
            "input": [
                {"role": "user", "content": "Read tests/python and add the suite."},
                {
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "%s, then stop." % MARKER}
                    ],
                },
            ],
            "tools": [{"type": "function", "function": {"name": "run"}}],
            "tool_choice": "auto",
            "reasoning_effort": "xhigh",
            "stream": True,
        }
        self.assertIs(True, should_retarget(body))
        handed, result = self.call(body)
        self.assertIs(result, handed)
        self.assertEqual(TARGET, handed.get("model"))
        for key in DROPPED_KEYS:
            self.assertNotIn(key, handed)

    def test_a_turn_that_only_quotes_the_ask_does_not_hop(self) -> None:
        body = chat_body("agent-xhigh-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        body["messages"] = messages + [
            {
                "role": "user",
                "content": "The CLI tells you to %s. Where is that written?" % MARKER,
            },
            {"role": "user", "content": "Never mind, run the suite."},
        ]
        self.assertIs(False, should_retarget(body))

    def test_a_body_with_no_messages_does_not_hop(self) -> None:
        body = summary_body("agent-xhigh-fast")
        body["messages"] = []
        self.assertIs(False, should_retarget(body))

    def test_an_estimate_above_the_ceiling_still_hops(self) -> None:
        # The ceiling is a fork, not a wall: past it the summary loses the Arc and gains
        # the Spark group that has the window, and a request that stopped hopping here
        # would be the bug this tier exists to prevent.
        body = summary_body("agent-xhigh-fast")
        self.set_knobs(EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10")
        self.assertGreater(estimate_input_tokens(body), 10)
        self.assertIs(True, should_retarget(body))

    def test_the_shipped_ceiling_sends_an_oversized_summary_to_the_spark_tier(
        self,
    ) -> None:
        # A real auto-compaction arrives near 70% of the 262144-token window, which is
        # far past the Arc model's 32k, so the shipped default has to answer it on a
        # Spark group. An empty tier target would be the inert feature.
        body = summary_body("agent-swarm-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.insert(
            -1, {"role": "user", "content": "the session, line after line\n" * 4000}
        )
        self.assertGreater(estimate_input_tokens(body), 24000)
        self.assertEqual(SPARK_TARGET, retarget_target(body))

    def test_an_estimate_exactly_at_the_ceiling_stays_on_the_arc_tier(self) -> None:
        body = summary_body("agent-swarm-fast")
        self.set_knobs(
            EVO_T1_FAST_COMPACTION_INPUT_LIMIT=str(estimate_input_tokens(body))
        )
        self.assertEqual(TARGET, retarget_target(body))

    def test_an_estimate_one_above_the_ceiling_crosses_to_the_spark_tier(
        self,
    ) -> None:
        body = summary_body("agent-swarm-fast")
        self.set_knobs(
            EVO_T1_FAST_COMPACTION_INPUT_LIMIT=str(estimate_input_tokens(body) - 1)
        )
        self.assertEqual(SPARK_TARGET, retarget_target(body))

    def test_a_ceiling_that_is_not_a_count_falls_back_and_warns_readably(self) -> None:
        # The fallback has to be quiet about the request and loud about the knob: the
        # operator who typed `24k` gets one line naming the variable, and that line has
        # to survive the logger's own % formatting rather than arrive as a traceback.
        self.set_knobs(EVO_T1_FAST_COMPACTION_INPUT_LIMIT="24k")
        with self.assertLogs("LiteLLM", level="WARNING") as caught:
            self.assertEqual(24000, max_compaction_input_tokens())
        self.assertEqual(1, len(caught.records))
        message = caught.records[0].getMessage()
        self.assertIn("EVO_T1_FAST_COMPACTION_INPUT_LIMIT", message)
        self.assertIn("24k", message)
        self.assertIn("24000", message)


class FastCompactionFlagTest(RouterCase):
    """EVO_T1_FAST_COMPACTION is the kill switch, and it defaults to armed."""

    def test_the_unset_default_arms_the_hop(self) -> None:
        # setUp cleared every knob, so this is the position a fresh container boots in.
        self.assertIs(True, should_retarget(summary_body("agent-xhigh-fast")))

    def test_each_disabled_value_leaves_the_summary_alone(self) -> None:
        for value in DISABLED_VALUES:
            with self.subTest(EVO_T1_FAST_COMPACTION=value):
                self.set_knobs(EVO_T1_FAST_COMPACTION=value)
                body = summary_body("agent-xhigh-fast")
                self.assertIs(False, should_retarget(body))
                self.assert_stays_put(body)


class FastCompactionLanesFlagTest(RouterCase):
    """EVO_T1_FAST_COMPACTION_LANES decides which lanes may leave, and only those."""

    def test_a_custom_lane_list_moves_which_lane_hops(self) -> None:
        # Padded and empty entries: the list is operator input, so the split has to
        # forgive the whitespace a comma-separated env value always carries.
        self.set_knobs(EVO_T1_FAST_COMPACTION_LANES="agent-xhigh, agent-swarm-fast ,")
        self.assertIs(True, should_retarget(summary_body("agent-xhigh")))
        self.assert_hops(summary_body("agent-xhigh"))
        self.assertIs(False, should_retarget(summary_body("agent-xhigh-fast")))
        self.assert_stays_put(summary_body("agent-xhigh-fast"))


class HookRetargetTest(RouterCase):
    """The mutation itself, on each of the two lanes the config offers."""

    def test_a_summary_on_agent_xhigh_fast_moves_and_loses_the_extras(self) -> None:
        self.assert_hops(summary_body("agent-xhigh-fast"))

    def test_a_summary_on_agent_swarm_fast_moves_and_loses_the_extras(self) -> None:
        self.assert_hops(summary_body("agent-swarm-fast"))

    def test_a_summary_on_an_ordinary_lane_comes_back_untouched(self) -> None:
        for lane in ORDINARY_LANES:
            with self.subTest(model=lane):
                self.assert_stays_put(summary_body(lane))

    def test_a_non_summary_on_a_fast_lane_comes_back_untouched(self) -> None:
        for lane in FAST_LANES:
            with self.subTest(model=lane):
                self.assert_stays_put(chat_body(lane))

    def test_an_oversized_summary_moves_to_the_spark_tier(self) -> None:
        # assert_hops already proves the thinking hint comes off on this tier too, which
        # is the point: agent-low is an ordinary group and would otherwise inherit the
        # caller's xhigh.
        body = summary_body("agent-xhigh-fast")
        self.set_knobs(EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10")
        self.assert_hops(body, SPARK_TARGET)


class TierFlagTest(RouterCase):
    """Each tier's target is an operator knob, and a tier with nowhere to go is off."""

    def test_a_custom_arc_target_moves_the_small_summary_there(self) -> None:
        self.set_knobs(EVO_T1_FAST_COMPACTION_TARGET="chat")
        self.assert_hops(summary_body("agent-xhigh-fast"), "chat")

    def test_a_custom_spark_target_moves_the_oversized_summary_there(self) -> None:
        self.set_knobs(EVO_T1_FAST_COMPACTION_SPARK_TARGET="agent-medium")
        body = summary_body("agent-swarm-fast")
        self.set_knobs(EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10")
        self.assert_hops(body, "agent-medium")

    def test_a_blank_arc_target_leaves_a_small_summary_on_its_lane(self) -> None:
        # Blank is a position an operator can choose, not a mistake: it means "the Arc
        # never answers a summary", and the safe answer is to keep the caller's own lane.
        self.set_knobs(EVO_T1_FAST_COMPACTION_TARGET="")
        body = summary_body("agent-xhigh-fast")
        self.assertIs("", retarget_target(body))
        self.assert_stays_put(body)

    def test_a_blank_spark_target_leaves_an_oversized_summary_on_its_lane(self) -> None:
        self.set_knobs(
            EVO_T1_FAST_COMPACTION_SPARK_TARGET="",
            EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10",
        )
        body = summary_body("agent-xhigh-fast")
        self.assertIs("", retarget_target(body))
        self.assert_stays_put(body)

    def test_a_target_named_after_the_arriving_lane_sends_nowhere(self) -> None:
        # agent-low is a lane the operator can pick as a session model, so a summary can
        # legitimately arrive on the group its spark tier points at. Moving it there is a
        # no-op that still costs a rewrite and drops the tool schemas, so the answer is no.
        self.set_knobs(
            EVO_T1_FAST_COMPACTION_LANES="agent-low",
            EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10",
        )
        body = summary_body("agent-low")
        self.assertIs("", retarget_target(body))
        self.assert_stays_put(body)

    def test_a_target_that_names_no_declared_group_sends_nowhere(self) -> None:
        # The two target knobs are operator input and LiteLLM validates neither, so a
        # mistyped group name would move the summary onto a model that does not exist and
        # the call would fail rather than degrade. The value is also taken whole, so a
        # comma-padded typo cannot quietly resolve to the one name that was meant.
        for typo in ("compaction-fas", "Compaction-Fast", "compaction-fast, agent-low"):
            with self.subTest(target=typo):
                self.set_knobs(EVO_T1_FAST_COMPACTION_TARGET=typo)
                body = summary_body("agent-xhigh-fast")
                self.assertIs("", retarget_target(body))
                self.assert_stays_put(body)

    def test_an_undeclared_spark_target_sends_an_oversized_summary_nowhere(
        self,
    ) -> None:
        self.set_knobs(
            EVO_T1_FAST_COMPACTION_SPARK_TARGET="agent-xhigh-fastest",
            EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10",
        )
        body = summary_body("agent-swarm-fast")
        self.assertIs("", retarget_target(body))
        self.assert_stays_put(body)

    def test_an_undeclared_target_is_refused_loudly(self) -> None:
        # A knob that silently does nothing is how a typo survives a quarter.
        self.set_knobs(EVO_T1_FAST_COMPACTION_TARGET="compaction-fas")
        with self.assertLogs("LiteLLM", level="WARNING") as caught:
            self.assertIs("", retarget_target(summary_body("agent-xhigh-fast")))
        self.assertEqual(1, len(caught.records))
        message = caught.records[0].getMessage()
        self.assertIn("compaction-fas", message)
        self.assertIn("config.yaml", message)

    def test_every_shipped_target_lane_and_parent_is_a_declared_group(self) -> None:
        # The guard the typo case leans on has to agree with the shipped config, or the
        # default policy would be refusing its own tiers.
        declared = declared_model_groups()
        self.assertTrue(declared, "the guard read no groups at all from config.yaml")
        for name in (TARGET, SPARK_TARGET, *FAST_LANES, *ORDINARY_LANES):
            self.assertIn(name, declared)

    def test_the_shipped_arc_target_still_moves(self) -> None:
        # A declared group moves, which is what makes the typo cases above about the name
        # rather than about the hook refusing to run at all.
        self.assert_hops(summary_body("agent-xhigh-fast"), TARGET)


class RoleGateTest(RouterCase):
    """Only the roles the CLI asks from can arm the hop."""

    def test_a_tool_result_that_quotes_the_ask_does_not_hop(self) -> None:
        # The repo quotes the marker verbatim in its docs and in this suite, so reading
        # one of those files back is an everyday turn on these lanes. Hopping it would
        # answer a real tool result from the summary model with its tools stripped.
        body = summary_body("agent-xhigh-fast")
        body["messages"] = [
            {"role": "system", "content": "You are the Grok Build coding agent."},
            {"role": "user", "content": "Read docs/litellm-routing.md."},
            {
                "role": "tool",
                "tool_call_id": "call_1",
                "content": "The page says: %s." % MARKER,
            },
        ]
        self.assertIs(False, should_retarget(body))
        self.assert_stays_put(body)

    def test_an_asking_role_behind_a_trailing_tool_result_does_not_hop(self) -> None:
        # The gate reads the trailing message, not any message: an earlier ask with a
        # tool result after it is a turn the agent is still working on.
        body = summary_body("agent-xhigh-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {"role": "tool", "tool_call_id": "call_1", "content": "suite passed"}
        )
        self.assertIs(False, should_retarget(body))
        self.assert_stays_put(body)

    def test_a_trailing_system_turn_that_asks_hops(self) -> None:
        # The CLI's asks are user turns; the system role stays in the gate for a caller
        # that writes the instruction there, which is only honoured when it is the
        # trailing turn as well.
        body = chat_body("agent-swarm-fast")
        body["messages"] = [
            {"role": "user", "content": "Read tests/python and add the suite."},
            {"role": "system", "content": "Task: %s." % MARKER},
        ]
        self.assertEqual(TARGET, retarget_target(body))

    def test_an_uppercase_role_still_asks(self) -> None:
        # The role on the wire is caller-supplied, so the gate compares it folded rather
        # than trusting one casing.
        body = chat_body("agent-swarm-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append({"role": "User", "content": "%s, then stop." % MARKER})
        self.assertEqual(TARGET, retarget_target(body))

    def test_the_marker_in_a_middle_turn_does_not_hop(self) -> None:
        body = chat_body("agent-xhigh-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.insert(
            1, {"role": "user", "content": "Earlier you were asked to %s." % MARKER}
        )
        self.assertIs(False, should_retarget(body))


class EstimateCompletenessTest(RouterCase):
    """The estimate has to see everything the backend will prefill."""

    def test_an_image_part_is_counted_by_its_payload(self) -> None:
        # 400,000 characters of base64 are one token to a text-only flattener, and are
        # the difference between "the Arc can read this" and "it cannot".
        body = chat_body("agent-swarm-fast")
        self.assertLess(estimate_input_tokens(body), 24000)
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": "data:image/png;base64," + "A" * 400_000},
                    },
                ],
            }
        )
        self.assertGreater(estimate_input_tokens(body), 24000)

    def test_tool_call_arguments_are_counted(self) -> None:
        body = chat_body("agent-swarm-fast")
        before = estimate_input_tokens(body)
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {
                            "name": "run_terminal_command",
                            "arguments": json.dumps({"command": "ls -la" * 20000}),
                        },
                    }
                ],
            }
        )
        self.assertGreater(estimate_input_tokens(body), before + 1000)

    def test_a_text_part_is_not_counted_twice(self) -> None:
        body = chat_body("agent-swarm-fast")
        before = estimate_input_tokens(body)
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {"role": "user", "content": [{"type": "text", "text": "a" * 4000}]}
        )
        self.assertLess(estimate_input_tokens(body) - before, 1200)

    def test_a_base64_payload_is_not_charged_the_prose_rate(self) -> None:
        # About 45,000 tokens of data URL will not fit a 32,768-token window. At four
        # characters to a token this read as 22,500 and the summary stayed on the Arc,
        # where Ollama clamps the input and the tail of the conversation is quietly gone.
        body = summary_body("agent-swarm-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.insert(
            -1,
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": "data:image/png;base64," + "A" * 90_000},
                    },
                ],
            },
        )
        self.assertGreater(estimate_input_tokens(body), 24000)
        self.assertEqual(SPARK_TARGET, retarget_target(body))

    def test_a_non_ascii_reply_is_charged_one_character_to_a_token(self) -> None:
        # 30,000 CJK characters are 30,000 tokens to any tokenizer; the prose rate read
        # them as 7,500 and put a session that compacts in Chinese onto the Arc.
        body = summary_body("agent-swarm-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.insert(-1, {"role": "user", "content": "文" * 30_000})
        self.assertGreater(estimate_input_tokens(body), 24000)
        self.assertEqual(SPARK_TARGET, retarget_target(body))

    def test_a_request_level_schema_is_counted(self) -> None:
        # The tool and response schemas ride with every turn and no message carries them.
        for key in ROUTER.PREFILLED_KEYS:
            with self.subTest(key=key):
                body = chat_body("agent-xhigh-fast")
                before = estimate_input_tokens(body)
                body[key] = {"name": "schema", "body": "y" * 200_000}
                self.assertGreater(estimate_input_tokens(body), before + 40_000)

    def test_content_that_is_a_mapping_is_counted(self) -> None:
        body = chat_body("agent-xhigh-fast")
        before = estimate_input_tokens(body)
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {
                "role": "user",
                "content": {"type": "text", "value": "z" * 200_000},
            }
        )
        self.assertGreater(estimate_input_tokens(body), before + 40_000)

    def test_a_content_part_that_is_a_plain_string_is_counted(self) -> None:
        # Some callers send the parts list as bare strings; a flattener that only reads
        # mappings would report the turn as empty.
        body = chat_body("agent-xhigh-fast")
        before = estimate_input_tokens(body)
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append({"role": "user", "content": ["a" * 4000, "b" * 4000]})
        self.assertGreaterEqual(estimate_input_tokens(body) - before, 1900)

    def test_tool_calls_that_is_not_a_list_is_still_counted(self) -> None:
        body = chat_body("agent-xhigh-fast")
        before = estimate_input_tokens(body)
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {
                "role": "assistant",
                "content": None,
                "tool_calls": {"function": {"arguments": "q" * 200_000}},
            }
        )
        self.assertGreater(estimate_input_tokens(body), before + 40_000)

    def test_a_message_name_is_counted(self) -> None:
        body = chat_body("agent-xhigh-fast")
        before = estimate_input_tokens(body)
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append({"role": "user", "content": "hi", "name": "n" * 4000})
        self.assertGreaterEqual(estimate_input_tokens(body) - before, 1000)

    def test_an_image_that_crosses_the_ceiling_picks_the_spark_tier(self) -> None:
        # The shape a real screenshot-heavy session compacts as: the prose is short, so
        # only a complete estimate keeps it off the 32k Arc model.
        body = summary_body("agent-swarm-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.insert(
            -1,
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": "data:image/png;base64," + "A" * 200_000},
                    },
                ],
            },
        )
        self.assertEqual(SPARK_TARGET, retarget_target(body))


class MalformedBodyTest(RouterCase):
    """A body the router cannot read is a body it leaves alone, never a raised error.

    The hook runs in front of every request the proxy serves, so any shape the CLI
    might send has to answer None rather than cost the request.
    """

    def test_messages_that_is_not_a_list_returns_none(self) -> None:
        body = summary_body("agent-xhigh-fast")
        body["messages"] = "please summarise the conversation"
        self.assert_stays_put(body)

    def test_a_body_with_no_model_returns_none(self) -> None:
        body = summary_body("agent-swarm-fast")
        del body["model"]
        self.assert_stays_put(body)

    def test_a_model_that_is_not_a_string_returns_none(self) -> None:
        body = summary_body("agent-swarm-fast")
        body["model"] = 42
        self.assert_stays_put(body)

    def test_a_non_string_content_returns_none(self) -> None:
        body = chat_body("agent-xhigh-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append({"role": "user", "content": 42})
        self.assert_stays_put(body)

    def test_a_content_of_parts_without_the_ask_returns_none(self) -> None:
        body = chat_body("agent-swarm-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Here is the diff, with the failing line"},
                    "a bare part that is not a mapping",
                    {"type": "text", "text": 42},
                    {"type": "image_url"},
                ],
            }
        )
        self.assert_stays_put(body)

    def test_the_ask_inside_one_content_part_does_hop(self) -> None:
        body = chat_body("agent-xhigh-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.append(
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Please"},
                    {"type": "text", "text": MARKER},
                    "a bare part that is not a mapping",
                ],
            }
        )
        self.assert_hops(body)

    def test_a_broken_classifier_costs_the_request_nothing(self) -> None:
        body = summary_body("agent-xhigh-fast")
        with (
            mock.patch.object(
                ROUTER, "retarget_target", side_effect=RuntimeError("classifier")
            ) as decision,
            mock.patch.object(ROUTER.LOGGER, "exception") as logged,
        ):
            self.assert_stays_put(body)
        self.assertEqual(1, decision.call_count)
        self.assertEqual(
            1, logged.call_count, "a swallowed decision must still be logged"
        )


class ProxyDispatchContractTest(RouterCase):
    """The two facts the config's callback entry rests on.

    ProxyLogging hands the pre-call hook to a callback only when it is a CustomLogger
    and overrides the hook in its own class dict, so an inherited or renamed one is a
    hop that silently stops happening.
    """

    def test_the_module_exposes_the_instance_the_config_names(self) -> None:
        self.assertIsNotNone(HANDLER)
        self.assertEqual("FastCompactionRouter", type(HANDLER).__name__)

    def test_the_class_itself_overrides_the_hook(self) -> None:
        self.assertIn("async_pre_call_hook", type(HANDLER).__dict__)

    def test_the_stubbed_base_never_supplied_it(self) -> None:
        self.assertNotIn("async_pre_call_hook", StubCustomLogger.__dict__)


if __name__ == "__main__":
    unittest.main()
