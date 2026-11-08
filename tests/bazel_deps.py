#!/usr/bin/env python3
"""Program purpose: check the Bazel target-to-file maps against the sources that use them.

`scripts/BUILD.bazel` and `tests/BUILD.bazel` carry the record of which repo file each
target reads: `_SCRIPT_LIBS` / `_SCRIPT_PAYLOAD` / `_SCRIPT_PAYLOAD_ALLOW` for the CLI
targets, `_SUITE_PAYLOAD` / `_SUITE_PAYLOAD_ALLOW` for the Bats suites. This program
re-derives those maps by scanning the shell and Bats sources and reports the drift in both
directions, so the BUILD files stay something an automated reader can trust: a script that
starts reading a payload its target does not declare, or a target that still ships a payload
nothing reads, fails here.

The scan is textual on purpose. A target's data reaches the sandbox only through what it
declares, and the only evidence of what a source opens is the path written in it. Lines that
are pure comments do not count: a note about a file nobody opens is not a dependency. The
`_ALLOW` maps are the escape hatch for pairings the scan cannot see from either side (help
text, a `case` glob over `git diff`, a runtime discovery), and each carries its reason in the
BUILD file.

Usage:
  python3 tests/bazel_deps.py [--root DIR]                  # the whole gate
  python3 tests/bazel_deps.py --root DIR --target scripts   # one map
Exit:
  0 when every map matches its sources, 1 on any finding.
"""

from __future__ import annotations

import argparse
import ast
import os
import re
import sys
from collections.abc import Callable, Iterable, Sequence
from typing import Final, NamedTuple, TypeAlias, cast

# The shape every `_NAME = {...}` literal in a BUILD file has: a key -> the labels listed
# under it. GROUP_FILES keys a same-package group by the files it stands for, TOKEN_GROUPS
# keys a path token by the groups that can satisfy it, and parse_dict hands back exactly
# this or None when the map is absent, so one alias names all three.
LabelMap: TypeAlias = dict[str, list[str]]

# A repo root as either caller spells it: argparse hands over a str and the unit fixtures a
# pathlib.Path, and every use below goes through os.path, which accepts both.
Root: TypeAlias = str | os.PathLike[str]

# A source's text, or None when the file is not there: read() reports a missing file instead
# of raising, and code_lines() treats None as no evidence at all.
MaybeText: TypeAlias = str | None

# The texts a target's sources carry, missing files included -- what present_tokens() and
# drift() scan, assembled by check_scripts() and check_suites().
Sources: TypeAlias = Sequence[MaybeText]

# The sink a check writes one finding line into. main() collects the lines and the unit tests
# append them straight to a list, so the sink answers nothing back.
Reporter: TypeAlias = Callable[[str], None]

# One map check, already bound to its root and its sink: it returns how many findings it made.
Check: TypeAlias = Callable[[], int]


class Drift(NamedTuple):
    """The two directions one target's map can disagree with its sources.

    drift() has always returned this pair; naming it keeps the two sorted label lists apart
    at every call site, and gives the fields the words the docstring already uses.
    """

    # Tokens the sources open whose TOKEN_GROUPS nobody declares.
    missing: list[str]
    # A declared label that no present token can explain.
    unused: list[str]


# Same-package filegroup -> the files it stands for, so the lib closure compares file for
# file. Mirrors scripts/BUILD.bazel; a new group there belongs here too.
GROUP_FILES: Final[LabelMap] = {
    ":seed_probes": [
        "lib/probes/seed-find-mtime.sh",
        "lib/probes/seed-owner.sh",
        "lib/probes/seed-rm-managed.sh",
        "lib/probes/seed-rm-mtime.sh",
        "lib/probes/seed-write.sh",
    ],
}

