# ## tftpl_strip_gates.awk — the gate stripper behind seed_render_grok_config
# in scripts/seed-dev-env.sh
#
# Drops the Terraform-template gates a contributor seed never turns on, so the
# rendered ~/.grok/config.toml carries no %{ ... } directive at all.
#
# Usage (the .tftpl source is named in ARGV; the substitutions stay in the
# caller's sed):
#   awk -f scripts/lib/tftpl_strip_gates.awk "${src}" | sed ...
#
# Invariants:
#   - The github_mcp, context7_mcp and grok_config_extra blocks are dropped
#     whole; the search_mcp block loses its own if/endif lines but keeps its
#     body.
#   - Every %{endif~} is consumed, so a kept block never leaves a directive
#     behind.

BEGIN { skip = 0 }
/%\{if github_mcp~\}/ { skip = 1; next }
/%\{if context7_mcp~\}/ { skip = 1; next }
/%\{if grok_config_extra != ""~\}/ { skip = 1; next }
/%\{if search_mcp~\}/ { next }
/%\{endif~\}/ {
  if (skip) { skip = 0; next }
  next
}
skip { next }
{ print }
