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
#     prometheus.yml alone mutes those alerts;
#   - the LiteLLM token seam: prometheus.yml opens its bearer token from a file,
#     compose writes that file from the proxy's own master key, and the path each
#     side names is the whole contract - they sit hundreds of lines apart in two
#     files, and a mismatch is one red target and an empty dashboard, not an error;
#   - the two Grafana knobs that silence the search-manifest-watcher pair and the
#     dashboard quota 501, which only do anything if the overrides file the knob
#     names is a file this tree actually ships, bound at exactly that path;
#   - that litellm/config.yaml leaves /metrics behind the master key: the switch that
#     would take that auth off is absent from the file, and the block it would sit in
#     is still there, so the absence reads as a decision and not as a file that lost
#     its shape.
#
#   - that the monitoring containers can boot at all: no Prometheus bind nests
#     inside another (runc mkdirs a mountpoint, which the read-only parent
#     refuses unless its own source already carries that directory), every
#     file_sd path lands in a bind compose declares, every alertmanagers and
#     blackbox http key is one the pinned image decodes, and no rule template
#     uses an infix operator: each is fatal at boot, not a log line.
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
OVERRIDES_YML=""
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

# The token seam and the two Grafana knobs, as pinned strings rather than as values
# read back out of the payload: prometheus.yml's credentials_file, compose's configs
# target, and the GF_UNIFIED_STORAGE_OVERRIDES_PATH / its bind destination are one
# contract stated in two files, so the tests below compare the files against each other
# and against these four strings.
LITELLM_TOKEN_FILE="/etc/prometheus-secrets/litellm_token"
LITELLM_TOKEN_CONTENT='${LITELLM_MASTER_KEY:-change-me-litellm}'
GRAFANA_OVERRIDES_CONTAINER_PATH="/etc/grafana/stack-overrides.yml"
GRAFANA_OVERRIDES_SOURCE="observability/grafana/unified-storage/overrides.yml"

# Keys Prometheus v3.16.0 decodes in an alerting.alertmanagers[] entry. Derived by
# planting each candidate at that level and asking promtool on the pinned image, so it
# is the decoder's own answer rather than a reading of config/config.go: accepted are
# these, and max_alerts, username, password, password_file, max_idle_conns,
# max_idle_conns_per_host, queue_capacity, min_backoff, max_backoff, max_retries,
# max_items and enable_http3 each came back "field <k> not found in type
# config.AlertmanagerConfig". The block is decoded strictly, so a key outside this set
# stops the container at boot. max_alerts is the trap this pins: it is a real key in
# alertmanager.yml's own webhook_configs, and no key at all on the Prometheus side.
PINNED_ALERTMANAGER_KEYS=(
  alert_relabel_configs api_version authorization basic_auth bearer_token
  bearer_token_file enable_http2 follow_redirects http_headers no_proxy oauth2
  path_prefix proxy_connect_header proxy_from_environment proxy_url
  relabel_configs scheme sigv4 static_configs timeout tls_config
)

