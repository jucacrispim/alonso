;;; alonso-tests.el --- Runner for the alonso test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -l ~/mysrc/alonso/test/alonso-tests.el
;;
;; Loads every alonso test file and exits with status 0 if all tests pass,
;; 1 otherwise.  The test files themselves are plain Emacs Lisp that run
;; `alonso-tests--assert' as they are loaded (see alonso-tests-lib.el).

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))

(require 'alonso-tests-lib)
(require 'alonso-client-tests)
(require 'alonso-ui-tests)
(require 'alonso-tools-tests)
(require 'alonso-markdown-tests)
(require 'alonso-image-tests)

;;; Summary

(princ (format "\n%d passed, %d failed\n"
               alonso-tests--pass alonso-tests--fail))
(when noninteractive
  (kill-emacs (if (zerop alonso-tests--fail) 0 1)))

;;; alonso-tests.el ends here
