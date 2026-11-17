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
TARGET: Final = "compaction-fast"
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
estimate_input_tokens: Final = cast(
    "Callable[[dict[str, object]], int]", ROUTER.estimate_input_tokens
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

    def assert_hops(self, body: dict[str, object]) -> dict[str, object]:
        """The call must move: the same dict back, retargeted, with the extras dropped."""
        for key in DROPPED_KEYS:
            self.assertIn(key, body, "the case must send what a hop is meant to drop")
        messages = body["messages"]
        handed, result = self.call(body)
        self.assertIs(result, handed, "the hook must return the dict it mutated")
        self.assertEqual(TARGET, handed.get("model"))
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

    def test_the_ask_in_the_system_prompt_still_counts(self) -> None:
        body = chat_body("agent-swarm-fast")
        body["messages"] = [
            {"role": "system", "content": "You must %s, in under 400 words." % MARKER},
            {"role": "user", "content": "Summarise this session."},
        ]
        self.assertIs(True, should_retarget(body))

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

    def test_an_estimate_above_the_ceiling_stays_on_the_lane(self) -> None:
        body = summary_body("agent-xhigh-fast")
        self.set_knobs(EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10")
        self.assertGreater(estimate_input_tokens(body), 10)
        self.assertIs(False, should_retarget(body))

    def test_the_shipped_ceiling_keeps_an_oversized_summary_on_the_lane(self) -> None:
        body = summary_body("agent-swarm-fast")
        messages = cast("list[dict[str, object]]", body["messages"])
        messages.insert(
            -1, {"role": "user", "content": "the session, line after line\n" * 4000}
        )
        self.assertGreater(estimate_input_tokens(body), 24000)
        self.assertIs(False, should_retarget(body))

    def test_an_estimate_exactly_at_the_ceiling_still_hops(self) -> None:
        body = summary_body("agent-swarm-fast")
        self.set_knobs(
            EVO_T1_FAST_COMPACTION_INPUT_LIMIT=str(estimate_input_tokens(body))
        )
        self.assertIs(True, should_retarget(body))

    def test_an_estimate_one_above_the_ceiling_does_not(self) -> None:
        body = summary_body("agent-swarm-fast")
        self.set_knobs(
            EVO_T1_FAST_COMPACTION_INPUT_LIMIT=str(estimate_input_tokens(body) - 1)
        )
        self.assertIs(False, should_retarget(body))


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

    def test_an_oversized_summary_comes_back_untouched(self) -> None:
        body = summary_body("agent-xhigh-fast")
        self.set_knobs(EVO_T1_FAST_COMPACTION_INPUT_LIMIT="10")
        self.assert_stays_put(body)


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
                ROUTER, "should_retarget", side_effect=RuntimeError("classifier")
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