# Keys blackbox_exporter v0.29.1 decodes in a module's http block, from the same
# plant-and-ask against --config.check on the pinned image. The loader runs with
# KnownFields(true), so an unknown key there rejects the whole file and the container
# restart-loops. keep_alive is the reason this list exists: it was set in all three
# modules, and the prober already builds its client with keep-alives disabled
# (prober/http.go:457), so the field bought nothing and cost the boot. username,
# password, keepalive, max_idle_conns and max_idle_conns_per_host are all refused.
PINNED_BLACKBOX_HTTP_KEYS=(
  authorization basic_auth bearer_token bearer_token_file body body_file
  body_size_limit check_revoked compression enable_http2 enable_http3
  fail_if_body_json_matches_cel fail_if_body_json_not_matches_cel
  fail_if_body_matches_regexp fail_if_body_not_matches_regexp
  fail_if_header_matches fail_if_header_not_matches fail_if_not_ssl fail_if_ssl
  follow_redirects headers http_headers ip_protocol_fallback method no_follow_redirects
  no_proxy oauth2 path_prefix preferred_ip_protocol proxy_connect_header
  proxy_from_environment proxy_url skip_resolve_phase_with_proxy
  tls_config valid_http_versions valid_status_codes
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
  # Deliberately not in the artefact loop below: one test's job is that this file is
  # in the tree at all, and skipping would let its absence pass as a green suite.
  OVERRIDES_YML="${OBS}/grafana/unified-storage/overrides.yml"
  COMPOSE="${REPO_ROOT}/docker-compose.yml"
  # The proxy's own config, and the one file here outside the observability bundle.
  # Out of the artefact loop below for the same reason as the overrides file: it feeds
  # a single case, and its absence is that case's finding rather than everyone's skip.
  LITELLM_CONFIG="${REPO_ROOT}/litellm/config.yaml"

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

# blackbox_facts <file> - module|<name>, prober|<name>|<prober>, httpkey|<name>|<key>
# per key of a module's http block, and one scan|<name>|<finding> line per host, port,
# or URL a module names.
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
    for key in sorted((module or {}).get("http") or {}):
        print("httpkey|%s|%s" % (name, key))
    blob = json.dumps(module or {})
    for pattern, label in ((re.compile(re.escape("://")), "carries a URL"),
                           (IPV4, "names an IPv4 address"),
                           (HOST_PORT, "names a host:port")):
        if pattern.search(blob):
            print("scan|%s|%s" % (name, label))
PY
}

# prom_facts <file> - job|<job_name> per scrape config, module|<m> per module value
# the scrape params ask blackbox for, target|<job>|<port> per static target, and
# file_sd|<job>|<path> per file-SD document. The file_sd path is emitted because it
# is read relative to the config file unless it is absolute, so the compose bind is
# the only other place that can say whether the file is reachable at all.
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
    for group in job.get("file_sd_configs") or []:
        for path in group.get("files") or []:
            print("file_sd|%s|%s" % (job.get("job_name"), str(path)))
PY
}

# prom_authorization_facts <file> <job_name> - job|1 when that scrape config exists,
# authkey|<k> per key of its authorization block, and authval|<k>|<value> per scalar key.
# Prometheus expands $VAR and ${VAR} in global.external_labels values and in nothing
# else in the file, so the only authorization value that can ever carry a working token
# is one naming a file.
prom_authorization_facts() {
  python3 - "${1}" "${2}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

job = next((entry for entry in doc.get("scrape_configs") or []
            if (entry or {}).get("job_name") == sys.argv[2]), None)
if job is None:
    sys.exit(0)
print("job|1")
for key, value in sorted((job.get("authorization") or {}).items()):
    print("authkey|%s" % key)
    if not isinstance(value, (dict, list)):
        print("authval|%s|%s" % (key, value))
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

# compose_mount_facts <file> <service> - mount|<source>|<dest>|<mode> per host-path
# bind of one service, plus confdir|<dir> for the directory --config.file= sits in.
# Only a source with no slash at all is a named volume (prometheus-data) and skipped;
# relative, absolute and variable-rooted host paths all stay in, so an absolute source
# cannot slip out of the nesting check. The nesting question is the load-bearing one:
# runc creates a bind's mountpoint with mkdirat, and inside an already-mounted
# read-only parent that call is EROFS unless the parent's own source directory already
# carries the mountpoint - which a generated, gitignored document never does, and git
# cannot carry an empty directory for. That is how one bind under /etc/prometheus kept
# Prometheus from ever starting.
compose_mount_facts() {
  python3 - "${1}" "${2}" <<'PY'
import os
import re
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

service = (doc.get("services") or {}).get(sys.argv[2]) or {}
for entry in service.get("volumes") or []:
    if isinstance(entry, dict):
        source = str(entry.get("source") or "")
        dest = str(entry.get("target") or "")
        mode = str(entry.get("mode") or "")
    else:
        parts = str(entry).split(":")
        source = parts[0] if parts else ""
        dest = parts[1] if len(parts) > 1 else ""
        mode = parts[2] if len(parts) > 2 else ""
    if "/" not in source:
        continue
    print("mount|%s|%s|%s" % (source, dest, mode or "rw"))

for arg in service.get("command") or []:
    match = re.match(r"^--config\.file=(.+)$", str(arg))
    if match:
        print("confdir|%s" % os.path.dirname(match.group(1)))
PY
}

# compose_config_facts <file> - top|<name>|<content> per top-level configs entry, and
# attach|<service>|<source>|<target>|<mode> per configs[] entry of one service. The two
# halves of the token seam are ~600 lines apart in this one file and joined by nothing a
# reader can see but the source name, so neither half alone can say whether the file
# Prometheus opens is the file compose writes. `mode` is rendered back as octal because
# YAML 1.1 reads an unquoted 0444 as the integer 292.
compose_config_facts() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

for name, definition in sorted((doc.get("configs") or {}).items()):
    content = (definition or {}).get("content") if isinstance(definition, dict) else None
    print("top|%s|%s" % (name, "" if content is None else content))

for service, spec in sorted((doc.get("services") or {}).items()):
    if not isinstance(spec, dict):
        continue
    for entry in spec.get("configs") or []:
        if isinstance(entry, dict):
            source = str(entry.get("source") or "")
            target = str(entry.get("target") or "")
            mode = entry.get("mode")
            mode = "" if mode is None or isinstance(mode, str) else "%04o" % int(mode)
        else:
            parts = str(entry).split(":")
            source = parts[0] if parts else ""
            target = parts[1] if len(parts) > 1 else ""
            mode = parts[2] if len(parts) > 2 else ""
        print("attach|%s|%s|%s|%s" % (service, source, target, mode or "rw"))
PY
}

