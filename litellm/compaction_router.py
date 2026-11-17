#!/usr/bin/env python3
"""Move the Grok CLI's conversation-summary call off its extra-high Spark lane.

The Grok Build CLI has no compaction-model setting. The summary call it makes when a
session nears its context window rides the session model, and on a Spark lane that means
Qwen3.8-Flash-Next answering at extra-high thinking -- which is most of what a summary
costs, because a summary needs no thinking at all. The two fast-compaction lanes
(``agent-xhigh-fast`` and ``agent-swarm-fast``) therefore ask this callback to move that
one call off the thinking level it was billed at, onto a target chosen by how much the
summary has to read, and every other call of the same conversation stays where it was.
Both of the CLI's two asks are recognised: the one it appends at the auto-compaction
threshold and the one ``/compact`` appends inside a ``<summary_request>`` tag.

Registered in litellm/config.yaml as ``litellm_settings.callbacks`` entry
``compaction_router.proxy_handler_instance``, and bind-mounted by docker-compose.yml at
``/app/compaction_router.py``: the proxy resolves a callback's dotted name against the
directory holding the config file, so the file has to sit beside the config rather than
in a subdirectory.

Everything a caller can tune is an environment variable read here and nowhere else, so
one ``docker compose up`` view shows the whole policy:

===========================================  =========================================
variable                                     default
===========================================  =========================================
``EVO_T1_FAST_COMPACTION``                   on (``0``/``false``/``off`` disable it)
``EVO_T1_FAST_COMPACTION_LANES``             ``agent-xhigh-fast,agent-swarm-fast``
``EVO_T1_FAST_COMPACTION_TARGET``            ``compaction-fast``
``EVO_T1_FAST_COMPACTION_SPARK_TARGET``      ``agent-low``
``EVO_T1_FAST_COMPACTION_INPUT_LIMIT``       ``24000``
===========================================  =========================================

Two targets, split by what the summary has to read. A summary within the ceiling goes to
``compaction-fast``, the small Ollama-served coding weight on the Arc, which is where the
speed comes from. One above it cannot go there: the Arc weights answer inside a 32k
window, so a bigger input would be truncated into a useless summary of the very history it
exists to preserve. That one goes to ``EVO_T1_FAST_COMPACTION_SPARK_TARGET`` instead --
the same three Spark boxes, the same warm prefix cache, ``low`` baked into its thinking
level rather than ``xhigh``, because a summary is prose and needs no reasoning at all.
Ollama accepts a per-request ``num_ctx``; it is deliberately not raised here, because a
window above what the weights were trained on silently degrades the answer.

A tier whose target reads blank, or names the group the call arrived on, has nowhere to
send the call, and the call stays exactly where its caller put it. A tier whose target names
no group ``config.yaml`` declares is refused the same way, with one warning line: LiteLLM
validates neither knob, so a typo there would move the summary onto a model that does not
exist and fail the call that this module exists to speed up. Staying put is the safe
position rather than a failure: the request still answers, only slowly.
"""

from __future__ import annotations

import functools
import json
import logging
import os
import pathlib
import re
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    # The gate types this module without LiteLLM installed, so the base class the proxy
    # needs is stood in for here and imported for real at runtime. ProxyLogging dispatches
    # the hook only to a callback that IS a CustomLogger and overrides async_pre_call_hook
    # in its own class dict, so the runtime base is load-bearing, not decoration.
    class CustomLogger:
        enforces_request_content: bool

        def __init__(self, **kwargs: object) -> None: ...

else:
    from litellm.integrations.custom_logger import CustomLogger

LOGGER: Final = logging.getLogger("LiteLLM")

# The two instructions the Grok CLI appends when it asks for a summary: the
# auto-compaction ask (crates/codegen/xai-grok-shell/src/session/helpers/
# session_summary.rs) and the manual `/compact` ask (.../session_compact.rs), which the
# CLI wraps in a <summary_request> tag. Each is matched on a stable interior clause
# rather than the whole sentence, so a reworded opening cannot unarm it. The second is
# the shorter of the two and is not a substring of the first, so neither subsumes it and
# a CLI that only ever sends one of the two still hops.
COMPACTION_MARKERS: Final = (
    "produce a faithful, concise summary of the conversation so far",
    "summarize the conversation so far",
)