# Path token -> the group labels that can satisfy it, most specific first. A token found in a
# source counts as covered when the target declares any one of them, so a CLI that addresses
# the payload tree whole declares the aggregate and one that opens a single file declares
# that file.
TOKEN_GROUPS: Final[LabelMap] = {
    ".devcontainer": ["//:devcontainer", "//:stack_data"],
    ".env.example": ["//:env_example", "//:stack_data"],
    ".env.sample": ["//:env_sample", "//:stack_data"],
    ".githooks": ["//:githooks", "//:stack_data"],
    ".gitignore": ["//:gitignore"],
    ".github/actions": ["//:ci_setup_bazel_action", "//:ci_workflows"],
    ".github/scripts": ["//:ci_lint_installer", "//:ci_workflows"],
    ".github/workflows": ["//:ci_pipelines", "//:ci_workflows"],
    "BUILD.bazel": ["//:bazel_files"],
    "Dockerfile": ["//images/dev:dockerfile", "//images/dev:context", "//:stack_data"],
    "LICENSE": ["//:license", "//:stack_data"],
    # The operator front door the seeded /ez-learn skill cites by name. :entry_docs is the
    # only group that ships it, and it sits outside the compose aggregate, so a consumer
    # cannot cover this read by declaring //:stack_data whole.
    "README.md": ["//:entry_docs"],
    "SOUL.md": ["//hermes:seed", "//hermes:payload", "//:stack_data"],
    "action.yml": ["//:ci_setup_bazel_action", "//:ci_workflows"],
    # The gate's own program, which the gate suite runs out of its runfiles.
    "bazel_deps.py": ["bazel_deps.py"],
    # The host-tool probe every lint runner starts with. The suite that drives it reads
    # the file by path, and :runners is the group that ships it beside the runners.
    "check_tool.sh": ["//lints:runners"],
    "deploy-docs": ["//:ci_pipelines", "//:ci_workflows"],
    "docker-compose.yml": ["//:compose_file", "//:stack_data"],
    "docs-site/": ["//docs-site:sources", "//docs-site:python_sources"],
    # The content tree the site renders. :manage-docs.sh rides beside it because a suite
    # runs that one file by path and owes nobody the pages beside it.
    "docs/": ["//docs:content", "//docs:manage-docs.sh"],
    # The trunk-refactor set, spelled as its two file stems rather than as `skills/` or
    # `.grok/`: a directory token would match the `~/.agents/skills/` and `.grok/config.toml`
    # paths the skill-authoring and seeding suites already name, billing them for payload
    # they never open. Same reason `run_mypy.sh` is a file token and `lints/` is not.
    "trunk-feature-flags.md": ["//:agent_rules", "//:stack_data"],
    "trunk-refactor/SKILL.md": ["//:skill_sources", "//:stack_data"],
    "flags.yaml.example": ["//:flags_example", "//:stack_data"],
    "fixtures/": [":fixtures"],
    "hermes/": [
        "//hermes:seed",
        "//hermes:skills",
        "//hermes:payload",
        "//:stack_data",
    ],
    "homepage/": [
        "//homepage:config",
        "//homepage:icons",
        "//homepage:payload",
        "//:stack_data",
    ],
    "homepage/config": [
        "//homepage:config",
        "//homepage:payload",
        "//:stack_data",
    ],
    "images/dev/": [
        "//images/dev:dockerfile",
        "//images/dev:tool_versions",
        "//images/dev:context",
        "//:stack_data",
    ],
    "install-lint-tools.sh": ["//:ci_lint_installer", "//:ci_workflows"],
    "litellm/": ["//litellm:config", "//:stack_data"],
    "manage-docs.sh": ["//docs:manage-docs.sh"],
    # The mypy profile //lints:mypy runs with. A suite that reads it by path - the
    # one that pins the strong-types rule - owes the group that ships it, the same
    # way a suite that reads .gitignore owes //:gitignore. It sits outside the
    # compose aggregate on purpose: it configures a gate, it is not stack payload.
    "mypy.ini": ["//:mypy_config"],
    "proxy/": ["//proxy:confs", "//:stack_data"],
    "psql-token": [":fixtures"],
    # The mypy runner, which the suite that pins the Python type gate reads by path to
    # check its target list against the :mypy data edge. A file token rather than
    # `lints/`, because scripts/setup-host.sh names that directory in its own text and
    # would otherwise owe a lint group it has no use for.
    "run_mypy.sh": ["//lints:runners"],
    "searxng/": ["//searxng:settings", "//:stack_data"],
    "templates/": [
        "//templates/common:payload",
        "//templates/workspace:payload",
        "//templates/devcontainer:payload",
        "//:templates_payload",
        "//:stack_data",
    ],
    # The suite tree a whole-repo gate walks. Only the gate itself opens it; a suite names
    # its own file, which the target carries already.
    "tests/bats/": ["//tests:all_bats"],
    # The coverage harness, which the byte-budget suite pins by path so the mirror
    # handoff cannot lose a leg unnoticed.
    # The unittest suites //tests:py_coverage discovers and //lints:mypy checks. Named
    # as its own token rather than folding into `tests/coverage/`, because the two
    # groups ship different halves of the same harness.
    "tests/python": ["//tests:python_sources"],
    "tests/coverage/": ["//tests:coverage_tools"],
    "tool-versions.env": [
        "//images/dev:dockerfile",
        "//images/dev:tool_versions",
        "//images/dev:context",
        "//:stack_data",
    ],
}

