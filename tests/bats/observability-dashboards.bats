#!/usr/bin/env bats
#
# ## observability-dashboards.bats - hermetic gate for the provisioned dashboards.
#
# `observability/grafana/provisioning/dashboards/stack.yaml` loads every file under
# observability/grafana/dashboards by glob, re-reads the path every 60 s, and runs
# with `disableDeletion: true` / `allowUiUpdates: false`. So the provider accepts any
# JSON it can parse, a broken panel is silent until someone opens the page in a
# browser, and nothing in the UI can be fixed to prove the JSON was wrong. This suite
# is the machine that says so at lint time.
#
# Everything is read from the checkout: no Grafana, no container, no network, no
# daemon. Structure is walked in Python over the parsed document, never grepped -
# `"uid"` appears as a datasource key, a link key, and inside exprs, so a text search
# answers a different question than the one being asked.
#
# The rules come from the PR5 contract: the four provisioned datasource uids, the
# house panel key set, the metric families each exporter actually publishes, and the
# recording rules this repo ships. Metric names are read from the rule files at test
# time, so a new recording rule never needs a test edit; a name outside the pinned
# lists is a finding for whoever wrote the panel.
#
# Usage: bats tests/bats/observability-dashboards.bats
#        bazelisk test //tests:bats_observability_dashboards_test   (after the parent
#        registers the suite in tests/BUILD.bazel)
# Safety: reads observability/grafana/dashboards/*.json,
#         observability/prometheus/rules/*.rules.yml and scripts/lib/parse_json.py;
#         writes only under BATS_SUITE_TMPDIR.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
DASH_DIR=""
RULES_DIR=""
PARSE_JSON=""
LITELLM_JSON=""
declare -a DASH_FILES=()

# The four datasource uids the provisioning registers. Nothing else resolves, and a
# panel that asks for another uid renders empty with no error in the container log.
PINNED_DS=(prometheus mimir loki tempo)

# The uids L0 pins as already shipped. The folder may grow; these four may not vanish.
PINNED_UIDS=(evo-litellm evo-stack-logs evo-stack-overview evo-stack-traces)

# Panel-level keys this stack's house shape allows, on every panel type. Anything
# outside it is a key Grafana ignores, which is how a panel ends up rendering nothing.
HOUSE_PANEL_KEYS=(
  collapsed datasource description fieldConfig gridPos id links maxPerRow noValue
  options panels pluginVersion repeat repeatDirection repeatOptions targets
  thresholds title transparent transformations type url
)

