#!/usr/bin/env python3
# managed-by: evo-t1-coder-stack -- stack-seeded helper. The canonical source is
# templates/common/ez-code-index.code_index.py in evo-t1-coder-stack: change the seed there and
# re-materialize this copy; editing the copy in a home invites it being restored.
"""Build the small local symbol-and-file map a later session reads instead of grepping.

One clone goes in, two artifacts come out, filed beside that repository's notes file
on the shared profile volume: `code-index.json` for a program and `code-index.md` for
a person. It is deliberately not a compiler front end. The patterns below name the
top-level definitions someone actually asks "where does X live" about, which is the
question a fresh `rg` costs a turn to answer every session.

Everything is local: no service, no network, no daemon. Nothing is written inside the
clone, so no repository needs an ignore rule for it. The banner each artifact starts
with carries the SHA the index was built at, so a reader compares it to the current
HEAD and decides whether the map is fresh or a hint.

Usage:
    ez-code-index.code_index.py --repo DIR [--home HOME] [--json] [--limit N]

Exit codes: 0 wrote the index, 1 the clone is not indexable, 2 usage error.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from typing import Dict, List, NamedTuple, Optional, Sequence, Tuple

MARKER = "ez-code-index v1"
SCHEMA = 1
TOOL_VERSION = "1"

# The two caps are the point of the artifact: a map you have to read in three screens
# is not a map. Both are stated in the banner, and a run that dropped rows says so.
DEFAULT_LIMIT = 400
FILE_LIMIT = 200
TOP_DIRS = 10
LINE_MAX = 400  # a minified or data line is not a definition, and it stalls a regex

# Anchored at column 0 on purpose: a top-level definition is what the map is for.
PATTERNS_BY_SUFFIX: Dict[str, List[Tuple[str, str]]] = {
    ".py": [("class", r"^class\s+([A-Za-z_]\w*)"),
            ("def", r"^def\s+([A-Za-z_]\w*)")],
    ".sh": [("function", r"^([A-Za-z_]\w*)\s*\(\s*\)"),
            ("@function", r"^#\s*@function\s+([A-Za-z_]\w*)")],
    ".bash": [("function", r"^([A-Za-z_]\w*)\s*\(\s*\)"),
              ("@function", r"^#\s*@function\s+([A-Za-z_]\w*)")],
    ".go": [("func", r"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)")],
    ".ts": [("export", r"^export\s+(?:(?:default|async|abstract)\s+)*"
                      r"(?:(?:const|let|var|function|class|interface|type|enum)\s+)?"
                      r"([A-Za-z_$][\w$]*)"),
            ("export", r"^export\s+\{([^}]*)\}")],
    ".tsx": [("export", r"^export\s+(?:(?:default|async|abstract)\s+)*"
                       r"(?:(?:const|let|var|function|class|interface|type|enum)\s+)?"
                       r"([A-Za-z_$][\w$]*)")],
    ".js": [("export", r"^export\s+(?:(?:default|async)\s+)*"
                      r"(?:(?:const|let|var|function|class)\s+)?([A-Za-z_$][\w$]*)"),
            ("export", r"^export\s+\{([^}]*)\}")],
    ".jsx": [("export", r"^export\s+(?:(?:default|async)\s+)*"
                       r"(?:(?:const|let|var|function|class)\s+)?([A-Za-z_$][\w$]*)")],
    ".mjs": [("export", r"^export\s+(?:(?:default|async)\s+)*"
                       r"(?:(?:const|let|var|function|class)\s+)?([A-Za-z_$][\w$]*)")],
}

# BUILD files are the machine-readable dependency record in this repo family, so the
# target names are the symbols worth having in the map.
BUILD_PATTERNS: List[Tuple[str, str]] = [("target", r'\bname\s*=\s*"([^"]+)"')]
BUILD_GLOBS = ("BUILD", "BUILD.bazel", "*.bzl", "MODULE.bazel", "WORKSPACE")
LANGUAGE_OF_SUFFIX = {".py": "python", ".sh": "shell", ".bash": "shell", ".go": "go",
                      ".ts": "typescript", ".tsx": "typescript", ".js": "javascript",
                      ".jsx": "javascript", ".mjs": "javascript"}

SKIP_DIRS = (".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build")
SKIP_DIR_PREFIXES = ("bazel-",)
SKIP_SUFFIXES = (".min.js", ".lock")
FILE_MAX_BYTES = 1024 * 1024

IDENT_RE = re.compile(r"^[A-Za-z_$][\w$]*$")
KEY_RE = re.compile(r"^[^/\s][^/\s]*(?:/[^/\s]+){2,}$")
_COMPILED: Dict[str, "re.Pattern[str]"] = {}


class Symbol(NamedTuple):
    """One definition, spelled the way the pinned JSON `symbols` entry is spelled."""

    name: str
    path: str
    line: int
    kind: str
    lang: str


class FileEntry(NamedTuple):
    """One indexed file, as the pinned JSON `files` entry carries it."""

    path: str
    lang: str
    symbols: int


class Report:
    """Collect what one run has to say, so the exit code stays one decision.

    Both channels go to stderr: stdout carries the summary line or the JSON, and a
    caller piping this into another program must never have prose mixed into it.
    """

    def __init__(self) -> None:
        self.notes: List[str] = []
        self.errors: List[str] = []

    def note(self, line: str) -> None:
        self.notes.append(line)

    def error(self, line: str) -> None:
        self.errors.append(line)

    def emit(self) -> None:
        for line in self.notes:
            sys.stderr.write("note: %s\n" % line)
        for line in self.errors:
            sys.stderr.write("error: %s\n" % line)


def finish(report: Report, code: int) -> int:
    """Say what the run found, then hand back the exit code."""
    report.emit()
    return code


def compiled(pattern: str) -> "re.Pattern[str]":
    cached = _COMPILED.get(pattern)
    if cached is None:
        cached = re.compile(pattern)
        _COMPILED[pattern] = cached
    return cached


def run(cmd: Sequence[str]) -> Tuple[int, str, str]:
    """Run one local command without a shell; a missing binary is a result, not a crash."""
    try:
        done = subprocess.run(list(cmd), capture_output=True, text=True, errors="replace",
                              timeout=120, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)
    return done.returncode, done.stdout, done.stderr


def is_git_repo(repo: str) -> bool:
    code, out, _ = run(["git", "-C", repo, "rev-parse", "--is-inside-work-tree"])
    return code == 0 and out.strip() == "true"


def git_head(repo: str) -> str:
    code, out, _ = run(["git", "-C", repo, "rev-parse", "HEAD"])
    return out.strip() if code == 0 else ""


def origin_remote(repo: str) -> str:
    code, out, _ = run(["git", "-C", repo, "remote", "get-url", "origin"])
    return out.strip() if code == 0 else ""


def local_repo_key(remote: str) -> str:
    """Reduce a remote URL to host/owner/repo here, for a home without notes-setup.sh.

    This is the fallback spelling, not the rule of record: notes_repo_key in
    notes-setup.sh is what files the notes file, so repo_key() asks that function
    first and only falls here when it cannot. A URL that carries login material is
    stripped of it and never printed.
    """
    raw = (remote or "").strip().lower().rstrip("/")
    if not raw:
        return ""
    if "://" in raw:
        raw = raw.split("://", 1)[1]
    raw = raw.split("@")[-1]
    if ":" in raw and "/" not in raw.split(":", 1)[0]:
        head, tail = raw.split(":", 1)
        # A numeric port is transport, not path; the scp spelling and a ported
        # ssh:// URL of one repository have to produce one key.
        tail_head, slash, tail_rest = tail.partition("/")
        raw = head + "/" + (tail_rest if slash and tail_head.isdigit() else tail)
    if raw.endswith(".git"):
        raw = raw[:-4]
    parts = [part for part in raw.split("/") if part and part not in (".", "..")]
    return "/".join(parts[:3]) if len(parts) >= 3 else ""


def repo_key(remote: str, home: str, report: Report) -> Tuple[str, str]:
    """Take the key the notes file already uses, so the index lands beside it.

    notes_repo_key is the rule of record for the shape of a key, so the shell
    function is asked first. It is written for bash (the library declares
    `# shellcheck shell=bash` and uses `[[` and `=~`), and `/bin/sh` on these images
    is dash, which refuses to parse the file at all (measured: exit 2, `Syntax error:
    "(" unexpected` at notes-setup.sh:318), so the same dot-source is retried under
    bash before falling back to the parse above. Whichever answered is what the banner
    names.
    """
    setup = os.path.join(home, ".grok", "notes-setup.sh")
    if os.path.isfile(setup):
        body = '. "$1" && notes_repo_key "$2"'
        for shell in ("sh", "bash"):
            code, out, err = run([shell, "-c", body, shell, setup, remote])
            key = out.strip().splitlines()[0].strip() if out.strip() else ""
            if code == 0 and KEY_RE.match(key):
                return key, "%s (%s)" % (os.path.relpath(setup, home), shell)
            if code != 127:
                report.note("notes_repo_key under %s did not answer: %s"
                            % (shell, (err.strip().splitlines() or ["exit %d" % code])[-1]))
        report.note("keying from the origin remote here; notes-setup.sh is present but "
                    "its notes_repo_key did not answer")
        return local_repo_key(remote), "parsed here (notes-setup.sh did not answer)"
    report.note("no %s; keying from the origin remote parsed here" % setup)
    return local_repo_key(remote), "parsed here (no notes-setup.sh)"


def patterns_for(rel: str) -> Optional[Tuple[str, List[Tuple[str, str]]]]:
    """Return (language, patterns) for one indexable file, or None when it is not one."""
    base = os.path.basename(rel)
    if base == "BUILD" or base.startswith("BUILD.") or base in ("WORKSPACE", "MODULE.bazel") \
            or base.endswith(".bzl"):
        return ("bazel", BUILD_PATTERNS)
    for suffix, patterns in PATTERNS_BY_SUFFIX.items():
        if rel.endswith(suffix):
            return (LANGUAGE_OF_SUFFIX[suffix], patterns)
    return None


def language_of(rel: str) -> str:
    pair = patterns_for(rel)
    return pair[0] if pair else ""


def skip_dir(name: str) -> bool:
    return name in SKIP_DIRS or any(name.startswith(prefix) for prefix in SKIP_DIR_PREFIXES)


def skip_file(rel: str) -> bool:
    base = os.path.basename(rel)
    # `.env*` is denied to the agent as well; the index must never read one.
    if base.startswith(".env"):
        return True
    return any(rel.endswith(suffix) for suffix in SKIP_SUFFIXES)


def indexable(repo: str, rel: str) -> bool:
    """One rule for both scanners, so rg and the walk agree on what the tree holds."""
    if skip_file(rel) or patterns_for(rel) is None:
        return False
    try:
        return os.path.getsize(os.path.join(repo, rel)) <= FILE_MAX_BYTES
    except OSError:
        return False


def rg_include_args() -> List[str]:
    """The positive globs: with one present, rg only ever offers these files."""
    args: List[str] = []
    for suffix in sorted(PATTERNS_BY_SUFFIX):
        args += ["--glob", "*%s" % suffix]
    for base in sorted(BUILD_GLOBS):
        args += ["--glob", base]
    return args


def rg_exclude_args() -> List[str]:
    args: List[str] = []
    for name in sorted(SKIP_DIRS):
        args += ["--glob", "!%s/**" % name, "--glob", "!**/%s/**" % name]
    for prefix in sorted(SKIP_DIR_PREFIXES):
        args += ["--glob", "!%s*/**" % prefix, "--glob", "!**/%s*/**" % prefix]
    for suffix in sorted(SKIP_SUFFIXES):
        bare = suffix[1:]
        args += ["--glob", "!*.%s" % bare, "--glob", "!**/*.%s" % bare]
    args += ["--glob", "!.env*", "--glob", "!**/.env*"]
    return args


def rg_base_command(repo: str, extra: Sequence[str]) -> List[str]:
    """rg honours neither .gitignore nor its own hidden-file default here: the skip
    list above is the single agreement between the rg path and the walk path.

    The order of the globs is load-bearing. ripgrep's matcher is last-rule-wins, so an
    exclusion that precedes `*.js` is re-admitted by it and node_modules comes back
    (measured on rg 14.1.0); the exclusions have to follow the inclusions.
    """
    return ["rg", "--no-messages", "--no-config", "--color", "never", "--hidden",
            "--no-ignore", "--sort=path"] + rg_include_args() + rg_exclude_args() \
        + list(extra) + ["--", repo]


def files_with_rg(repo: str) -> Optional[List[str]]:
    """rg --files is the tree lister; None means rg is absent or refused."""
    if not shutil.which("rg"):
        return None
    code, out, _ = run(rg_base_command(repo, ["--files"]))
    if code not in (0, 1):
        return None
    files: List[str] = []
    for line in out.splitlines():
        rel = relative(repo, line.strip())
        if rel and indexable(repo, rel) and rel not in files:
            files.append(rel)
    return files


def relative(repo: str, path: str) -> str:
    """rg answers absolute paths; the index stores clone-relative forward-slash ones."""
    if not path:
        return ""
    rel = os.path.relpath(path, repo).replace(os.sep, "/")
    return "" if rel == "." or rel.startswith("..") else rel


def symbols_with_rg(repo: str) -> Optional[List[Symbol]]:
    """One rg pass over the whole tree with every pattern; the line is then classified
    against that file's own language, so a cross-language match yields nothing."""
    if not shutil.which("rg"):
        return None
    extra = ["--no-heading", "--line-number", "--null"]
    every = sorted({pattern for patterns in list(PATTERNS_BY_SUFFIX.values()) + [BUILD_PATTERNS]
                    for _kind, pattern in patterns})
    for pattern in every:
        extra += ["--regexp", pattern]
    code, out, _ = run(rg_base_command(repo, extra))
    if code not in (0, 1):
        return None
    found: List[Symbol] = []
    for line in out.splitlines():
        head, nul, rest = line.partition("\0")
        if not nul:
            continue
        number, colon, text = rest.partition(":")
        if not colon or not number.isdigit():
            continue
        rel = relative(repo, head)
        pair = patterns_for(rel) if rel else None
        if pair is None:
            continue
        lang, patterns = pair
        found.extend(symbols_from_lines(rel, [(int(number), text)], lang, patterns))
    return found


