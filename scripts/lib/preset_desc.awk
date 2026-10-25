# ## preset_desc.awk — the preset description reader behind preset_desc_guard
# in scripts/push-template.sh
#
# Emits one tab-separated record per coder_workspace_preset block in a .tf file:
#   DESC\t<label>\t<name>\t<description>
#   SKIP\t<label>\t<name>\t
#
# Usage (the .tf file is named in ARGV; the byte count and the 128-byte verdict
# stay in the shell, which reads the records with IFS=$'\t' read):
#   awk -f scripts/lib/preset_desc.awk "${f}"
#
# Invariants:
#   - A heredoc description cannot be measured from one line, so it is reported
#     as SKIP and left unchecked rather than guessed at.
#   - Braces are counted on a copy of the line, so a brace inside a quoted
#     value cannot end the block early.

BEGIN { depth = 0; label = ""; bname = ""; desc = ""; unchecked = "" }
function flush() {
  if (unchecked != "") printf "SKIP\t%s\t%s\t\n", label, bname
  else if (desc != "") printf "DESC\t%s\t%s\t%s\n", label, bname, desc
  desc = ""; unchecked = ""
}
# Braces are counted on a copy of the line, so a brace inside a quoted value
# cannot end the block early, and the block is over when the count balances.
function braces(line,   copy, n) { copy = line; n = gsub(/[{}]/, "", copy); return n }
depth == 0 {
  if (index($0, "\"coder_workspace_preset\"") > 0) {
    # Splitting on quotes: field 2 is the resource type, field 4 the block
    # label, with the text between the quotes as the odd-numbered fields.
    split($0, q, "\""); label = q[4]
    gsub(/^[ \t]+|[ \t]+$/, "", label)
    depth = braces($0)
    bname = ""; desc = ""; unchecked = ""
  }
  next
}
{
  if ($0 ~ /^[ \t]*name[ \t]*=/ && bname == "") {
    bname = $0; sub(/^[^=]*=[ \t]*/, "", bname); sub(/^"/, "", bname); sub(/"$/, "", bname)
  }
  if ($0 ~ /^[ \t]*description[ \t]*=/ && desc == "" && unchecked == "") {
    value = $0; sub(/^[^=]*=[ \t]*/, "", value); sub(/^[ \t]*/, "", value)
    if (substr(value, 1, 2) == "<<") { unchecked = value }
    else { sub(/^"/, "", value); sub(/"$/, "", value); desc = value }
  }
  depth += braces($0)
  if (depth <= 0) { flush(); depth = 0 }
}
END { if (depth > 0) flush() }
