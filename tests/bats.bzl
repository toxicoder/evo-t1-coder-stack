"""Helpers to declare one hermetic Bats sh_test per suite file."""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

def bats_file_tests(srcs, common_data):
    """Declare bats_<stem>_test sh_test targets and a bats test_suite.

    Args:
        srcs: labels of bats/*.bats files.
        common_data: shared runfiles (helper, bats-core, scripts).
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
            srcs = ["bats_runner.sh"],
            args = [base],
            data = common_data + [src],
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
