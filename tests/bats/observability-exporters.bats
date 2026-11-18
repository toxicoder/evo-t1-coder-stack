#!/usr/bin/env bats
#
# ## observability-exporters.bats - hermetic coverage for the observability payload.
#
# These files are read by containers this suite must never start. Nothing here can
# catch a broken scrape or a mis-routed alert except by asserting the contract the
# consumers key on, so that is what each test pins:
#
#   - the two labels Alertmanager's route tree and its three inhibit rules match
#     on (`tier`, and `spark` on the Spark tier). A rule file that drops one still
#     loads, and then alerts wrongly: without `tier` every branch of the tree misses
#     and the catch-all answers; without `spark` two Sparks that both lack the label
#     compare equal, so one box silences another;
#   - that the routing config is internally closed (every route names a defined
#     receiver, no receiver sits unreferenced, every inhibit carries `equal`);
#   - the entrypoint that turns ALERTMANAGER_WEBHOOK_URL into the file alertmanager.yml
#     names, driven with a fake binary and a temp dir: the empty key is the shipped
#     default, so "writes nothing and still execs" is a state production is in today;
#   - that the blackbox modules the scrape params ask for exist, each names a prober,
#     and none names a host or a port (targets arrive per scrape, from the generated
#     sparks.json, and a committed hostname is a contract break);
#   - the DCGM counter CSV's column count, and that it names only DCGM_FI_* fields -
#     a name DCGM does not know costs one exporter log error per scrape, forever;
#   - the scrape job names, which the exporter-gap alerts select on, so a rename in
#     prometheus.yml alone mutes those alerts.
#
# Structure is read through the YAML, never grepped: every fact comes from
# `python3 - <<PY` over yaml.safe_load, and the whole set parses first through the
# repo's own scripts/lib/parse_yaml.py.
#
# Usage: bats tests/bats/observability-exporters.bats
#        bazelisk test //tests:bats_observability_exporters_test   (after the parent
#        registers the suite in tests/BUILD.bazel)
# Safety: fixtures under BATS_TEST_TMPDIR only. No container, no Docker, no network,
# no daemon, and nothing written outside this test's tmpdir.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
OBS=""
STACK_RULES=""
SPARK_RULES=""
INFERENCE_RULES=""
ALERTMANAGER_YML=""
ENTRYPOINT=""
BLACKBOX_YML=""
COUNTERS=""
PROMETHEUS_YML=""
SCRATCH=""
STUB_LOG=""

# The job names prometheus.yml must carry, exactly. The gap alerts in
# rules/stack.rules.yml select on node_exporter and cadvisor by these strings, so
# the set is a contract and not a preference.
PINNED_JOBS=(
  prometheus mimir loki tempo grafana alloy coder litellm
  node_exporter cadvisor spark-node blackbox-spark blackbox-spark-models
  blackbox alertmanager
)

# The spark label every Spark alert has to carry, kept out of the awk programs so
# no shell layer has to agree on how it escapes a dollar sign.
# shellcheck disable=SC2016  # the dollar sign is Prometheus template syntax
SPARK_TEMPLATE='{{ $labels.hostname }}'

# setup - resolve the checkout and the payload, clear the one environment variable
# the entrypoint reads, and lay down the fake alertmanager binary. Nothing from this
# process's environment may decide what a test sees.
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"

  OBS="${REPO_ROOT}/observability"
  STACK_RULES="${OBS}/prometheus/rules/stack.rules.yml"
  SPARK_RULES="${OBS}/prometheus/rules/spark.rules.yml"
  INFERENCE_RULES="${OBS}/prometheus/rules/inference.rules.yml"
  ALERTMANAGER_YML="${OBS}/alertmanager/alertmanager.yml"
  ENTRYPOINT="${OBS}/alertmanager/boot-webhook-url.sh"
  BLACKBOX_YML="${OBS}/blackbox/blackbox.yml"
  COUNTERS="${OBS}/dcgm/custom-counters.csv"
  PROMETHEUS_YML="${OBS}/prometheus/prometheus.yml"
  COMPOSE="${REPO_ROOT}/docker-compose.yml"

  local artefact
  for artefact in "${STACK_RULES}" "${SPARK_RULES}" "${INFERENCE_RULES}" \
    "${ALERTMANAGER_YML}" "${ENTRYPOINT}" "${BLACKBOX_YML}" "${COUNTERS}" \
    "${PROMETHEUS_YML}" "${COMPOSE}"; do
    [[ -f ${artefact} ]] || skip "${artefact} is not in the tree"
  done

  SCRATCH="$(make_scratch)"
  mkdir -p "${SCRATCH}/bin"
  STUB_LOG="${SCRATCH}/alertmanager.argv"
  export STUB_LOG
  write_alertmanager_stub "${SCRATCH}/bin"
  PATH="$(with_path "${SCRATCH}/bin")"
  export PATH
  unset ALERTMANAGER_WEBHOOK_URL
}

