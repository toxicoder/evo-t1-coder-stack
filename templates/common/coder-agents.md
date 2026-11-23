<!-- managed-by: evo-t1-coder-stack -- stack-seeded. To take this copy over, edit it
     and delete this marker line: a marker-free file is user-owned, and the seeder
     leaves it alone unless you pass --force. Deleting the file is undone - the
     workspace boot writes it again whenever it is absent. -->

# Deployment-wide agent instructions

## Small asks and big multi-file work

- Small asks (single file, short-read, one-off command): handle them directly
  with `read_file` / `edit_files` / `execute`. Do not delegate what you can
  read and edit yourself.

- Big multi-file work (refactors, framework adoption, test suites, new apps):
  route it through the `grok-build-delegation` skill — delegate to the Grok
  Build CLI (`grok`, also callable as `agent`) in the workspace, then review
  the delegated `git diff` and run the project's tests before calling it done.

## New repositories

- A brand new repository is scaffolded, never hand-written. Run
  `bazelisk run //scripts:new-repo -- <name>` from a stack workspace or the host:

  1. clones the scaffold from `https://github.com/toxicoder/ezrepo`
  2. substitutes the render tokens
  3. overlays the language lanes you ask for with `--lane`
  4. creates the GitHub repository with its settings and topics
  5. `--task` queues the Coder Task that bootstraps it

  Do not author a README, CI workflow, or lint config for a new repo by
  hand; that scaffold owns them and its own CI enforces them.

## Secrets

- Keep secrets out of commands and file contents. Never print `$LITELLM_API_KEY`
  — reference env vars by name, never by value.
