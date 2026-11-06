# ## tf_types.awk - the Terraform variable-type reader behind scripts/validate.sh
#
# Terraform is the one language in this repo with a real, enforced type system at
# its input boundary: every `variable` block can carry a `type` constraint, and
# without one the value arriving from `terraform apply -var`, from a `.tfvars`
# file, or from the Coder create form is whatever HCL guessed, so `search_mcp =
# "flase"` reaches a `== "true"` comparison and reads as false with no diagnostic
# anywhere. The type constraint is what turns that from a silently wrong
# workspace into a plan-time error. `//:validate` therefore asks the same two
# questions of both template twins that //lints:mypy asks of Python: is every
# input declared, and did anyone reach for the broad type instead.
#
# Those two questions are the whole contract, because a `variable` block is the
# only place Terraform lets you declare a type. `output` and `locals` have no
# type attribute, so there is nothing to check there, and `terraform fmt -check`,
# which //:validate runs before this, already owns formatting.
#
# Usage (one line per finding on stdout, nothing when the tree conforms):
#   awk -f scripts/lib/tf_types.awk templates/workspace/main.tf templates/workspace/coder.tf
#
# Line shape:  file<TAB>line<TAB>rule<TAB>detail
#   rule  one of missing-type|broad-any|bare-container
#
# Invariants:
#   - Silence means conformance, and the caller treats it as success. A file with
#     no `variable` block at all is legal and prints nothing, which is what lets
#     main.tf and coder.tf both be passed on one command line.
#   - Only the `type` attribute of a top-level `variable` block is inspected. The
#     same words appear in `default = { ... }` bodies and in `validation { ... }`
#     conditions, and flagging those would turn a real default into a false
#     finding, so the scan starts at the `type` line and stops once the block has
#     one.
#   - A block ends at a `}` in column 1. terraform fmt guarantees top-level
#     closers sit at column 0 and attributes are indented, so a nested brace
#     cannot be mistaken for the end of the block.
#   - A multi-line type expression (the `object({ ... })` shape a future template
#     would use) is collected until its parentheses and braces balance, so the
#     `any` hiding inside `object({ url = any })` is still seen.
#   - `any` is matched as a word, not a substring: `any`, `list(any)` and
#     `optional(any)` are findings, while a variable named `company_mcp` or a
#     `map(string)` whose value mentions "many" is not.
#   - `list`, `set` and `map` with no parenthesized element type are findings too.
#     They are valid HCL and mean "elements of any type", which is the same hole
#     the bare `any` is, reached by a different spelling.

# Trim leading and trailing blanks and tabs from one collected field.
function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

# Count how many times one single character appears in s. Character-wise because
# mawk has no gawk-style global count and a type expression is short.
function count_of(s, ch,  i, n) {
  n = 0
  for (i = 1; i <= length(s); i++) {
    if (substr(s, i, 1) == ch) n++
  }
  return n
}

# Report one finding in the shape the caller parses. The file travels in as an
# argument rather than being read from FILENAME at print time, because the
# end-of-file flush names the file a block *opened* in, which is not the file awk
# happens to be reading when it gets there.
function finding(file, line, rule, detail) {
  printf "%s\t%d\t%s\t%s\n", file, line, rule, detail
}

# Is this type expression balanced in both bracket kinds? An unbalanced one is a
# multi-line constraint whose remaining lines have not been read yet.
function balanced(s) {
  return count_of(s, "(") <= count_of(s, ")") &&
         count_of(s, "{") <= count_of(s, "}")
}

# Does this type expression name the broad type anywhere in it? Word-matched, so
# `company_mcp` and `many` are not findings.
function mentions_any(s) {
  return s ~ /(^|[^A-Za-z0-9_])any([^A-Za-z0-9_]|$)/
}

# Does it use a container with no declared element type? `map(string)` is a real
# constraint and `map` alone is not, which is the whole difference this tests.
function bare_container(s) {
  return s ~ /(^|[^A-Za-z0-9_])(list|set|map)([ \t]*($|[,)\]}=]))/
}

# Judge one completed type expression and report it if it is too broad.
function check_type(file, line, name, expr) {
  if (mentions_any(expr)) {
    finding(file, line, "broad-any", name " type = " expr)
  } else if (bare_container(expr)) {
    finding(file, line, "bare-container", name " type = " expr " declares no element type")
  }
}

# Report a variable that opened without ever carrying a type attribute.
function flush_untyped(file, line, name) {
  finding(file, line, "missing-type", "variable \"" name "\" declares no type constraint")
}

# A new file resets the state machine: both twins are read in one call, and a
# block left open at the end of one file must not bleed into the next. It does
# not `next`, because a file whose very first line is a variable still has to be
# seen by the opening rule below.
FNR == 1 {
  if (in_var && !has_type) flush_untyped(var_file, var_line, var_name)
  in_var = 0
  in_type = 0
}

# A top-level `variable "name" {` opens a block. Anchored at column 1 on purpose:
# a nested block whose first token happens to be `variable` is not an input.
/^variable[ \t]+"/ {
  if (in_var && !has_type) flush_untyped(var_file, var_line, var_name)
  in_var = 1
  in_type = 0
  has_type = 0
  type_expr = ""
  var_file = FILENAME
  var_line = FNR
  var_name = $0
  sub(/^variable[ \t]+"/, "", var_name)
  sub(/".*$/, "", var_name)
  next
}

# Inside a block, the first `type = ...` at attribute depth is the constraint.
# Once one has been seen the scan stops looking, so a `type` key inside a
# `default` object body is never mistaken for the constraint.
in_var && !in_type && !has_type && /^[ \t]*type[ \t]*=/ {
  has_type = 1
  type_line = FNR
  type_expr = $0
  sub(/^[ \t]*type[ \t]*=/, "", type_expr)
  sub(/[ \t]*#.*/, "", type_expr)
  type_expr = trim(type_expr)
  if (balanced(type_expr)) {
    check_type(var_file, type_line, var_name, type_expr)
  } else {
    in_type = 1
  }
  next
}

# Continuation lines of a multi-line type expression, collected until balanced.
in_var && in_type {
  type_expr = type_expr " " trim($0)
  if (balanced(type_expr)) {
    in_type = 0
    check_type(var_file, type_line, var_name, type_expr)
  }
  next
}

# The column-1 closer ends the block. A variable that never carried a `type`
# attribute is the finding this program exists to keep at zero.
in_var && /^\}/ {
  if (!has_type) flush_untyped(var_file, var_line, var_name)
  in_var = 0
  in_type = 0
  next
}

END {
  if (in_var && !has_type) flush_untyped(var_file, var_line, var_name)
  if (in_var && has_type && in_type) check_type(var_file, type_line, var_name, type_expr)
}