# write_alertmanager_stub <dir> - the binary stand-in. The entrypoint asks PATH first
# and only then falls back to the documented /bin/alertmanager, so putting this stub on
# PATH catches the primary resolution; entrypoint_copy relocates the fallback literal
# into the same directory so the second branch is proven by the same run. The stub
# records the argv it was exec'd with and exits 0.
write_alertmanager_stub() {
  cat >"${1}/alertmanager" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_LOG:?}"
STUB
  chmod 755 "${1}/alertmanager"
}

# entrypoint_copy - print the path of a sandboxed copy of the entrypoint: the two
# absolute paths it hardcodes are relocated into this test's scratch, and nothing
# else is touched, so the guard, the write, and the exec all run verbatim.
entrypoint_copy() {
  local copy="${SCRATCH}/boot-webhook-url.sh"
  sed -e "s|/alertmanager/webhook_url|${SCRATCH}/webhook_url|g" \
    -e "s|/bin/alertmanager|${SCRATCH}/bin/alertmanager|g" \
    "${ENTRYPOINT}" >"${copy}"
  printf '%s\n' "${copy}"
}

# group_names <rules-file> - one group name per line, in file order.
group_names() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}
for group in doc.get("groups") or []:
    print(group.get("name") or "")
PY
}

# rules_facts <rules-file> - one line per rule: kind|name|tier|spark|has_expr.
# has_expr is 1 or 0; Prometheus rejects a rule with no expr and a YAML parse does
# not, so the suite has to look.
rules_facts() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}
for group in doc.get("groups") or []:
    for rule in group.get("rules") or []:
        labels = rule.get("labels") or {}
        kind = "alert" if "alert" in rule else "record"
        name = rule.get("alert") or rule.get("record") or ""
        print("%s|%s|%s|%s|%s" % (
            kind, name, labels.get("tier") or "", labels.get("spark") or "",
            "1" if str(rule.get("expr") or "").strip() else "0",
        ))
PY
}

# alertmanager_facts <file> - the routing shape as lines: receiver|<name>,
# route|<receiver> for the root and every descendant, inhibit|<n>|<equal>,
# key|<name> for every mapping key anywhere in the document, url_file|<value>.
alertmanager_facts() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}


def walk_keys(node):
    if isinstance(node, dict):
        for key, value in node.items():
            print("key|%s" % key)
            if key == "url_file":
                print("url_file|%s" % value)
            walk_keys(value)
    elif isinstance(node, list):
        for value in node:
            walk_keys(value)


def walk_routes(route):
    for sub in route.get("routes") or []:
        print("route|%s" % (sub.get("receiver") or ""))
        walk_routes(sub)


route = doc.get("route") or {}
print("route|%s" % (route.get("receiver") or ""))
walk_routes(route)

for receiver in doc.get("receivers") or []:
    print("receiver|%s" % (receiver.get("name") or ""))

for index, rule in enumerate(doc.get("inhibit_rules") or []):
    print("inhibit|%d|%s" % (index, ",".join(rule.get("equal") or [])))

walk_keys(doc)
PY
}

