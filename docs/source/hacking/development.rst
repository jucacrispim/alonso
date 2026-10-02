Development
===========

The project uses **Eldev** to manage dependencies and to run the tests,
coverage and linters.  Install the ``eldev`` script once — the official
installer drops it in ``~/.local/bin/eldev``::

   curl -fsSL https://raw.githubusercontent.com/emacs-eldev/eldev/master/webinstall/eldev | sh

Dependencies
------------

* **Runtime** dependencies live in the ``Package-Requires:`` header of
  ``alonso.el`` (``emacs``, ``transient``).  That header is what **Eldev**
  reads (and what **MELPA** reads when it builds the package) — there is no
  other source.
* **Test/coverage** dependencies — ``undercover`` (with its own ``dash`` and
  ``shut-up``) — are **not** runtime dependencies, so they do **not** go into
  ``Package-Requires:``.  They are declared in the ``Eldev`` file::

      (eldev-add-extra-dependencies 'test 'undercover)

  That way ``eldev deps test``, ``eldev test`` and ``eldev coverage`` install
  everything on their own, in Eldev's cache (``~/.cache/eldev``), without
  polluting the package.

Commands
--------

::

   eldev test                 # the ERT suite
   eldev test-ert '(tag ui)'  # only the UI-tagged tests
   eldev lint                 # checkdoc + package-lint + relint
   eldev coverage             # run under undercover and print the coverage
   eldev deps                 # install/refresh the dependencies

The same, through the ``Makefile``: ``make test``, ``make test-ui``,
``make lint``, ``make coverage``, ``make deps``, ``make clean``.

.. note::

   The standalone runner ``emacs -Q --batch -l test/alonso-tests.el`` is
   **not** used by Eldev: it calls ``ert-run-tests-batch-and-exit`` and would
   terminate the Eldev process.  That is why ``eldev-test-fileset`` lists the
   five test files, without the runner or ``alonso-tests-lib.el``.

Linting
-------

``eldev lint`` runs the same checks MELPA runs when building the package:

* ``doc`` — checkdoc (docstring style).
* ``package`` — package-lint (package metadata / conventions).
* ``re`` — relint (regexp linting).

The ``re`` linter ships only in **GNU ELPA**, so the ``Eldev`` file enables
that archive (``(eldev-use-package-archive 'gnu)``) alongside MELPA — without
it, the ``re`` linter is silently skipped.  ``make lint`` is the same command.

Coverage
--------

The ``coverage`` command (defined in the ``Eldev`` file) turns on
``undercover``, instruments ``alonso*.el`` (excluding ``test/``), runs the
suite and emits the report.  Environment variables:

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Variable
     - Effect
   * - ``COVERAGE_FORMAT``
     - ``text`` (default), ``lcov``, ``coveralls``, ``codecov`` or ``simplecov``.
   * - ``COVERAGE_FILE``
     - where to write the report (default ``coverage.txt``).
   * - ``COVERAGE_MIN``
     - when set, **fail** (exit 1) below that overall percentage.

Examples::

   make coverage                                   # text
   make coverage-lcov                              # coverage/lcov.info
   COVERAGE_MIN=75 make coverage                   # coverage gate

CI
--

A minimal pipeline:

::

   eldev deps test    # install runtime + test deps
   eldev lint         # the same checks MELPA runs when building
   eldev test         # the ERT suite, exit code 0/1
   eldev coverage     # (optional) report; use COVERAGE_MIN for the gate
