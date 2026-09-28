;;; tagarela-tests.el --- Runner for the tagarela test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -l ~/mysrc/tagarela/test/tagarela-tests.el
;;
;; Loads every tagarela test file and exits with status 0 if all tests pass,
;; 1 otherwise.  The test files themselves are plain Emacs Lisp that run
;; `tagarela-tests--assert' as they are loaded (see tagarela-tests-lib.el).

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))

(require 'tagarela-tests-lib)
(require 'tagarela-client-tests)
(require 'tagarela-ui-tests)
(require 'tagarela-tools-tests)
(require 'tagarela-markdown-tests)
(require 'tagarela-image-tests)

;;; Summary

(princ (format "\n%d passed, %d failed\n"
               tagarela-tests--pass tagarela-tests--fail))
(when noninteractive
  (kill-emacs (if (zerop tagarela-tests--fail) 0 1)))

;;; tagarela-tests.el ends here