# The payload groups //:stack_data is supposed to aggregate. A payload group left out of the
# aggregate is invisible to the compose bind-mount gate, so it belongs here.
STACK_DATA_GROUPS: Final[list[str]] = [
    "//:agent_rules",
    "//:compose_file",
    "//:devcontainer",
    "//:env_example",
    "//:env_sample",
    "//:flags_example",
    "//:githooks",
    "//:license",
    "//:skill_sources",
    "//:templates_payload",
    "//hermes:payload",
    "//homepage:payload",
    "//images/dev:context",
    "//litellm:config",
    "//proxy:confs",
    "//searxng:settings",
]

# Any path that reaches into scripts/lib, however the caller spells it: `source`, `.`,
# `awk -f`, `python3`, or the `cat` that ships a POSIX probe to a remote host.
_LIB_RE: Final[re.Pattern[str]] = re.compile(r"([A-Za-z0-9_./-]*lib/[A-Za-z0-9_./-]+\.(?:awk|py|sh))")

# A program named without its directory, as a lib reaches its own helpers.
_BARE_RE: Final[re.Pattern[str]] = re.compile(r"([A-Za-z0-9_-]+\.(?:awk|py|sh))")


def token_pattern(token: str) -> re.Pattern[str]:
    """Compile a TOKEN_GROUPS key into a matcher that recognises a path, not a word.

    A directory token needs a separator on at least one side: `"$root/homepage"` or
    `homepage/config`, because `[ "${output}" = "hermes" ]` and
    `run public_host_for STACK_HERMES_NAME hermes` name a compose service or a subdomain, not
    the payload tree. The separator may not be a dot or a colon either, so
    `proxy/certs/homepage.crt` and `http://litellm:4000/v1` stay out. A file token must be a
    whole word and the stem of nothing longer, so `LICENSE` never matches a scratch
    `LICENSE.txt`.
    """
    name = re.escape(token[:-1] if token.endswith("/") else token)
    if token.endswith("/"):
        return re.compile(r"(?:^|[^A-Za-z0-9_.-])%s/|/%s(?![A-Za-z0-9_.:/-])" % (name, name))
    return re.compile(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_.])" % name)


def present_tokens(texts: Sources) -> set[str]:
    """The tokens from TOKEN_GROUPS that appear in any of `texts`."""
    codes = [code_lines(text) for text in texts]
    return {token for token in TOKEN_GROUPS
            if any(token_pattern(token).search(code) for code in codes)}


def read(root: Root, rel_path: str) -> MaybeText:
    """Read repo-relative `rel_path` under `root`, or return None when it is not there."""
    try:
        with open(os.path.join(root, rel_path), encoding = "utf-8") as handle:
            return handle.read()
    except OSError:
        return None


def strip_comment(line: str) -> str:
    """Drop a trailing `#` comment that is not inside quotes.

    A comment is prose about a file, not a read of it, so it must not create a dependency.
    """
    quote = ""
    for index, char in enumerate(line):
        if quote:
            if char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
        elif char == "#" and (index == 0 or line[index - 1] in " \t"):
            return line[:index]
    return line


