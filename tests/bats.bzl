"""Helpers to declare one hermetic Bats sh_test per suite file."""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

def bats_file_tests(srcs, common_data, runner, payload, payload_allow = None):
    """Declare bats_<stem>_test sh_test targets and a bats test_suite.

    Args:
        srcs: labels of bats/*.bats files.
        common_data: runfiles every suite needs: bats-core, the runner, the shared helpers,
            the tool stubs, and the repo-root marker.
        runner: exec_shell launcher label whose runfiles include bats_runner.sh.
        payload: dict of suite basename -> payload group labels that suite reads by path.
            Every suite must have a key: a missing key fails analysis rather than quietly
            inheriting the payload tree, and //tests:bats_bazel_deps_test re-derives the
            map from the suite sources. A suite that reads a payload its target does not
            declare skips under its own target and only runs inside //tests:shell_coverage,
            which carries the whole tree - which is exactly the silent gap the map closes.
        payload_allow: optional dict of suite basename -> labels paired on purpose for a
            reason the source scan cannot derive; each carries its reason in BUILD.
    """
    if payload == None:
        fail("bats_file_tests needs the payload map: every suite declares what it reads")

    tests = []
    for src in srcs:
        base = src.split("/")[-1]
        stem = base.replace(".bats", "").replace("-", "_")
        name = "bats_" + stem + "_test"
        sh_test(
            name = name,
            size = "small",
            timeout = "moderate",
            srcs = [runner],
            args = [base],
            data = common_data + [src] + payload[base] + (payload_allow.get(base, []) if payload_allow else []),
            tags = [
                "local",
                "no-sandbox",
            ],
            visibility = ["//visibility:public"],
        )
        tests.append(":" + name)
    native.test_suite(
        name = "bats",
        tests = tests,
        visibility = ["//visibility:public"],
    )
