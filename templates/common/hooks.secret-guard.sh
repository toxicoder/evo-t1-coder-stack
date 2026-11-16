#!/bin/sh
# managed-by: evo-t1-coder-stack
#
# ## secret-guard -- the PreToolUse write guard
#
# Seeded to ~/.grok/hooks/bin/secret-guard.sh by
# templates/common/stack-hooks.sh.tftpl (which chmods it 0755, because the runner
# execs it directly), and matched by the PreToolUse entry in
# templates/common/hooks/evo-t1-hooks.json: Edit|Write|search_replace|write, timeout 5.
#
# Why this guard exists: the agent that writes a file is the same agent that may have
# just read a credential out of one, and a secret that reaches a file is one commit
# away from being permanent. The rulebook forbids printing one
# (templates/common/GROK_BUILD_AGENTS.md); this is the mechanical half of that rule.
#
# Fail-open is the load-bearing decision, and it is deliberate. This runs in front of
# every write the agent makes, so a guard that cannot read its own input has to get out
# of the way rather than stop the session: every error path prints an allow and exits 0,
# and only a positive pattern match denies. The two things it will still refuse are a
# pattern hit and tool input the runner says it clipped, because in both cases the scan
# proved nothing about the text.

set -u

# The bracket ranges in the patterns have to mean ASCII. Under a UTF-8 locale grep can
# fold them, and an A-Z that also matches an accented letter is not what a secret
# pattern is for.
LC_ALL=C
export LC_ALL

allow() {
  printf '%s\n' '{"decision":"allow"}'
  exit 0
}

# The reason carries whatever the caller names and never the match: putting any part of
# the matched text here would write the secret into the transcript the guard exists to
# keep it out of.
deny() {
  printf '%s\n' "{\"decision\":\"deny\",\"reason\":\"secret-guard: $1\"}"
  exit 2
}

# One event line on stdin. GROK_HOOK_EVENT is the reserved env the runner may carry the
# same event in, so an empty stdin is not yet a missing event.
event="$(cat 2>/dev/null || true)"
if [ -z "${event}" ] && [ -n "${GROK_HOOK_EVENT:-}" ]; then
  event="${GROK_HOOK_EVENT}"
fi
[ -n "${event}" ] || allow

if command -v jq >/dev/null 2>&1; then
  # The four text fields a write can carry, joined for one scan. The type guards keep a
  # malformed event (toolInput a string, or the whole event an array) from failing jq:
  # jq's exit status is the only signal here, and a failure must read as "the guard
  # could not see this event", which is an allow, not as "no secrets".
  #
  # "malformed" and "absent" are kept apart on purpose. The runner documents
  # toolInputTruncated as always present on a PreToolUse event, so a well-formed object
  # that lacks it is not an event this guard can vouch for the text of, and it goes the
  # same way as true. An event jq could not read as an object is a broken hook, and a
  # broken hook stays out of the way.
  truncated="$(printf '%s' "${event}" |
    jq -r 'if type == "object" then (if has("toolInputTruncated") then (.toolInputTruncated | tostring) else "absent" end) else "malformed" end' 2>/dev/null)" ||
    allow
  [ "${truncated}" = "malformed" ] && allow
  haystack="$(printf '%s' "${event}" |
    jq -r '
      def body: if type == "object" then
        (if (.toolInput | type) == "object" then .toolInput else {} end)
        | [.new_string, .content, .contents, .command]
        | map(select(type == "string")) | join("\n")
      else "" end;
      body
    ' 2>/dev/null)" ||
    allow
else
  # No jq: fall back to grepping the raw event, so a box without the golden image's jq
  # still gets a verdict. Less precise by construction (a JSON key name can carry one of
  # the pattern words), and the truncation check reads the key textually instead of
  # parsing it.
  truncated="absent"
  if printf '%s\n' "${event}" | grep -qE -- '"toolInputTruncated"'; then
    if printf '%s\n' "${event}" | grep -qE -- '"toolInputTruncated"[[:space:]]*:[[:space:]]*false'; then
      truncated="false"
    else
      truncated="true"
    fi
  fi
  haystack="${event}"
fi

# Clipped input is a deny: the runner has told us it dropped part of what we cannot see,
# so a clean scan says nothing about it. The field is documented as always present, so a
# missing one is the same unknown, and this guard's whole job is to refuse to bless text
# it could not read. A guard that checks a string's text denies unless the field is
# exactly false -- which is the form the hooks guide's own example uses.
if [ "${truncated}" != "false" ]; then
  deny 'toolInputTruncated is not false, so the runner clipped text this scan could not see'
fi
[ -n "${haystack}" ] || allow

