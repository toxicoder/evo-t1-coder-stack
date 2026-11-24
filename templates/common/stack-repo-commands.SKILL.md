---
name: stack-repo-commands
description: "The command recipes that exist only inside a checkout of the
  evo-t1-coder-stack repository: the gate's formatter target, the Bazel graph reader
  that names the test covering a file, and the commit hook that runs the hermetic gate.
  Use when working in this repository's own clone and a formatter target, a coverage
  question, or a pre-commit refusal has to be reproduced by hand."
when-to-use: "Use inside the stack repository's own checkout, when you need the format
  sweep, the test target that covers one path, or the check the commit hook runs."
compatibility: "Requires bazelisk and git, and a checkout of evo-t1-coder-stack -- the
  clone that tracks .evo-t1-stack-repo at its root. Nothing here exists in any other
  repository."
metadata:
  author: "operator"
  short-description: "Command recipes for the stack repository's own checkout"
---

<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it and
     delete the `managed-by: evo-t1-coder-stack` marker line: a marker-free file is
     user-owned. Deleting it is undone -- the workspace boot writes the file again whenever
     it is absent. To hide the slash command, set `disabled = ["stack-repo-commands"]` under `[skills]`
     in `~/.grok/config.toml`. -->

# Command recipes for the stack repository's own checkout

The global rulebook names the fleet, the lanes, the ports and the operator CLIs,
because those are true of every workspace this stack deploys. The three commands below
are true only inside a clone of the stack repository itself, so they live here rather
than in the rulebook. Each is one line, plus what it proves.

- `bazelisk run //:fix` -- the gate's own formatter: `shfmt -w -s -i 2 -ci` over every
  shell source and `buildifier -mode=fix` over `BUILD`, `BUILD.bazel`, `MODULE.bazel`
  and `.bzl`, in the same invocation `//:lint` checks against. Run it after editing a
  shell script or a BUILD file, and re-read what it changed.

  What it proves: the next `bazelisk test //:lint --test_tag_filters=manual` has no
  format finding left to print. It does not touch Python -- that is `ruff format`.

- `bazelisk run //scripts:bazel-map -- tests-for <path> [<path>...]` -- asks the
  repository's declared Bazel graph which test target covers the paths you touched, and
  prints the labels. `-- scope --untracked` is the same answer for what is not tracked
  yet, and `-- owners <path>` answers whether a new payload file joined a filegroup at
  all.

  What it proves: the `bazelisk test <label>` you then run is the scoped set that
  actually covers your edit, so you iterate on three suites instead of the whole
  `//:test-fast` and save the one uncached full pass for before the pull request. An
  empty list is not proof nothing depends on the file: the BUILD files are the record,
  and an unlisted file is invisible to the gates.

- `.githooks/pre-commit` -- the hook this repository installs
  (`bazelisk run //scripts:install-hooks -- --check` says whether it is installed) and
  runs on every `git commit`, gate included.

  What it proves: the commit you just made is one the hermetic gate accepted, so
  `git log --oneline main..HEAD` stays a record of green units rather than a queue of
  failures to fix afterwards.

The operator CLIs the rulebook points at (`//scripts:dev-stack`,
`//scripts:update-configs`, `//scripts:refresh-configs`, `//scripts:bootstrap`,
`//scripts:github-auth`, `//scripts:search-check`, `//scripts:mcp-check`) are not
workspace tooling either: they live in this same checkout, so run them there or in a
host shell. The rulebook keeps them named because an agent in any workspace has to be
able to ask for them.