def files_with_walk(repo: str) -> List[str]:
    """The no-rg fallback: the same skip list, applied by os.walk."""
    found: List[str] = []
    for root, dirs, names in os.walk(repo):
        dirs[:] = sorted(name for name in dirs if not skip_dir(name))
        for name in sorted(names):
            rel = relative(repo, os.path.join(root, name))
            if rel and indexable(repo, rel):
                found.append(rel)
    return found


def symbols_with_walk(repo: str, files: Sequence[str]) -> List[Symbol]:
    found: List[Symbol] = []
    for rel in files:
        pair = patterns_for(rel)
        if pair is None:
            continue
        lang, patterns = pair
        try:
            with open(os.path.join(repo, rel), "r", encoding="utf-8",
                      errors="replace") as handle:
                lines = list(enumerate(handle, 1))
        except OSError:
            continue
        found.extend(symbols_from_lines(rel, lines, lang, patterns))
    return found


def symbols_from_lines(rel: str, lines: Sequence[Tuple[int, str]], lang: str,
                       patterns: Sequence[Tuple[str, str]]) -> List[Symbol]:
    """Apply a language's patterns to one file's lines; a capture may hold a list."""
    found: List[Symbol] = []
    for number, text in lines:
        line = text.rstrip("\n")
        if len(line) > LINE_MAX:
            continue
        for kind, pattern in patterns:
            for match in compiled(pattern).finditer(line):
                captured = match.group(1) or ""
                for name in re.split(r"[,\s]+", captured):
                    if IDENT_RE.match(name):
                        found.append(Symbol(name, rel, number, kind, lang))
    return found


