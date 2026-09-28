;;; tagarela-tests-lib.el --- Shared helpers for the tagarela test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared helpers for the tagarela test suite: the mini assert/reporting
;; machinery (`tagarela-tests--assert' and the pass/fail counters), the
;; `declare-function'/`defvar' forward declarations for everything under test,
;; and the helpers that more than one test file uses (the Markdown rendering
;; helpers).  Every test file `(require 'tagarela-tests-lib)'; the runner
;; `tagarela-tests.el' loads them all and prints the summary.

;;; Code:

;;; Code:

(require 'cl-lib)

(load-file (expand-file-name "../tagarela.el"
                             (file-name-directory load-file-name)))

;; Declare the functions from tagarela.el (loaded at runtime) so the
;; byte-compiler knows them.
(declare-function tagarela--json-object "tagarela")
(declare-function tagarela--json-plist-to-hash "tagarela")
(declare-function tagarela--process-filter "tagarela")
(declare-function tagarela--tool-read "tagarela")
(declare-function tagarela--tool-write "tagarela")
(declare-function tagarela--tool-search-replace "tagarela")
(declare-function tagarela--tool-glob "tagarela")
(declare-function tagarela--tool-read-only-p "tagarela")
(declare-function tagarela--reset-session "tagarela")
(declare-function tagarela--record-tool-confirmation "tagarela")
(declare-function tagarela--keep-question-visible "tagarela")
(declare-function tagarela--show-tool-call "tagarela")
(declare-function tagarela--on-turn-end "tagarela")
(declare-function tagarela--on-hook-action "tagarela")
(declare-function tagarela--on-chunk "tagarela")
(declare-function tagarela--on-thinking "tagarela")
(declare-function tagarela--prompt-send "tagarela")
(declare-function tagarela--hook-send "tagarela")
(declare-function tagarela--mode-line-status "tagarela")
(declare-function tagarela--spinner-tick "tagarela")
(declare-function tagarela--start-spinner "tagarela")
(declare-function tagarela--stop-spinner "tagarela")
(declare-function tagarela--mode-line-session "tagarela")
(declare-function tagarela--setup-input-mode-line "tagarela")
(declare-function tagarela--prompt-params "tagarela")
(declare-function tagarela--request-annotation "tagarela")
(declare-function tagarela--mode-line-request "tagarela")
(declare-function tagarela--start-args "tagarela")
(declare-function tagarela--confirm-question "tagarela")
(declare-function tagarela--tool-icon "tagarela")
(declare-function tagarela--confirm-pending "tagarela")
(declare-function tagarela--confirm-next "tagarela")
(declare-function tagarela--confirm-ask "tagarela")
(declare-function tagarela--confirm-answer "tagarela")
(declare-function tagarela--confirm-trust "tagarela")
(declare-function tagarela--menu-exit-hook "tagarela")
(declare-function tagarela--trust-cancel "tagarela")
(declare-function tagarela--confirm-menu "tagarela")
(declare-function tagarela--confirm-menu-question "tagarela")
(declare-function tagarela--confirm-run "tagarela")
(declare-function tagarela--confirm-deny "tagarela")
(declare-function tagarela--dispatch-tool "tagarela")
(declare-function tagarela--dispatch-tool-guarded "tagarela")
(declare-function tagarela--send-tool-result "tagarela")
(declare-function tagarela--insert-propertized "tagarela")
(declare-function tagarela--ask-user-trust "tagarela")
(declare-function tagarela--trust-class-key "tagarela")
(declare-function tagarela--class-prefix-p "tagarela")
(declare-function tagarela--trusted-p "tagarela")
(declare-function tagarela--trust-record "tagarela")
(declare-function tagarela--trust-pause "tagarela")
(declare-function tagarela--trust-finish "tagarela")
(declare-function tagarela--render-markdown-region "tagarela")
(declare-function tagarela--render-answer "tagarela")
(declare-function tagarela--answer-begin "tagarela")
(declare-function tagarela--image-json "tagarela")
(declare-function tagarela--images-json "tagarela")
(declare-function tagarela--image-string "tagarela")
(declare-function tagarela--insert-image "tagarela")
(declare-function tagarela--yank-media-image "tagarela")
(declare-function tagarela--image-mime-rank "tagarela")
(declare-function tagarela--clipboard-image "tagarela")
(declare-function tagarela-yank "tagarela")
(declare-function tagarela-attach-image-file "tagarela")
(declare-function tagarela-attach-image-url "tagarela")
(declare-function tagarela--buffer-collect "tagarela")
(declare-function tagarela--buffer-collect-segments "tagarela")
(declare-function tagarela--prompt-echo-body "tagarela")
(declare-function tagarela-send-input "tagarela")
(defvar tagarela-model)
(defvar tagarela-thinking)
(defvar tagarela-reasoning-effort)
(defvar tagarela-logfile)
(defvar tagarela-aggressive-prune)
(defvar tagarela-prune)
(defvar tagarela-request-model)
(defvar tagarela-request-thinking)
(defvar tagarela-request-reasoning-effort)
(defvar tagarela-ready)
(defvar tagarela--thinking-separator-pending)
(defvar tagarela--after-tool-separator-pending)
(defvar tagarela-line-buffer)
(defvar tagarela-session-input-tokens)
(defvar tagarela-session-output-tokens)
(defvar tagarela-session-cache-hit-tokens)
(defvar tagarela-session-cache-miss-tokens)
(defvar tagarela-session-model)
(defvar tagarela--tool-call-pos)
(defvar tagarela--tool-confirm-pos)
(defvar tagarela--confirm-queue)
(defvar tagarela--confirm-timer)
(defvar tagarela--confirm-context)
(defvar tagarela--trust-specific)
(defvar tagarela--trust-class)
(defvar tagarela--trust-all)
(defvar tagarela--trust-context)
(defvar tagarela--tool-procs)
(defvar tagarela--answer-start)
(defvar tagarela-render-markdown)
(defvar tagarela-hide-markdown-markers)
(defvar tagarela-image-max-width)

(defvar tagarela-tests--pass 0)
(defvar tagarela-tests--fail 0)

(defun tagarela-tests--assert (label condition)
  "Report the result of CONDITION under LABEL."
  (if condition
      (progn (setq tagarela-tests--pass (1+ tagarela-tests--pass))
             (princ (format "PASS: %s\n" label)))
    (setq tagarela-tests--fail (1+ tagarela-tests--fail))
    (princ (format "FAIL: %s\n" label))))

(defmacro tagarela-tests--with-rendered (text &rest body)
  "Eval BODY in a temp buffer containing TEXT rendered as Markdown."
  (declare (indent 1) (debug t))
  `(let ((pdj-lb-md-buf (generate-new-buffer " *pdj-lb-md-test*")))
     (unwind-protect
         (with-current-buffer pdj-lb-md-buf
           (insert ,text)
           (tagarela--render-markdown-region (point-min) (point-max))
           ,@body)
       (kill-buffer pdj-lb-md-buf))))

(defun tagarela-tests--md-pos (text)
  "Return the position of the first occurrence of TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward text nil t)
      (match-beginning 0))))

(defun tagarela-tests--md-face (text)
  "Return the `face' property of the first occurrence of TEXT in the buffer."
  (get-text-property (tagarela-tests--md-pos text) 'face))

(defun tagarela-tests--md-display (text)
  "Return the `display' property of the first occurrence of TEXT."
  (get-text-property (tagarela-tests--md-pos text) 'display))

(defun tagarela-tests--md-prop (text prop)
  "Return PROP of the first occurrence of TEXT in the buffer."
  (get-text-property (tagarela-tests--md-pos text) prop))

(defun tagarela-tests--md-faces (text)
  "Return the `face' of the first occurrence of TEXT, always as a list.
A single face is wrapped in a one-element list so tests can use `memq'."
  (let ((f (tagarela-tests--md-face text)))
    (cond ((null f) nil)
          ((listp f) f)
          (t (list f)))))
(provide 'tagarela-tests-lib)

;;; tagarela-tests-lib.el ends here