# How long the trailing turn may be and still be an ask. Both instructions are the whole
# message -- roughly 1,100 characters for the auto ask and 900 for the tagged manual one
# -- so the CLI appends the ask with nothing else in the turn. The ceiling is what tells
# an ask from a turn that merely quotes one: this repo prints both sentences in
# docs/litellm-routing.md, and a message long enough to be carrying a thought around that
# sentence is conversation, not the CLI asking.
MAX_ASK_CHARS: Final = 4000

DISABLED_VALUES: Final = frozenset({"0", "false", "off", "no"})
ENABLED_VALUES: Final = frozenset({"1", "true", "on", "yes"})
# The two roles the CLI writes the summary ask from. A trailing message in any other
# role -- a tool result, an assistant turn -- is conversation content that quotes the
# sentence rather than the CLI asking for a summary. Compared case-folded, because the
# role a caller puts on the wire is not something this module can pin.
ASKING_ROLES: Final = frozenset({"user", "system"})
# The key each protocol carries its turns under: Chat Completions and Anthropic Messages
# send ``messages``, the Responses API sends ``input``. The CLI picks with ``api_backend``
# and defaults to chat_completions, so ``input`` is the arm that keeps the hop alive if
# an operator ever points a fast alias at the Responses protocol.
REQUEST_TURN_KEYS: Final = ("messages", "input")
DEFAULT_LANES: Final = "agent-xhigh-fast,agent-swarm-fast"
DEFAULT_TARGET: Final = "compaction-fast"
DEFAULT_SPARK_TARGET: Final = "agent-low"
DEFAULT_INPUT_LIMIT: Final = 24000
# Four characters per token is the usual rough fit for English prose. An underestimate
# now costs more than a slow answer -- it sends a summary the Arc cannot read to the Arc
# -- so the count below leans generous and takes the structural characters with it.
CHARS_PER_TOKEN: Final = 4

# A ``model_name:`` entry at any indent in the config beside this module. Read as text
# rather than parsed as YAML: the only question asked of the file is whether one string is
# one of these values, and a parser would be a second way for the routing file to break
# this module's boot.
_MODEL_NAME_LINE: Final = re.compile(r"^[ \t]*-[ \t]+model_name:[ \t]*([^ \t#]+)")


@functools.lru_cache(maxsize=1)
def declared_model_groups() -> frozenset[str]:
    """The model groups the routing config beside this module declares.

    The two target knobs are operator input and neither is validated by LiteLLM: point one
    at a group nobody declared and the summary call is moved onto a model that does not
    exist, where it fails instead of degrading -- and a mistyped knob looks exactly like a
    working one until the next compaction. An unreadable file returns the empty set and the
    caller treats that as "nothing to check against", because a missing config is a reason
    to keep the hop the alias asked for, not to disarm it.
    """
    try:
        text = (pathlib.Path(__file__).resolve().parent / "config.yaml").read_text(
            encoding="utf-8"
        )
    except OSError:
        LOGGER.warning(
            "compaction router: cannot read the config beside this module;"
            " the two target knobs go unchecked"
        )
        return frozenset()
    return frozenset(
        match.group(1)
        for line in text.splitlines()
        if (match := _MODEL_NAME_LINE.match(line))
    )


def _target_is_declared(target: str, declared: frozenset[str]) -> bool:
    """Whether a tier may be used, with an unreadable config read as no objection."""
    if not declared:
        return True
    if target in declared:
        return True
    LOGGER.warning(
        "compaction router: target %r is no model group in config.yaml;"
        " leaving the summary on its lane",
        target,
    )
    return False


def _setting(name: str, default: str) -> str:
    """Read one environment knob, treating blank as unset."""
    value = os.environ.get(name)
    if value is None or not value.strip():
        return default
    return value.strip()


