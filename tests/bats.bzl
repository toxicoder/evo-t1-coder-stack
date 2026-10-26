"""Helpers to declare one hermetic Bats sh_test per suite file."""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

def bats_file_tests(srcs, common_data, runner, extra_data = None):
    """Declare bats_<stem>_test sh_test targets and a bats test_suite.

    Args:
        srcs: labels of bats/*.bats files.
        common_data: shared runfiles (helper, bats-core, scripts).
        runner: exec_shell launcher label whose runfiles include bats_runner.sh.
        extra_data: optional dict of suite basename -> extra runfiles labels. A
            suite that reads a payload outside the shared set needs it named
            here, or it skips under its own target and only runs inside
            //tests:shell_coverage, which carries the whole tree.
    """
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
            data = common_data + [src] + (extra_data.get(base, []) if extra_data else []),
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
