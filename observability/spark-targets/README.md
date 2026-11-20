# Generated Spark scrape targets

`sparks.json` lives here and is the only file this directory ever holds. Prometheus
reads it through `file_sd_configs` (`observability/prometheus/prometheus.yml` names
`/etc/spark-targets/sparks.json`, and compose bind-mounts this directory at that
path) for the `spark-node`, `blackbox-spark` and `blackbox-spark-models` jobs.
That mount is a sibling of `/etc/prometheus` rather than a directory under it:
runc creates a mountpoint with mkdirat, and inside the read-only
`/etc/prometheus` bind that fails, which stops the container before Prometheus
starts.

It is generated on the stack host and is gitignored, because it names the Spark
boxes by hostname:

    bazelisk run //scripts:spark-monitor -- --targets \
      > observability/spark-targets/sparks.json

`//scripts:spark-monitor` prints the document rather than writing it so a run from a
laptop cannot rewrite the host's target set, and `SPARK_MONITOR_ENABLED=false` makes
it print an empty array. Prometheus refreshes the file every 60 seconds, so an
operator edits `.env`, re-runs the redirect, and waits a minute.

An absent `sparks.json` is the normal state of a stack that has not enrolled any
Spark. It is not an error: the three jobs simply have no groups, which reads as zero
Sparks on the dashboards rather than as a probe pointed at this box.

This directory itself is committed, with only this file in it, because compose
bind-mounts it and `//tests:bats_stack_data_test` refuses a bind source that has no
directory beside the compose file.