# blackbox_facts <file> - module|<name>, prober|<name>|<prober>, and one
# scan|<name>|<finding> line per host, port, or URL a module names.
blackbox_facts() {
  python3 - "${1}" <<'PY'
import json
import re
import sys

import yaml

FORBIDDEN_KEYS = {
    "target", "targets", "url", "urls", "host", "hostname", "port", "address",
}
IPV4 = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
HOST_PORT = re.compile(r"\b[A-Za-z][\w.-]{2,}:\d{2,5}\b")

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

for name, module in sorted((doc.get("modules") or {}).items()):
    print("module|%s" % name)
    print("prober|%s|%s" % (name, (module or {}).get("prober") or ""))
    keys = set()

    def collect(node):
        if isinstance(node, dict):
            for key, value in node.items():
                keys.add(key)
                collect(value)
        elif isinstance(node, list):
            for value in node:
                collect(value)

    collect(module or {})
    for key in sorted(keys & FORBIDDEN_KEYS):
        print("scan|%s|names the key %s" % (name, key))
    blob = json.dumps(module or {})
    for pattern, label in ((re.compile(re.escape("://")), "carries a URL"),
                           (IPV4, "names an IPv4 address"),
                           (HOST_PORT, "names a host:port")):
        if pattern.search(blob):
            print("scan|%s|%s" % (name, label))
PY
}

# prom_facts <file> - job|<job_name> per scrape config and module|<m> per module
# value the scrape params ask blackbox for.
prom_facts() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

for job in doc.get("scrape_configs") or []:
    print("job|%s" % (job.get("job_name") or ""))
    for value in (job.get("params") or {}).get("module") or []:
        print("module|%s" % value)
    for group in job.get("static_configs") or []:
        for target in group.get("targets") or []:
            print("target|%s|%s" % (job.get("job_name"), str(target).rsplit(":", 1)[-1]))
PY
}

# compose_facts <file> - published|<service>|<container port> per ports: entry and
# listen|<service>|<port> per bind-address flag in command:. Both the container side
# of the mapping and the flag decide whether a scrape can reach the container, and
# neither is visible from the other file, which is the gap that let node_exporter
# publish 9101 while the image bound its default 9100.
compose_facts() {
  python3 - "${1}" <<'PY'
import re
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

for name, service in sorted((doc.get("services") or {}).items()):
    if not isinstance(service, dict):
        continue
    for entry in service.get("ports") or []:
        # "127.0.0.1:9101:9101" and the short "9115" form both end in the
        # container side, which is the half Prometheus dials on the network.
        text = entry if isinstance(entry, str) else str(entry.get("target", ""))
        print("published|%s|%s" % (name, text.rsplit(":", 1)[-1]))
    for arg in service.get("command") or []:
        arg = str(arg)
        for pattern in (r"^--(?:web\.)?listen-address=(?:[^:]*:)?(\d+)$", r"^--port=(\d+)$"):
            match = re.match(pattern, arg)
            if match:
                print("listen|%s|%s" % (name, match.group(1)))
PY
}

# csv_facts <file> - one line per active (non-comment, non-blank) DCGM counter row:
# row|<line>|<columns>|<tabs>|<non_ascii>|<field>.
csv_facts() {
  python3 - "${1}" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    for number, line in enumerate(handle, start=1):
        text = line.rstrip("\n")
        if not text.strip() or text.lstrip().startswith("#"):
            continue
        print("row|%d|%d|%d|%d|%s" % (
            number, len(text.split(",")), text.count("\t"),
            sum(1 for char in text if ord(char) > 127),
            text.split(",")[0].strip(),
        ))
PY
}

# assert_file_namespace <rules-file> <tier> <prefix>... - every group name starts
# with the file's tier token and every recording rule starts with one of the given
# `<domain>:` prefixes, which is how a reader tells a host series from a Spark
# series from a router series without opening the file.
assert_file_namespace() {
  local file="$1" tier="$2"
  shift 2
  local -a prefixes=("$@")
  local facts kind name prefix matched findings=""
  facts="$(rules_facts "${file}")"
  while IFS='|' read -r kind name _; do
    [[ ${kind} == "record" ]] || continue
    matched=0
    for prefix in "${prefixes[@]}"; do
      [[ ${name} == "${prefix}:"* ]] && matched=1
    done
    [[ ${matched} -eq 1 ]] || findings+="record ${name}; "
  done <<<"${facts}"

  local group bad_groups=""
  while IFS= read -r group; do
    [[ ${group} == "${tier}"* ]] || bad_groups+="${group}; "
  done < <(group_names "${file}")

  assert_eq "$(basename "${file}"): every group is named for its tier" "" "${bad_groups}"
  assert_eq "$(basename "${file}"): every recording rule is namespaced" "" "${findings}"
}