# compose_env_facts <file> <service> - env|<KEY>|<value> for one service's environment,
# in either the mapping or the list form. A `${VAR:-default}` is reported as the literal
# compose text: what the gate pins is the string the operator's .env interpolates into,
# and this suite must not read this machine's environment to answer.
compose_env_facts() {
  python3 - "${1}" "${2}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

spec = (doc.get("services") or {}).get(sys.argv[2]) or {}
environment = spec.get("environment") or {}
if isinstance(environment, dict):
    items = sorted(environment.items())
else:
    items = [str(entry).split("=", 1) if "=" in str(entry) else (str(entry), "")
             for entry in environment]
for key, value in items:
    print("env|%s|%s" % (key, value))
PY
}

# overrides_facts <file> - key|<k> per top-level key of the Grafana quota overrides
# file, plus map|<k> when that value is a mapping. Grafana takes the file's presence as
# "quotas are configured" and then decodes overrides as a map, so a comment-only file or
# a top key holding a string leaves the dashboard's quota call answering 501 exactly as
# before, with no error anywhere to say so.
overrides_facts() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

if not isinstance(doc, dict):
    sys.exit(0)
for key, value in sorted(doc.items()):
    print("key|%s" % key)
    if isinstance(value, dict):
        print("map|%s" % key)
PY
}

# prom_alertmanager_keys <file> - key|<k> for each key of each alerting.alertmanagers[]
# entry. Prometheus decodes that block strictly, so an unknown key is a fatal
# "field <k> not found in type config.AlertmanagerConfig" rather than a warning.
prom_alertmanager_keys() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

for entry in (doc.get("alerting") or {}).get("alertmanagers") or []:
    for key in sorted(entry or {}):
        print("key|%s" % key)
PY
}

# rule_template_facts <file> - rule|<name> per rule, and infix|<name>|<field>|<key>|
# <template> for every annotation or label whose Go template does infix arithmetic.
# text/template has no infix operators and Prometheus registers no mul or div either
# (promtool on the pinned image: 'function "mul" not defined'), so such a template
# fails the rule file at boot - and Prometheus exits rather than skipping the group.
rule_template_facts() {
  python3 - "${1}" <<'PY'
import re
import sys

import yaml

TEMPLATE = re.compile(r"\{\{(.*?)\}\}", re.S)
QUOTED = re.compile(r'"[^"]*"|\'[^\']*\'')
# An operator between two operands, with or without the spaces: text/template needs
# spaces to read it, and a rule author who omits them still writes a fatal file. The
# right operand is required to open a term ($, (, or a digit) so a hyphenated label
# name like $labels.app-version is not mistaken for subtraction. A pipeline's pipe and
# a function's own argument list are not operators, and quoted prose inside the
# template is stripped first so it cannot match on its own punctuation.
INFIX = re.compile(r"[\w)\]]\s*[-+*/]\s*[$(\d]")

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}

