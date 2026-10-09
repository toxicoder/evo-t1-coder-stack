# evo-t1-coder-stack — Bazel-primary with Make compatibility shims.
#
# Preferred:
#   bazelisk test //:test-fast
#   bazelisk test //:lint --test_tag_filters=manual
#   bazelisk run //:validate
#   bazelisk run //:fix
#
# This Makefile exists for muscle memory. Targets delegate to Bazelisk.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

BAZEL := $(shell command -v bazelisk 2>/dev/null || command -v bazel 2>/dev/null || echo "")

.PHONY: help test bats lint fmt fix validate

help:
	@echo "evo-t1-coder-stack (Bazel primary)"
	@echo ""
	@echo "  bazelisk test //:test-fast"
	@echo "  bazelisk test //:lint --test_tag_filters=manual"
	@echo "  bazelisk run //:validate"
	@echo "  bazelisk run //:fix"
	@echo ""
	@echo "  make test | make bats | make lint | make fix | make validate"

test:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) test //:test-fast

bats: test

lint:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) test //:lint --test_tag_filters=manual

fmt: fix

fix:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //:fix

validate:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //:validate
