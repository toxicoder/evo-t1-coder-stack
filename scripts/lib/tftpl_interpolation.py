#!/usr/bin/env python3
"""Fail when a .tftpl body interpolates a name its templatefile() call never passes.

Usage: tftpl_interpolation.py TEMPLATES_DIR [--strict] [--list]

templatefile() reads a single-dollar brace reference anywhere in the body - including
inside a shell comment or a for-loop - as an interpolation, and the plan fails with
"vars map does not contain key" when the caller's map has no such key. A shell variable
in a body therefore has to carry the double-dollar escape. Text greps cannot tell the two
apart, so this program parses both sides: every templatefile() call in every *.tf under
TEMPLATES_DIR (the map keys it declares) and every body it names (the names it
interpolates, honouring the $$ and %% escapes and the names a %{ for ~} directive binds).

Exit 0 when every interpolated name is declared and every body is reached. Exit 1 on an
undeclared name, a body no call reaches, a construct that opens and never closes, or a call
this parser cannot read; --strict also fails a declared key the body never uses. A call that
hides its key set behind merge() or a local is refused rather than guessed at, because the
silence would be the same shape as the bug this program exists to catch. Prints one finding
per line and a closing "summary:" line.
--list puts the calls on stdout as TAB-separated
"<tf path>\\t<line>\\t<body path>\\t<comma-separated keys>" and the prose on stderr, so a
suite can drive terraform from the key list.
"""

import re
import sys
from pathlib import Path

IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
TEMPLATE_CALL_RE = re.compile(r"(?<![A-Za-z0-9_.])templatefile\(")

# Names that are not variables: the literals and operators a template expression may hold.
# Function names are excluded separately, by the "(" that follows them.
RESERVED = frozenset(
    {
        "true",
        "false",
        "null",
        "and",
        "or",
        "not",
        "in",
        "if",
        "else",
        "for",
        "endif",
        "endfor",
        "elseif",
    }
)


def _mask_comments(text: str) -> str:
    """Blank out HCL comments and heredoc bodies so a mention there is not a call.

    Keeps the length and the line breaks, so an offset in the masked text is an offset
    in the original.
    """
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif text.startswith("//", i) or text.startswith("#", i):
            while i < n and text[i] != "\n":
                out[i] = " " if text[i] != "\n" else text[i]
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            for j in range(i, end):
                if text[j] != "\n":
                    out[j] = " "
            i = end
        elif text.startswith("<<", i):
            tag_match = re.match(r"<<-?\s*([A-Za-z0-9_]+)", text[i:])
            if tag_match:
                tag = tag_match.group(1)
                # A <<- heredoc may close on an indented line, so the marker is searched
                # for rather than assumed to sit at column 0.
                close = re.compile(r"\n[ \t]*" + tag + r"[ \t]*(?=\r?\n|\Z)").search(text, i)
                end = n if close is None else close.end()
                for j in range(i, end):
                    if text[j] != "\n":
                        out[j] = " "
                i = end
            else:
                i += 1
        else:
            i += 1
    return "".join(out)


def _split_args(text: str, open_paren: int) -> tuple[list[str], int]:
    """Return the top-level argument slices of the call whose "(" sits at open_paren."""
    args: list[str] = []
    depth = 0
    start = open_paren + 1
    i = open_paren
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append(text[start:i])
                return args, i + 1
        elif ch == "," and depth == 1:
            args.append(text[start:i])
            start = i + 1
        i += 1
    return args, -1


def _map_keys(map_slice: str) -> list[str]:
    """Top-level `name =` entries of the templatefile() vars map."""
    body = map_slice.strip()
    if not body.startswith("{"):
        return []
    keys: list[str] = []
    depth = 0
    at_entry_start = True
    i = 0
    n = len(body)
    while i < n:
        ch = body[i]
        if ch == '"':
            i += 1
            while i < n and body[i] != '"':
                i += 2 if body[i] == "\\" else 1
        elif ch in "{[(":
            depth += 1
            at_entry_start = ch == "{" and depth == 1
        elif ch in "}])":
            depth -= 1
            at_entry_start = False
        elif ch in ",\n":
            at_entry_start = depth == 1
        elif ch.isspace():
            pass
        elif at_entry_start and (ch.isalpha() or ch == "_"):
            match = IDENT_RE.match(body, i)
            if match:
                after = body[match.end():]
                stripped = after.lstrip()
                if stripped.startswith("=") and not stripped.startswith(("==", "=>")):
                    keys.append(match.group(0))
                at_entry_start = False
                i = match.end()
                continue
            at_entry_start = False
        else:
            at_entry_start = False
        i += 1
    return keys