# A line that builds a scratch tree is not a read of the payload that shares its name. A
# suite that does `mkdir -p "$root/homepage"` and `printf ... >"$dir/LICENSE.txt"` proves its
# own fixture layout, and nothing more.
_WRITE_RE: Final[re.Pattern[str]] = re.compile(
    r"(?:\bmkdir\b|\btouch\b|>>?\s*[\"$]|(?:^|[;&|]\s*)printf\b.*>|<<-\s*[\"'A-Za-z])"
)

# A path named in a message is not a path opened. A line counts as evidence when it carries a
# read verb, a file test, or an asserting helper; `for payload in homepage proxy` and
# `local tpl="${root}/templates/..."` count through the loop, the assignment, and the test
# that act on the path.
_OUTPUT_RE: Final[re.Pattern[str]] = re.compile(
    r"^\s*(?:log|echo|printf|die|warn|err|error|info|note|debug|summary|cat_eof|fail)\b"
    r"|^\s*@test\s+[\"']"
)
_READ_RE: Final[re.Pattern[str]] = re.compile(
    r"(?:\bcat\b|\bgrep\b|\bsed\b|\bawk\b|\bpython3\b|\bsource\b|^\s*\.\s"
    r"|\bfind_lib\b|\bfind_common_lib\b|\bload_shell_function\b"
    r"|\[\[?\s+-[frsdxo]\b|\btest\s+-[frsd]\b|\bcmp\b|\bdiff\b|\bhead\b|\btail\b|\bwc\b"
    r"|\bfind\b|\bls\b|\bstat\b|\brealpath\b|\breadlink\b|\bbasename\b|\bdirname\b"
    r"|\bsha256sum\b|\bjq\b|\bcp\b|\binstall\b|\btar\b|\bunzip\b|\bzip\b|\brun\b"
    r"|\bassert_[a-z_]*file[a-z_]*\b|\bassert_contains\b)"
)

# `cat` and `tee` only forward bytes, so they sit out of the strong set: they read a payload in
# `cat "$f"` (no file opened, so the line stays) and build a fixture in
# `cat >"$dir/Dockerfile"` (a file opened, so the line goes).
_STRONG_READ_RE: Final[re.Pattern[str]] = re.compile(
    r"(?:\bgrep\b|\bsed\b|\bawk\b|\bpython3\b|\bsource\b|^\s*\.\s"
    r"|\bfind_lib\b|\bfind_common_lib\b|\bload_shell_function\b"
    r"|\[\[?\s+-[frsdxo]\b|\btest\s+-[frsd]\b|\bcmp\b|\bdiff\b|\bhead\b|\btail\b|\bwc\b"
    r"|\bfind\b|\bls\b|\bstat\b|\brealpath\b|\breadlink\b|\bbasename\b|\bdirname\b"
    r"|\bsha256sum\b|\bjq\b|\bcp\b|\binstall\b|\btar\b|\bunzip\b|\bzip\b|\brun\b"
    r"|\bassert_[a-z_]*file[a-z_]*\b|\bassert_contains\b)"
)

# The delimiter of a here-doc opener. The body of a here-doc is the text a command emits, so
# it reads the same way a `printf` argument does: a usage example naming `litellm` there is
# not a read of //litellm:config.
_HEREDOC_RE: Final[re.Pattern[str]] = re.compile(r"<<(?!<)-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")


def heredoc_delimiter(line: str) -> str:
    """The delimiter of the first here-doc opener on a line, or "" when there is none.

    A quoted `<<'NAME'` can be an argument rather than an opener: a Bats needle like
    `grep -F -- "<<'EZ_LEARN_SKILL_MD_EOF'"` quotes the closer of a heredoc the suite is
    pinning. Treating that as an opener swallows every line below it, and the payload a
    suite reads further down then looks undeclared, so only an opener sitting outside
    quotes counts.
    """
    for match in _HEREDOC_RE.finditer(line):
        before = line[:match.start()]
        if before.count('"') % 2 or before.count("'") % 2:
            continue
        return match.group(1)
    return ""


