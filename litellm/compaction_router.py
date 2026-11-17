#!/usr/bin/env python3
"""Move the Grok CLI's conversation-summary call onto the stack's fast Arc lane.

The Grok Build CLI has no compaction-model setting. The summary call it makes when a
session nears its context window rides the session model, and on a Spark lane that means
Qwen3.8-Flash-Next answering at extra-high thinking -- which is most of what a summary
costs, because a summary needs no thinking at all. The two fast-compaction lanes
(``agent-xhigh-fast`` and ``agent-swarm-fast``) therefore ask this callback to move that
one call onto ``compaction-fast``, the small Ollama-served coding weight on the Arc, and
every other call of the same conversation stays on its Spark box.

Registered in litellm/config.yaml as ``litellm_settings.callbacks`` entry
``compaction_router.proxy_handler_instance``, and bind-mounted by docker-compose.yml at
``/app/compaction_router.py``: the proxy CLI puts the working directory on ``sys.path``,
so the file has to sit beside the config rather than in a subdirectory.

Everything a caller can tune is an environment variable read here and nowhere else, so
one ``docker compose up`` view shows the whole policy:

===========================================  =========================================
variable                                     default
===========================================  =========================================
``EVO_T1_FAST_COMPACTION``                   on (``0``/``false``/``off`` disable it)
``EVO_T1_FAST_COMPACTION_LANES``             ``agent-xhigh-fast,agent-swarm-fast``
``EVO_T1_FAST_COMPACTION_TARGET``            ``compaction-fast``
``EVO_T1_FAST_COMPACTION_INPUT_LIMIT``       ``24000``
===========================================  =========================================

The token ceiling is the safety half of the design. The Arc weights answer inside a 32k
window, so a summary whose input is estimated above the ceiling is left on the Spark lane
rather than truncated into a useless summary: the slow path is a worse day than a bad
memory. Ollama accepts a per-request ``num_ctx``; it is deliberately not raised here,
because a window above what the weights were trained on silently degrades the answer.
"""

from __future__ import annotations

import json
import logging
import os
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

# The instruction the Grok CLI appends when it asks for a summary. Matched on a stable
# interior clause rather than the whole sentence, so a reworded opening cannot unarm it.
COMPACTION_MARKER: Final = (
    "produce a faithful, concise summary of the conversation so far"
)

DISABLED_VALUES: Final = frozenset({"0", "false", "off", "no"})
DEFAULT_LANES: Final = "agent-xhigh-fast,agent-swarm-fast"
DEFAULT_TARGET: Final = "compaction-fast"
DEFAULT_INPUT_LIMIT: Final = 24000
# Four characters per token is the usual rough fit for English prose and it is the wrong
# direction to be wrong in here: an underestimate only leaves a call on the Spark lane.
CHARS_PER_TOKEN: Final = 4


def _setting(name: str, default: str) -> str:
    """Read one environment knob, treating blank as unset."""
    value = os.environ.get(name)
    if value is None or not value.strip():
        return default
    return value.strip()


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
    """The model group a recognised compaction call is moved to."""
    return _setting("EVO_T1_FAST_COMPACTION_TARGET", DEFAULT_TARGET)


def max_compaction_input_tokens() -> int:
    """The largest summary input the target lane can actually hold."""
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
    raw = data.get("messages")
    return list(raw) if isinstance(raw, list) else []


def is_compaction_request(data: dict[str, object]) -> bool:
    """Whether this request is the CLI asking for a summary of the conversation.

    The instruction lands as the trailing message, with the system prompt beside it, so
    both are read and nothing in between is: a conversation that merely quotes the
    sentence is not a compaction call, and the newest message is where the CLI puts it.
    """
    messages = _messages(data)
    if not messages:
        return False
    candidates: list[object] = [messages[-1]]
    first = messages[0]
    if isinstance(first, dict) and first.get("role") == "system":
        candidates.append(first)
    for message in candidates:
        content = message.get("content") if isinstance(message, dict) else None
        if COMPACTION_MARKER in _content_text(content):
            return True
    return False


def estimate_input_tokens(data: dict[str, object]) -> int:
    """Rough input size of the request, counting the schemas riding along with it.

    The proxy has no tokenizer here and the Arc lane has no headroom to guess about, so
    this counts characters over everything the backend will actually prefill. It is an
    estimate with one job: keep an oversized summary off a 32k model.
    """
    chars = 0
    for message in _messages(data):
        if isinstance(message, dict):
            chars += len(_content_text(message.get("content")))
            name = message.get("name")
            if isinstance(name, str):
                chars += len(name)
    tools = data.get("tools")
    if tools:
        chars += len(json.dumps(tools, sort_keys=True, default=str))
    return chars // CHARS_PER_TOKEN


def should_retarget(data: dict[str, object]) -> bool:
    """The whole decision, kept apart from the mutation so a test can ask it alone."""
    if not fast_compaction_enabled():
        return False
    model = data.get("model")
    if not isinstance(model, str) or model not in fast_compaction_lanes():
        return False
    if not _messages(data):
        return False
    if not is_compaction_request(data):
        return False
    return estimate_input_tokens(data) <= max_compaction_input_tokens()


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
            if not should_retarget(data):
                return None
        except Exception:  # a broken classifier must never cost a request
            LOGGER.exception(
                "compaction router: decision failed; leaving the request on its lane"
            )
            return None
        target = fast_compaction_target()
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