def _string_literal(arg_slice: str) -> str:
    """The contents of a plain "..." argument, or "" when it is anything else."""
    body = arg_slice.strip()
    if len(body) < 2 or not body.startswith('"') or not body.endswith('"'):
        return ""
    inner = body[1:-1]
    if '"' in inner or "\\" in inner:
        return ""
    return inner


def _expression_names(expr: str) -> list[str]:
    """Names an interpolation or directive references, minus literals, functions, members.

    `${a.b}` asks for `a` and reads `b` off it, so the member is not a key the caller
    declares: Terraform resolves the whole path against the one value it was handed.
    """
    without_strings = re.sub(r'"(?:[^"\\]|\\.)*"', " ", expr)
    without_strings = re.sub(r"'(?:[^'\\]|\\.)*'", " ", without_strings)
    without_members = re.sub(r"\.\s*[A-Za-z_][A-Za-z0-9_]*", " ", without_strings)
    names: list[str] = []
    for match in IDENT_RE.finditer(without_members):
        name = match.group(0)
        if name in RESERVED or name in names:
            continue
        rest = without_members[match.end():].lstrip()
        if rest.startswith("("):
            continue  # a function call, not a variable
        names.append(name)
    return names


def _body_names(text: str) -> tuple[list[tuple[str, int]], int]:
    """(name, line) pairs the body interpolates, and the line of a construct that opens.

    Walks the template the way Terraform does: `$${` and `%%{` are literal text, `${`
    starts an interpolation and `%{` a directive, and a shell comment is not a comment
    here - it is template text, which is how a bare shell variable turns into a plan
    failure. A `%{ for k, v in xs ~}` binds k and v for its own region and nobody else's:
    the same name read outside that loop is a key the caller owes, which is the case a
    body-wide whitelist would have waved through. The second half of the result is the
    line of an interpolation or directive that never closes, or 0 when every one does -
    Terraform refuses a body that opens like that, so the gate refuses it too rather
    than counting it clean.
    """
    uses: list[tuple[str, int]] = []
    frames: list[set[str]] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "$" and nxt == "$" and text.startswith("$${", i):
            i += 3
        elif ch == "%" and nxt == "%" and text.startswith("%%{", i):
            i += 3
        elif ch == "$" and nxt == "{":
            end = _match_brace(text, i + 1)
            if end < 0:
                return uses, text.count("\n", 0, i) + 1
            line = text.count("\n", 0, i) + 1
            inside = {name for frame in frames for name in frame}
            for name in _expression_names(text[i + 2:end]):
                if name not in inside:
                    uses.append((name, line))
            i = end + 1
        elif ch == "%" and nxt == "{":
            end = _match_brace(text, i + 1)
            if end < 0:
                return uses, text.count("\n", 0, i) + 1
            directive = text[i + 2:end]
            line = text.count("\n", 0, i) + 1
            head = directive.replace("~", " ").strip().split()
            bindings: set[str] = set()
            if head and head[0] == "for" and "in" in head:
                for token in head[1:head.index("in")]:
                    bindings.update(IDENT_RE.findall(token))
            inside = {name for frame in frames for name in frame} | bindings
            for name in _expression_names(directive):
                if name not in inside:
                    uses.append((name, line))
            if head and head[0] == "for":
                frames.append(bindings)
            elif head and head[0] == "endfor" and frames:
                frames.pop()
            i = end + 1
        else:
            i += 1
    return uses, 0


def _match_brace(text: str, brace_at: int) -> int:
    """Index of the "}" closing the "{" at brace_at, honouring strings, or -1."""
    depth = 0
    i = brace_at
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _resolve_body(tf_path: Path, rel: str, templates_dir: Path) -> Path | None:
    """The body a `${path.module}/name` names: beside the .tf, or in templates/common/."""
    rel = rel[len("${path.module}/"):] if rel.startswith("${path.module}/") else rel
    if "/" in rel:
        return None
    beside = tf_path.parent / rel
    if beside.is_file():
        return beside
    shared = templates_dir / "common" / rel
    if shared.is_file():
        return shared
    return None