def is_write(line: str) -> bool:
    """True when a line builds a file and opens nothing beyond the bytes it forwards.

    `mkdir -p "$root/homepage"` and `cat >"$dir/Dockerfile"` declare a fixture layout, which is
    how a suite proves its own case. `awk -f lib/env_set_key.awk "$f" >"$stage"` still opens
    its program, so a line with a strong read verb stays in the evidence.
    """
    if not _WRITE_RE.search(line):
        return False
    return not _STRONG_READ_RE.search(line)


def code_lines(text: MaybeText) -> str:
    """The lines of a source that could open a file, as one string.

    Comments, here-doc bodies, message lines, and scratch-writing lines are dropped, so a path
    a suite builds or a filename a CLI prints does not read as a dependency on the payload of
    the same name.
    """
    if text is None:
        return ""
    kept: list[str] = []
    delimiter = ""
    for line in text.splitlines():
        if delimiter:
            if line.strip() == delimiter:
                delimiter = ""
            continue
        if line.lstrip().startswith("#"):
            continue
        line = strip_comment(line)
        if not line.strip():
            continue
        if _OUTPUT_RE.match(line) or is_write(line):
            delimiter = heredoc_delimiter(line)
            continue
        kept.append(line)
        delimiter = heredoc_delimiter(line)
    return "\n".join(kept)


def read_lines(text: MaybeText) -> str:
    """The subset of code_lines that carries a read verb, a file test, or an assert.

    The lib closure is built from these alone: a bare program name in a comment or a help
    string is prose about a file, and the whole-word resolution against scripts/lib would
    otherwise turn it into a declared dependency.
    """
    return "\n".join(line for line in code_lines(text).splitlines() if _READ_RE.search(line))


