# Convenience wrapper around Eldev.  Eldev has its own dependency management,
# so a plain `make` target is all most workflows need:
#
#   make            # same as `make test`
#   make test       # run the ERT suite
#   make test-ui    # run only the `ui'-tagged tests
#   make coverage   # run the suite under undercover and print line coverage
#   make deps       # install/refresh dependencies (runtime + test) in eldev's cache
#   make clean      # remove build/coverage artifacts
#
# Requires the `eldev' script on PATH (see the Development section of
# test/ERT-MIGRATION.md).

ELDEV ?= eldev

# Minimum overall line coverage enforced by `make coverage': the target fails
# when the suite drops below it.  Defaults to 100% (the project is fully
# covered); override for a looser local run, e.g.
#   make coverage COVERAGE_MIN=90
# Eldev reads this from the environment (its `eldev-coverage' command).
COVERAGE_MIN ?= 100
export COVERAGE_MIN

.PHONY: all test test-ui coverage coverage-lcov deps clean

all: test

test:
	$(ELDEV) test

# Only the window/UI tests (the largest group):
test-ui:
	$(ELDEV) test-ert '(tag ui)'

# Line coverage, gated at COVERAGE_MIN (default 100%).  Override the
# format/path/threshold via the environment, e.g.
#   make coverage COVERAGE_MIN=90
#   make coverage COVERAGE_FORMAT=coveralls COVERAGE_FILE=coverage/lcov.info
coverage:
	$(ELDEV) coverage

coverage-lcov:
	COVERAGE_FORMAT=lcov COVERAGE_FILE=coverage/lcov.info $(ELDEV) coverage

deps:
	$(ELDEV) deps

clean:
	$(ELDEV) clean
	rm -rf coverage.txt coverage/
