# ## key_comment.awk — the comment lift behind key_comment in scripts/update-configs.sh
#
# Prints the comment lines that sit directly above one key in an example env
# file: the explanation its twin carries for that key, and nothing from the
# block above it.
#
# Usage (the key is passed in, the example file is named in ARGV):
#   awk -v want="${key}" -f scripts/lib/key_comment.awk "${file}"
#
# Invariants:
#   - Scanning stops at the key itself, so a comment block below the key never
#     leaks upward into the answer.
#   - A blank line or a non-comment line resets the run, so only the block that
#     touches the key is printed.

index($0, want "=") == 1 { exit }
/^#/ { block[++n] = $0; next }
/^$|^[^#]/ { n = 0 }
END { for (i = 1; i <= n; i++) print block[i] }