@test "the payload files this suite reads all parse as YAML" {
  run python3 "${REPO_ROOT}/scripts/lib/parse_yaml.py" \
    "${STACK_RULES}" "${SPARK_RULES}" "${INFERENCE_RULES}" \
    "${ALERTMANAGER_YML}" "${BLACKBOX_YML}" "${PROMETHEUS_YML}"
  assert_eq "the repo's own parser accepts all six" 0 "${status}"
  assert_eq "and prints nothing on success" "" "${output}"
}

@test "every stack alert carries tier: host and an expr" {
  local facts alerts missing
  facts="$(rules_facts "${STACK_RULES}")"
  alerts="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="alert"')"
  # 11, not 9: the two single-exporter gap alerts are joined by HostExportersSilent
  # (both host exporters gone, which neither of them can see) and BlackboxProbeGap (a
  # dead prober produces no probe series at all, so nothing it probes can report it).
  assert_eq "stack.rules.yml ships 11 alerts" "11" "$(printf '%s\n' "${alerts}" | wc -l | tr -d ' ')"
  assert_eq "every one carries tier: host" "" \
    "$(printf '%s\n' "${alerts}" | awk -F'|' '$3!="host"{print $2}')"
  missing="$(printf '%s\n' "${facts}" | awk -F'|' '$5!="1"{print $1" "$2}')"
  assert_eq "every rule carries a non-empty expr" "" "${missing}"
}

@test "every spark alert carries tier: spark and a hostname-templated spark label" {
  local facts alerts
  facts="$(rules_facts "${SPARK_RULES}")"
  alerts="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="alert"')"
  assert_eq "spark.rules.yml ships 7 alerts" "7" "$(printf '%s\n' "${alerts}" | wc -l | tr -d ' ')"
  # Both labels are what the tree and the inhibit rules match on; the Alertmanager
  # comment says it plainly - two alerts that both lack `spark` compare equal, so a
  # dropped spark label lets one box silence another.
  assert_eq "every one carries tier: spark" "" \
    "$(printf '%s\n' "${alerts}" | awk -F'|' '$3!="spark"{print $2}')"
  assert_eq "every one carries the templated spark label" "" \
    "$(printf '%s\n' "${alerts}" | awk -F'|' -v want="${SPARK_TEMPLATE}" '$4!=want{print $2}')"
  local missing_expr
  missing_expr="$(printf '%s\n' "${facts}" | awk -F'|' '$5!="1"{print $1" "$2}')"
  assert_eq "every rule carries a non-empty expr" "" "${missing_expr}"
}

@test "every inference alert carries tier: inference and an expr" {
  local facts alerts missing
  facts="$(rules_facts "${INFERENCE_RULES}")"
  alerts="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="alert"')"
  assert_eq "inference.rules.yml ships 10 alerts" "10" "$(printf '%s\n' "${alerts}" | wc -l | tr -d ' ')"
  assert_eq "every one carries tier: inference" "" \
    "$(printf '%s\n' "${alerts}" | awk -F'|' '$3!="inference"{print $2}')"
  missing="$(printf '%s\n' "${facts}" | awk -F'|' '$5!="1"{print $1" "$2}')"
  assert_eq "every rule carries a non-empty expr" "" "${missing}"
}

@test "every group and recording rule is prefixed for its file" {
  # stack.rules.yml records cAdvisor's container: series beside the host: ones, so
  # the host file owns two namespaces; the other two files own one each.
  assert_file_namespace "${STACK_RULES}" stack host container
  assert_file_namespace "${SPARK_RULES}" spark spark
  assert_file_namespace "${INFERENCE_RULES}" inference litellm
}

@test "every route names a defined receiver and no receiver is dead weight" {
  local facts used defined
  facts="$(alertmanager_facts "${ALERTMANAGER_YML}")"
  used="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="route" && $2!=""{print $2}' | sort -u)"
  defined="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="receiver" && $2!=""{print $2}' | sort -u)"
  [[ -n ${used} && -n ${defined} ]] || fail "no routes or no receivers parsed"
  assert_eq "every route receiver is defined in receivers:" "" \
    "$(comm -23 <(printf '%s\n' "${used}") <(printf '%s\n' "${defined}"))"
  assert_eq "every defined receiver is referenced by a route" "" \
    "$(comm -13 <(printf '%s\n' "${used}") <(printf '%s\n' "${defined}"))"
}