for group in doc.get("groups") or []:
    for rule in group.get("rules") or []:
        name = rule.get("alert") or rule.get("record") or "?"
        print("rule|%s" % name)
        for field in ("annotations", "labels"):
            for key, value in sorted((rule.get(field) or {}).items()):
                for expr in TEMPLATE.findall(str(value)):
                    if INFIX.search(QUOTED.sub(" ", expr)):
                        print("infix|%s|%s|%s|%s" % (name, field, key, expr.strip()))
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

# litellm_config_facts <file> - setting|<k> for every mapping key at any depth, and
# map|<top key> for each top-level key whose value is a mapping. The key this feeds is
# read out of litellm_settings, so the scan cannot stop at the top level, and the map
# line is what tells a key nobody set apart from a block nobody has.
litellm_config_facts() {
  python3 - "${1}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}


def walk_keys(node):
    if isinstance(node, dict):
        for key, value in node.items():
            print("setting|%s" % key)
            walk_keys(value)
    elif isinstance(node, list):
        for value in node:
            walk_keys(value)


for key, value in sorted(doc.items()):
    if isinstance(value, dict):
        print("map|%s" % key)

walk_keys(doc)
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
  # 12, not 9: the two single-exporter gap alerts are joined by HostExportersSilent
  # (both host exporters gone, which neither of them can see), BlackboxProbeGap (a
  # dead prober produces no probe series at all, so nothing it probes can report it),
  # and AlertmanagerGap (the one component whose death no other rule reads).
  assert_eq "stack.rules.yml ships 12 alerts" "12" "$(printf '%s\n' "${alerts}" | wc -l | tr -d ' ')"
  assert_eq "every one carries tier: host" "" \
    "$(printf '%s\n' "${alerts}" | awk -F'|' '$3!="host"{print $2}')"
  missing="$(printf '%s\n' "${facts}" | awk -F'|' '$5!="1"{print $1" "$2}')"
  assert_eq "every rule carries a non-empty expr" "" "${missing}"
}