def parse_dict(text: str, name: str) -> LabelMap | None:
    """Extract a `_NAME = {...}` literal from Starlark source, or None.

    The maps are literal strings and lists only, which is what lets ast.literal_eval read
    them without a Starlark interpreter.
    """
    match = re.search(r"^%s = \{" % re.escape(name), text, re.MULTILINE)
    if not match:
        return None
    depth = 0
    for index in range(match.end() - 1, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                # literal_eval hands back whatever the literal holds. The maps are strings
                # and lists by contract (see the docstring), and a BUILD file that broke that
                # shape fails the gate anyway, so the alias states the agreed shape rather
                # than re-deriving it here.
                return cast(LabelMap, ast.literal_eval(text[match.end() - 1:index + 1]))
    return None


def parse_filegroup(text: str, name: str) -> list[str]:
    """Extract the string labels of `filegroup(name = "...")` from Starlark source."""
    match = re.search(
        r'filegroup\(\s*name = "%s",\s*srcs = \[(.*?)\]' % re.escape(name),
        text,
        re.DOTALL,
    )
    if not match:
        return []
    return re.findall(r"\"([^\"]+)\"", match.group(1))


def overlap(declared: Iterable[str], allow: Iterable[str]) -> list[str]:
    """Labels a target lists in both its payload map and its allow map.

    The macros concatenate the two lists into one `data` attribute, so a label in both is a
    Bazel analysis error ("Label ... is duplicated in the 'data' attribute"), and the reason
    the allow entry carries is then a lie about a read the payload map already states.
    """
    return sorted(set(declared) & set(allow))


def drift(texts: Sources, declared: Iterable[str], allow: Iterable[str]) -> Drift:
    """Return (missing, unused) for one target.

    `missing` holds tokens whose groups nobody declares; `unused` holds a declared group that
    no present token can explain. Entries in `allow` are exempt from both directions, which
    is what the BUILD-file reasons are for.
    """
    tokens = present_tokens(texts)
    exempt = set(allow)
    missing = sorted(
        token for token in tokens
        if not any(label in declared or label in exempt for label in TOKEN_GROUPS[token])
    )
    unused = sorted(
        label for label in set(declared) - exempt
        if not any(label in TOKEN_GROUPS[token] for token in tokens)
    )
    return Drift(missing, unused)


def sourced_libs(root: Root, rel_path: str, seen: set[str] | None = None) -> set[str]:
    """The transitive scripts/lib closure of one source file, repo-relative.

    Two spellings resolve: a path that names `lib/` outright, and a bare program name that
    lives in scripts/lib or scripts/lib/probes (how config_seed.sh reaches its probes and its
    Python helper through `${_CONFIG_SEED_DIR}`). A name that matches no file there is not a
    lib, which is what keeps remote filenames out of the closure.
    """
    if seen is None:
        seen = set()
    text = read(root, rel_path)
    if text is None:
        return seen
    code = code_lines(text)
    reads = read_lines(text)
    candidates: set[str] = set()
    for match in _LIB_RE.finditer(code):
        candidates.add(os.path.join("scripts", match.group(1)[match.group(1).find("lib/"):]))
    for match in _BARE_RE.finditer(reads):
        name = match.group(1)
        candidates.add(os.path.join("scripts", "lib", name))
        candidates.add(os.path.join("scripts", "lib", "probes", name))
    for candidate in sorted(candidates):
        if candidate in seen or not os.path.isfile(os.path.join(root, candidate)):
            continue
        seen.add(candidate)
        sourced_libs(root, candidate, seen)
    return seen


def declared_libs(entries: Iterable[str]) -> set[str]:
    """Expand a declared lib list: same-package groups to files, the rest as given."""
    expanded: set[str] = set()
    for entry in entries:
        if entry in GROUP_FILES:
            expanded.update(GROUP_FILES[entry])
        else:
            expanded.add(entry)
    return expanded


def check_scripts(root: Root, report: Reporter) -> int:
    """Compare _SCRIPT_LIBS and _SCRIPT_PAYLOAD against scripts/*.sh and their libs."""
    build = read(root, "scripts/BUILD.bazel")
    if build is None:
        report("error: scripts/BUILD.bazel is not readable")
        return 1
    libs_map = parse_dict(build, "_SCRIPT_LIBS")
    payload_map = parse_dict(build, "_SCRIPT_PAYLOAD")
    allow_map = parse_dict(build, "_SCRIPT_PAYLOAD_ALLOW") or {}
    if libs_map is None or payload_map is None:
        report("error: scripts/BUILD.bazel must declare _SCRIPT_LIBS and _SCRIPT_PAYLOAD")
        return 1

    scripts = sorted(name for name in os.listdir(os.path.join(root, "scripts"))
                     if name.endswith(".sh"))
    findings = 0
    for name in scripts:
        stem = name[:-3]
        if stem not in libs_map or stem not in payload_map:
            report("error: scripts:%s has no _SCRIPT_LIBS/_SCRIPT_PAYLOAD key" % stem)
            findings += 1
            continue

        derived_libs = {
            path[len("scripts/"):]
            for path in sourced_libs(root, os.path.join("scripts", name))
        }
        declared = declared_libs(libs_map[stem])
        for path in sorted(derived_libs - declared):
            report("error: //scripts:%s sources %s without declaring it" % (stem, path))
            findings += 1
        for path in sorted(declared - derived_libs):
            report("error: //scripts:%s declares %s that it never sources" % (stem, path))
            findings += 1

        texts = [read(root, os.path.join("scripts", name))]
        texts += [read(root, os.path.join("scripts", path)) for path in sorted(derived_libs)]
        for label in overlap(payload_map[stem], allow_map.get(stem, [])):
            report("error: //scripts:%s lists %s in both payload maps" % (stem, label))
            findings += 1
        missing, unused = drift(texts, set(payload_map[stem]), allow_map.get(stem, []))
        for token in missing:
            report("error: //scripts:%s reads %s with no group declared for it" % (stem, token))
            findings += 1
        for label in unused:
            report("error: //scripts:%s declares %s that no source mentions" % (stem, label))
            findings += 1
    return findings


def check_suites(root: Root, report: Reporter) -> int:
    """Compare _SUITE_PAYLOAD against tests/bats/*.bats and the CLIs they exec."""
    build = read(root, "tests/BUILD.bazel")
    if build is None:
        report("error: tests/BUILD.bazel is not readable")
        return 1
    payload_map = parse_dict(build, "_SUITE_PAYLOAD")
    allow_map = parse_dict(build, "_SUITE_PAYLOAD_ALLOW") or {}
    scripts_build = read(root, "scripts/BUILD.bazel") or ""
    script_payload = parse_dict(scripts_build, "_SCRIPT_PAYLOAD") or {}
    script_allow = parse_dict(scripts_build, "_SCRIPT_PAYLOAD_ALLOW") or {}
    if payload_map is None:
        report("error: tests/BUILD.bazel must declare _SUITE_PAYLOAD")
        return 1

    # What every suite already carries, so a suite is not charged for the repo-root marker
    # or the scripts tree it inherits.
    common: set[str] = set()
    match = re.search(r"^_BATS_COMMON = \[(.*?)\]", build, re.MULTILINE | re.DOTALL)
    if match:
        common = set(re.findall(r"\"([^\"]+)\"", match.group(1)))

    suites = sorted(name for name in os.listdir(os.path.join(root, "tests", "bats"))
                    if name.endswith(".bats"))
    findings = 0
    for name in suites:
        if name not in payload_map:
            report("error: tests/bats/%s has no _SUITE_PAYLOAD key" % name)
            findings += 1
            continue
        target = "//tests:bats_%s_test" % name.replace(".bats", "").replace("-", "_")
        text = read(root, os.path.join("tests", "bats", name))
        texts = [text]
        declared = set(payload_map[name]) | common
        exempt = set(allow_map.get(name, []))

        # A suite that execs a CLI inherits that CLI's declared reads, and the CLI's own text
        # is what explains them. The CLI map is checked against the CLI's sources by
        # check_scripts, so inheriting the declaration is both cheaper and stricter than
        # re-deriving it here.
        for match in re.finditer(r"scripts/([a-z0-9-]+)\.sh", code_lines(text)):
            stem = match.group(1)
            declared |= set(script_payload.get(stem, []))
            exempt |= set(script_allow.get(stem, []))
            entry = os.path.join("scripts", match.group(1) + ".sh")
            texts.append(read(root, entry))
            for lib in sorted(sourced_libs(root, entry)):
                texts.append(read(root, lib))

        missing, unused = drift(texts, declared, exempt)
        for label in overlap(payload_map[name], allow_map.get(name, [])):
            report("error: %s lists %s in both suite payload maps" % (target, label))
            findings += 1
        for token in missing:
            report("error: %s reads %s with no group declared for it" % (target, token))
            findings += 1
        for label in unused:
            if label in common:
                continue
            report("error: %s declares %s that no source mentions" % (target, label))
            findings += 1
    return findings


def check_aggregate(root: Root, report: Reporter) -> int:
    """//:stack_data must list every payload group, or that payload hides from the gate."""
    build = read(root, "BUILD.bazel")
    if build is None:
        report("error: BUILD.bazel is not readable")
        return 1

    def absolute(label: str) -> str:
        """Spell a same-package label the way STACK_DATA_GROUPS does, so the sets compare."""
        return "//:%s" % label[1:] if label.startswith(":") else label

    srcs = {absolute(label) for label in parse_filegroup(build, "stack_data")}
    findings = 0
    for group in STACK_DATA_GROUPS:
        if group not in srcs:
            report("error: //:stack_data omits %s" % group)
            findings += 1
    return findings


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected checks, print the report, and return the exit status."""
    parser = argparse.ArgumentParser(description = "Check Bazel data maps against the sources.")
    parser.add_argument("--root", default = ".", help = "repo root to check")
    parser.add_argument(
        "--target",
        choices = ["all", "scripts", "suites", "aggregate"],
        default = "all",
        help = "which map to check",
    )
    args = parser.parse_args(argv)

    checks: dict[str, Check] = {
        "scripts": lambda: check_scripts(args.root, report),
        "suites": lambda: check_suites(args.root, report),
        "aggregate": lambda: check_aggregate(args.root, report),
    }
    lines: list[str] = []

    def report(line: str) -> None:
        lines.append(line)

    selected = ["scripts", "suites", "aggregate"] if args.target == "all" else [args.target]
    print("== bazel_deps ==")
    failures = 0
    for name in selected:
        print("-> checking %s" % name)
        failures += checks[name]()
    for line in lines:
        print(line)
    if failures:
        print("summary: 0 ok, 0 warnings, %d failed" % failures)
        return 1
    print("summary: %d ok, 0 warnings, 0 failed" % len(selected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
