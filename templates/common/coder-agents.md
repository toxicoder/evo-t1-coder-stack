<!-- managed-by: evo-t1-coder-stack — stack-seeded. Delete this file to take the
     instructions over: the workspace boot reseeds it only while it is absent. -->

# Deployment-wide agent instructions

- Small asks (single file, short-read, one-off command): handle them directly
  with `read_file` / `edit_files` / `execute`. Do not delegate what you can
  read and edit yourself.
- Big multi-file work (refactors, framework adoption, test suites, new apps):
  route it through the `grok-build-delegation` skill — delegate to the Grok
  Build CLI (`grok`, also callable as `agent`) in the workspace, then review
  the delegated `git diff` and run the project's tests before calling it done.
- Keep secrets out of commands and file contents. Never print `$LITELLM_API_KEY`
  — reference env vars by name, never by value.
