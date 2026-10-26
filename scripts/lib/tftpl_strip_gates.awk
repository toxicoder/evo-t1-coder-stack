# ## tftpl_strip_gates.awk — the gate stripper behind seed_render_grok_config
# in scripts/seed-dev-env.sh
#
# Drops the Terraform-template gates a contributor seed never turns on, so the
# rendered ~/.grok/config.toml carries no %{ ... } directive at all.
#
# Usage (the .tftpl source is named in ARGV; the substitutions stay in the
# caller's sed):
#   awk -v keep_context7=1 -f scripts/lib/tftpl_strip_gates.awk "${src}" | sed ...
#
# keep_context7 carries the verdict for the [mcp_servers.context7] block. Only
# the literal 1 keeps it, and the seed passes that when the lane can actually
# run (CONTEXT7_API_KEY is in the environment, or --context7-mcp was asked
# for). Any other value, and no -v at all, drops the block whole, so a keyless
# laptop keeps the pre-flag behaviour.
#
# Invariants:
#   - The github_mcp and grok_config_extra blocks are always dropped whole.
#   - The search_mcp block loses its own if/endif lines but keeps its body; a
#     kept context7_mcp block is handled exactly the same way.
#   - Every %{endif~} is consumed, so a kept block never leaves a directive
#     behind.

BEGIN { skip = 0 }
/%\{if github_mcp~\}/ { skip = 1; next }
/%\{if context7_mcp~\}/ {
  # Kept blocks behave like search_mcp: the gate line goes, the body stays.
  if (keep_context7 == "1") { next }
  skip = 1
  next
}
/%\{if grok_config_extra != ""~\}/ { skip = 1; next }
/%\{if search_mcp~\}/ { next }
/%\{endif~\}/ {
  if (skip) { skip = 0; next }
  next
}
skip { next }
{ print }
