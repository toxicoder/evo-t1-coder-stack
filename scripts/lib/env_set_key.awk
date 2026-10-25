# ## env_set_key.awk — the rewriter behind env_set_key in scripts/update-configs.sh
#
# Replaces the one assignment whose key matches, and prints every other line
# unchanged, so an env file is rewritten without the shell ever re-parsing the
# value.
#
# Usage (the key and the new value travel in the environment, never in argv or
# a re-parsed string):
#   UCKEY="${key}" UCVAL="${value}" awk -f scripts/lib/env_set_key.awk "${file}"
#
# Invariants:
#   - The match is a prefix match on KEY= at column 1, so a key that only
#     appears inside another name is left alone.
#   - The value reaches the line through ENVIRON: no shell expansion, no sed
#     escaping, so a value holding $, & or a quote survives verbatim.

BEGIN { n = ENVIRON["UCKEY"]; v = ENVIRON["UCVAL"] }
index($0, n "=") == 1 { print n "=" v; next }
{ print }
