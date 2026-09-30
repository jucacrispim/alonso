# Convenience wrapper around Eldev.  Eldev has its own dependency management,
# so a plain `make` target is all most workflows need:
#
#   make            # same as `make test`
#   make test       # run the ERT suite (all 282 tests)
#   make test-ui    # run only the `ui'-tagged tests
#   make coverage   # run the suite under undercover and print line coverage
#   make deps       # install/refresh dependencies (runtime + test) in eldev's cache
#   make clean      # remove build/coverage artifacts
#
# Requires the `eldev' script on PATH (see the Development section of
# test/ERT-MIGRATION.md).

ELDEV ?= eldev

.PHONY: all test test-ui coverage coverage-lcov deps clean

all: test

test:
	$(ELDEV) test

# Only the window/UI tests (the largest group):
test-ui:
	$(ELDEV) test-ert '(tag ui)'

# Line coverage.  Override the format/path/threshold via environment, e.g.
#   make coverage COVERAGE_MIN=80
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