# dashlist carries its own option names at panel level in this folder; they are legal
# for that type alone, so they sit beside the house set only there.
DASHLIST_KEYS=(headings maxItems query recent search sort starred)

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML is not installed"

  DASH_DIR="${REPO_ROOT}/observability/grafana/dashboards"
  RULES_DIR="${REPO_ROOT}/observability/prometheus/rules"
  PARSE_JSON="${REPO_ROOT}/scripts/lib/parse_json.py"
  LITELLM_JSON="${DASH_DIR}/litellm.json"

  # A missing payload is a broken tree, not a reason to skip: every one of these four
  # conditions used to `skip`, which meant an emptied folder reported sixteen skips and
  # exit 0, and the floor in the first test below never ran. Environmental gaps (no repo
  # marker, no PyYAML) still skip; a missing artifact fails.
  [[ -d ${DASH_DIR} ]] || fail "${DASH_DIR} is not in the tree"
  [[ -f ${PARSE_JSON} ]] || fail "${PARSE_JSON} is not in the tree"
  [[ -f ${LITELLM_JSON} ]] || fail "${LITELLM_JSON} is not in the tree"

  DASH_FILES=()
  local candidate
  for candidate in "${DASH_DIR}"/*.json; do
    [[ -f ${candidate} ]] && DASH_FILES+=("${candidate}")
  done
  [[ ${#DASH_FILES[@]} -gt 0 ]] || fail "no dashboard JSON under ${DASH_DIR}"
}

# --- fact emitter ----------------------------------------------------------

# dash_facts_dir - print the directory holding one `.facts` file per dashboard,
# building them once per suite run. Every assertion below reads these lines, so the
# JSON is parsed exactly once per file rather than once per property.
dash_facts_dir() {
  local dir="${BATS_SUITE_TMPDIR}/facts" file
  if [[ ! -f ${dir}/.built ]]; then
    mkdir -p "${dir}" || return 1
    for file in "${DASH_FILES[@]}"; do
      dash_emit_facts "${file}" >"${dir}/$(basename "${file}").facts" || return 1
    done
    : >"${dir}/.built"
  fi
  printf '%s' "${dir}"
}

# dash_all_facts <kind> - every `<kind>|...` line for the whole folder, prefixed with
# the dashboard file name as field 2, so one @test can speak over the folder.
dash_all_facts() {
  local kind="$1" dir facts name
  dir="$(dash_facts_dir)" || return 1
  for facts in "${dir}"/*.facts; do
    name="$(basename "${facts}")"
    awk -F'|' -v f="${name%.facts}" -v k="${kind}" \
      '$1 == k { printf "%s|%s", f, substr($0, index($0, "|") + 1); print "" }' "${facts}"
  done
}

# dash_emit_facts <file> - parse one dashboard and print its facts. Free text has its
# pipes and newlines folded so the field split stays unambiguous. Kinds:
#
#   file|<non_ascii>|<crlf>|<trailing_blank_lines>
#   top|<key>                       one line per top-level key
#   scalar|<key>|<value>            uid, title, schemaVersion, timezone as strings
#   panel|<id>|<type>|<title>|<visible>
#   panelkey|<id>|<type>|<key>
#   grid|<id>|<x>|<y>|<w>|<h>       visible panels only
#   badgrid|<id>|<title>|<detail>
#   dupid|<id>|<title>
#   overlap|<id_a>|<title_a>|<id_b>|<title_b>
#   query|<id>|<title>|<has_description>   panels that issue a query
#   target|<id>|<legend>|<first_key>|<refid>|<has_datasource>
#   ds|<where>|<uid>|<type>         every datasource object in the document
#   metric|<id>|<title>|<name>      candidate metric family from every expr
#   var|<name>|<type>|<ds_uid>|<has_query>
#   varref|<name>                   a $var / ${var} / repeat reference from a panel
#   link|<where>|<url>              every dashboard-level and link-panel URL
#   dashlist|<id>|<title>|<query>|<maxItems>|<headings>|<starred>|<visible>
#   forbid|<detail>                 a shape the contract forbids outright
dash_emit_facts() {
  python3 - "${1}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "rb") as handle:
    raw = handle.read()

text = raw.decode("utf-8", errors="replace")
trailing = len(text) - len(text.rstrip("\n"))
print("file|%d|%d|%d" % (
    sum(1 for byte in raw if byte > 127),
    raw.count(b"\r\n"),
    0 if text.endswith("\n") and trailing == 1 else trailing + (0 if text.endswith("\n") else 1),
))


def clean(value):
    return str(value).replace("|", ";").replace("\n", " ").replace("\r", " ").strip()


try:
    doc = json.loads(text)
except ValueError as error:
    print("forbid|does not parse as JSON: %s" % clean(error))
    sys.exit(0)

if not isinstance(doc, dict):
    print("forbid|root is not a JSON object")
    sys.exit(0)

for key in doc:
    print("top|%s" % clean(key))
for key in ("uid", "title", "schemaVersion", "timezone"):
    print("scalar|%s|%s" % (key, clean(doc.get(key, ""))))


def visible_panels(document):
    """Yield (panel, rendered) pairs; children of a collapsed row are not rendered."""
    for panel in document.get("panels") or []:
        if not isinstance(panel, dict):
            continue
        yield panel, True
        if panel.get("type") == "row" and panel.get("collapsed"):
            for child in panel.get("panels") or []:
                if isinstance(child, dict):
                    yield child, False


def walk_datasources(node, where):
    if isinstance(node, dict):
        source = node.get("datasource")
        if isinstance(source, dict):
            print("ds|%s|%s|%s" % (clean(where), clean(source.get("uid", "")),
                                   clean(source.get("type", ""))))
        for key, value in node.items():
            walk_datasources(value, where)
    elif isinstance(node, list):
        for value in node:
            walk_datasources(value, where)


# PromQL function and keyword names, so the extractor reports selectors and not the
# operators around them. A name in this set is never a metric family.
PROMQL_WORDS = {
    "abs", "absent", "acos", "alias", "and", "asin", "atan", "avg", "avg_over_time",
    "bottomk", "by", "ceil", "clamp", "clamp_max", "clamp_min", "cos", "cosh",
    "count", "count_over_time", "count_values", "day_of_month", "day_of_week",
    "days_in_month", "deg", "delta", "deriv", "degrad", "end", "exp", "floor",
    "group", "histogram_count", "histogram_mean", "histogram_quantile",
    "histogram_sum", "hour", "idelta", "ignoring", "increase", "info", "irate",
    "label_join", "label_replace", "last_over_time", "limit", "ln", "log10", "log2",
    "max", "max_over_time", "min", "min_over_time", "minute", "month", "or",
    "pi", "predict_linear", "present_over_time", "quantile", "quantile_over_time",
    "rad", "raddeg", "rate", "round", "scalar", "sgn", "sin", "sinh", "sort",
    "sort_desc", "sqrt", "stddev", "stddev_over_time", "stdvar",
    "stdvar_over_time", "step", "sum", "sum_over_time", "tan", "tanh", "timestamp",
    "time", "topk", "unless", "without", "year",
}
VARIABLE = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_:]*")
STRING_LIT = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')
GROUPING = re.compile(r"\b(?:by|without|on|ignoring|limit)\s*\([^)]*\)", re.I)
LABELS = re.compile(r"\{[^}]*\}")
RANGE = re.compile(r"\[[^\]]*\]")
SELECTOR = re.compile(r"([A-Za-z_][A-Za-z0-9_:]*)(\s*\()?")
UID_PATH = re.compile(r"^/d/([^/?#]+)")

# Grafana's own globals are not templating variables, and `${var:queryparam}` is the
# link-parameter form L0 pins for dashboard-to-dashboard links.
GRAFANA_GLOBALS = {
    "var", "queryparam", "value", "field", "series", "data", "panel", "dashboard",
    "user", "elements", "local", "from", "to", "iso", "interval", "interval_ms",
    "rate_interval", "range", "range_s", "range_ms", "timefilter", "url_path",
    "percentile", "pipe", "csv", "json", "raw", "sqlstring", "doublequote",
    "singlequote", "text", "auto",
}


def metric_candidates(expr):
    """Bounded PromQL name extraction: drop strings, variables, groupings, label
    matchers and ranges, then keep the bare words that are not functions."""
    body = VARIABLE.sub(" ", expr)
    body = STRING_LIT.sub("''", body)
    body = GROUPING.sub(" ", body)
    body = LABELS.sub("{}", body)
    body = RANGE.sub("[ ]", body)
    found = []
    for match in SELECTOR.finditer(body):
        name, called = match.group(1), match.group(2)
        if called or name.lower() in PROMQL_WORDS:
            continue
        found.append(name)
    return found


def variable_names(node, where):
    """$name / ${name} references, and the repeat target, from rendered panels."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("description", "title", "tooltip", "content", "links"):
                continue
            if key == "repeat":
                target = value
                if isinstance(target, dict):
                    target = target.get("queryName") or ""
                if isinstance(target, str) and target:
                    name = target.split(":")[0]
                    if name.startswith("var-"):
                        name = name[4:]
                    print("varref|%s" % clean(name))
                continue
            variable_names(value, where)
    elif isinstance(node, list):
        for value in node:
            variable_names(value, where)
    elif isinstance(node, str):
        for token in VARIABLE.findall(node):
            name = token.lstrip("$").strip("{}").split(":")[0]
            if name and name.lstrip("_").lower() not in GRAFANA_GLOBALS:
                print("varref|%s" % clean(name))


def scan_forbidden(blob):
    for needle in ("__inputs", "__requires", "localhost", "127.0.0.1", "-- Mixed --",
                   "container_running", "container_created"):
        if needle in blob:
            print("forbid|contains %s" % needle)
    if re.search(r"\bdcgm_", blob):
        print("forbid|uses a dcgm_ prefixed name; DCGM series are DCGM_FI_*")
    for match in re.finditer(r'(pressure|operation)\s*=\s*"[^"]*"', blob):
        print("forbid|matches on the PSI label %s=; the five PSI series carry no labels"
              % match.group(1))
    for expr in re.findall(r'"expr"\s*:\s*"((?:[^"\\]|\\.)*)"', blob):
        if re.search(r'\bmode\s*=\s*"', expr) and "node_cpu_seconds_total" not in expr:
            print("forbid|matches on mode= outside a node_cpu_seconds_total selector")


# Prose is what a person reads, not what Grafana resolves, so a text panel may explain
# that Alertmanager binds to loopback without tripping the no-host-name rule. Anything
# a panel resolves - a URL, a datasource, an expr, a legend - is still scanned.
PROSE_KEYS = {"content", "description", "title", "tooltip"}


def strip_prose(node):
    if isinstance(node, dict):
        return {key: (" " if key in PROSE_KEYS else strip_prose(value))
                for key, value in node.items()}
    if isinstance(node, list):
        return [strip_prose(value) for value in node]
    return node


scan_forbidden(json.dumps(strip_prose(doc)))

for entry in doc.get("links") or []:
    if isinstance(entry, dict) and entry.get("url"):
        print("link|dashboards.links|%s" % clean(entry["url"]))
    if isinstance(entry, dict) and "panelId" in entry:
        print("forbid|a dashboard link addresses a panel by panelId only")

seen_ids = {}
rectangles = []
for panel, shown in visible_panels(doc):
    pid = panel.get("id")
    title = clean(panel.get("title"))
    ptype = clean(panel.get("type"))
    print("panel|%s|%s|%s|%s" % (clean(pid), ptype, title, "1" if shown else "0"))
    if panel.get("type") == "stat":
        # A stat with no noValue prints Grafana's own "No data" in the panel's colour,
        # so an outage and an unenrolled feature look alike. The house value is explicit.
        defaults = (panel.get("fieldConfig") or {}).get("defaults") or {}
        print("statnovalue|%s|%s" % (clean(pid), "1" if defaults.get("noValue") else "0"))
    for key in panel:
        print("panelkey|%s|%s|%s" % (clean(pid), ptype, clean(key)))
    if pid in seen_ids:
        print("dupid|%s|%s" % (clean(pid), title))
    seen_ids[pid] = title

    grid = panel.get("gridPos")
    if shown:
        if not isinstance(grid, dict) or any(
                not isinstance(grid.get(axis), int) for axis in ("x", "y", "w", "h")):
            print("badgrid|%s|%s|gridPos lacks integer x, y, w, h" % (clean(pid), title))
        else:
            rectangles.append((pid, title, grid["x"], grid["y"], grid["w"], grid["h"]))
            print("grid|%s|%d|%d|%d|%d" % (clean(pid), grid["x"], grid["y"],
                                           grid["w"], grid["h"]))

    where = "panel %s (%s)" % (clean(pid), title)
    walk_datasources(panel, where)
    variable_names(panel, where)

    targets = panel.get("targets") or []
    for target in targets:
        if not isinstance(target, dict):
            continue
        keys = list(target)
        print("target|%s|%s|%s|%s|%s" % (
            clean(pid), title, clean(keys[0]) if keys else "",
            clean(target.get("refId", "")),
            "1" if isinstance(target.get("datasource"), dict) else "0"))
    exprs = []

    def collect_exprs(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "expr" and isinstance(value, str):
                    exprs.append(value)
                else:
                    collect_exprs(value)
        elif isinstance(node, list):
            for value in node:
                collect_exprs(value)

    collect_exprs(panel)
    if targets or exprs:
        description = panel.get("description")
        print("query|%s|%s|%s" % (clean(pid), title,
                                  "1" if str(description or "").strip() else "0"))
    for expr in exprs:
        for name in metric_candidates(expr):
            print("metric|%s|%s|%s" % (clean(pid), title, clean(name)))
    if panel.get("type") == "link":
        if panel.get("url"):
            print("link|%s|%s" % (where, clean(panel["url"])))
        for entry in panel.get("links") or []:
            if isinstance(entry, dict) and entry.get("url"):
                print("link|%s|%s" % (where, clean(entry["url"])))

    # The dashlist is the folder's backstop navigator, so its filter and its cap
    # decide whether it reaches anything: a starred-only or headings-only list, a
    # filtered query, or a maxItems below the folder size silently drops pages.
    if panel.get("type") == "dashlist":
        print("dashlist|%s|%s|%s|%s|%s|%s|%s" % (
            clean(pid), title, clean(panel.get("query", "")),
            clean(panel.get("maxItems", "")),
            "1" if panel.get("headings") else "0",
            "1" if panel.get("starred") else "0",
            "1" if shown else "0"))

for left in range(len(rectangles)):
    for right in range(left + 1, len(rectangles)):
        _ida, _ta, x1, y1, w1, h1 = rectangles[left]
        _idb, _tb, x2, y2, w2, h2 = rectangles[right]
        if x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1:
            print("overlap|%s|%s|%s|%s" % (clean(rectangles[left][0]), clean(_ta),
                                           clean(rectangles[right][0]), clean(_tb)))

for variable in (doc.get("templating") or {}).get("list") or []:
    if not isinstance(variable, dict):
        continue
    source = variable.get("datasource")
    print("var|%s|%s|%s|%s" % (
        clean(variable.get("name", "")), clean(variable.get("type", "")),
        clean((source or {}).get("uid", "")) if isinstance(source, dict) else "",
        "1" if str(variable.get("query", "")).strip() else "0"))
PY
}

# dash_metric_findings - every metric name the folder names that no pinned list
# allows, as `<file>|<panel id>|<panel title>|<name>`. The allow-list is the contract
# L0 pins, plus the recording rules this repo ships (read now, so adding a rule never
# edits this file), plus the families litellm.json already charts.
dash_metric_findings() {
  local dir
  dir="$(dash_facts_dir)" || return 1
  python3 - "${dir}" "${RULES_DIR}" "${LITELLM_JSON}" <<'PY'
import glob
import json
import os
import sys

facts_dir, rules_dir, litellm_json = sys.argv[1:4]

NODE = """
node_cpu_seconds_total node_load1 node_load5 node_load15 node_memory_MemTotal_bytes
node_memory_MemAvailable_bytes node_memory_SwapTotal_bytes node_memory_SwapFree_bytes
node_filesystem_size_bytes node_filesystem_avail_bytes node_filesystem_files
node_filesystem_files_free node_disk_reads_completed_total
node_disk_writes_completed_total node_disk_read_bytes_total
node_disk_written_bytes_total node_disk_io_time_seconds_total
node_network_receive_bytes_total node_network_transmit_bytes_total
node_network_receive_packets_total node_network_receive_drop_total
node_network_transmit_drop_total node_boot_time_seconds node_procs_running
node_procs_blocked node_filefd_allocated node_filefd_maximum
node_nf_conntrack_entries node_nf_conntrack_entries_limit node_processes_pids
node_processes_max_processes node_uname_info node_exporter_build_info
node_pressure_cpu_waiting_seconds_total node_memory_waiting_seconds_total
node_io_waiting_seconds_total node_memory_stalled_seconds_total
node_io_stalled_seconds_total
"""
CADVISOR = """
container_cpu_usage_seconds_total container_cpu_cfs_throttled_seconds_total
container_memory_working_set_bytes container_memory_max_usage_bytes
container_memory_rss container_spec_memory_limit_bytes container_oom_events_total
container_network_receive_bytes_total container_network_transmit_bytes_total
container_fs_reads_bytes_total container_fs_writes_bytes_total container_processes
container_threads container_file_descriptors container_start_time_seconds
container_last_seen cadvisor_version_info
"""
DCGM = """
DCGM_FI_DEV_GPU_UTIL DCGM_FI_DEV_MEM_COPY_UTIL DCGM_FI_DEV_FB_USED
DCGM_FI_DEV_FB_FREE DCGM_FI_DEV_GPU_TEMP DCGM_FI_DEV_MEMORY_TEMP
DCGM_FI_DEV_POWER_USAGE DCGM_FI_DEV_SM_CLOCK DCGM_FI_DEV_MEM_CLOCK
DCGM_FI_DEV_ENC_UTIL DCGM_FI_DEV_DEC_UTIL DCGM_FI_DEV_PCIE_REPLAY_COUNTER
DCGM_FI_PROF_PCIE_TX_BYTES DCGM_FI_PROF_PCIE_RX_BYTES
DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS
DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS DCGM_FI_DEV_ROW_REMAP_FAILURE
"""
# The LiteLLM surface this stack is pinned to (v1.102.1), read off LiteLLM's own
# Prometheus exposition docs rather than off a page in this folder. That is deliberate:
# these names used to be lifted from litellm.json's own expressions, which let a page
# audit itself - a family invented there became legal there and on every page that
# copied it, and the queue-wait panel on the models page was the result, titled away
# from a first-token series it could not have named. Every name is now here or nowhere,
# so adding one is a decision with a source behind it and the reference page is held to
# the same list as the pages that copy it.
LITELLM = """
litellm_input_tokens_metric_total litellm_output_tokens_metric_total
litellm_total_tokens_metric_total litellm_request_total_latency_metric_bucket
litellm_llm_api_latency_metric_bucket litellm_request_queue_time_seconds_bucket
litellm_overhead_latency_metric_bucket
litellm_deployment_latency_per_output_token_bucket
litellm_cache_hits_metric_total litellm_cache_misses_metric_total
litellm_cached_tokens_metric_total
litellm_provider_cache_read_input_tokens_metric_total
litellm_input_cached_tokens_metric_total
litellm_output_reasoning_tokens_metric_total litellm_in_flight_requests
litellm_admission_queued_requests litellm_admission_rejected_requests_total
litellm_remaining_requests_metric litellm_remaining_tokens_metric
litellm_deployment_rpm_limit litellm_deployment_tpm_limit
litellm_deployment_successful_fallbacks_total
litellm_deployment_failed_fallbacks_total litellm_deployment_state
litellm_deployment_cooled_down_total
litellm_llm_api_time_to_first_token_metric
litellm_proxy_total_requests_metric_total litellm_proxy_failed_requests_metric_total
litellm_deployment_total_requests_total litellm_deployment_failure_responses_total
litellm_spend_metric_total
"""
BUNDLE = """
up scrape_samples_scraped prometheus_rule_group_last_duration_seconds
prometheus_rule_group_rules prometheus_notifications_dropped_total
loki_ingester_streams_created_total mimir_ingest_samples tempo_ingest_spans_total
grafana_stat_totals alertmanager_alerts alertmanager_alerts_received_total
probe_success probe_duration_seconds probe_http_status_code
ALERTS ALERTS_FOR_STATE
"""

# The bundle watching itself. Every page here can say "the app is slow" while the
# layer answering it quietly falls behind, and no app-facing family shows that, so the
# overview charts each component's own telemetry. Each name is the component's published
# exposition rather than a guess, read off its own docs or the upstream repo: the three
# remote-storage names are Prometheus' remote-write contract, the two TSDB names and the
# Loki distributor counter are the ingestion figures their meta-monitoring pages name,
# and the last two are what Tempo's metrics_generator writes when span metrics are on
# (its docs call the histogram traces_spanmetrics_latency, so _bucket is a suffix of a
# listed family). One candidate did not survive that check and is gone from the page:
# Prometheus exports no WAL size gauge, so the panel that asked for it now charts only
# the block bytes and says why.
SELF_TELMETRY = """
prometheus_tsdb_storage_blocks_bytes
prometheus_remote_storage_samples_pending
prometheus_remote_storage_samples_failed_total
prometheus_remote_storage_samples_retried_total
loki_distributor_lines_received_total
traces_spanmetrics_calls_total traces_spanmetrics_latency
"""

allowed = set()
for block in (NODE, CADVISOR, DCGM, LITELLM, BUNDLE, SELF_TELMETRY):
    allowed.update(block.split())

import yaml  # noqa: E402  (the suite skips when this import fails)

for path in sorted(glob.glob(os.path.join(rules_dir, "*.rules.yml"))):
    with open(path, encoding="utf-8") as handle:
        document = yaml.safe_load(handle) or {}
    for group in document.get("groups") or []:
        for rule in group.get("rules") or []:
            name = rule.get("record")
            if name:
                allowed.add(name)

with open(litellm_json, encoding="utf-8") as handle:
    shipped = json.load(handle)  # noqa: F841  (presence is checked in setup)

# The reference page used to seed this list with whatever it happened to chart, which
# made it its own oracle: a family written there was legal there and on every page that
# copied it. It is now audited as a page like any other, so a name enters through the
# curated block above and nothing else.
_ = shipped

# A histogram family publishes _bucket, _sum and _count beside the name the contract
# lists, and L0 itself tells a panel to derive rates off the bare
# `litellm_llm_api_latency_metric`, so those three siblings are one family and not a
# new metric. Nothing else folds onto a listed name, so an invented family still fails.
SUFFIXES = ("_bucket", "_sum", "_count")


def family(name):
    for suffix in SUFFIXES:
        if name.endswith(suffix) and len(name) > len(suffix):
            return name[: -len(suffix)]
    return name


families = {family(name) for name in allowed}


def accepted(name):
    return name in allowed or family(name) in families


for facts in sorted(glob.glob(os.path.join(facts_dir, "*.facts"))):
    name = os.path.basename(facts)[: -len(".facts")]
    with open(facts, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("|")
            if fields[0] != "metric":
                continue
            if not accepted(fields[3]):
                print("%s|%s|%s|%s" % (name, fields[1], fields[2], fields[3]))
PY
}

# --- the gate --------------------------------------------------------------

@test "the folder is non-empty and every dashboard parses with the repo's own parser" {
  local -a paths=("${DASH_FILES[@]}")
  run python3 "${PARSE_JSON}" "${paths[@]}"
  assert_eq "the same parser scripts/lib/validate runs accepts every file" 0 "${status}"
  assert_eq "and it prints nothing on success" "" "${output}"
  [[ ${#paths[@]} -ge 4 ]] || fail "only ${#paths[@]} dashboards in ${DASH_DIR}"
}

@test "every dashboard is pure ASCII, LF-only, and ends in exactly one newline" {
  local findings=""
  while IFS='|' read -r file non_ascii crlf trailing; do
    [[ ${non_ascii} == "0" ]] || findings+="${file}: ${non_ascii} non-ASCII bytes; "
    [[ ${crlf} == "0" ]] || findings+="${file}: ${crlf} CRLF pairs; "
    [[ ${trailing} == "0" ]] || findings+="${file}: ${trailing} trailing newline(s), want exactly 1; "
  done < <(dash_all_facts "file")
  assert_eq "every file in ${DASH_DIR} is ASCII, LF, and single-newline" "" "${findings}"
}

@test "every dashboard carries the pinned top-level keys and the house values" {
  local findings="" file key value
  while IFS='|' read -r file key value; do
    case "${key}" in
      uid)
        [[ ${value} == evo-* ]] || findings+="${file}: uid '${value}' is not evo- prefixed; "
        [[ -n ${value} ]] || findings+="${file}: uid is empty; "
        ;;
      title) [[ -n ${value} ]] || findings+="${file}: title is empty; " ;;
      schemaVersion)
        [[ ${value} == "39" ]] || findings+="${file}: schemaVersion is '${value}', want 39; "
        ;;
      timezone)
        [[ ${value} == "browser" ]] || findings+="${file}: timezone is '${value}', want browser; "
        ;;
    esac
  done < <(dash_all_facts "scalar")
  assert_eq "uid, title, schemaVersion and timezone are present and house-shaped" \
    "" "${findings}"
}

@test "the four pinned uids are present and no uid or title repeats across the folder" {
  local -a uids=() titles=()
  local uid missing="" dupe=""
  mapfile -t uids < <(dash_all_facts "scalar" | awk -F'|' '$2=="uid"{print $3}' | sort)
  mapfile -t titles < <(dash_all_facts "scalar" | awk -F'|' '$2=="title"{print $3}' | sort)

  [[ ${#uids[@]} -gt 0 ]] || fail "no uid parsed from ${DASH_DIR}"
  local pinned
  for pinned in "${PINNED_UIDS[@]}"; do
    printf '%s\n' "${uids[@]}" | grep -qx "${pinned}" || missing+="${pinned}; "
  done
  assert_eq "the uids L0 pins are all still in the folder" "" "${missing}"
  assert_eq "uids are unique across the folder" \
    "$(printf '%s\n' "${uids[@]}")" "$(printf '%s\n' "${uids[@]}" | uniq)"

  dupe="$(printf '%s\n' "${titles[@]}" | uniq -d)"
  assert_eq "titles are unique across the folder" "" "${dupe}"
}

@test "every panel id is an integer, unique within its file" {
  local findings=""
  findings="$(dash_all_facts "dupid" | awk -F'|' '{print $1": panel id "$2" ("$3") repeats"}')"
  assert_eq "no dashboard reuses a panel id" "" "${findings}"
  local bad
  bad="$(dash_all_facts "panel" | awk -F'|' '$2 !~ /^[0-9]+$/{print $1": panel id "$2" ("$4")"}')"
  assert_eq "every panel id is an integer" "" "${bad}"
}

@test "every panel carries a full gridPos and no two visible panels overlap" {
  local findings=""
  findings="$(dash_all_facts "badgrid" | awk -F'|' '{print $1": panel "$2" ("$3"): "$4}')"
  assert_eq "every panel has integer x, y, w, h" "" "${findings}"
  findings="$(dash_all_facts "overlap" \
    | awk -F'|' '{print $1": panels "$2" ("$3") and "$4" ("$5") overlap"}')"
  assert_eq "no two rendered panels occupy the same gridPos rectangle" "" "${findings}"
}

@test "every panel stays inside the house key set" {
  local allowed findings="" file pid ptype key
  allowed=" ${HOUSE_PANEL_KEYS[*]} ${DASHLIST_KEYS[*]} "
  while IFS='|' read -r file pid ptype key; do
    # dashlist names its own options at panel level; nothing else may.
    if [[ ${ptype} == "dashlist" ]]; then
      allowed=" ${HOUSE_PANEL_KEYS[*]} ${DASHLIST_KEYS[*]} "
    else
      allowed=" ${HOUSE_PANEL_KEYS[*]} "
    fi
    case "${allowed}" in
      *" ${key} "*) ;;
      *) findings+="${file}: key ${key} on panel ${pid}; " ;;
    esac
  done < <(dash_all_facts "panelkey")
  assert_eq "every panel key is one Grafana reads for this stack" "" "${findings}"
}

@test "every target opens with refId and carries its own datasource" {
  local findings="" file pid legend first refid nodesc
  while IFS='|' read -r file pid legend first refid nodesc; do
    [[ ${first} == "refId" ]] || findings+="${file} panel ${pid} (${legend}): target's first key is '${first}', want refId; "
    [[ -n ${refid} ]] || findings+="${file} panel ${pid} (${legend}): target has no refId; "
    [[ ${nodesc} == "1" ]] || findings+="${file} panel ${pid} (${legend}): target has no datasource object; "
  done < <(dash_all_facts "target")
  assert_eq "every target is refId-first and pinned to a datasource" "" "${findings}"
  [[ -n $(dash_all_facts "target") ]] || fail "no targets found in ${DASH_DIR}"
}

@test "every datasource is one of the four provisioned uids" {
  local findings="" file where uid type known
  while IFS='|' read -r file where uid type; do
    known=0
    local pinned
    for pinned in "${PINNED_DS[@]}"; do
      [[ ${uid} == "${pinned}" ]] && known=1
    done
    [[ ${known} -eq 1 ]] || findings+="${file} ${where}: datasource uid '${uid}' is not provisioned; "
    [[ -n ${uid} ]] || findings+="${file} ${where}: datasource has no uid (Grafana falls back to the default); "
    [[ -n ${type} ]] || findings+="${file} ${where}: datasource '${uid}' carries no type; "
    [[ ${uid} != *"--"* ]] || findings+="${file} ${where}: datasource '${uid}' asks for Mixed; "
    [[ ${uid} != *://* ]] || findings+="${file} ${where}: datasource '${uid}' is a URL, not a uid; "
  done < <(dash_all_facts "ds")
  assert_eq "every datasource object names prometheus, mimir, loki or tempo by uid" \
    "" "${findings}"
  [[ -n $(dash_all_facts "ds") ]] || fail "no datasource found anywhere in ${DASH_DIR}"
}

@test "every panel that issues a query carries a description" {
  local findings=""
  findings="$(dash_all_facts "query" | awk -F'|' '$4=="0"{print $1": panel "$2" ("$3")"}')"
  assert_eq "every querying panel says what a rising line means" "" "${findings}"
  local total
  total="$(dash_all_facts "query" | wc -l | tr -d ' ')"
  [[ ${total} -gt 0 ]] || fail "no querying panel found in ${DASH_DIR}"
}

@test "every stat says something when its query returns nothing" {
  # Grafana prints its own "No data" in the panel's threshold colour when a stat carries
  # no noValue, so a stopped exporter and an unenrolled feature look identical. Every
  # stat here states its empty reading instead.
  local findings=""
  while IFS='|' read -r kind pid has; do
    [[ ${has} == "1" ]] || findings+="panel ${pid}; "
  done < <(dash_all_facts "statnovalue")
  assert_eq "every stat panel sets a noValue (missing: ${findings})" "" "${findings}"
}

@test "every metric named in an expr is on the pinned allow-list" {
  local findings=""
  findings="$(dash_metric_findings)"
  if [[ -n ${findings} ]]; then
    findings="$(printf '%s\n' "${findings}" \
      | awk -F'|' '{print $1" panel "$2" ("$3"): metric "$4" is not in the pinned allow-list"}')"
  fi
  assert_eq "every expr names a family L0 pins, a rule this repo records, or a name litellm.json charts" \
    "" "${findings}"
}

@test "every variable a panel references is declared in templating" {
  local declared refs findings="" name
  declared="$(dash_all_facts "var" | awk -F'|' '{print $2}')"
  refs="$(dash_all_facts "varref" | awk -F'|' '{print $2}' | sort -u)"
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    printf '%s\n' "${declared}" | grep -qx "${name}" || findings+="${name}; "
  done <<<"${refs}"
  assert_eq "every \$var / \${var} / repeat reference resolves to a templating variable" \
    "" "${findings}"
}

@test "every templating variable is well formed" {
  local findings="" file name vtype dsuid hasquery known
  while IFS='|' read -r file name vtype dsuid hasquery; do
    [[ -n ${name} ]] || findings+="${file}: a variable has no name; "
    [[ -n ${vtype} ]] || findings+="${file} var ${name}: no type; "
    if [[ ${vtype} == "query" ]]; then
      known=0
      local pinned
      for pinned in "${PINNED_DS[@]}"; do
        [[ ${dsuid} == "${pinned}" ]] && known=1
      done
      [[ ${known} -eq 1 ]] || findings+="${file} var ${name}: query variable's datasource uid is '${dsuid}'; "
      [[ ${hasquery} == "1" ]] || findings+="${file} var ${name}: query variable has an empty query; "
    fi
  done < <(dash_all_facts "var")
  assert_eq "every templating variable has a name, a type, and a provisioned datasource" \
    "" "${findings}"
}

@test "every dashboard link points at a dashboard that exists in the folder" {
  local uids findings="" file where url want
  uids="$(dash_all_facts "scalar" | awk -F'|' '$2=="uid"{print $3}')"
  while IFS='|' read -r file where url; do
    [[ ${url} == /d/* ]] || continue
    want="${url#/d/}"
    want="${want%%/*}"
    want="${want%%\?*}"
    printf '%s\n' "${uids}" | grep -qx "${want}" \
      || findings+="${file} ${where}: links to /d/${want}, which no dashboard in ${DASH_DIR} has; "
  done < <(dash_all_facts "link")
  assert_eq "no link is a dead tile" "" "${findings}"
  [[ -n $(dash_all_facts "link") ]] || fail "no dashboard link found in ${DASH_DIR}"
}

@test "the home dashboard reaches every other dashboard in the folder" {
  local uids others total reached want findings="" backstop
  uids="$(dash_all_facts "scalar" | awk -F'|' '$2=="uid"{print $3}')"
  printf '%s\n' "${uids}" | grep -qx "evo-home" \
    || fail "no dashboard in ${DASH_DIR} carries uid evo-home, so nothing anchors the folder"

  others="$(printf '%s\n' "${uids}" | awk 'NF && $0 != "evo-home"')"
  total="$(printf '%s\n' "${others}" | awk 'NF' | wc -l | tr -d ' ')"
  [[ ${total} -gt 0 ]] || fail "evo-home is the only dashboard in ${DASH_DIR}; nothing to reach"

  # Every /d/<uid> home.json resolves: a dashboard-level links: entry, a link panel's
  # own url, or one of its links: entries. The dashlist is deliberately not counted
  # here - it truncates at maxItems and filters by query, so a page can sit below its
  # fold while the list still looks healthy. A page that drops off home.json becomes
  # dead weight nobody navigates to, so each one needs a hand-placed tile.
  reached="$(dash_all_facts "link" | awk -F'|' '
      $1 == "home.json" && $3 ~ /^\/d\// {
        url = $3; sub(/^\/d\//, "", url); sub(/[/?].*/, "", url); print url }' | sort -u)"
  while IFS= read -r want; do
    [[ -n ${want} ]] || continue
    printf '%s\n' "${reached}" | grep -qx "${want}" \
      || findings+="evo-home reaches no link panel or links: entry for ${want}; "
  done <<<"${others}"
  assert_eq "every dashboard in ${DASH_DIR} other than evo-home is reachable from home.json" \
    "" "${findings}"

  # And the dashlist has to be the folder-wide backstop the contract promises:
  # unfiltered, not starred-only or headings-only, and tall enough to name every page.
  backstop="$(dash_all_facts "dashlist" | awk -F'|' -v n="${total}" \
      '$1 == "home.json" && $8 == "1" && $4 == "" && $6 != "1" && $7 != "1" && ($5 + 0) >= n { print "1"; exit }')"
  assert_eq "home.json's dashlist is a folder-wide backstop (empty query, not starred or headings, maxItems >= ${total})" \
    "1" "${backstop}"
}

@test "no dashboard carries an import block, a host name, or a dead metric shape" {
  local findings=""
  findings="$(dash_all_facts "forbid" | awk -F'|' '{print $1": "$2}')"
  assert_eq "no file carries __inputs, __requires, a loopback host, -- Mixed --, a dcgm_ name, a container_running/container_created gauge, a PSI label matcher, or a stray mode=" \
    "" "${findings}"
}