def _target_setting(name: str, default: str) -> str:
    """Read one target knob, keeping a blank blank.

    An unset destination means the shipped one; a destination the operator cleared means
    this tier has nowhere to send the call. Reading either as the default would move the
    call they were parking, and a rewritten ``model`` cannot be undone from here.
    """
    value = os.environ.get(name)
    return default if value is None else value.strip()


def fast_compaction_enabled() -> bool:
    """Whether the hop is armed at all; the default is on, and the alias choice is the opt-in."""
    return _setting("EVO_T1_FAST_COMPACTION", "1").lower() not in DISABLED_VALUES


def fast_compaction_lanes() -> frozenset[str]:
    """The model groups whose compaction call may leave the lane."""
    return frozenset(
        part
        for part in (
            raw.strip()
            for raw in _setting("EVO_T1_FAST_COMPACTION_LANES", DEFAULT_LANES).split(
                ","
            )
        )
        if part
    )


def fast_compaction_target() -> str:
    """The Arc model group a summary small enough to read whole is moved to."""
    return _target_setting("EVO_T1_FAST_COMPACTION_TARGET", DEFAULT_TARGET)


def fast_compaction_spark_target() -> str:
    """The Spark model group a summary too big for the Arc is moved to."""
    return _target_setting("EVO_T1_FAST_COMPACTION_SPARK_TARGET", DEFAULT_SPARK_TARGET)


def max_compaction_input_tokens() -> int:
    """The largest summary input the Arc target can actually hold."""
    raw = _setting("EVO_T1_FAST_COMPACTION_INPUT_LIMIT", str(DEFAULT_INPUT_LIMIT))
    try:
        return int(raw)
    except ValueError:
        LOGGER.warning(
            "compaction router: EVO_T1_FAST_COMPACTION_INPUT_LIMIT=%r is not a count;"
            " using %d",
            raw,
            DEFAULT_INPUT_LIMIT,
        )
        return DEFAULT_INPUT_LIMIT