def top_of(rel: str) -> str:
    return rel.split("/")[0] if "/" in rel else "."


def round_robin(buckets: Dict[str, List[str]]) -> List[str]:
    """Interleave one bucket after another so no single directory reads as the tree."""
    queues = [buckets[name] for name in sorted(buckets)]
    ordered: List[str] = []
    while any(queues):
        for queue in queues:
            if queue:
                ordered.append(queue.pop(0))
    return ordered


def spread_by_dir(files: Sequence[str]) -> List[str]:
    """Round-robin the candidate files across their top directories.

    The caps are the scarce thing, and a path-sorted list spends all of one on
    whichever directory sorts first. Interleaving makes a cap mean "a little of each",
    which is what a map is for.
    """
    buckets: Dict[str, List[str]] = {}
    for rel in files:
        buckets.setdefault(top_of(rel), []).append(rel)
    return round_robin(buckets)


def spread_symbols(symbols: Sequence[Symbol]) -> List[Symbol]:
    """Same interleaving for the symbol budget, so one dense directory is not the map."""
    buckets: Dict[str, List[Symbol]] = {}
    for symbol in symbols:
        buckets.setdefault(top_of(symbol.path), []).append(symbol)
    queues = [sorted(buckets[name], key=lambda s: (s.name, s.path, s.line, s.kind))
              for name in sorted(buckets)]
    ordered: List[Symbol] = []
    while any(queues):
        for queue in queues:
            if queue:
                ordered.append(queue.pop(0))
    return ordered


