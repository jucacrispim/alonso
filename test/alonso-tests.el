;;; alonso-tests.el --- ERT runner for the alonso test suite  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Juca Crispim <juca@poraodojuca.dev>
;;
;; This file is part of alonso.
;;
;; alonso is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; alonso is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with alonso.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -l ~/mysrc/alonso/test/alonso-tests.el
;;
;; Loads every alonso test file (which define `ert-deftest's, see
;; alonso-tests-lib.el for the shared helpers) and runs them, exiting with
;; status 0 if all tests pass and 1 otherwise.
;;
;; Run a subset by loading only the wanted file(s) and selecting with ERT, e.g.
;;   emacs -Q --batch -L test -l alonso-tests-lib.el -l alonso-ui-tests.el \
;;     --eval '(ert-run-tests-batch-and-exit (quote (tag ui)))'
;; or interactively: M-x ert RET ui RET.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))

(require 'ert)
(require 'alonso-tests-lib)
(require 'alonso-client-tests)
(require 'alonso-ui-tests)
(require 'alonso-tools-tests)
(require 'alonso-markdown-tests)
(require 'alonso-image-tests)

;;; Run

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; alonso-tests.el ends here