@test "every spark alert carries tier: spark and a hostname-templated spark label" {
  local facts alerts
  facts="$(rules_facts "${SPARK_RULES}")"
  alerts="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="alert"')"
  # 8: the seven GPU and box alerts, plus SparkHostMetricsSilent for the box that
  # answers its probe and reports no host metrics at all.
  assert_eq "spark.rules.yml ships 8 alerts" "8" "$(printf '%s\n' "${alerts}" | wc -l | tr -d ' ')"
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

@test "a webhook file that cannot be written is removed rather than left stale" {
  # The other road to the same stale URL. printf's redirection truncates only once
  # the open succeeds, so a read-only or full /alertmanager leaves the previous
  # boot's URL on disk and Alertmanager keeps posting to the webhook the operator
  # rotated away from. Root ignores the mode below, so that arm is skipped rather
  # than passing for the wrong reason.
  [[ ${EUID} -eq 0 ]] && skip "running as root: a 0444 file is still writable"
  local copy webhook="${SCRATCH}/webhook_url"
  copy="$(entrypoint_copy)"
  printf '%s' "http://old.example.invalid:9095/alert" >"${webhook}"
  chmod 0444 "${webhook}"

  run env ALERTMANAGER_WEBHOOK_URL="http://new.example.invalid:9095/alert" \
    sh "${copy}" --web.listen-address=:9093
  assert_eq "the container still starts" 0 "${status}"
  assert_file_not_exists "the stale URL did not survive the failed write" "${webhook}"
  assert_match "the message names alertmanager" 'alertmanager: cannot write' "${output}"
  assert_not_match "and no line blames another CLI" 'spark-monitor' "${output}"
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

@test "every blackbox http key is one the pinned image decodes" {
  local facts unknown="" seen=0 lines module key
  facts="$(blackbox_facts "${BLACKBOX_YML}")"
  lines="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="httpkey"')"
  [[ -n ${lines} ]] || fail "no module carries an http block, so this proved nothing"
  # Two modules with two keys each is the floor: one key would let a file whose whole
  # http block is a single invented key pass as a real config.
  seen="$(printf '%s\n' "${lines}" | wc -l | tr -d ' ')"
  [[ ${seen} -ge 4 ]] || fail "only ${seen} http keys are declared, too few to prove the set"
  if [[ $(printf '%s\n' "${lines}" | awk -F'|' '{print $2}' | sort -u | wc -l) -lt 2 ]]; then
    fail "only one module carries an http block, so the per-module scan proved nothing"
  fi
  while IFS='|' read -r _ module key; do
    [[ ${key} ]] || continue
    [[ " ${PINNED_BLACKBOX_HTTP_KEYS[*]} " == *" ${key} "* ]] ||
      unknown+="${module}.${key}; "
  done <<<"${lines}"
  assert_eq "blackbox.yml asks for no http field v0.29.1 does not know" "" "${unknown}"
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

@test "AlertmanagerGap asks both shapes of an unreachable notifier" {
  # up == 0 alone goes quiet when the service is deleted, because the up series
  # disappears with it; absent() alone goes quiet when the container runs and does
  # not answer. Neither half is enough, and the host gate keeps a bundle that is
  # deliberately down from paging.
  local body
  body="$(awk '/alert: AlertmanagerGap/{f=1} f{print} f&&/^$/{exit}' "${STACK_RULES}")"
  assert_match "it asks for the series to exist at all" \
    'absent\(up\{job="alertmanager"\}\)' "${body}"
  assert_match "and for the scrape to be failing" 'up\{job="alertmanager"\} == 0' "${body}"
  assert_match "and stays quiet while the host itself is down" \
    'max by \(\) \(up\{job="node_exporter"\} == 1\)' "${body}"
}

@test "SparkHostMetricsSilent pages a probed box with no host metrics" {
  # The orphan case no other Spark rule reaches: the probe says the box is up, so
  # SparkDown cannot fire, and the GPU family has its own rule. The right side has
  # to be `== 1` - a box whose scrape is failing carries box_up == 0, which is the
  # same finding rather than an exemption from it.
  local body
  body="$(awk '/alert: SparkHostMetricsSilent/{f=1} f{print} f&&/^$/{exit}' "${SPARK_RULES}")"
  assert_match "it starts from a box whose health probe succeeds" \
    'spark:probe_up == 1' "${body}"
  assert_match "and keeps only the boxes with no successful node_exporter scrape" \
    'unless on \(hostname\)' "${body}"
  assert_match "by way of the recorded box rule compared to 1" 'spark:box_up == 1' "${body}"
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

# The three containers on this profile read one another's files: prometheus.yml names
# paths that only the compose binds can make reachable, and its own blocks are decoded
# by a pinned binary that refuses an unknown field outright. A suite that stubs curl
# sees none of this, and each of these four held a container in a restart loop.

@test "no Prometheus bind nests inside another bind" {
  local facts findings="" pair_a pair_b a amode b
  local -a mounts=()
  facts="$(compose_mount_facts "${COMPOSE}" prometheus)"
  [[ -n ${facts} ]] ||
    fail "the prometheus service declares no host bind, so this proved nothing"
  mapfile -t mounts < <(printf '%s\n' "${facts}" | awk -F'|' '$1=="mount"{print $3"|"$4}')
  [[ ${#mounts[@]} -ge 2 ]] ||
    fail "the prometheus service binds ${#mounts[@]} host paths, so nesting cannot be seen"
  for pair_a in "${mounts[@]}"; do
    a="${pair_a%%|*}"
    amode="${pair_a##*|}"
    for pair_b in "${mounts[@]}"; do
      b="${pair_b%%|*}"
      [[ ${a} != "${b}" ]] || continue
      case ${b} in
        "${a}"/*)
          if [[ ${amode} == ro ]]; then
            findings+="bind ${b} nests inside the read-only ${a}, which mounts only "
            findings+="while ${a}'s own source still carries ${b}; "
          else
            findings+="bind ${b} nests inside ${a}; keep the binds siblings so every "
            findings+="mountpoint exists before runc reaches for it; "
          fi
          ;;
      esac
    done
  done
  assert_eq "every prometheus bind destination stands on its own" "" "${findings}"
}

@test "every file_sd path is a document compose actually binds into Prometheus" {
  local mounts confdir paths findings=""
  local -a dirs=()
  mounts="$(compose_mount_facts "${COMPOSE}" prometheus)"
  confdir="$(printf '%s\n' "${mounts}" | awk -F'|' '$1=="confdir"{print $2}')"
  [[ -n ${confdir} ]] ||
    fail "the prometheus service names no --config.file, so a relative path has no base"
  mapfile -t dirs < <(printf '%s\n' "${mounts}" | awk -F'|' '$1=="mount"{print $3}')
  paths="$(prom_facts "${PROMETHEUS_YML}" | awk -F'|' '$1=="file_sd"{print $3}')"
  [[ -n ${paths} ]] || fail "prometheus.yml names no file_sd file, so this proved nothing"
  local path reldir
  while IFS= read -r path; do
    [[ -n ${path} ]] || continue
    if [[ ${path} == /* ]]; then
      reldir="${path%/*}"
    else
      reldir="${confdir}/$(dirname "${path}")"
      [[ ${reldir} == "${confdir}/." ]] && reldir="${confdir}"
    fi
    [[ " ${dirs[*]-} " == *" ${reldir} "* ]] ||
      findings+="${path} resolves to ${reldir}, which no prometheus bind delivers; "
    # The directory alone is not the contract: file_sd on a name nothing generates is
    # not an error either, so all three jobs would go quietly to zero targets.
    [[ ${path##*/} == sparks.json ]] ||
      findings+="${path} is not the sparks.json that //scripts:spark-monitor writes; "
  done <<<"${paths}"
  assert_eq "each file_sd document sits inside a bind the prometheus service declares" \
    "" "${findings}"
}

@test "the alertmanagers block carries only keys the pinned Prometheus decodes" {
  local keys unknown="" key
  keys="$(prom_alertmanager_keys "${PROMETHEUS_YML}" | awk -F'|' '$1=="key"{print $2}')"
  [[ -n ${keys} ]] ||
    fail "prometheus.yml declares no alertmanagers entry, so this proved nothing"
  printf '%s\n' "${keys}" | grep -qx timeout ||
    fail "the block no longer sets timeout, so the key set proves nothing about a real entry"
  for key in ${keys}; do
    [[ " ${PINNED_ALERTMANAGER_KEYS[*]} " == *" ${key} "* ]] || unknown+="${key}; "
  done
  assert_eq "every alertmanagers key is one Prometheus v3.16.0 knows" "" "${unknown}"
}

@test "no rule template does arithmetic text/template cannot parse" {
  local file facts findings=""
  local -a files=() seen=()
  # Globbed rather than found: under Bazel the payload arrives as symlinks, which
  # `find -type f` would filter out and report as an empty rules directory.
  shopt -s nullglob
  files=("${OBS}/prometheus/rules"/*.yml)
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || fail "no rule file under observability/prometheus/rules"
  for file in "${files[@]}"; do
    facts="$(rule_template_facts "${file}")"
    mapfile -t seen < <(printf '%s\n' "${facts}" | awk -F'|' '$1=="rule"')
    [[ ${#seen[@]} -gt 0 ]] || fail "$(basename "${file}") carries no rule, so it proved nothing"
    if [[ -n ${facts} ]]; then
      findings+="$(printf '%s\n' "${facts}" |
        awk -F'|' '$1=="infix"{print $2" "$3" "$4": {"$5"}; "}')"
    fi
  done
  assert_eq "no annotation or label template uses an infix operator" "" "${findings}"
}

@test "the litellm scrape authenticates with a token file" {
  local facts path
  facts="$(prom_authorization_facts "${PROMETHEUS_YML}" litellm)"
  printf '%s\n' "${facts}" | grep -qx 'job|1' ||
    fail "prometheus.yml carries no litellm job, so this proved nothing"
  printf '%s\n' "${facts}" | grep -qx 'authkey|credentials_file' ||
    fail "the litellm job no longer opens its bearer from a file: $(printf '%s\n' "${facts}" | tr '\n' ' ')"
  # authorization.credentials is the shape that broke the target: Prometheus expands
  # $VAR and ${VAR} in global.external_labels values only, and nowhere else in the file
  # (measured on v3.16.0 against a listener that logs its request headers - $(VAR),
  # ${VAR} and $VAR all go out verbatim), so an inline value is sent as a literal and
  # LiteLLM answers 401.
  if printf '%s\n' "${facts}" | grep -qx 'authkey|credentials'; then
    fail "the litellm job sets authorization.credentials, which no environment can fill"
  fi
  path="$(printf '%s\n' "${facts}" |
    awk -F'|' '$1=="authval" && $2=="credentials_file"{print $3}')"
  assert_eq "the scrape opens the token at the path compose writes it to" \
    "${LITELLM_TOKEN_FILE}" "${path}"
}

@test "compose writes the token file the litellm scrape opens" {
  local facts top content attach source target mode
  facts="$(compose_config_facts "${COMPOSE}")"
  [[ -n ${facts} ]] ||
    fail "docker-compose.yml declares no top-level configs, so this proved nothing"
  top="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="top" && $2=="litellm_metrics_token"' | head -1)"
  [[ -n ${top} ]] ||
    fail "no configs.litellm_metrics_token, so nothing writes the file the litellm job opens"
  content="${top#*|*|}"
  assert_eq "the token renders from the same key the proxy authenticates with" \
    "${LITELLM_TOKEN_CONTENT}" "${content}"
  [[ ${content} == *LITELLM_MASTER_KEY* ]] ||
    fail "the token does not come from LITELLM_MASTER_KEY, so it can never match the master key"
  # The fallback has to be a string: an empty configs content makes the daemon refuse the
  # bind, and compose then fails the whole project at startup rather than one target.
  [[ ${content} != *':-}' ]] ||
    fail "configs.litellm_metrics_token falls back to an empty string"
  attach="$(printf '%s\n' "${facts}" | awk -F'|' '$1=="attach" && $2=="prometheus"' | head -1)"
  [[ -n ${attach} ]] ||
    fail "the prometheus service attaches no config, so it has no token file to open"
  IFS='|' read -r _ _ source target mode <<<"${attach}"
  assert_eq "the prometheus service attaches the litellm token config" \
    "litellm_metrics_token" "${source}"
  assert_eq "compose writes it where the scrape reads it" \
    "${LITELLM_TOKEN_FILE}" "${target}"
  assert_eq "the token file is world-readable and unwritable" "0444" "${mode}"
}

@test "the prometheus service holds no copy of the master key in its environment" {
  local keys
  keys="$(compose_env_facts "${COMPOSE}" prometheus | awk -F'|' '$1=="env"{print $2}')"
  # The service used to carry LITELLM_MASTER_KEY here on the belief that Prometheus would
  # substitute it into the scrape config. It never does, so the entry only put the key in
  # the container's environment (and into docker inspect) for nothing.
  if printf '%s\n' "${keys}" | grep -qx LITELLM_MASTER_KEY; then
    fail "prometheus has LITELLM_MASTER_KEY in its environment again, which Prometheus cannot use"
  fi
}

@test "the Grafana knobs that quiet 13.3 noise name a file this tree ships" {
  local env filters overrides_path binds src dest mode found="" findings=""
  env="$(compose_env_facts "${COMPOSE}" grafana)"
  [[ -n ${env} ]] ||
    fail "the grafana service declares no environment, so this proved nothing"
  filters="$(printf '%s\n' "${env}" | awk -F'|' '$1=="env" && $2=="GF_LOG_FILTERS"{print $3}')"
  [[ -n ${filters} ]] ||
    fail "GF_LOG_FILTERS is gone, and upstream grafana/grafana#137058 puts the manifest-watcher pair back in the log every poll"
  [[ ${filters} == *search-manifest-watcher:error* ]] ||
    fail "GF_LOG_FILTERS='${filters}' leaves the search-manifest-watcher warnings at warn"
  overrides_path="$(printf '%s\n' "${env}" |
    awk -F'|' '$1=="env" && $2=="GF_UNIFIED_STORAGE_OVERRIDES_PATH"{print $3}')"
  assert_eq "Grafana is pointed at the stack's quota overrides file" \
    "${GRAFANA_OVERRIDES_CONTAINER_PATH}" "${overrides_path}"
  # The variable alone buys nothing: Grafana takes the 501 away only once the path it
  # names resolves, so the bind is half of the fix and lives 600 lines away from it.
  binds="$(compose_mount_facts "${COMPOSE}" grafana)"
  while IFS='|' read -r _ src dest mode; do
    [[ ${dest} == "${GRAFANA_OVERRIDES_CONTAINER_PATH}" ]] || continue
    found=1
    [[ ${src} == *"${GRAFANA_OVERRIDES_SOURCE}" ]] ||
      findings+="bind source ${src} is not ${GRAFANA_OVERRIDES_SOURCE}; "
    [[ ${mode} == ro ]] || findings+="${src} is mounted ${mode}; the payload is stack-owned; "
  done <<<"${binds}"
  [[ ${found} == 1 ]] ||
    fail "nothing binds ${GRAFANA_OVERRIDES_CONTAINER_PATH} into grafana, so the quota call keeps answering 501"
  assert_eq "the quota overrides bind carries this tree's file, read-only" "" "${findings}"
}

@test "the shipped quota overrides file is the shape Grafana decodes" {
  local facts
  [[ -f ${OVERRIDES_YML} ]] ||
    fail "${GRAFANA_OVERRIDES_SOURCE} is missing, so GF_UNIFIED_STORAGE_OVERRIDES_PATH points at nothing and /apis/quotas.grafana.app keeps answering 501 (grafana/grafana#136271)"
  facts="$(overrides_facts "${OVERRIDES_YML}")"
  printf '%s\n' "${facts}" | grep -qx 'key|overrides' ||
    fail "${GRAFANA_OVERRIDES_SOURCE} carries no top-level overrides: key - a comment-only file leaves the 501 in place with no error to say so"
  printf '%s\n' "${facts}" | grep -qx 'map|overrides' ||
    fail "overrides: is not a mapping, which Grafana's decoder refuses at boot"
}

@test "litellm/config.yaml keeps the metrics endpoint authenticated" {
  local facts
  [[ -f ${LITELLM_CONFIG} ]] ||
    fail "litellm/config.yaml is not in this run's tree - it rides //litellm:config, which this suite's _SUITE_PAYLOAD entry in tests/BUILD.bazel has to declare"
  facts="$(litellm_config_facts "${LITELLM_CONFIG}")"
  [[ -n ${facts} ]] || fail "litellm/config.yaml parsed to nothing, so the key scan proved nothing"
  # Absence is the required state here, not an omission. /metrics answers under the
  # master key like every other LiteLLM route (SECURITY.md), and compose publishes
  # :4000 to the LAN, so the series the litellm scrape carries - model aliases, token
  # counts, per-key traffic - are readable by anything on that network the moment that
  # auth is switched off. LiteLLM's own 401 body offers the switch as the remedy
  # (litellm_settings.require_auth_for_metrics_endpoint: false), which is why false is
  # not a neutral answer to a red target: the target goes green by publishing the
  # fleet's traffic counts. A wrong token is fixed on the scrape side, at the file the
  # seam above pins.
  if printf '%s\n' "${facts}" | grep -qx 'setting|require_auth_for_metrics_endpoint'; then
    fail "litellm/config.yaml sets require_auth_for_metrics_endpoint, which takes /metrics off the master key while :4000 is published to the LAN"
  fi
  # The guard against a vacuous pass: without it a config whose litellm_settings block
  # had been renamed or dropped would satisfy the absence above by carrying nothing.
  printf '%s\n' "${facts}" | grep -qx 'map|litellm_settings' ||
    fail "litellm/config.yaml carries no litellm_settings: mapping, so it is not the shape that switch would live under"
}