def scan(repo: str, limit: int, report: Report
         ) -> Tuple[List[str], List[Symbol], str, bool, bool]:
    """Return (files, symbols, how the tree was read, files_capped, symbols_capped)."""
    files = files_with_rg(repo)
    if files is not None:
        how = "rg"
        symbols = symbols_with_rg(repo)
        if symbols is None:
            how = "os.walk fallback (rg pattern pass failed)"
            symbols = symbols_with_walk(repo, files)
            report.note("rg listed the tree but its pattern pass failed; the symbols "
                        "come from os.walk over the same files and patterns")
    else:
        how = ("os.walk fallback (rg not found)" if shutil.which("rg") is None
               else "os.walk fallback (rg could not list the tree)")
        report.note("no rg on this box; os.walk covered the tree with the same skip list"
                    if "not found" in how else
                    "rg could not list the tree; os.walk covered it instead")
        files = files_with_walk(repo)
        symbols = symbols_with_walk(repo, files)

    ordered_files = spread_by_dir(sorted(set(files)))
    files_capped = len(ordered_files) > FILE_LIMIT
    kept_files = ordered_files[:FILE_LIMIT]
    if files_capped:
        report.note("capped the file map at %d of %d indexable files"
                    % (FILE_LIMIT, len(ordered_files)))

    kept = set(kept_files)
    seen = set()
    unique: List[Symbol] = []
    for symbol in symbols:
        marker = (symbol.name, symbol.path, symbol.line, symbol.kind)
        if symbol.path in kept and marker not in seen:
            seen.add(marker)
            unique.append(symbol)
    ordered_symbols = spread_symbols(unique)
    symbols_capped = len(ordered_symbols) > limit
    if symbols_capped:
        report.note("capped the symbol list at %d of %d symbols; the rest are still in "
                    "the tree" % (limit, len(ordered_symbols)))
    return kept_files, ordered_symbols[:limit], how, files_capped, symbols_capped


