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
``EVO_T1_FAST_COMPACTION``                   on (``0``/``false``/``off``/``no`` off)
``EVO_T1_FAST_COMPACTION_LANES``             ``agent-xhigh-fast,agent-swarm-fast``
``EVO_T1_FAST_COMPACTION_TARGET``            ``compaction-fast``
``EVO_T1_FAST_COMPACTION_SPARK_TARGET``      ``agent-low``
``EVO_T1_FAST_COMPACTION_INPUT_LIMIT``       ``24000``
===========================================  =========================================

A switch value that is neither of those two sets leaves the hop off and says so once: an
operator who wrote something the module cannot parse meant something, and the safe reading
of "meant something I cannot tell" is the request staying where it was sent.

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

# The clause that recognises each ask, with the wrapper that has to ride with it: the
# auto-compaction ask (crates/codegen/xai-grok-shell/src/session/helpers/
# session_summary.rs) and the manual `/compact` ask (.../session_compact.rs). Each is
# matched on a stable interior clause rather than the whole sentence, so a reworded
# opening cannot unarm it. The auto ask is a sentence nobody types by hand, so its
# clause alone is the ask. The
# manual one is ordinary English -- "please summarize the conversation so far, then push"
# is a user asking for work -- so it counts only inside the tag the CLI puts around it
# (.../session_compact.rs). Matching that clause bare moved such a turn to the Arc with
# its tools, tool_choice and thinking level popped, which is a turn that can no longer
# call a tool at all, and the ceiling cannot help: the protection it gives is against
# length, and the turn that bites is a short one. Neither clause is a substring of the
# other, so a CLI that only ever sends one of the two still hops. Both are compared
# case-folded, the way the role is, so the boundary does not depend on how the sentence
# happened to start.
SUMMARY_TAG: Final = "<summary_request>"
COMPACTION_ASKS: Final = (
    ("produce a faithful, concise summary of the conversation so far", ""),
    ("summarize the conversation so far", SUMMARY_TAG),
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
# Characters per token, per class of character. English prose fits about four; a base64
# payload fits about two and a CJK reply about one, and a real conversation is full of
# the first and regularly full of the second. Charging all three the prose rate read a
# 90,000-character image as 22,500 tokens and handed it to a model with a 32,768-token
# window, which truncates the very history the summary exists to preserve. The guesses
# are not symmetric -- reading high only costs a slower target, reading low costs the
# summary itself -- so every class gets its own rate.
PROSE_CHARS_PER_TOKEN: Final = 4
BLOB_CHARS_PER_TOKEN: Final = 2
GLYPH_CHARS_PER_TOKEN: Final = 1
# The estimate is accumulated in whole-number fractions of a token, this many to one.
TOKEN_UNIT: Final = PROSE_CHARS_PER_TOKEN
# An unbroken run of this alphabet at least this long is a payload sitting in a plain
# string: a data URL, a base64 dump, a minified asset. Below it the same characters are a
# long word, a slug, or a path, and charging those the blob rate only costs the slower
# target -- which is the cheap direction, so the floor sits where ordinary text cannot
# reach. A run of nothing but lowercase is treated as prose anyway (see _text_units):
# base64 and hex are mixed-case or digit-bearing by construction.
BLOB_RUN_MIN_CHARS: Final = 64
_BLOB_RUN: Final = re.compile(r"[A-Za-z0-9+/=_-]{%d,}" % BLOB_RUN_MIN_CHARS)
_LOWERCASE_ONLY_RUN: Final = re.compile(r"[a-z]*\Z")
# Request-level keys the backend prefills and no message carries: the schemas a call is
# given, and the Responses API's system prompt under ``instructions``. Left unbilled they
# read as nothing, and a 200 KB tool schema is the difference between the two tiers.
PREFILLED_KEYS: Final = (
    "instructions",
    "tools",
    "tool_choice",
    "functions",
    "function_call",
    "response_format",
    "audio",
    "prediction",
    "web_search_options",
)

# A ``model_name:`` entry at any indent in the config beside this module. Read as text
# rather than parsed as YAML: the only question asked of the file is whether one string is
# one of these values, and a parser would be a second way for the routing file to break
# this module's boot. The quotes come off because YAML accepts them and a quoted group is
# the same group -- a matcher that kept them would report every shipped target undeclared
# and park every summary on its lane behind one warning line nobody reads.
_MODEL_NAME_LINE: Final = re.compile(r"^[ \t]*-[ \t]+model_name:[ \t]*([^ \t#]+)")
# The window one of those entries declares, read from the same text for the same reason.
# Only a whole non-negative integer counts: a value this module cannot read is a value it
# has no business clamping against, so it comes back as "no window declared" and the
# operator's own guard stands.
_MAX_INPUT_TOKENS_LINE: Final = re.compile(
    r"^[ \t]+max_input_tokens:[ \t]*([0-9]+)[ \t]*$"
)


@functools.lru_cache(maxsize=1)
def _read_config_text() -> str:
    """The routing config beside this module, read once per process.

    Cached on the text rather than on the parsed set so that a failed read is not what
    the cache remembers: caching an empty set would leave both target knobs unchecked for
    the life of the proxy off one transient EIO, and an unchecked knob is the mistake
    this guard exists to catch.
    """
    return (pathlib.Path(__file__).resolve().parent / "config.yaml").read_text(
        encoding="utf-8"
    )


def declared_model_groups() -> frozenset[str]:
    """The model groups the routing config beside this module declares.

    The two target knobs are operator input and neither is validated by LiteLLM: point one
    at a group nobody declared and the summary call is moved onto a model that does not
    exist, where it fails instead of degrading -- and a mistyped knob looks exactly like a
    working one until the next compaction. An unreadable file returns the empty set and
    the caller treats that as "nothing to check against", because a missing config is a
    reason to keep the hop the alias asked for, not to disarm it. The read is retried on
    the next call rather than remembered.
    """
    try:
        text = _read_config_text()
    except OSError:
        LOGGER.warning(
            "compaction router: cannot read the config beside this module;"
            " the two target knobs go unchecked"
        )
        return frozenset()
    return frozenset(
        match.group(1).strip("'\"")
        for line in text.splitlines()
        if (match := _MODEL_NAME_LINE.match(line))
    )


def declared_input_window(model: str) -> int | None:
    """The window ``config.yaml`` declares for *model*, or None when it declares none.

    This is the second half of the guard: LiteLLM validates neither target knob, and it
    does not check a request against the ``max_input_tokens`` of the deployment it picks
    either -- at the pinned tag the router has no context-window pre-call check, so an
    input past the window goes to Ollama and comes back truncated rather than raising.
    The number is therefore only in the routing file, and this is the only place that
    reads it.

    Scanned entry by entry rather than file-wide: ``max_input_tokens`` is per deployment,
    so the first number after the matching ``model_name:`` and before the next entry (or
    a top-level key) is the one that belongs to this group. A blank line or a comment
    inside the block neither ends the block nor supplies a window.
    """
    try:
        lines = _read_config_text().splitlines()
    except OSError:
        LOGGER.warning(
            "compaction router: cannot read the config beside this module;"
            " the Arc window goes unchecked"
        )
        return None
    inside = False
    window: int | None = None
    for line in lines:
        entry = _MODEL_NAME_LINE.match(line)
        if entry is not None:
            inside = entry.group(1).strip("'\"") == model
            continue
        if not line.strip():
            continue
        if line[:1] not in (" ", "\t"):
            inside = False
            continue
        if inside and window is None and not line.lstrip().startswith("#"):
            declared = _MAX_INPUT_TOKENS_LINE.match(line)
            if declared is not None:
                digits = int(declared.group(1))
                if digits > 0:
                    window = digits
    return window


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


@functools.lru_cache(maxsize=8)
def _warn_unknown_switch(raw: str) -> None:
    """One line per distinct unparseable switch value, not one per request.

    A value that is neither on nor off is an operator who meant something, and the two
    guesses are not equal: a hop that silently stays armed after ``EVO_T1_FAST_COMPACTION
    =disabled`` is a knob that does not do what it was set to, while a hop that silently
    stops is the documented stay-put. So the switch goes off and says why.
    """
    LOGGER.warning(
        "compaction router: EVO_T1_FAST_COMPACTION=%r is neither on nor off; leaving the"
        " hop off -- name one of %s to arm it",
        raw,
        ", ".join(sorted(ENABLED_VALUES)),
    )


def fast_compaction_enabled() -> bool:
    """Whether the hop is armed at all; the default is on, and the alias choice is the opt-in.

    Anything that parses as neither an on nor an off value leaves it off: an unrecognised
    spelling is an operator's own edit, and guessing "on" would keep a summary hopping
    after the operator asked for it not to.
    """
    raw = _setting("EVO_T1_FAST_COMPACTION", "1")
    value = raw.casefold()
    if value in DISABLED_VALUES:
        return False
    if value not in ENABLED_VALUES:
        _warn_unknown_switch(raw)
        return False
    return True


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


@functools.lru_cache(maxsize=8)
def _warn_clamped_ceilings(target: str, guard: int, window: int) -> None:
    """One line per distinct clamp, not one per summary.

    Raising ``EVO_T1_FAST_COMPACTION_INPUT_LIMIT`` is an operator decision this module
    must not silently overrule, so the override says what it did and why: the group's own
    declared window is a fact about the weights, and a guard above it would park a summary
    inside a model that answers from a truncated reading of the history.
    """
    LOGGER.warning(
        "compaction router: EVO_T1_FAST_COMPACTION_INPUT_LIMIT=%d is above the %d tokens"
        " config.yaml declares for %r; forking at the declared window instead",
        guard,
        window,
        target,
    )


def arc_input_ceiling(target: str) -> int:
    """The largest input the Arc tier may actually be handed.

    The operator's guard is the policy and the group's declared ``max_input_tokens`` is
    the physics, so the smaller of the two forks the tier. Reading the guard alone let
    ``EVO_T1_FAST_COMPACTION_INPUT_LIMIT=100000`` park a summary inside a 32k model, and
    the pinned LiteLLM has no context-window check between here and Ollama: the request
    would go, come back answered from a truncated reading, and read as a success. That is
    the one outcome this fork exists to prevent, so a knob cannot reach past it.

    A target with no declared window leaves the guard whole. Every shipped Arc target
    declares one, and inventing a ceiling for a group the operator pointed the knob at
    would refuse a hop that was deliberately asked for.
    """
    guard = max_compaction_input_tokens()
    window = declared_input_window(target) if target else None
    if window is None or window >= guard:
        return guard
    _warn_clamped_ceilings(target, guard, window)
    return window


def _content_text(content: object) -> str:
    """Flatten one message's content, which is a string or a list of typed parts.

    A list holds dicts for the Chat Completions shape and bare strings for the shapes
    some callers send; both are prose here, and anything else in the list is a payload
    the caller below bills by its serialized size.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                text = part.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    return ""


def _serialized_chars(value: object) -> int:
    """Size of ``value`` once it is on the wire, which is what a backend prefills."""
    return len(json.dumps(value, sort_keys=True, default=str, ensure_ascii=False))


def _prose_and_glyph_units(text: str) -> int:
    """``text`` in TOKEN_UNIT fractions, weighted by which character classes it holds.

    ASCII is the class that gets the prose rate and everything else the glyph rate: a
    token of CJK or of Cyrillic costs a whole token each, so those characters are charged
    PROSE_CHARS_PER_TOKEN times their count. Escaped JSON punctuation is ASCII and so
    takes the prose rate, which is this flattener's known under-read; the shape that
    carries escaped JSON as payload rather than as text is a mapping or a tool argument,
    and those are billed by their serialized size in ``_extra_units``, not here.
    """
    prose = sum(1 for char in text if char.isascii())
    glyphs = len(text) - prose
    return prose * (TOKEN_UNIT // PROSE_CHARS_PER_TOKEN) + glyphs * (
        TOKEN_UNIT // GLYPH_CHARS_PER_TOKEN
    )


def _text_units(text: str) -> int:
    """``text`` in TOKEN_UNIT fractions of a token, with payloads billed at their own rate.

    A string is not automatically prose. An OpenAI ``role: "tool"`` turn carries its
    result as a plain string, and so does every ordinary user and assistant turn, so a
    pasted data URL or a base64 dump reaches here as text and would be read at four
    characters to a token -- half the truth for that payload. The same bytes sitting in a
    content *part* already bill at the blob rate, which makes the shape of the turn, and
    not the payload, decide whether a summary is handed a window it cannot hold.
    """
    units = 0
    cursor = 0
    for run in _BLOB_RUN.finditer(text):
        chunk = run.group(0)
        if _LOWERCASE_ONLY_RUN.match(chunk):
            # A long slug, not a payload: base64 and hex are mixed-case or digit-bearing
            # by construction, and a run of nothing but lowercase is a word nobody will
            # ever fill a turn with. Reading it as a blob costs a slower target; reading
            # a real blob as prose costs the summary its tail, so only the second one is
            # a mistake worth guarding.
            continue
        units += _prose_and_glyph_units(text[cursor : run.start()])
        units += _blob_units(len(chunk))
        cursor = run.end()
    return units + _prose_and_glyph_units(text[cursor:])


def _blob_units(chars: int) -> int:
    """``chars`` of opaque payload, which packs denser than prose."""
    return chars * (TOKEN_UNIT // BLOB_CHARS_PER_TOKEN)


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
    asks from, and it has to *be* one of the two asks: the clause has to sit in that
    turn, the wrapper the manual ask ships in has to sit there too, and the turn has to
    be about the size of the instruction. The system prompt is
    deliberately not consulted. A summary request always carries the ask as its last
    turn, while the rulebook sitting at ``messages[0]`` is shared by every turn of the
    session, so matching there would move an entire conversation onto the summary target
    the moment an operator pasted the sentence printed in docs/litellm-routing.md into
    a workspace AGENTS.md. A turn that only quotes an ask is answered by its own lane,
    with its tools intact: the ceiling rules a quoted ask out by length and the wrapper
    rules the quotable one out by shape, because a hopped quote loses its tools, its
    tool choice and its thinking level, which is a turn that can no longer act.
    """
    last = _asking_turn(data)
    if last is None:
        return False
    text = _content_text(last.get("content"))
    if not text or len(text) > MAX_ASK_CHARS:
        return False
    folded = text.casefold()
    return any(
        clause in folded and (not wrapper or wrapper in folded)
        for clause, wrapper in COMPACTION_ASKS
    )


def _extra_units(message: dict[str, object]) -> int:
    """What this turn makes the backend prefill that ``_content_text`` drops.

    Three shapes are invisible to the text flatteners and each is a real payload: a
    content part with no ``text`` (an image's base64 data URL is the case that matters),
    a ``content`` that is a mapping rather than a string or a list, and an assistant's
    ``tool_calls`` arguments, whose serialized size is not a list at all when a caller
    sends a single call as a dict. A text-only flattener reads a 400,000-character image
    as one token, which is the whole failure this function exists to close.
    """
    units = 0
    content = message.get("content")
    if isinstance(content, dict):
        units += _blob_units(_serialized_chars(content))
    elif isinstance(content, list):
        for part in content:
            # Anything in the list that contributed no prose is a payload: an image's
            # data URL, a file reference, or a part shaped like neither of the two the
            # protocol defines. All of them are prefilled, none of them is visible to
            # the text flattener, and a 400,000-character image read as one token is
            # exactly how an oversized summary reached a 32k model.
            if isinstance(part, str):
                continue
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                continue
            units += _blob_units(_serialized_chars(part))
    calls = message.get("tool_calls")
    if calls:
        units += _blob_units(_serialized_chars(calls))
    return units


def estimate_input_tokens(data: dict[str, object]) -> int:
    """Rough input size of the request, counting the schemas riding along with it.

    The proxy has no tokenizer here and the Arc lane has no headroom to guess about, so
    this counts what the backend will actually prefill: every turn's text at its own
    character rates, the payloads those rates cannot see at the blob rate, and each
    request-level schema key. It is an estimate with one job, and it errs toward the
    larger number, because the tier it would rather not use still answers correctly.
    """
    units = 0
    for message in _messages(data):
        if isinstance(message, dict):
            units += _text_units(_content_text(message.get("content")))
            units += _extra_units(message)
            name = message.get("name")
            if isinstance(name, str):
                units += _text_units(name)
    for key in PREFILLED_KEYS:
        value = data.get(key)
        if value:
            units += _blob_units(_serialized_chars(value))
    return units // TOKEN_UNIT


def retarget_target(data: dict[str, object]) -> str:
    """The group a recognised summary moves to, or "" when it stays where it is.

    The ceiling is a fork rather than a wall. Within it the Arc reads the conversation
    whole and answers fastest; above it no 32k model can, so the summary goes to a Spark
    group that keeps the window and drops the thinking level. The Arc side of that fork
    is the operator's guard clamped to the window the Arc group itself declares, so no
    value of ``EVO_T1_FAST_COMPACTION_INPUT_LIMIT`` can park a summary inside a model too
    small to read it. A tier whose target is
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
    arc_target = fast_compaction_target()
    if estimate_input_tokens(data) <= arc_input_ceiling(arc_target):
        target = arc_target
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