def _content_text(content: object) -> str:
    """Flatten one message's content, which is a string or a list of typed parts."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, dict):
                text = part.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    return ""


def _messages(data: dict[str, object]) -> list[object]:
    """The turns of a request body, under whichever key its protocol uses."""
    for key in REQUEST_TURN_KEYS:
        raw = data.get(key)
        if isinstance(raw, list):
            return list(raw)
    return []


def _asking_turn(data: dict[str, object]) -> dict[str, object] | None:
    """The trailing turn, but only when its role is one the CLI asks from.

    The ask is the last thing in the body, so a body whose trailing turn is a tool
    result or an assistant turn is not a compaction no matter what it says: reading
    those is how an agent that just cat-ed one of the pages quoting this sentence would
    have its real turn answered from the summary target with its tools stripped.
    """
    messages = _messages(data)
    if not messages:
        return None
    last = messages[-1]
    if not isinstance(last, dict):
        return None
    role = last.get("role")
    if not isinstance(role, str) or role.casefold() not in ASKING_ROLES:
        return None
    return last


def is_compaction_request(data: dict[str, object]) -> bool:
    """Whether this request is the CLI asking for a summary of the conversation.

    Two conditions, both about the trailing turn. It has to be a turn the CLI writes
    asks from, and it has to *be* one of the two asks: the sentence has to sit in that
    turn and the turn has to be about the size of the instruction. The system prompt is
    deliberately not consulted. A summary request always carries the ask as its last
    turn, while the rulebook sitting at ``messages[0]`` is shared by every turn of the
    session, so matching there would move an entire conversation onto the summary target
    the moment an operator pasted the sentence printed in docs/litellm-routing.md into
    a workspace AGENTS.md. The one residue the ceiling cannot cover is a user turn whose
    entire content is the quoted instruction; that turn is answered by the summary
    target, which is the pre-hop behaviour for any message a session sends on a
    non-fast alias.
    """
    last = _asking_turn(data)
    if last is None:
        return False
    text = _content_text(last.get("content"))
    if not text or len(text) > MAX_ASK_CHARS:
        return False
    return any(marker in text for marker in COMPACTION_MARKERS)


def _extra_chars(message: dict[str, object]) -> int:
    """Characters this turn makes the backend prefill that ``_content_text`` drops.

    A content part with no ``text`` -- an image's base64 payload is the case that
    matters -- and an assistant's ``tool_calls`` arguments are both prefilled and both
    invisible to the text flatteners, which read a 400,000-character image as one token.
    The estimate's only job is keeping an oversized summary off a 32k model, so it counts
    what goes over the wire rather than what a human would call prose.
    """
    chars = 0
    content = message.get("content")
    if isinstance(content, list):
        for part in content:
            if isinstance(part, dict) and not isinstance(part.get("text"), str):
                chars += len(json.dumps(part, sort_keys=True, default=str))
    calls = message.get("tool_calls")
    if isinstance(calls, list):
        chars += len(json.dumps(calls, sort_keys=True, default=str))
    return chars


def estimate_input_tokens(data: dict[str, object]) -> int:
    """Rough input size of the request, counting the schemas riding along with it.

    The proxy has no tokenizer here and the Arc lane has no headroom to guess about, so
    this counts characters over everything the backend will actually prefill. It is an
    estimate with one job: pick the tier that can read the whole conversation.
    """
    chars = 0
    for message in _messages(data):
        if isinstance(message, dict):
            chars += len(_content_text(message.get("content")))
            chars += _extra_chars(message)
            name = message.get("name")
            if isinstance(name, str):
                chars += len(name)
    tools = data.get("tools")
    if tools:
        chars += len(json.dumps(tools, sort_keys=True, default=str))
    return chars // CHARS_PER_TOKEN


def retarget_target(data: dict[str, object]) -> str:
    """The group a recognised summary moves to, or "" when it stays where it is.

    The ceiling is a fork rather than a wall. Within it the Arc reads the conversation
    whole and answers fastest; above it no 32k model can, so the summary goes to a Spark
    group that keeps the window and drops the thinking level. A tier whose target is
    blank, or is the group the call already arrived on, has nowhere to send the call, and
    the "" answer leaves the request exactly as its caller sent it.
    """
    if not fast_compaction_enabled():
        return ""
    model = data.get("model")
    if not isinstance(model, str) or model not in fast_compaction_lanes():
        return ""
    if not _messages(data):
        return ""
    if not is_compaction_request(data):
        return ""
    if estimate_input_tokens(data) <= max_compaction_input_tokens():
        target = fast_compaction_target()
    else:
        target = fast_compaction_spark_target()
    if not target or target == model:
        return ""
    if not _target_is_declared(target, declared_model_groups()):
        return ""
    return target


def should_retarget(data: dict[str, object]) -> bool:
    """The whole decision as a yes or no, for a caller that only asks that."""
    return bool(retarget_target(data))


class FastCompactionRouter(CustomLogger):
    """The one callback allowed to move a request off its declared Spark lane."""

    # Left False on purpose: this hook rewrites the payload for routing, and the base
    # class documents that a routing rewrite stays False while a content judge flips it.
    enforces_request_content = False

    async def async_pre_call_hook(
        self,
        user_api_key_dict: object,
        cache: object,
        data: dict[str, object],
        call_type: str,
    ) -> dict[str, object] | None:
        """Rewrite the model of a compaction call, before the router picks a deployment.

        Returns the mutated dict when the call moves, and None every other time so the
        request continues exactly as its caller sent it.
        """
        try:
            target = retarget_target(data)
        except Exception:  # a broken classifier must never cost a request
            LOGGER.exception(
                "compaction router: decision failed; leaving the request on its lane"
            )
            return None
        if not target:
            return None
        original = data.get("model")
        data["model"] = target
        # A summary is prose: the tool schemas are dead weight to it, the tool-choice hint
        # can make a small model answer with a call instead of a summary, and the thinking
        # level is the cost this hop exists to stop paying.
        data.pop("tools", None)
        data.pop("tool_choice", None)
        data.pop("reasoning_effort", None)
        LOGGER.info(
            "compaction router: moved a summary call from %s to %s", original, target
        )
        return data


proxy_handler_instance: Final = FastCompactionRouter()
