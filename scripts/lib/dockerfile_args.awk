# ## dockerfile_args.awk — the Dockerfile ARG scanner behind scripts/lib/image.sh
#
# Backs two functions there, selected with -v mode=:
#   dockerfile_arg_names    (mode=names, the default) — one ARG name per line
#   dockerfile_arg_defaults (mode=defaults)           — KEY=value per ARG default
#
# Usage (the sort stays with the caller; the Dockerfile is named in ARGV):
#   awk -f scripts/lib/dockerfile_args.awk "${dockerfile}" | sort -u
#   awk -v mode=defaults -f scripts/lib/dockerfile_args.awk "${dockerfile}" | sort -u
#
# Invariants:
#   - The scan matches the historical awk in build-dev-image.sh, including
#     backslash-continued ARG lines and comment skipping.
#   - An ARG without a default prints nothing in defaults mode (the reserved
#     TARGETARCH is how that shows up in the golden-image Dockerfile).

BEGIN { mode = (mode == "defaults") ? "defaults" : "names" }
/^[[:space:]]*#/ { next }
/^[[:space:]]*ARG[[:space:]]/ { inblk = 1 }
inblk {
  line = $0
  sub(/^[[:space:]]*ARG[[:space:]]+/, "", line)
  sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
  gsub(/^[[:space:]]+/, "", line)
  if (mode == "defaults") {
    eq = index(line, "=")
    if (eq > 0) {
      name = substr(line, 1, eq - 1)
      value = substr(line, eq + 1)
      sub(/[[:space:]]+$/, "", name)
      sub(/[[:space:]]+$/, "", value)
      if (name ~ /^[A-Z0-9_]+$/) print name "=" value
    }
  } else {
    split(line, kv, /=/)
    if (kv[1] ~ /^[A-Z0-9_]+$/) print kv[1]
  }
  inblk = ($0 ~ /[[:space:]]\\[[:space:]]*$/)
}
