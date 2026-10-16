# evo-t1-coder-stack — Bazel-primary with Make compatibility shims.
#
# Preferred:
#   bazelisk test //:test-fast
#   bazelisk test //:lint --test_tag_filters=manual
#   bazelisk run //:validate
#   bazelisk run //:fix
#   bazelisk run //scripts:<stem> -- <args>
#
# This Makefile exists for muscle memory. Every target delegates to Bazelisk:
# nothing here runs a script by path. scripts/setup-host.sh is the one script
# the repo documents for direct shell use, and it runs before Bazel exists.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

BAZEL := $(shell command -v bazelisk 2>/dev/null || command -v bazel 2>/dev/null || echo "")

# Compose project the dev-stack shims address. Compose keeps one project per name,
# so an override here addresses a different stack: `PROJECT=evo-t1-coder-stack`
# names the stable one (the checkout folder's name), and dev-stack then reads the
# port numbers from .env instead of dev-stack.env.
PROJECT ?= evo-t1-dev

# Compose project the prod-stack shims address: the stable stack, on default
# ports and with no env file (override PROD_PROJECT to address a stack brought
# up under another project name, e.g. evo-t1-coder-stack for a hand-raised one).
PROD_PROJECT ?= evo-t1-prod

# Extra argv handed to the two shims that need some (ARGS="--dry-run" plus the
# positional). Leave empty for everything else.
ARGS ?=

.PHONY: help test bats lint fmt fix validate bootstrap stack-up stack-down stack-status \
stack-logs stack-reset prod-stack-up prod-stack-down prod-stack-status prod-stack-logs \
prod-stack-reset new-workspace models spark-configure spark-verify

help:
	@echo "evo-t1-coder-stack (Bazel primary)"
	@echo ""
	@echo "  bazelisk test //:test-fast"
	@echo "  bazelisk test //:lint --test_tag_filters=manual"
	@echo "  bazelisk run //:validate"
	@echo "  bazelisk run //:fix"
	@echo "  bazelisk run //scripts:dev-stack -- up|down|status|logs|reset"
	@echo "  bazelisk run //scripts:prod-stack -- up|down|status|logs|reset"
	@echo ""
	@echo "  make test | make bats | make lint | make fix | make validate"
	@echo "  make stack-up | stack-down | stack-status | stack-logs | stack-reset  (PROJECT=evo-t1-dev;"
	@echo "    set PROJECT=evo-t1-coder-stack to address the stable stack instead)"
	@echo "  make prod-stack-up | prod-stack-down | prod-stack-status | prod-stack-logs | prod-stack-reset"
	@echo "    (PROD_PROJECT=evo-t1-prod: the stable stack, on default ports)"
	@echo "  make bootstrap | make models | make spark-verify | make spark-configure"
	@echo "  make new-workspace ARGS=\"https://host/org/repo.git\"  (ARGS is argv, not a make flag)"
	@echo ""
	@echo "  One Bazel target per script: bazelisk run //scripts:<stem> -- <args>"

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

# ---- first-boot and the fleet/stack CLIs, still Bazel targets -------------

bootstrap:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:bootstrap

stack-up:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:dev-stack -- up --project-name $(PROJECT)

stack-down:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:dev-stack -- down --project-name $(PROJECT)

stack-status:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:dev-stack -- status --project-name $(PROJECT)

stack-logs:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:dev-stack -- logs --project-name $(PROJECT) $(ARGS)

stack-reset:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:dev-stack -- reset --project-name $(PROJECT)

prod-stack-up:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:prod-stack -- up --project-name $(PROD_PROJECT)

prod-stack-down:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:prod-stack -- down --project-name $(PROD_PROJECT)

prod-stack-status:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:prod-stack -- status --project-name $(PROD_PROJECT)

prod-stack-logs:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:prod-stack -- logs --project-name $(PROD_PROJECT) $(ARGS)

prod-stack-reset:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:prod-stack -- reset --project-name $(PROD_PROJECT)

new-workspace:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:new-workspace -- $(ARGS)

models:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:pull-models

spark-configure:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:spark-configure -- $(ARGS)

spark-verify:
	@if [ -z "$(BAZEL)" ]; then echo "bazelisk is required" >&2; exit 1; fi
	$(BAZEL) run //scripts:spark-verify -- --no-tests
