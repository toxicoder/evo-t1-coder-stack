# The only command entry point a rendered project has.
RUNNER := tests/run.sh

.PHONY: help test lint doctor
help:
	@printf '## test   - run every lane present in this checkout\n'
	@printf '## doctor - prove the toolchain the present lanes need is installed\n'

test:
	@bash $(RUNNER)

lint:
	@bash $(RUNNER) --list

doctor:
	@printf 'ok: doctor (fixture)\n'
