# ## startup_size.awk - the composed-body reader behind startup_size_guard
# in scripts/push-template.sh
#
# The Coder agent execs coder_agent.startup_script, and every coder_script.script, as
# `bash -c <body>`, so each body travels as one argument to execve(2). Linux caps a
# single argument at MAX_ARG_STRLEN, 32 pages = 131072 bytes; past it the fork fails
# with E2BIG, the home directory never seeds, and the workspace banner reads "A startup
# script has failed". main.tf composes each body from one .tftpl plus the payloads it
# inlines, so the number that decides whether a workspace boots is a composed total.
#
# Emits one tab-separated record per inlining found in one main.tf:
#   <body>\t<payload name>    the body renders from that .tftpl and inlines the file
#   <body>\tHEREDOC           the body is a heredoc, whose length this cannot measure
#   <body>\tOTHER             the body is neither a templatefile() nor a heredoc
#   <body>\tCLASH             two bodies render templates of the same name, so this
#                             reader cannot tell their arguments apart
#
# <body> is the basename of the .tftpl the body renders from, which is what tells two
# coder_script bodies apart. For the two unmeasurable kinds it is the label of the
# enclosing resource, of any resource type, or "?" when no resource line precedes the
# assignment.
#
# Usage (the main.tf is named in ARGV; the path resolution, the byte count and the
# verdict stay in the shell, which reads the records with IFS=$'\t' read):
#   awk -f scripts/lib/startup_size.awk "${main}"
#
# Invariants:
#   - A payload inlined twice is printed twice, because its bytes travel twice. The
#     caller sums per body, so an argument that carries the same file twice is charged
#     for it twice.
#   - The template a body renders from arrives as a record of its own, since its bytes
#     occupy the argument as much as any payload it inlines.
#   - The block runs from `^  (startup_script|script) = templatefile(` to the next line
#     that is exactly `  })`. A coder_script body closes at two spaces, so a nested
#     templatefile() inside the startup map, which closes at four, cannot end it early.
#   - A `key = local.NAME` entry credits the one file that local's own assignment reads,
#     and stops there. Recursing into that file's block would count bytes the
#     independent parser in tests/bats/startup-script-size.bats does not, and the two
#     have to agree; no local's template inlines anything today.
#   - Bodies are recognised at exactly two spaces, which is terraform fmt output. A body
#     written at any other indent is invisible to this reader rather than reported, so
#     the twins have to stay formatted: scripts/validate.sh runs `terraform fmt -check`
#     over both of them, and skips that check only where terraform is absent.

BEGIN { res = "?" }

{ L[NR] = $0 }

END {
  i = 1
  while (i <= NR) {
    # Any resource header, not just coder_script: a body always sits inside one, and
    # remembering only coder_script would stamp an unmeasurable coder_agent body with
    # the name of whichever coder_script was read last.
    if (L[i] ~ /^resource "[A-Za-z0-9_-]+" "/) {
      res = L[i]
      sub(/^resource "[^"]*" "/, "", res)
      sub(/".*$/, "", res)
      i++
      continue
    }
    if (L[i] ~ /^  (startup_script|script) = templatefile\(/) {
      body = tmpl_of(L[i])
      if (body == "") {
        i++
        continue
      }
      # The body key is the template basename, so two bodies rendered from templates of
      # the same name would be summed as one argument. That over-counts rather than
      # under-counts, but it measures neither body honestly, so say so and let the
      # caller refuse instead of reporting a number nobody can act on.
      if (body in seenres) {
        print body "\tCLASH"
      }
      seenres[body] = res
      j = i
      while (j <= NR && L[j] !~ /^  \}\)$/) {
        emit_paths(L[j], body)
        emit_locals(L[j], body)
        j++
      }
      i = j + 1
      continue
    }
    if (L[i] ~ /^  (startup_script|script) = <</) {
      print res "\tHEREDOC"
      # Step over the heredoc body. Leaving it in the top-level scan would read its
      # contents as template source, and a line that happens to look like an assignment
      # would bill bytes to a body that never carried them.
      delim = L[i]
      sub(/^  (startup_script|script) = <</, "", delim)
      sub(/^[-]?["']?/, "", delim)
      sub(/[[:space:]]+$/, "", delim)
      i++
      while (i <= NR && L[i] !~ ("^[[:space:]]*" delim "[[:space:]]*$")) {
        i++
      }
      i++
      continue
    }
    if (L[i] ~ /^  (startup_script|script) = /) {
      print res "\tOTHER"
      i++
      continue
    }
    i++
  }
}

# tmpl_of - the basename inside templatefile("${path.module}/NAME"), or "" when the
# line carries no such path.
function tmpl_of(line) {
  if (match(line, /\$\{path\.module\}\/[A-Za-z0-9._-]+"/)) {
    s = substr(line, RSTART, RLENGTH)
    sub(/^\$\{path\.module\}\//, "", s)
    sub(/"$/, "", s)
    return s
  }
  return ""
}

# emit_paths - every ${path.module}/NAME quoted on this line, as its own record.
function emit_paths(line, body,   n, parts, k, t) {
  n = split(line, parts, "\"")
  for (k = 1; k <= n; k++) {
    if (parts[k] ~ /^\$\{path\.module\}\/[A-Za-z0-9._-]+$/) {
      t = parts[k]
      sub(/^\$\{path\.module\}\//, "", t)
      print body "\t" t
    }
  }
}

# emit_locals - a `key = local.NAME` entry means the body carries whatever that local
# holds, so credit the single file the local's own assignment reads. A `locals` entry
# sits at two spaces under terraform fmt; that form wins when the file has one, so a
# same-named key deeper in some other map cannot shadow the real local.
function emit_locals(line, body,   k, tok) {
  if (!match(line, /=[[:space:]]*local\.[A-Za-z0-9_]+/)) {
    return
  }
  tok = substr(line, RSTART, RLENGTH)
  sub(/.*local\./, "", tok)
  for (k = 1; k <= NR; k++) {
    if (L[k] ~ ("^  " tok "[[:space:]]*=") && L[k] ~ /path\.module/) {
      emit_paths(L[k], body)
      return
    }
  }
  for (k = 1; k <= NR; k++) {
    if (L[k] ~ ("^[[:space:]]*" tok "[[:space:]]*=") && L[k] ~ /path\.module/) {
      emit_paths(L[k], body)
      return
    }
  }
}
