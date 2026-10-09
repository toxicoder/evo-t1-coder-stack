# Project conventions

Shell follows the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).

## File header

Every `scripts/**/*.sh` file starts with a `# ## ` header that names the file and says whether it is an entry point or a sourced library.

## Functions

Every function carries this block immediately above the definition:

```bash
# @function name
# One sentence.
# Globals:
#   NAME, or None
# Arguments:
#   $1 - meaning
# Outputs:
#   What is printed
# Returns:
#   0, a status, or the exit code
```

`tests/doc_coverage.sh` fails the build when a header or a block is missing.

## Tests

Every function under `scripts/` is named by an asserting test under `tests/`. `tests/shell_inventory.sh` fails when a name is missing. Tests are hermetic: docker, ssh, curl, and the other external tools resolve through `tests/bats/tool_stubs`.

## Ingress

Bazelisk is the primary command. `make` only delegates.

```bash
bazelisk test //:test-fast
bazelisk test //:lint --test_tag_filters=manual
bazelisk run //:validate
bazelisk run //:fix
```

Runtime stays `docker compose`. Bazel does not build the golden image or pull models.