def top_dirs(files: Sequence[str], symbols: Sequence[Symbol]) -> List[Tuple[str, int, int]]:
    rows: Dict[str, List[int]] = {}
    for rel in files:
        head = rel.split("/")[0] if "/" in rel else "."
        rows.setdefault(head, [0, 0])[0] += 1
    for symbol in symbols:
        head = symbol.path.split("/")[0] if "/" in symbol.path else "."
        rows.setdefault(head, [0, 0])[1] += 1
    return sorted(((name, counts[0], counts[1]) for name, counts in rows.items()),
                  key=lambda row: (-row[2], -row[1], row[0]))


def banner(key: str, sha: str, generated: str, files: int, symbols: int,
           how: str, key_source: str) -> List[str]:
    """The header both artifacts start with, so a reader can price the index's age."""
    return ["repo_key: %s" % key, "sha: %s" % sha, "generated: %s" % generated,
            "files: %d" % files, "symbols: %d" % symbols,
            "tool: %s (schema %d, version %s)" % (MARKER, SCHEMA, TOOL_VERSION),
            "scanned_with: %s" % how, "key_source: %s" % key_source]


def render_markdown(key: str, head: Sequence[str], files: Sequence[str],
                    symbols: Sequence[Symbol], files_capped: bool,
                    symbols_capped: bool, limit: int) -> str:
    rows = top_dirs(files, symbols)
    out = ["<!-- %s -->" % MARKER]
    out += ["", "# Code index: %s" % key, ""]
    out += ["- %s" % line for line in head]
    out += ["", "Compare the `sha` above with `git rev-parse HEAD` before trusting a",
            "line below: an index older than the working tree is a hint, not an answer.",
            "", "## Top directories by files", "", "| directory | files | symbols |",
            "| --- | --- | --- |"]
    for name, nfiles, nsymbols in rows[:TOP_DIRS]:
        out.append("| `%s` | %d | %d |" % (name, nfiles, nsymbols))
    out += ["", "## Top directories by symbols", "", "| directory | symbols | files |",
            "| --- | --- | --- |"]
    for name, nfiles, nsymbols in sorted(rows, key=lambda row: (-row[2], row[0]))[:TOP_DIRS]:
        out.append("| `%s` | %d | %d |" % (name, nsymbols, nfiles))
    out += ["", "## Symbols by kind", ""]
    by_kind: Dict[str, List[Symbol]] = {}
    for symbol in symbols:
        by_kind.setdefault(symbol.kind, []).append(symbol)
    for kind in sorted(by_kind, key=lambda name: (-len(by_kind[name]), name)):
        out.append("### %s (%d)" % (kind, len(by_kind[kind])))
        out.append("")
        for symbol in sorted(by_kind[kind], key=lambda s: (s.name, s.path, s.line)):
            out.append("- `%s` -- `%s:%d`" % (symbol.name, symbol.path, symbol.line))
        out.append("")
    out += ["## Cap", ""]
    out.append("- files: %d indexed%s" % (len(files), " (cap %d)" % FILE_LIMIT
                                          if files_capped else ""))
    out.append("- symbols: %d indexed%s" % (len(symbols), " (cap %d)" % limit
                                            if symbols_capped else ""))
    out.append("")
    return "\n".join(out) + "\n"