@test "each of the three inhibit rules carries an equal list" {
  local facts rules blank
  facts="$(alertmanager_facts "${ALERTMANAGER_YML}")"
  rules="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="inhibit"')"
  assert_eq "the file ships three inhibit rules" "3" "$(printf '%s\n' "${rules}" | wc -l | tr -d ' ')"
  # An inhibit with no equal lets one box silence another: equal compares label
  # values, and two alerts that both lack the label compare equal.
  blank="$(printf '%s\n' "${rules}" | awk -F'|' '$3==""{print $2}')"
  assert_eq "none of them has an empty equal list" "" "${blank}"
}

@test "alertmanager.yml carries no url: key and reads the webhook from the pinned file" {
  local facts keys url_files
  facts="$(alertmanager_facts "${ALERTMANAGER_YML}")"
  keys="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="key"{print $2}' | sort -u)"
  assert_not_match "no mapping anywhere carries a url: key" '^url$' "${keys}"
  url_files="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="url_file"{print $2}' | sort -u)"
  assert_eq "every webhook reads the one pinned url_file" \
    "/alertmanager/webhook_url" "${url_files}"
  # /etc/alertmanager is mounted read-only; only --storage.path is writable.
  assert_not_match "the webhook file is not under the read-only config mount" \
    '^/etc/' "${url_files}"
  assert_contains_file "and the entrypoint writes that same path" "${ENTRYPOINT}" \
    '^webhook_file="/alertmanager/webhook_url"$'
}

@test "ALERTMANAGER_WEBHOOK_URL set writes exactly that value and still execs" {
  local copy webhook="${SCRATCH}/webhook_url"
  copy="$(entrypoint_copy)"
  assert_eq "the entrypoint names the webhook path once" "1" \
    "$(grep -c '/alertmanager/webhook_url' "${ENTRYPOINT}")"
  assert_eq "and execs the binary by absolute path once" "1" \
    "$(grep -c '^exec /bin/alertmanager ' "${ENTRYPOINT}")"
  assert_eq "only those two lines are relocated" "2" \
    "$(diff "${ENTRYPOINT}" "${copy}" | grep -c '^<')"

  run env ALERTMANAGER_WEBHOOK_URL="http://sink.example.invalid:9095/alert" \
    sh "${copy}" --config.file=/etc/alertmanager/alertmanager.yml
  assert_eq "the entrypoint exits 0" 0 "${status}"
  assert_file_exists "the webhook file is written" "${webhook}"
  assert_eq "and holds exactly the configured URL" \
    "http://sink.example.invalid:9095/alert" "$(cat "${webhook}")"
  assert_match "alertmanager was exec'd with the forwarded flags" \
    '--config.file=/etc/alertmanager/alertmanager.yml' "$(cat "${STUB_LOG}")"
}

@test "an empty ALERTMANAGER_WEBHOOK_URL writes nothing and still execs" {
  # The shipped default: an empty key must leave a config that loads and a container
  # that starts, with every webhook receiver a no-op.
  local copy webhook="${SCRATCH}/webhook_url"
  copy="$(entrypoint_copy)"
  run env ALERTMANAGER_WEBHOOK_URL= sh "${copy}" --web.listen-address=:9093
  assert_eq "the empty-key path exits 0" 0 "${status}"
  assert_file_not_exists "no webhook file is created" "${webhook}"
  assert_eq "alertmanager was exec'd exactly once" "1" "$(wc -l <"${STUB_LOG}" | tr -d ' ')"
  assert_match "with its flags forwarded verbatim" \
    '--web.listen-address=:9093' "$(cat "${STUB_LOG}")"
}

@test "an emptied key removes the webhook file a previous boot left behind" {
  # The file lives under --storage.path, which is a named volume that outlives the
  # container. Without the removal, a URL the operator deleted keeps receiving alerts
  # and nothing in the compose file or the config shows why.
  local copy webhook="${SCRATCH}/webhook_url"
  copy="$(entrypoint_copy)"
  printf '%s' "http://old.example.invalid:9095/alert" >"${webhook}"

  run env ALERTMANAGER_WEBHOOK_URL= sh "${copy}" --web.listen-address=:9093
  assert_eq "the emptied-key path still exits 0" 0 "${status}"
  assert_file_not_exists "and the stale URL is gone" "${webhook}"
  assert_match "with alertmanager still exec'd" \
    '--web.listen-address=:9093' "$(cat "${STUB_LOG}")"
}


