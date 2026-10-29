# ## suspended_engines.awk - the unresponsive-engine reader behind scripts/search-check.sh
#
# A SearXNG reply that carries zero results still answers 200 and still says
# why, in its `unresponsive_engines` key: which engines the instance has given
# up on, and what each one did to earn it ("access denied", "CAPTCHA", "Suspended:
# too many requests"). That is the difference between "this engine is broken" and
# "this engine is parked for another ten minutes", and before this reader the
# probe threw it away and printed one generic note.
#
# Usage (the body is named in ARGV, one `name<TAB>reason` per line on stdout):
#   awk -f scripts/lib/suspended_engines.awk "${body_file}"
#
# Invariants:
#   - Nothing is printed for a body that is not a results envelope, for a body
#     whose key is absent, or for an empty list. Silence means "this reply blames
#     no engine", which is what the caller reports as a clean answer.
#   - The two array shapes SearXNG has shipped are both read: a list of
#     two-element lists (`[["google","access denied"]]`) and a map
#     (`{"google":"access denied"}`). Splitting on the quote characters handles
#     both, so neither shape is a parse failure that would silently read as
#     "nothing suspended".
#   - The `Suspended: ` prefix SearXNG puts on some reasons is dropped and the
#     reason is lowercased, so one engine reporting `Suspended: too many
#     requests` and another reporting `too many requests` deduplicate together
#     in the caller's `sort -u`.
#   - The engine name and the reason are the first two quoted strings of one
#     entry, and neither is allowed to contain the record separator: a tab or a
#     newline in either field is turned into a space before printing, because
#     the caller reads this line-by-line and a stray newline would split one
#     finding into two.

BEGIN {
  FS = "\n"
  OFS = "\t"
  buf = ""
}

{ buf = buf $0 }

END {
  key = "\"unresponsive_engines\""
  at = index(buf, key)
  if (at == 0) exit

  rest = substr(buf, at + length(key))

  # Step over the colon onto the value. No colon means the key appeared inside
  # some other string, which is not an answer to this question.
  colon = index(rest, ":")
  if (colon == 0) exit
  rest = substr(rest, colon + 1)

  # Keep only the value. The list closes with "]]" for the list-of-lists shape
  # and with "]" for the map or the empty list, so the longer form is tried
  # first; cutting at the first "]" would drop every entry after the first.
  close_at = index(rest, "]]")
  if (close_at > 0) {
    rest = substr(rest, 1, close_at - 1)
  } else {
    close_at = index(rest, "]")
    if (close_at > 0) rest = substr(rest, 1, close_at - 1)
  }

  # Splitting on the quote character puts the quoted strings at the even
  # indices and the text between them (`[[`, `,`, `],[`, `":"`) at the odd ones,
  # so the strings are collected first and then paired. Pairing the raw
  # indices instead would read the commas as reasons.
  n = split(rest, parts, "\"")
  count = 0
  for (i = 2; i <= n; i += 2) {
    if (parts[i] == "") continue
    count++
    quoted[count] = parts[i]
  }

  for (i = 1; i + 1 <= count; i += 2) {
    name = quoted[i]
    reason = quoted[i + 1]
    if (name == "") continue

    gsub(/[[:space:]]+/, " ", name)
    gsub(/[[:space:]]+/, " ", reason)
    sub(/^ /, "", name);   sub(/ $/, "", name)
    sub(/^ /, "", reason); sub(/ $/, "", reason)

    # SearXNG prefixes some reasons with the word the operator already knows.
    sub(/^[Ss]uspended:[[:space:]]*/, "", reason)
    reason = tolower(reason)

    if (reason == "") reason = "no reason given"
    print name, reason
  }
}
