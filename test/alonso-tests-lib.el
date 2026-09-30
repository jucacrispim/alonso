;;; alonso-tests-lib.el --- Shared helpers for the alonso test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared helpers for the alonso test suite: the mini assert/reporting
;; machinery (`alonso-tests--assert' and the pass/fail counters), the
;; `declare-function'/`defvar' forward declarations for everything under test,
;; and the helpers that more than one test file uses (the Markdown rendering
;; helpers).  Every test file `(require 'alonso-tests-lib)'; the runner
;; `alonso-tests.el' loads them all and prints the summary.

;;; Code:

;;; Code:

(require 'cl-lib)

(load-file (expand-file-name "../alonso.el"
                             (file-name-directory load-file-name)))

;; Declare the functions from alonso.el (loaded at runtime) so the
;; byte-compiler knows them.
(declare-function alonso--json-object "alonso")
(declare-function alonso--json-plist-to-hash "alonso")
(declare-function alonso--process-filter "alonso")
(declare-function alonso--tool-read "alonso")
(declare-function alonso--tool-write "alonso")
(declare-function alonso--tool-search-replace "alonso")
(declare-function alonso--tool-glob "alonso")
(declare-function alonso--tool-read-only-p "alonso")
(declare-function alonso--reset-session "alonso")
(declare-function alonso--record-tool-confirmation "alonso")
(declare-function alonso--keep-question-visible "alonso")
(declare-function alonso--show-tool-call "alonso")
(declare-function alonso--on-turn-end "alonso")
(declare-function alonso--on-hook-action "alonso")
(declare-function alonso--on-chunk "alonso")
(declare-function alonso--on-thinking "alonso")
(declare-function alonso--prompt-send "alonso")
(declare-function alonso--hook-send "alonso")
(declare-function alonso--mode-line-status "alonso")
(declare-function alonso--spinner-tick "alonso")
(declare-function alonso--start-spinner "alonso")
(declare-function alonso--stop-spinner "alonso")
(declare-function alonso--mode-line-session "alonso")
(declare-function alonso--mode-line-model "alonso")
(declare-function alonso--setup-input-mode-line "alonso")
(declare-function alonso--prompt-params "alonso")
(declare-function alonso--request-annotation "alonso")
(declare-function alonso--mode-line-request "alonso")
(declare-function alonso--start-args "alonso")
(declare-function alonso--confirm-question "alonso")
(declare-function alonso--tool-icon "alonso")
(declare-function alonso--confirm-pending "alonso")
(declare-function alonso--confirm-next "alonso")
(declare-function alonso--confirm-ask "alonso")
(declare-function alonso--confirm-answer "alonso")
(declare-function alonso--confirm-trust "alonso")
(declare-function alonso--menu-exit-hook "alonso")
(declare-function alonso--trust-cancel "alonso")
(declare-function alonso--confirm-menu "alonso")
(declare-function alonso--confirm-menu-question "alonso")
(declare-function alonso--confirm-run "alonso")
(declare-function alonso--confirm-deny "alonso")
(declare-function alonso--dispatch-tool "alonso")
(declare-function alonso--dispatch-tool-guarded "alonso")
(declare-function alonso--send-tool-result "alonso")
(declare-function alonso--insert-propertized "alonso")
(declare-function alonso--ask-user-trust "alonso")
(declare-function alonso--trust-class-key "alonso")
(declare-function alonso--class-prefix-p "alonso")
(declare-function alonso--trusted-p "alonso")
(declare-function alonso--trust-record "alonso")
(declare-function alonso--trust-pause "alonso")
(declare-function alonso--trust-finish "alonso")
(declare-function alonso--render-markdown-region "alonso")
(declare-function alonso--render-answer "alonso")
(declare-function alonso--answer-begin "alonso")
(declare-function alonso--show-answer-start "alonso")
(declare-function alonso--pin-window-to-end "alonso")
(declare-function alonso--pair-window-parent "alonso")
(declare-function alonso--make-windows-atomic "alonso")
(declare-function alonso--close-pair-windows "alonso")
(declare-function alonso--on-pair-buffer-killed "alonso")
(declare-function alonso--pair-takeover-window "alonso")
(declare-function alonso--pair-window-takeover-p "alonso")
(declare-function alonso--display-in-pair-window "alonso")
(declare-function alonso--pair-restore "alonso")
(declare-function alonso--pair-forget "alonso")
(declare-function alonso--after-window-closed "alonso")
(declare-function alonso-open "alonso")
(declare-function alonso--image-json "alonso")
(declare-function alonso--images-json "alonso")
(declare-function alonso--image-string "alonso")
(declare-function alonso--insert-image "alonso")
(declare-function alonso--yank-media-image "alonso")
(declare-function alonso--image-mime-rank "alonso")
(declare-function alonso--clipboard-image "alonso")
(declare-function alonso-yank "alonso")
(declare-function alonso-attach-image-file "alonso")
(declare-function alonso-attach-image-url "alonso")
(declare-function alonso--buffer-collect "alonso")
(declare-function alonso--buffer-collect-segments "alonso")
(declare-function alonso--prompt-echo-body "alonso")
(declare-function alonso-send-input "alonso")
(defvar alonso-model)
(defvar alonso-thinking)
(defvar alonso-reasoning-effort)
(defvar alonso-logfile)
(defvar alonso-aggressive-prune)
(defvar alonso-prune)
(defvar alonso-request-model)
(defvar alonso-request-thinking)
(defvar alonso-request-reasoning-effort)
(defvar alonso-ready)
(defvar alonso--thinking-separator-pending)
(defvar alonso--after-tool-separator-pending)
(defvar alonso-line-buffer)
(defvar alonso-session-input-tokens)
(defvar alonso-session-output-tokens)
(defvar alonso-session-cache-hit-tokens)
(defvar alonso-session-cache-miss-tokens)
(defvar alonso-session-model)
(defvar alonso--tool-call-pos)
(defvar alonso--tool-confirm-pos)
(defvar alonso--confirm-queue)
(defvar alonso--confirm-timer)
(defvar alonso--confirm-context)
(defvar alonso--trust-specific)
(defvar alonso--trust-class)
(defvar alonso--trust-all)
(defvar alonso--trust-context)
(defvar alonso--tool-procs)
(defvar alonso--answer-start)
(defvar alonso--turn-answer-start)
(defvar alonso-render-markdown)
(defvar alonso-hide-markdown-markers)
(defvar alonso-image-max-width)
(defvar alonso-display-other-buffers-in-pair)
(defvar alonso--pair-restore)

(defvar alonso-tests--pass 0)
(defvar alonso-tests--fail 0)

(defun alonso-tests--assert (label condition)
  "Report the result of CONDITION under LABEL."
  (if condition
      (progn (setq alonso-tests--pass (1+ alonso-tests--pass))
             (princ (format "PASS: %s\n" label)))
    (setq alonso-tests--fail (1+ alonso-tests--fail))
    (princ (format "FAIL: %s\n" label))))

(defmacro alonso-tests--with-rendered (text &rest body)
  "Eval BODY in a temp buffer containing TEXT rendered as Markdown."
  (declare (indent 1) (debug t))
  `(let ((pdj-lb-md-buf (generate-new-buffer " *pdj-lb-md-test*")))
     (unwind-protect
         (with-current-buffer pdj-lb-md-buf
           (insert ,text)
           (alonso--render-markdown-region (point-min) (point-max))
           ,@body)
       (kill-buffer pdj-lb-md-buf))))

(defun alonso-tests--md-pos (text)
  "Return the position of the first occurrence of TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward text nil t)
      (match-beginning 0))))

(defun alonso-tests--md-face (text)
  "Return the `face' property of the first occurrence of TEXT in the buffer."
  (get-text-property (alonso-tests--md-pos text) 'face))

(defun alonso-tests--md-display (text)
  "Return the `display' property of the first occurrence of TEXT."
  (get-text-property (alonso-tests--md-pos text) 'display))

(defun alonso-tests--md-prop (text prop)
  "Return PROP of the first occurrence of TEXT in the buffer."
  (get-text-property (alonso-tests--md-pos text) prop))

(defun alonso-tests--md-faces (text)
  "Return the `face' of the first occurrence of TEXT, always as a list.
A single face is wrapped in a one-element list so tests can use `memq'."
  (let ((f (alonso-tests--md-face text)))
    (cond ((null f) nil)
          ((listp f) f)
          (t (list f)))))
(provide 'alonso-tests-lib)

;;; alonso-tests-lib.el ends here
