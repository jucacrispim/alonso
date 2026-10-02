;;; alonso-tests-lib.el --- Shared helpers for the alonso test suite  -*- lexical-binding: t; -*-

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

;; Shared helpers for the alonso ERT test suite: the
;; `declare-function'/`defvar' forward declarations for everything under test,
;; and the helpers that more than one test file uses (the Markdown rendering
;; helpers).  Every test file `(require 'alonso-tests-lib)'; the runner
;; `alonso-tests.el' loads them all and runs them with ERT.

;;; Code:

;;; Code:

(require 'cl-lib)
(require 'ert)

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
(declare-function alonso--thinking-placeholder-active-p "alonso")
(declare-function alonso--thinking-placeholder-start "alonso")
(declare-function alonso--thinking-placeholder-end "alonso")
(declare-function alonso--thinking-placeholder-tick "alonso")
(declare-function alonso--thinking-placeholder-frame "alonso")
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
(declare-function alonso--insert-propertized-at "alonso")
(declare-function alonso--apply-project-dir-locals "alonso")
(declare-function alonso--handle-slash-command "alonso")
(declare-function alonso-prompt "alonso")
(declare-function alonso-cancel "alonso")
(declare-function alonso-set-cwd "alonso")
(declare-function alonso-set-provider "alonso")
(declare-function alonso-set-model "alonso")
(declare-function alonso-set-thinking "alonso")
(declare-function alonso-toggle-show-thinking "alonso")
(declare-function alonso-set-reasoning-effort "alonso")
(declare-function alonso-set-knowledge-bases "alonso")
(declare-function alonso-quit "alonso")
(declare-function alonso-restart "alonso")
(declare-function alonso--ask-user-trust "alonso")
(declare-function alonso--trust-class-key "alonso")
(declare-function alonso--class-prefix-p "alonso")
(declare-function alonso--trusted-p "alonso")
(declare-function alonso--trust-record "alonso")
(declare-function alonso--trust-pause "alonso")
(declare-function alonso--trust-finish "alonso")
(declare-function alonso--trust-description "alonso")
(declare-function alonso--cancel-confirm "alonso")
(defvar alonso--menu-answered)
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
(declare-function alonso--image-bytes "alonso")
(declare-function alonso-open-link "alonso")
(declare-function alonso--open-link-mouse "alonso")
(declare-function alonso--md-line-end "alonso")
(declare-function alonso--on-files-changed "alonso")
(declare-function alonso--buffer-collect "alonso")
(declare-function alonso--buffer-collect-segments "alonso")
(declare-function alonso--prompt-echo-body "alonso")
(declare-function alonso-send-input "alonso")
;; Client transport / process / tools.
(declare-function alonso--send "alonso")
(declare-function alonso--process-sentinel "alonso")
(declare-function alonso--handle-line "alonso")
(declare-function alonso--on-tool-call "alonso")
(declare-function alonso--on-error "alonso")
(declare-function alonso--on-cancelled "alonso")
(declare-function alonso--on-usage-delta "alonso")
(declare-function alonso--on-hook-action "alonso")
(declare-function alonso--schedule-confirm "alonso")
(declare-function alonso--tool-proc-filter "alonso")
(declare-function alonso--tool-shell-async "alonso")
(declare-function alonso--tool-grep-async "alonso")
(declare-function alonso--kill-tool-procs "alonso")
(declare-function alonso--execute-tool "alonso")
(declare-function alonso--resolve-command "alonso")
(declare-function alonso--start-process "alonso")
(declare-function alonso--ensure-ready "alonso")
(declare-function alonso--hval "alonso")
(defvar alonso-model)
(defvar alonso-provider)
(defvar alonso-onnxruntime-lib)
(defvar alonso-confirm-tools)
(defvar alonso-process)
(defvar alonso-pending-tools)
(defvar alonso-in-turn)
(defvar alonso-thinking)
(defvar alonso-reasoning-effort)
(defvar alonso-logfile)
(defvar alonso-aggressive-prune)
(defvar alonso-prune)
(defvar alonso-request-provider)
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
(defvar alonso-files-changed-hook)
(defvar alonso--answer-start)
(defvar alonso--turn-answer-start)
(defvar alonso-render-markdown)
(defvar alonso-hide-markdown-markers)
(defvar alonso-image-max-width)
(defvar alonso-thinking-placeholder)
(defvar alonso--thinking-placeholder-overlay)
(defvar alonso-display-other-buffers-in-pair)
(defvar alonso--pair-restore)

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