def write_atomic(path: str, text: str) -> None:
    """Land one artifact in one step: a reader never opens a half-written index."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build the local code index of one clone beside its notes file.")
    parser.add_argument("--repo", required=True, help="clone to index")
    parser.add_argument("--home", default=None,
                        help="profile home the notes volume sits under (default $HOME)")
    parser.add_argument("--json", action="store_true",
                        help="print the index as JSON instead of the summary line")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT,
                        help="symbol cap, default %d" % DEFAULT_LIMIT)
    args = parser.parse_args()
    report = Report()

    if args.limit < 1:
        report.error("--limit must be at least 1")
        return finish(report, 2)
    repo = os.path.abspath(os.path.expanduser(args.repo))
    if not os.path.isdir(repo):
        report.error("no directory at %s" % repo)
        return finish(report, 2)
    # Every home-derived path below goes through this value, never os.environ["HOME"],
    # so a Bats suite can point a run at a scratch home.
    if not args.home and not os.environ.get("HOME"):
        report.error("HOME is unset and --home was not given")
        return finish(report, 2)
    home = os.path.abspath(os.path.expanduser(args.home if args.home
                                              else os.environ.get("HOME", "")))
    if not os.path.isdir(home):
        report.error("no home directory at %s" % home)
        return finish(report, 2)

    if not is_git_repo(repo):
        report.error("%s is not a git working tree, and the index key comes from its "
                     "origin remote" % repo)
        return finish(report, 1)
    sha = git_head(repo)
    if not sha:
        report.error("%s has no commit yet, so the index would carry no sha for a reader "
                     "to price against HEAD" % repo)
        return finish(report, 1)
    remote = origin_remote(repo)
    if not remote:
        report.error("%s has no origin remote, so there is no host/owner/repo key to file "
                     "the index under" % repo)
        return finish(report, 1)

    key, key_source = repo_key(remote, home, report)
    if not key:
        # The remote may carry login material, so it is never echoed.
        report.error("the origin remote of %s does not reduce to a host/owner/repo key"
                     % repo)
        return finish(report, 1)

    files, symbols, how, files_capped, symbols_capped = scan(repo, args.limit, report)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    counts: Dict[str, int] = {path: 0 for path in files}
    for symbol in symbols:
        if symbol.path in counts:
            counts[symbol.path] += 1
    entries = [FileEntry(path, language_of(path), counts[path]) for path in sorted(files)]
    head = banner(key, sha, generated, len(entries), len(symbols), how, key_source)

    out_dir = os.path.join(home, ".grok", "notes", *key.split("/"))
    json_path = os.path.join(out_dir, "code-index.json")
    md_path = os.path.join(out_dir, "code-index.md")
    record = {"schema": SCHEMA, "repo_key": key, "sha": sha, "generated": generated,
              "tool": MARKER, "tool_version": TOOL_VERSION, "scanned_with": how,
              "key_source": key_source,
              "counts": {"files": len(entries), "symbols": len(symbols),
                         "file_cap": FILE_LIMIT, "symbol_cap": args.limit,
                         "files_capped": files_capped, "symbols_capped": symbols_capped},
              "files": [entry._asdict() for entry in entries],
              "symbols": [symbol._asdict() for symbol in symbols]}
    # Both texts are rendered before either lands, so a failure cannot leave the pair
    # describing different runs.
    json_text = json.dumps(record, indent=2) + "\n"
    md_text = render_markdown(key, head, [entry.path for entry in entries], symbols,
                              files_capped, symbols_capped, args.limit)
    try:
        os.makedirs(out_dir, exist_ok=True)
        write_atomic(json_path, json_text)
        write_atomic(md_path, md_text)
    except OSError as exc:
        report.error("cannot write the index under %s: %s" % (out_dir, exc))
        return finish(report, 2)

    if args.json:
        print(json.dumps(record, indent=2))
    else:
        print("ok: %d files, %d symbols -> %s" % (len(entries), len(symbols), md_path))
    return finish(report, 0)


if __name__ == "__main__":
    sys.exit(main())