# A LiteLLM secret source names the environment instead of carrying a value, and it is the
# form this repo's own litellm/config.yaml writes: api_key: os.environ/SPARK_1_API_KEY. The
# value class below excludes a leading dollar sign, which is the shell's reference, and this
# indirection spells the same idea in Python, so it would be denied as a credential. Folding
# every secret source to one fixed token keeps the line's shape for the rest of the scan and
# takes the digits out of the name with it, which is what the assignment gate reads.
haystack="$(printf '%s\n' "${haystack}" |
  sed -E 's#(os\.environ|os\.env|base64_environ|base64_env)/[A-Za-z_][A-Za-z0-9_]*([?][^"[:space:]]*)?#ENVIRON_REF#g')"

# One grep per class, so the reason can name the class that fired. The patterns are the
# family's pinned list.
#
# Two things keep this list from becoming the thing that blocks every write. The value must
# start on a character that cannot be a variable reference -- a leading dollar sign means the
# file points at the environment, which is the correct pattern this guard exists to protect --
# and the line must carry a digit, which is what separates a credential from an identifier.
# The digit test is applied to the lines the assignment pattern matched, not to the whole
# scan, so a digit elsewhere in the file cannot convict an innocent assignment.
#
# The known-format scans are exact and case-sensitive. The assignment scans also run
# case-folded, because a real write names the variable the way its SDK does --
# AWS_SECRET_ACCESS_KEY in upper case -- and LC_ALL=C makes grep byte-wise, so a lowercase
# list alone would walk straight past it.
scan() {
  if printf '%s\n' "${haystack}" | grep -qE -- "$2"; then
    deny "$1 matched; its text is not quoted here, so pass the credential through the environment instead of the file"
  fi
}

scan_i() {
  if printf '%s\n' "${haystack}" | grep -qiE -- "$2"; then
    deny "$1 matched; its text is not quoted here, so pass the credential through the environment instead of the file"
  fi
}

# Assignment-shaped text, then a digit somewhere on the same line.
scan_assign() {
  if printf '%s\n' "${haystack}" | grep -E -- "$2" | grep -q '[0-9]'; then
    deny "$1 matched; its text is not quoted here, so pass the credential through the environment instead of the file"
  fi
}

# The same, case-folded. The names on this list reach a file spelled the way the SDK
# spells them -- AWS_SECRET_ACCESS_KEY -- and LC_ALL=C makes the plain pass byte-wise, so
# a lowercase list would read straight past the one case that actually shows up.
scan_assign_i() {
  if printf '%s\n' "${haystack}" | grep -iE -- "$2" | grep -q '[0-9]'; then
    deny "$1 matched; its text is not quoted here, so pass the credential through the environment instead of the file"
  fi
}

# Whitespace or a quote may sit between the separator and the value; a dollar sign may not,
# because that is a reference. The value class excludes the punctuation that ends a value in
# the formats a workspace actually writes, so a bare word cannot stretch to 12 characters by
# eating its own sentence.
KW='(api[_-]?key|apikey|secret|token|password|passwd|client[_-]?secret|access[_-]?token|refresh[_-]?token|private[_-]?key|credentials?)'
GAP='[[:space:]"'"'"']{0,4}'
VAL='[^$[:space:]"'"'"',;()<>]{12,}'

scan 'the AWS access key id pattern' 'AKIA[0-9A-Z]{16}'
scan 'the GitHub token pattern' 'gh[pousr]_[A-Za-z0-9]{36,}'
scan 'the Slack token pattern' 'xox[baprs]-'
scan 'the Google API key pattern' 'AIza[0-9A-Za-z_-]{35}'
scan 'the private key block pattern' '-----BEGIN [A-Z ]*PRIVATE KEY-----'
# A URL carrying both a user and a password is a credential whatever it is called, and this
# is the shape most often pasted straight into a config file.
scan 'a URL carrying a user and password' '[A-Za-z][A-Za-z0-9+.-]*://[^/:[:space:]]+:[^@[:space:]]{9,}@'

scan_assign 'the generic api key / secret / token assignment pattern' \
  "${KW}[[:space:]]*[:=]${GAP}${VAL}"
# The same shape under the names an SDK spells in upper case, which the pass above cannot see.
scan_assign_i 'an upper-case credential assignment' \
  '(aws_secret_access_key|aws_session_token|azure_client_secret|google_api_key|db[_-]?password|database_url)[[:space:]]*[:=]?[[:space:]"'"'"']{0,4}[^$[:space:]"'"'"',;()<>]{8,}'
# The same shape case-folded, and under the same digit gate: a write that names a
# credential the way a non-upper-case SDK does still has to carry the entropy a real
# secret has, or it is a variable holding a value that lives somewhere else.
scan_assign_i 'a credential assignment in another case' \
  "${KW}[[:space:]]*[:=]${GAP}${VAL}"

allow