class _Report:
    """Findings and the counters the closing summary prints."""

    def __init__(self) -> None:
        self.errors = 0
        self.warnings = 0
        self.checked = 0
        self.rows: list[str] = []
        self.reached: set[Path] = set()

    def error(self, message: str) -> None:
        print(f"error: {message}")
        self.errors += 1

    def warn(self, message: str) -> None:
        print(f"warning: {message}")
        self.warnings += 1

    def ok(self) -> None:
        self.checked += 1


def check_call(tf_path: Path, call_at: int, templates_dir: Path, report: _Report) -> None:
    """Check one templatefile() call and the body it names."""
    text = tf_path.read_text(encoding="utf-8")
    paren = text.index("(", call_at)
    args, _ = _split_args(text, paren)
    line = text.count("\n", 0, call_at) + 1
    where = f"{tf_path}:{line}"

    if len(args) != 2:
        report.error(f"{where}: templatefile() called with {len(args)} arguments")
        return
    path_arg = _string_literal(args[0])
    if not path_arg:
        report.error(f"{where}: templatefile() path argument is not a plain string")
        return
    rel = path_arg[len("${path.module}/"):] if path_arg.startswith("${path.module}/") else path_arg
    if "${" in rel:
        # A path assembled at plan time has no key set this gate can settle, which is a
        # finding to report rather than a body to go looking for.
        report.error(f"{where}: templatefile() path {path_arg} is built dynamically")
        return

    body_path = _resolve_body(tf_path, path_arg, templates_dir)
    if body_path is None:
        report.error(f"{where}: no body found for {path_arg}")
        return

    keys = _map_keys(args[1])
    if not keys and args[1].strip() not in ("{}", ""):
        report.error(f"{where}: cannot read the vars map for {body_path.name}")
        return

    body_text = body_path.read_text(encoding="utf-8")
    uses, broken = _body_names(body_text)
    declared = set(keys)
    report.rows.append("\t".join([str(tf_path), str(line), str(body_path), ",".join(keys)]))
    report.reached.add(body_path)

    if broken:
        # Terraform refuses to render a body whose interpolation never closes, so a
        # scan that stopped early has to be a finding rather than a clean count.
        report.error(f"{body_path}:{broken}: an interpolation or a directive never closes")

    missing: list[str] = []
    for name, body_line in uses:
        if name in declared:
            continue
        finding = f"{body_path}:{body_line}: '{name}' interpolates but {where} passes no such key"
        if finding not in missing:
            missing.append(finding)
    for finding in missing:
        report.error(finding)

    unused = [key for key in keys if key not in {name for name, _ in uses}]
    for key in unused:
        report.warn(f"{where}: passes '{key}', {body_path.name} never interpolates it")

    if not missing:
        report.ok()


def check_tree(templates_dir: Path, report: _Report) -> None:
    """Check every templatefile() call under templates_dir, and every body one should reach."""
    for tf_path in sorted(templates_dir.rglob("*.tf")):
        if ".terraform" in tf_path.parts:
            continue
        masked = _mask_comments(tf_path.read_text(encoding="utf-8"))
        for match in TEMPLATE_CALL_RE.finditer(masked):
            check_call(tf_path, match.start(), templates_dir, report)
    # A body no call names renders nowhere: it may be a rename that left the old file
    # behind, or a payload the push stopped staging beside its twin. Either way the tree
    # carries text nobody reads, which is what this pass is for.
    for body in sorted(templates_dir.rglob("*.tftpl")):
        if ".terraform" in body.parts:
            continue
        if body not in report.reached:
            report.error(f"{body}: no templatefile() call under {templates_dir} reaches it")


def main(argv: list[str]) -> int:
    strict = "--strict" in argv
    listing = "--list" in argv
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.stderr.write("usage: tftpl_interpolation.py TEMPLATES_DIR [--strict] [--list]\n")
        return 2
    templates_dir = Path(args[0])
    if not templates_dir.is_dir():
        sys.stderr.write(f"error: {templates_dir} is not a directory\n")
        return 2

    prose = sys.stderr if listing else sys.stdout
    saved, sys.stdout = sys.stdout, prose
    try:
        report = _Report()
        check_tree(templates_dir, report)
    finally:
        sys.stdout = saved
    warnings = report.warnings
    if strict and warnings:
        report.errors += warnings
        warnings = 0
    if listing:
        for row in report.rows:
            print(row)
    else:
        print(
            f"summary: {report.checked} call(s) checked, {warnings} warnings, {report.errors} failed"
        )
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