@test "the blackbox modules the scrape params ask for exist" {
  local -a asked=()
  local missing=""
  mapfile -t asked < <(prom_facts "${PROMETHEUS_YML}" | awk -F'|' '$1=="module"{print $2}')
  assert_eq "the scrape configs ask for two modules" "2" "${#asked[@]}"
  local modules module
  modules="$(blackbox_facts "${BLACKBOX_YML}" | awk -F'|' '$1=="module"{print $2}')"
  for module in "${asked[@]}"; do
    printf '%s\n' "${modules}" | grep -qx "${module}" || missing+="${module}; "
  done
  assert_eq "blackbox.yml defines spark_health and spark_models" "" "${missing}"
}

@test "every blackbox module has a prober and names no host or port" {
  local facts count missing findings
  facts="$(blackbox_facts "${BLACKBOX_YML}")"
  count="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="module"' | wc -l | tr -d ' ')"
  assert_eq "the file defines three modules" "3" "${count}"
  missing="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="prober" && $3==""{print $2}')"
  assert_eq "every module names a prober" "" "${missing}"
  # Targets arrive per scrape as __param_target, composed from SPARK_HTTP_PORT by
  # whoever owns the scrape configs, so nothing committed here may name one.
  findings="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="scan"{print $2": "$3}')"
  assert_eq "no module names a host, a port, or a URL" "" "${findings}"
}

@test "every active DCGM counter row keeps the exporter's three-column shape" {
  local facts rows bad_cols bad_tabs bad_ascii
  facts="$(csv_facts "${COUNTERS}")"
  rows="$(printf '%s\n' "${facts}" | grep -c '^row|')"
  [[ ${rows} -gt 0 ]] || fail "the counter file has no active rows"
  bad_cols="$(printf '%s\n' "${facts}" | awk -F'|' '$3!=3{print $2}')"
  assert_eq "each of the ${rows} rows splits into exactly 3 comma-separated columns" \
    "" "${bad_cols}"
  bad_tabs="$(printf '%s\n' "${facts}" | awk -F'|' '$4!="0"{print $2}')"
  assert_eq "no active row carries a tab" "" "${bad_tabs}"
  bad_ascii="$(printf '%s\n' "${facts}" | awk -F'|' '$5!="0"{print $2}')"
  assert_eq "no active row carries a non-ASCII byte" "" "${bad_ascii}"
}

@test "every active DCGM counter row names a DCGM_FI_* field" {
  # A field name DCGM does not know is one exporter log error per scrape per field,
  # so the prefix is the cheapest thing to pin.
  local bad
  bad="$(csv_facts "${COUNTERS}" | awk -F'|' '$6 !~ /^DCGM_FI_/{print $6}')"
  assert_eq "every row opens with a DCGM_FI_* field" "" "${bad}"
}

@test "the four jobs that read sparks.json each keep only their own groups" {
  # One generated file feeds four jobs, so every one of them has to filter on the
  # exporter label the generator stamps. A job with no keep scrapes all four groups
  # per box, and the two probe URLs then read as permanently failing metric endpoints.
  local facts missing
  facts="${BATS_TEST_TMPDIR}/keeps.txt"
  python3 - "${PROMETHEUS_YML}" >"${facts}" <<'PY'
import sys

import yaml

wanted = {"spark-node", "blackbox-spark", "blackbox-spark-models"}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

for job in doc.get("scrape_configs") or []:
    name = job.get("job_name") or ""
    if name not in wanted:
        continue
    wanted.discard(name)
    keeps = [r for r in job.get("relabel_configs") or [] if (r or {}).get("action") == "keep"]
    if not keeps:
        print("no-keep|%s" % name)
    elif not any("exporter" in (r.get("source_labels") or []) for r in keeps):
        print("no-exporter-keep|%s" % name)

for name in sorted(wanted):
    print("absent|%s" % name)
PY
  missing="$(tr -d ' \t' <"${facts}")"
  assert_eq "every Spark job filters the shared file on its own exporter label" "" "${missing}"
}

