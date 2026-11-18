#!/bin/sh
# observability/alertmanager/boot-webhook-url.sh -- the alertmanager container's entrypoint.
#
# Alertmanager's own config parser cannot expand an environment variable inside a
# webhook URL: the value is a SecretTemplateURL validated only when it is not a
# template, nothing runs os.Expand on it, and the template funcmap has no `env`
# accessor. So ALERTMANAGER_WEBHOOK_URL has to become a file before the binary
# starts, and this is the one place that can do it.
#
# It lives beside alertmanager.yml rather than inside the compose `entrypoint:` so
# the repo's own shell gate (shellcheck, shfmt) reads it, and so the compose file
# stays a list of flags. compose mounts this directory read-only at
# /etc/alertmanager, which is why the file is written into --storage.path:
# /alertmanager is the container user's own writable volume, and the entrypoint
# regenerates it on every start, so an edited key takes effect on the next
# restart and a deleted key cannot survive as a stale URL on disk.
#
# An empty ALERTMANAGER_WEBHOOK_URL writes nothing at all, which is a working
# configuration: alertmanager.yml loads, the container starts, and every webhook
# receiver is a no-op until an operator sets the key. A missing file costs one
# failed send, not a failed pipeline, so the alert itself still reaches
# Prometheus's /alerts page and Grafana's Alerting tab.
#
# Positional arguments are the flags compose passes as `command:`, so they are
# forwarded verbatim and `exec` leaves alertmanager as PID 1 to receive SIGTERM.

set -u

webhook_file="/alertmanager/webhook_url"

if [ -n "${ALERTMANAGER_WEBHOOK_URL:-}" ]; then
  # Written in one shot and unquoted on purpose: Alertmanager trims the value it
  # reads, so a trailing newline is harmless, and no credential belongs in argv.
  printf '%s' "${ALERTMANAGER_WEBHOOK_URL}" >"${webhook_file}" ||
    echo "spark-monitor: cannot write ${webhook_file}; webhook receivers stay silent" >&2
else
  # The key is unset or empty, so the file has to go with it. It sits under
  # --storage.path, which is a named volume that outlives the container: an earlier
  # boot's URL would otherwise keep receiving alerts for a webhook the operator has
  # since deleted, and nothing in the compose file or the config would show why.
  rm -f "${webhook_file}" 2>/dev/null || true
fi

# Where the binary sits has only ever been proved by the image itself, so PATH is
# asked first and the documented location is the fallback. One exec either way, so
# alertmanager stays PID 1.
if command -v alertmanager >/dev/null 2>&1; then
  exec alertmanager "$@"
fi
exec /bin/alertmanager "$@"
