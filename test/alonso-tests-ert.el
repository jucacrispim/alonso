;;; alonso-tests-ert.el --- ERT runner for the alonso test suite (migration scaffold)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Parallel ERT runner introduced in Phase 0 of the test-suite migration to
;; ERT (see ERT-MIGRATION.md).  It is a *scaffold*: it does not replace
;; `alonso-tests.el' yet.  During the migration each test file progressively
;; grows `ert-deftest's (one per assertion) while keeping the legacy
;; load-time `alonso-tests--assert' calls until its own phase converts it.
;;
;; Because the not-yet-converted files still run their assertions as a side
;; effect of being loaded, requiring them here also performs those checks.
;; The converted files contribute `ert-deftest's, which are collected and run
;; by `ert-run-tests-batch-and-exit'.
;;
;; Run with:
;;   emacs -Q --batch -l ~/mysrc/alonso/test/alonso-tests-ert.el
;;
;; Once every file is converted (Phase 6) this runner replaces the legacy
;; `alonso-tests.el'.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))

(require 'alonso-tests-lib)

;; Loading a test file registers its `ert-deftest's.  Files not yet converted
;; also run their load-time assertions here (side effect), reporting through
;; the legacy counters.
(require 'alonso-client-tests)
(require 'alonso-ui-tests)
(require 'alonso-tools-tests)
(require 'alonso-markdown-tests)
(require 'alonso-image-tests)

;;; Run

;; Report the legacy counters too, so unconverted files stay visible while the
;; migration is in progress.
(princ (format "\n[legacy] %d passed, %d failed\n"
               alonso-tests--pass alonso-tests--fail))

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; alonso-tests-ert.el ends here