@test "spark:box_up asks only the node_exporter whether a box is up" {
  # A box whose DCGM container died is still a running box, and a box serving no
  # weights is still a serving box. If either answer reaches this rule the fleet pages
  # critical for an optional exporter that simply is not running.
  local body
  body="$(awk '/record: spark:box_up/{f=1} f{print} f&&/^$/{exit}' "${SPARK_RULES}")"
  assert_match "the rule names the stamped exporter label" 'exporter="node_exporter"' "${body}"
  assert_not_match "the rule does not take every spark job's up" 'job=~"\.\*spark\.\*"' "${body}"
  assert_match "a hand-written file still resolves by the exporter port" 'instance=~"\.\*:9100"' "${body}"
}

@test "spark:probe_up counts only the health probe" {
  # The model-list probe goes red on a healthy box with no weights loaded. Folding it
  # in would make SparkDown depend on whether someone loaded a model.
  local body
  body="$(awk '/record: spark:probe_up/{f=1} f{print} f&&/^$/{exit}' "${SPARK_RULES}")"
  assert_match "the model-list probe stays out of the down verdict" \
    'probe_success\{job="blackbox-spark"\}' "${body}"
}

@test "prometheus.yml's job names are exactly the pinned set" {
  local -a actual=()
  mapfile -t actual < <(prom_facts "${PROMETHEUS_YML}" | awk -F'|' '$1=="job"{print $2}')
  assert_eq "no job is defined twice" "${#PINNED_JOBS[@]}" "${#actual[@]}"
  assert_eq "the job set matches the contract the gap alerts select on" \
    "$(printf '%s\n' "${PINNED_JOBS[@]}" | sort)" \
    "$(printf '%s\n' "${actual[@]}" | sort)"
}

# The four host exporters as service|scrape job|the one port that has to be
# published and dialed|the port the image binds when command: names none. The
# last column is the upstream default and is written down for one reason: a
# service may leave its bind to that default only while the default already is
# the port Prometheus dials. node_exporter is exactly the case where it is not -
# it published 9101 while binding 9100, so every host series was missing,
# HostNodeExporterGap paged 10 minutes after each boot, and BlackboxProbeGap's
# gate on the same job could never be satisfied. The suites that stub curl
# cannot see that, because nothing in them addresses the container.
LISTEN_CONTRACT=(
  "node_exporter|node_exporter|9101|9100"
  "cadvisor|cadvisor|8080|8080"
  "blackbox_exporter|blackbox|9115|9115"
  "alertmanager|alertmanager|9093|9093"
)

@test "every host exporter binds, publishes and is scraped on one port" {
  local row service job want default facts listen finding="" port
  local -a ports=()
  facts="$(compose_facts "${COMPOSE}")"
  for row in "${LISTEN_CONTRACT[@]}"; do
    IFS='|' read -r service job want default <<<"${row}"
    mapfile -t ports < <(printf '%s\n' "${facts}" |
      awk -F'|' -v s="${service}" '$1=="published" && $2==s {print $3}')
    [[ "${ports[*]-}" == "${want}" ]] ||
      finding+="${service} publishes ${ports[*]-nothing}, Prometheus dials ${want}; "
    mapfile -t ports < <(prom_facts "${PROMETHEUS_YML}" |
      awk -F'|' -v j="${job}" '$1=="target" && $2==j {print $3}')
    [[ ${#ports[@]} -gt 0 ]] || finding+="${job} names no static target at all; "
    for port in "${ports[@]-}"; do
      [[ ${port} == "${want}" ]] ||
        finding+="${job} scrapes ${port}, the service publishes ${want}; "
    done
    listen="$(printf '%s\n' "${facts}" |
      awk -F'|' -v s="${service}" '$1=="listen" && $2==s {print $3}')"
    if [[ -n ${listen} ]]; then
      [[ ${listen} == "${want}" ]] ||
        finding+="${service} binds ${listen}, Prometheus dials ${want}; "
    elif [[ ${default} != "${want}" ]]; then
      finding+="${service} names no listen flag, so it binds its default ${default} while Prometheus dials ${want}; "
    fi
  done
  assert_eq "each exporter's bind, published port and scrape target are one port" \
    "" "${finding}"
}
