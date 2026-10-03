;;; alonso-ui-tests.el --- Tests for the alonso UI shell: session/usage, separators, spinner, project, hooks and the answer glue.  -*- lexical-binding: t; -*-

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

;; Tests for the alonso UI shell: session/usage, separators, spinner, project,
;; hooks and the answer glue.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT: one `ert-deftest' per
;; assertion, all tagged `ui'.  The window/state setup that used to be shared
;; by the assertions in a block is now re-created by a per-scenario helper
;; (each deftest re-runs the prefix it needs), so the tests are order
;; independent.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'ert)
(require 'alonso-tests-lib)

;;; Shared helpers

(defun alonso-ui-tests--conversation-text-from (start)
  "Return the conversation buffer text from START to the end."
  (with-current-buffer (alonso--get-buffer)
    (buffer-substring-no-properties start (point-max))))

(defun alonso-ui-tests--reset-conversation-state ()
  "Empty the conversation buffer and clear the answer/turn state."
  (alonso--thinking-placeholder-end)
  (with-current-buffer (alonso--get-buffer)
    (let ((inhibit-read-only t)) (erase-buffer)))
  (setq alonso--answer-start nil
        alonso--turn-answer-start nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil))

(defun alonso-ui-tests--turn-end-event ()
  "Return a `turn_end' event hash-table (deepseek-chat, 1/1 tokens)."
  (let ((ev (make-hash-table :test 'equal)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "deepseek-chat" ev)
    (puthash "input_tokens" 1 ev)
    (puthash "output_tokens" 1 ev)
    ev))

(defun alonso-ui-tests--accumulate-turns ()
  "Feed two `turn_end' events accumulating session tokens (deepseek-chat)."
  (alonso--reset-session)
  (dolist (turn '((12 8 100 4) (30 15 900 120)))
    (let ((ev (make-hash-table :test 'equal)))
      (puthash "event" "turn_end" ev)
      (puthash "stop_reason" "END_TURN" ev)
      (puthash "model" "deepseek-chat" ev)
      (puthash "input_tokens" (nth 0 turn) ev)
      (puthash "output_tokens" (nth 1 turn) ev)
      (puthash "cache_hit_tokens" (nth 2 turn) ev)
      (puthash "cache_miss_tokens" (nth 3 turn) ev)
      (puthash "total_tokens" (+ (nth 0 turn) (nth 1 turn)) ev)
      (alonso--on-turn-end ev))))

(defun alonso-ui-tests--feed-no-cache-turn ()
  "Feed a `turn_end' from a provider without prompt cache (gemini 5/3)."
  (alonso--reset-session)
  (let ((ev (make-hash-table :test 'equal)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "gemini" ev)
    (puthash "input_tokens" 5 ev)
    (puthash "output_tokens" 3 ev)
    (puthash "cache_hit_tokens" 0 ev)
    (puthash "cache_miss_tokens" 0 ev)
    (alonso--on-turn-end ev)))

(defun alonso-ui-tests--feed-context-turn (pct used window)
  "Feed a `turn_end' (gemini) carrying context usage PCT of USED/WINDOW."
  (alonso--reset-session)
  (let ((ev (make-hash-table :test 'equal)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "gemini" ev)
    (puthash "input_tokens" 5 ev)
    (puthash "output_tokens" 3 ev)
    (puthash "cache_hit_tokens" 0 ev)
    (puthash "cache_miss_tokens" 0 ev)
    (puthash "context_pct" pct ev)
    (puthash "context_tokens" used ev)
    (puthash "context_window" window ev)
    (alonso--on-turn-end ev)))

(defun alonso-ui-tests--setup-input-mode-line-fresh ()
  "Kill the input buffer (if any) and run the mode-line setup for the first open."
  (let ((input (get-buffer "alonso-chat")))
    (when input (kill-buffer input)))
  (alonso--setup-input-mode-line))

(defun alonso-ui-tests--spinner-cleanup ()
  "Stop the spinner and clear the turn/spinner state."
  (ignore-errors (alonso--stop-spinner))
  (setq alonso-in-turn nil
        alonso--spinner-active nil
        alonso--spinner-timer nil))

;; The alonso pair (conversation + input) as two windows, used by the
;; atomic-window and takeover tests.

(defun alonso-tests--pair-layout ()
  "Display the conversation and input buffers as the alonso pair.
Builds a left window plus the conversation (top) and input (bottom) on the
right — the `alonso-open' layout — and makes the pair atomic."
  (let ((left (get-buffer-create "*alonso-tests-left*")))
    (delete-other-windows)
    (switch-to-buffer left)
    (split-window-right)
    (other-window 1)
    (switch-to-buffer (alonso--get-buffer))
    (split-window-below)
    (other-window 1)
    (switch-to-buffer (get-buffer-create alonso-input-buffer-name))
    (alonso--make-windows-atomic)
    (get-buffer-window left)))

(defun alonso-tests--reset-windows ()
  "Return the frame to a single, undedicated, non-atomic window."
  (setq alonso--pair-restore nil)
  (dolist (win (window-list nil 'nomini))
    (ignore-errors (set-window-dedicated-p win nil))
    (set-window-parameter win 'alonso--pair-state nil)
    (let ((parent (window-parent win)))
      (while parent
        (set-window-parameter parent 'window-atom nil)
        (setq parent (window-parent parent)))))
  (delete-other-windows))

(defun alonso-ui-tests--with-pair (fn)
  "Set up the atomic pair layout and call FN with the left window selected."
  (unwind-protect
      (progn (alonso-tests--reset-windows)
             (funcall fn (select-window (alonso-tests--pair-layout))))
    (alonso-tests--reset-windows)))

(defun alonso-ui-tests--open-pair ()
  "Reset the windows and run `alonso-open' (bridge startup stubbed)."
  (alonso-tests--reset-windows)
  (switch-to-buffer (get-buffer-create "*alonso-tests-left*"))
  (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ())))
    (alonso-open)))

;;; Kill hook registered

(ert-deftest alonso-ui--kill-emacs-hook-registered ()
  :tags '(ui)
  (should (memq 'alonso-kill kill-emacs-hook)))

;;; Token formatting — compact counts

(ert-deftest alonso-ui--format-tokens-0 ()
  :tags '(ui)
  (should (equal "0" (alonso--format-tokens 0))))

(ert-deftest alonso-ui--format-tokens-999 ()
  :tags '(ui)
  (should (equal "999" (alonso--format-tokens 999))))

(ert-deftest alonso-ui--format-tokens-1000 ()
  :tags '(ui)
  (should (equal "1k" (alonso--format-tokens 1000))))

(ert-deftest alonso-ui--format-tokens-1500 ()
  :tags '(ui)
  (should (equal "1.5k" (alonso--format-tokens 1500))))

(ert-deftest alonso-ui--format-tokens-2439 ()
  :tags '(ui)
  (should (equal "2.44k" (alonso--format-tokens 2439))))

(ert-deftest alonso-ui--format-tokens-999999 ()
  :tags '(ui)
  (should (equal "1M" (alonso--format-tokens 999999))))

(ert-deftest alonso-ui--format-tokens-1000000 ()
  :tags '(ui)
  (should (equal "1M" (alonso--format-tokens 1000000))))

(ert-deftest alonso-ui--format-tokens-1232432 ()
  :tags '(ui)
  (should (equal "1.23M" (alonso--format-tokens 1232432))))

;;; Session — token accumulation, per-turn summary and input mode-line

(ert-deftest alonso-ui--session-accumulates-sent-received-tokens ()
  :tags '(ui)
  (alonso-ui-tests--accumulate-turns)
  (should (and (= 42 alonso-session-input-tokens)
               (= 23 alonso-session-output-tokens))))

(ert-deftest alonso-ui--session-accumulates-cache-hit-miss-tokens ()
  :tags '(ui)
  (alonso-ui-tests--accumulate-turns)
  (should (and (= 1000 alonso-session-cache-hit-tokens)
               (= 124 alonso-session-cache-miss-tokens))))

(ert-deftest alonso-ui--session-model-comes-from-turn-end ()
  :tags '(ui)
  (alonso-ui-tests--accumulate-turns)
  (should (equal "deepseek-chat" alonso-session-model)))

(ert-deftest alonso-ui--mode-line-session-shows-sent-received-cache ()
  :tags '(ui)
  (alonso-ui-tests--accumulate-turns)
  (should (and (string-match-p "↑42 ↓23 ⚡1k/124" (alonso--mode-line-session))
               (not (string-match-p "deepseek" (alonso--mode-line-session))))))

(ert-deftest alonso-ui--mode-line-model-shows-session-model ()
  :tags '(ui)
  (alonso-ui-tests--accumulate-turns)
  (should (string-match-p "\\[deepseek-chat\\]" (alonso--mode-line-model))))

(ert-deftest alonso-ui--turn-inserts-a-summary ()
  :tags '(ui)
  (alonso-ui-tests--accumulate-turns)
  (should (string-match-p "turn: sent 30, received 15, cache 900/120"
                          (with-current-buffer (alonso--get-buffer)
                            (buffer-string)))))

(ert-deftest alonso-ui--reset-clears-the-session ()
  :tags '(ui)
  (alonso-ui-tests--accumulate-turns)
  (alonso--reset-session)
  (should (and (zerop alonso-session-input-tokens)
               (zerop alonso-session-output-tokens)
               (zerop alonso-session-cache-hit-tokens)
               (zerop alonso-session-cache-miss-tokens)
               (null alonso-session-model))))

;; A provider without prompt cache reports 0 hit / 0 miss: the mode-line must
;; omit the ⚡ fragment entirely (nothing to show).

(ert-deftest alonso-ui--mode-line-omits-cache-fragment-without-cache ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--feed-no-cache-turn)
        (should (and (string-match-p "↑5 ↓3" (alonso--mode-line-session))
                     (not (string-match-p "⚡" (alonso--mode-line-session))))))
    (alonso--reset-session)))

;;; Context usage — dial glyph, percentage and window

(ert-deftest alonso-ui--context-dial-char-fills-with-pct ()
  :tags '(ui)
  (should (and (equal ?○ (alonso--context-dial-char 0))
               (equal ?◔ (alonso--context-dial-char 0.2))
               (equal ?◑ (alonso--context-dial-char 0.4))
               (equal ?◕ (alonso--context-dial-char 0.6))
               (equal ?● (alonso--context-dial-char 0.8))
               (equal ?● (alonso--context-dial-char 1.0)))))

(ert-deftest alonso-ui--format-context-shows-dial-percent-and-window ()
  :tags '(ui)
  (unwind-protect
      (progn
        (setq alonso-session-context-pct 0.42
              alonso-session-context-tokens 420000
              alonso-session-context-window 1000000)
        (should (equal "◑ 42% (420k/1M)" (alonso--format-context))))
    (setq alonso-session-context-pct nil
          alonso-session-context-tokens nil
          alonso-session-context-window nil)))

(ert-deftest alonso-ui--format-context-shows-zero-at-session-start ()
  :tags '(ui)
  (let ((alonso-session-context-pct nil)
        (alonso-session-context-tokens nil)
        (alonso-session-context-window nil))
    (should (equal "○ 0% (0/?)" (alonso--format-context)))))

(ert-deftest alonso-ui--format-context-shows-unknown-window ()
  :tags '(ui)
  (let ((alonso-session-context-pct nil)
        (alonso-session-context-tokens 420000)
        (alonso-session-context-window 0))
    (should (equal "○ 0% (420k/?)" (alonso--format-context)))))

(ert-deftest alonso-ui--mode-line-session-shows-context ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--feed-context-turn 0.42 420000 1000000)
        (should (string-match-p (regexp-quote "◑ 42%% (420k/1M)")
                                (alonso--mode-line-session))))
    (alonso--reset-session)))

(ert-deftest alonso-ui--mode-line-shows-zero-context-without-it ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--accumulate-turns)
        (should (string-match-p (regexp-quote "] ○ 0%% (0/?)")
                                (alonso--mode-line-session))))
    (alonso--reset-session)))

(ert-deftest alonso-ui--turn-summary-omits-session-and-context ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--feed-context-turn 0.42 420000 1000000)
        (let ((buf (with-current-buffer (alonso--get-buffer)
                     (buffer-substring-no-properties (point-min) (point-max)))))
          ;; The summary keeps the model and per-turn token/cache usage...
          (should (string-match-p
                   (regexp-quote "[model=gemini | turn: sent 5, received 3, cache 0/0]")
                   buf))
          ;; ...but drops stop_reason, the session totals and the context.
          (should-not (string-match-p (regexp-quote "stop_reason") buf))
          (should-not (string-match-p (regexp-quote "session:") buf))
          (should-not (string-match-p (regexp-quote "ctx ") buf))))
    (alonso--reset-session)))

(ert-deftest alonso-ui--turn-end-nil-context-shows-zero ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso--reset-session)
        (let ((ev (make-hash-table :test 'equal)))
          (puthash "event" "turn_end" ev)
          (puthash "stop_reason" "END_TURN" ev)
          (puthash "model" "unknown" ev)
          (puthash "input_tokens" 1 ev)
          (puthash "output_tokens" 1 ev)
          (puthash "context_pct" nil ev)
          (puthash "context_window" 0 ev)
          (alonso--on-turn-end ev))
        (should (and (null alonso-session-context-pct)
                     (equal "○ 0% (0/?)" (alonso--format-context)))))
    (alonso--reset-session)))

(ert-deftest alonso-ui--reset-clears-context ()
  :tags '(ui)
  (setq alonso-session-context-pct 0.5
        alonso-session-context-tokens 100
        alonso-session-context-window 200)
  (alonso--reset-session)
  (should (and (null alonso-session-context-pct)
               (null alonso-session-context-tokens)
               (null alonso-session-context-window))))

;;; Usage delta — incremental updates during turn and final turn_end

(ert-deftest alonso-ui--usage-delta-accumulates-incrementally ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso--reset-session)
        (let ((ev (make-hash-table :test 'equal)))
          (puthash "event" "usage_delta" ev)
          (puthash "input_tokens" 10 ev)
          (puthash "output_tokens" 5 ev)
          (puthash "total_tokens" 15 ev)
          (alonso--on-usage-delta ev))
        (should (and (= 10 alonso-session-input-tokens)
                     (= 5 alonso-session-output-tokens))))
    (alonso--reset-session)))

(ert-deftest alonso-ui--turn-end-finalizes-session-tokens ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso--reset-session)
        (let ((ev (make-hash-table :test 'equal)))
          (puthash "event" "usage_delta" ev)
          (puthash "input_tokens" 10 ev)
          (puthash "output_tokens" 5 ev)
          (puthash "total_tokens" 15 ev)
          (alonso--on-usage-delta ev))
        (let ((ev (make-hash-table :test 'equal)))
          (puthash "event" "turn_end" ev)
          (puthash "stop_reason" "END_TURN" ev)
          (puthash "model" "deepseek-chat" ev)
          (puthash "input_tokens" 25 ev)
          (puthash "output_tokens" 12 ev)
          (puthash "total_tokens" 37 ev)
          (alonso--on-turn-end ev))
        (should (and (= 25 alonso-session-input-tokens)
                     (= 12 alonso-session-output-tokens))))
    (alonso--reset-session)))

;;; Regression: first open — the input buffer does not exist yet when the
;;; mode-line setup runs; even so, the request indicator must be installed
;;; and the default constructs (modes + position) stripped.

(ert-deftest alonso-ui--setup-creates-the-input-buffer ()
  :tags '(ui)
  (alonso-ui-tests--setup-input-mode-line-fresh)
  (should (get-buffer "alonso-chat")))

(ert-deftest alonso-ui--setup-installs-request-indicator-on-first-open ()
  :tags '(ui)
  (alonso-ui-tests--setup-input-mode-line-fresh)
  (should (with-current-buffer (get-buffer "alonso-chat")
            (cl-member '(:eval (alonso--mode-line-request))
                       mode-line-misc-info :test #'equal))))

(ert-deftest alonso-ui--setup-strips-modes-construct ()
  :tags '(ui)
  (alonso-ui-tests--setup-input-mode-line-fresh)
  (should (with-current-buffer (get-buffer "alonso-chat")
            (equal mode-line-modes ""))))

(ert-deftest alonso-ui--setup-strips-position ()
  :tags '(ui)
  (alonso-ui-tests--setup-input-mode-line-fresh)
  (should (with-current-buffer (get-buffer "alonso-chat")
            (null mode-line-position))))

(ert-deftest alonso-ui--repeated-setup-does-not-duplicate-indicator ()
  :tags '(ui)
  (alonso-ui-tests--setup-input-mode-line-fresh)
  (alonso--setup-input-mode-line)
  (should (with-current-buffer (get-buffer "alonso-chat")
            (let ((n 0))
              (dolist (el mode-line-misc-info)
                (when (equal el '(:eval (alonso--mode-line-request)))
                  (cl-incf n)))
              (= n 1)))))

;; The conversation bar carries the session token usage, with the
;; status/spinner as the very last fragment.

(ert-deftest alonso-ui--conversation-mode-line-installs-session-indicator ()
  :tags '(ui)
  (with-current-buffer (alonso--get-buffer)
    (should (cl-member '(:eval (alonso--mode-line-session))
                       mode-line-misc-info :test #'equal))))

(ert-deftest alonso-ui--spinner-status-is-last-mode-line-fragment ()
  :tags '(ui)
  (with-current-buffer (alonso--get-buffer)
    (should (equal (car (last mode-line-misc-info))
                   '(:eval (alonso--mode-line-status))))))

;;; Thinking — two-blank-lines separator before the response

(ert-deftest alonso-ui--thinking-marks-pending-separator ()
  :tags '(ui)
  (let ((alonso-show-thinking t))
    (setq alonso--thinking-separator-pending nil)
    (alonso--on-thinking "model reasoning")
    (should alonso--thinking-separator-pending)))

(ert-deftest alonso-ui--first-chunk-clears-pending-separator ()
  :tags '(ui)
  (alonso-ui-tests--reset-conversation-state)
  (alonso--on-thinking "model reasoning")
  (alonso--on-chunk "response")
  (should (not alonso--thinking-separator-pending)))

(ert-deftest alonso-ui--two-blank-lines-between-thinking-and-response ()
  :tags '(ui)
  (let ((alonso-show-thinking t))
    (alonso-ui-tests--reset-conversation-state)
    (let ((start (with-current-buffer (alonso--get-buffer) (point-max))))
      (alonso--on-thinking "model reasoning")
      (alonso--on-chunk "response")
      (alonso--on-chunk " final")
      (should (equal "model reasoning\n\n\nresponse final"
                     (alonso-ui-tests--conversation-text-from start))))))

(ert-deftest alonso-ui--without-thinking-response-goes-straight ()
  :tags '(ui)
  (alonso-ui-tests--reset-conversation-state)
  (let ((start (with-current-buffer (alonso--get-buffer) (point-max))))
    (alonso--on-chunk "direct response")
    (should (equal "direct response"
                   (alonso-ui-tests--conversation-text-from start)))))

;;; Tool → model: two blank lines between the tool output and the model's
;;; next thinking/response

(ert-deftest alonso-ui--tool-confirm-marks-pending-separator ()
  :tags '(ui)
  (setq alonso--after-tool-separator-pending nil)
  (alonso--show-tool-call
   "call_1" "read"
   (alonso--json-plist-to-hash (list "path" "/tmp/x.txt")))
  (alonso--send-tool-confirm "call_1")
  (should alonso--after-tool-separator-pending))

(ert-deftest alonso-ui--thinking-consumes-tool-separator ()
  :tags '(ui)
  (let ((alonso-show-thinking t))
    (setq alonso--after-tool-separator-pending nil)
    (alonso--show-tool-call
     "call_1" "read"
     (alonso--json-plist-to-hash (list "path" "/tmp/x.txt")))
    (alonso--send-tool-confirm "call_1")
    (alonso--on-thinking "post-tool reasoning")
    (should (not alonso--after-tool-separator-pending))))

(ert-deftest alonso-ui--two-blank-lines-between-tool-and-thinking ()
  :tags '(ui)
  (let ((alonso-show-thinking t))
    (alonso-ui-tests--reset-conversation-state)
    (let ((start (with-current-buffer (alonso--get-buffer) (point-max))))
      (alonso--show-tool-call
       "call_1" "read"
       (alonso--json-plist-to-hash (list "path" "/tmp/x.txt")))
      (alonso--send-tool-confirm "call_1")
      (alonso--on-thinking "post-tool reasoning")
      (alonso--on-chunk "post-tool response")
      (should (equal "\n📄 read\n  path:\n    /tmp/x.txt\n\n\npost-tool reasoning\n\n\npost-tool response"
                     (alonso-ui-tests--conversation-text-from start))))))

(ert-deftest alonso-ui--read-only-tool-marks-pending-separator ()
  :tags '(ui)
  (alonso-ui-tests--reset-conversation-state)
  (let ((ev (make-hash-table :test 'equal)))
    (puthash "event" "tool_call" ev)
    (puthash "id" "call_1" ev)
    (puthash "name" "read" ev)
    (puthash "input" (alonso--json-plist-to-hash (list "path" "/tmp/x.txt")) ev)
    (alonso--on-tool-call ev))
  (should alonso--after-tool-separator-pending))

(ert-deftest alonso-ui--two-blank-lines-between-read-only-tool-and-thinking ()
  :tags '(ui)
  (let ((alonso-show-thinking t))
    (alonso-ui-tests--reset-conversation-state)
    (let ((start (with-current-buffer (alonso--get-buffer) (point-max))))
      (let ((ev (make-hash-table :test 'equal)))
        (puthash "event" "tool_call" ev)
        (puthash "id" "call_1" ev)
        (puthash "name" "read" ev)
        (puthash "input" (alonso--json-plist-to-hash (list "path" "/tmp/x.txt")) ev)
        (alonso--on-tool-call ev))
      (alonso--on-thinking "post-tool reasoning")
      (alonso--on-chunk "post-tool response")
      (should (equal "\n📄 read\n  path:\n    /tmp/x.txt\n\n\npost-tool reasoning\n\n\npost-tool response"
                     (alonso-ui-tests--conversation-text-from start))))))

(ert-deftest alonso-ui--tool-to-response-separator-appears-once ()
  :tags '(ui)
  (alonso-ui-tests--reset-conversation-state)
  (let ((start (with-current-buffer (alonso--get-buffer) (point-max))))
    (alonso--show-tool-call
     "call_2" "glob"
     (alonso--json-plist-to-hash (list "pattern" "*.el")))
    (alonso--send-tool-confirm "call_2")
    (alonso--on-chunk "direct post-tool response")
    (alonso--on-chunk " continues")
    (should (equal "\n🔎 glob\n  pattern:\n    *.el\n\n\ndirect post-tool response continues"
                   (alonso-ui-tests--conversation-text-from start)))))

(ert-deftest alonso-ui--turn-end-resets-tool-separator ()
  :tags '(ui)
  (setq alonso--after-tool-separator-pending t)
  (alonso--on-turn-end (alonso-ui-tests--turn-end-event))
  (should (not alonso--after-tool-separator-pending)))

;;; Slash command /project

(defun alonso-ui-tests--with-project-dir (fn)
  "Create a temp dir and call FN with its expanded path; clean up after."
  (let ((tmp-dir (expand-file-name (make-temp-file "pdj-proj-test" t))))
    (unwind-protect
        (funcall fn tmp-dir)
      (ignore-errors (delete-directory tmp-dir t)))))

(defun alonso-ui-tests--run-project (arg)
  "Run `/project' ARG with `alonso--send' stubbed.
Return (RETURN-VALUE METHOD CWD)."
  (let (captured-method captured-cwd ret
        (old (symbol-function 'alonso--send)))
    (unwind-protect
        (progn
          (fset 'alonso--send
                (lambda (m params)
                  (setq captured-method m)
                  (setq captured-cwd (cadr (member "cwd" params)))))
          (setq ret (alonso--handle-slash-command arg)))
      (fset 'alonso--send old))
    (list ret captured-method captured-cwd)))

(ert-deftest alonso-ui--project-sends-set-cwd ()
  :tags '(ui)
  (alonso-ui-tests--with-project-dir
   (lambda (tmp-dir)
     (should (equal "set_cwd" (nth 1 (alonso-ui-tests--run-project
                                      (format "/project %s" tmp-dir))))))))

(ert-deftest alonso-ui--project-returns-t-when-handled ()
  :tags '(ui)
  (alonso-ui-tests--with-project-dir
   (lambda (tmp-dir)
     (should (alonso-ui-tests--run-project (format "/project %s" tmp-dir))))))

(ert-deftest alonso-ui--project-sends-correct-cwd-path ()
  :tags '(ui)
  (alonso-ui-tests--with-project-dir
   (lambda (tmp-dir)
     (let ((res (alonso-ui-tests--run-project (format "/project %s" tmp-dir))))
       (should (equal (file-truename tmp-dir)
                      (file-truename (nth 2 res))))))))

;; `/project' argument resolution.  With `alonso-project-dir' non-nil the
;; argument is a project NAME resolved as BASE/NAME.

(defun alonso-ui-tests--with-project-base (fn)
  "Create BASE with a `tupi' subdir and call FN with (BASE PROJ); clean up."
  (let* ((base (expand-file-name (make-temp-file "alonso-projbase" t)))
         (proj (expand-file-name "tupi" base)))
    (unwind-protect
        (progn (make-directory proj) (funcall fn base proj))
      (ignore-errors (delete-directory base t)))))

(ert-deftest alonso-ui--project-with-project-dir-name-is-handled ()
  :tags '(ui)
  (alonso-ui-tests--with-project-base
   (lambda (base _proj)
     (let ((alonso-project-dir base))
       (should (alonso-ui-tests--run-project "/project tupi"))))))

(ert-deftest alonso-ui--project-with-project-dir-resolves-base-name ()
  :tags '(ui)
  (alonso-ui-tests--with-project-base
   (lambda (base proj)
     (let* ((alonso-project-dir base)
            (res (alonso-ui-tests--run-project "/project tupi")))
       (should (equal (file-truename proj)
                      (file-truename (nth 2 res))))))))

;; With `alonso-project-dir' nil the argument is a path relative to
;; `default-directory'.

(ert-deftest alonso-ui--project-nil-resolves-against-default-directory ()
  :tags '(ui)
  (let ((tmp (expand-file-name (make-temp-file "alonso-relproj" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "sub" tmp))
          (let* ((alonso-project-dir nil)
                 (default-directory (file-name-as-directory tmp))
                 (res (alonso-ui-tests--run-project "/project sub")))
            (should (equal (file-truename (expand-file-name "sub" tmp))
                           (file-truename (nth 2 res))))))
      (ignore-errors (delete-directory tmp t)))))

;; `alonso-project-change-hook' is run with the new project directory.

(ert-deftest alonso-ui--project-change-hook-runs-with-new-dir ()
  :tags '(ui)
  (let ((tmp (expand-file-name (make-temp-file "alonso-hookproj" t))))
    (unwind-protect
        (let ((captured nil))
          (let ((alonso-project-change-hook (list (lambda (dir) (setq captured dir)))))
            (alonso-ui-tests--run-project (format "/project %s" tmp))
            (should (equal (file-truename tmp) (file-truename captured)))))
      (ignore-errors (delete-directory tmp t)))))

;;; Hooks — a prompt starting with "#" runs a local script (no LLM)

(defun alonso-ui-tests--feed-hook-action ()
  "Feed a `hook_action' event through the process filter."
  (setq alonso-line-buffer "" alonso-in-turn t)
  (alonso--process-filter
   nil (concat "{\"event\":\"hook_action\",\"name\":\"ls\",\"output\":\"a\\nb\"}\n")))

(ert-deftest alonso-ui--hook-action-output-inserted-into-conversation ()
  :tags '(ui)
  (alonso-ui-tests--feed-hook-action)
  (should (string-match-p "a\nb"
                          (with-current-buffer (get-buffer "alonso")
                            (buffer-string)))))

(ert-deftest alonso-ui--hook-action-clears-in-turn-state ()
  :tags '(ui)
  (alonso-ui-tests--feed-hook-action)
  (should (not alonso-in-turn)))

(ert-deftest alonso-ui--hook-action-error-shown-in-conversation ()
  :tags '(ui)
  (let ((ev (make-hash-table :test 'equal)))
    (puthash "event" "hook_action" ev)
    (puthash "name" "naoexiste" ev)
    (puthash "error" "hook: not found: naoexiste" ev)
    (alonso--on-hook-action ev))
  (should (string-match-p "\\[hook naoexiste\\] error: hook: not found: naoexiste"
                          (with-current-buffer (get-buffer "alonso")
                            (buffer-string)))))

;; A prompt whose text starts with "#" goes through the hook path.

(defun alonso-ui-tests--prompt-send-hook (fn)
  "Send \"#ls -l\" through `--prompt-send' and call FN with (SENT START)."
  (let ((sent nil)
        (start (with-current-buffer (get-buffer "alonso") (point-max))))
    (setq alonso-in-turn nil alonso-pending-tools nil)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ()))
                    ((symbol-function 'alonso--send)
                     (lambda (method &optional params)
                       (push (cons method params) sent))))
            (alonso--prompt-send "#ls -l"))
          (funcall fn sent start))
      (alonso-ui-tests--spinner-cleanup))))

(ert-deftest alonso-ui--hook-prompt-sent-as-prompt-command ()
  :tags '(ui)
  (alonso-ui-tests--prompt-send-hook
   (lambda (sent _start)
     (should (equal "prompt" (caar sent))))))

(ert-deftest alonso-ui--hook-prompt-carries-hash-text ()
  :tags '(ui)
  (alonso-ui-tests--prompt-send-hook
   (lambda (sent _start)
     (should (string-match-p "#ls -l" (format "%S" (cdar sent)))))))

(ert-deftest alonso-ui--hook-prompt-echoes-command ()
  :tags '(ui)
  (alonso-ui-tests--prompt-send-hook
   (lambda (_sent start)
     (should (string-match-p ">>> #ls -l"
                             (alonso-ui-tests--conversation-text-from start))))))

(ert-deftest alonso-ui--hook-prompt-marks-turn-in-progress ()
  :tags '(ui)
  (alonso-ui-tests--prompt-send-hook
   (lambda (_sent _start)
     (should alonso-in-turn))))

;;; Braille spinner & mode-line status

(ert-deftest alonso-ui--mode-line-status-empty-when-idle ()
  :tags '(ui)
  (let ((alonso-in-turn nil)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (should (equal "" (alonso--mode-line-status)))))

(ert-deftest alonso-ui--mode-line-status-shows-alonso-when-in-turn ()
  :tags '(ui)
  (let ((alonso-in-turn t)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (should (equal " alonso…" (alonso--mode-line-status)))))

(ert-deftest alonso-ui--mode-line-status-shows-braille-spinner ()
  :tags '(ui)
  (let ((alonso-in-turn t)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (unwind-protect
        (progn
          (alonso--start-spinner)
          (should (string-match-p " [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]" (alonso--mode-line-status))))
      (alonso-ui-tests--spinner-cleanup))))

(ert-deftest alonso-ui--spinner-stays-active-after-a-chunk ()
  :tags '(ui)
  (let ((alonso-in-turn t)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (unwind-protect
        (progn
          (alonso--start-spinner)
          (alonso--start-spinner)
          (should (and alonso--spinner-active
                       (timerp alonso--spinner-timer)
                       (string-match-p " [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"
                                       (alonso--mode-line-status)))))
      (alonso-ui-tests--spinner-cleanup))))

(ert-deftest alonso-ui--on-chunk-keeps-spinner-active ()
  :tags '(ui)
  (let ((alonso-in-turn t)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (unwind-protect
        (progn
          (alonso--start-spinner)
          (alonso--on-chunk "response")
          (should (and alonso--spinner-active
                       (timerp alonso--spinner-timer))))
      (alonso-ui-tests--spinner-cleanup))))

(ert-deftest alonso-ui--turn-end-stops-spinner-and-clears-turn ()
  :tags '(ui)
  (let ((alonso-in-turn t)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (unwind-protect
        (progn
          (alonso--start-spinner)
          (alonso--on-turn-end (alonso-ui-tests--turn-end-event))
          (should (and (not alonso--spinner-active)
                       (not (timerp alonso--spinner-timer))
                       (equal "" (alonso--mode-line-status)))))
      (alonso-ui-tests--spinner-cleanup))))

(ert-deftest alonso-ui--error-stops-spinner ()
  :tags '(ui)
  (let ((alonso-in-turn t)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (unwind-protect
        (progn
          (alonso--start-spinner)
          (alonso--on-error "boom")
          (should (not alonso--spinner-active)))
      (alonso-ui-tests--spinner-cleanup))))

(ert-deftest alonso-ui--cancelled-stops-spinner ()
  :tags '(ui)
  (let ((alonso-in-turn t)
        (alonso--spinner-active nil)
        (alonso--spinner-timer nil))
    (unwind-protect
        (progn
          (alonso--start-spinner)
          (alonso--on-cancelled)
          (should (not alonso--spinner-active)))
      (alonso-ui-tests--spinner-cleanup))))

;;; The answer segment is accumulated while streaming.

;; With live rendering off, the segment is only tracked (not rendered) until
;; it closes.

(ert-deftest alonso-ui--streaming-live-off-tracks-but-not-renders ()
  :tags '(ui)
  (let ((alonso-render-markdown-live nil))
    (alonso-ui-tests--reset-conversation-state)
    (alonso--on-chunk "# Hi\n")
    (should (and alonso--answer-start
                 (with-current-buffer (alonso--get-buffer)
                   (null (get-text-property 1 'display)))))))

(ert-deftest alonso-ui--render-answer-renders-and-closes ()
  :tags '(ui)
  (let ((alonso-render-markdown-live nil))
    (alonso-ui-tests--reset-conversation-state)
    (alonso--on-chunk "# Hi\n")
    (alonso--render-answer)
    (should (and (null alonso--answer-start)
                 (with-current-buffer (alonso--get-buffer)
                   (equal "" (get-text-property 1 'display)))))))

(ert-deftest alonso-ui--rendering-answer-does-not-change-text ()
  :tags '(ui)
  (let ((alonso-render-markdown-live nil))
    (alonso-ui-tests--reset-conversation-state)
    (alonso--on-chunk "# Hi\n")
    (alonso--render-answer)
    (should (equal "# Hi\n"
                   (with-current-buffer (alonso--get-buffer)
                     (buffer-substring-no-properties (point-min) (point-max)))))))

;; With live rendering on, every chunk re-renders the segment as it streams.

(ert-deftest alonso-ui--streaming-live-on-renders-chunk-right-away ()
  :tags '(ui)
  (let ((alonso-render-markdown-live t))
    (alonso-ui-tests--reset-conversation-state)
    (alonso--on-chunk "# Hi\n")
    (should (and alonso--answer-start
                 (with-current-buffer (alonso--get-buffer)
                   (equal "" (get-text-property 1 'display)))))))

(ert-deftest alonso-ui--streaming-live-on-leaves-incomplete-bold-raw ()
  :tags '(ui)
  (let ((alonso-render-markdown-live t))
    (alonso-ui-tests--reset-conversation-state)
    (alonso--on-chunk "# Hi\n")
    (alonso--on-chunk "a **bo")
    (should (with-current-buffer (alonso--get-buffer)
              (null (get-text-property (alonso-tests--md-pos "**") 'display))))))

(ert-deftest alonso-ui--streaming-live-on-renders-bold-once-closed ()
  :tags '(ui)
  (let ((alonso-render-markdown-live t))
    (alonso-ui-tests--reset-conversation-state)
    (alonso--on-chunk "# Hi\n")
    (alonso--on-chunk "a **bo")
    (alonso--on-chunk "ld** b\n")
    (should (with-current-buffer (alonso--get-buffer)
              (and (eq (alonso-tests--md-face "bold") 'alonso-md-bold-face)
                   (equal "" (get-text-property
                              (alonso-tests--md-pos "**") 'display)))))))

(ert-deftest alonso-ui--streaming-live-on-keeps-buffer-text ()
  :tags '(ui)
  (let ((alonso-render-markdown-live t))
    (alonso-ui-tests--reset-conversation-state)
    (alonso--on-chunk "# Hi\n")
    (alonso--on-chunk "a **bo")
    (alonso--on-chunk "ld** b\n")
    (should (equal "# Hi\na **bold** b\n"
                   (with-current-buffer (alonso--get-buffer)
                     (buffer-substring-no-properties (point-min) (point-max)))))))

;; turn_end closes (and renders) the pending answer

(ert-deftest alonso-ui--turn-end-renders-pending-answer ()
  :tags '(ui)
  (alonso-ui-tests--reset-conversation-state)
  (setq alonso-session-input-tokens 0
        alonso-session-output-tokens 0)
  (alonso--on-chunk "## Sub\n")
  (alonso--on-turn-end (alonso-ui-tests--turn-end-event))
  (with-current-buffer (alonso--get-buffer)
    (should (and (null alonso--answer-start)
                 (equal "" (get-text-property 1 'display))
                 (eq (get-text-property 4 'face) 'alonso-md-heading-2-face)))))

;; thinking keeps the raw markers

(ert-deftest alonso-ui--thinking-not-markdown-rendered ()
  :tags '(ui)
  (let ((alonso--answer-start nil)
        (alonso--thinking-separator-pending nil)
        (alonso--after-tool-separator-pending nil)
        (alonso-show-thinking t)
        (start (with-current-buffer (alonso--get-buffer) (point-max))))
    (unwind-protect
        (progn
          (alonso--on-thinking "# raw **thinking**\n")
          (with-current-buffer (alonso--get-buffer)
            (should (and (null (get-text-property start 'display))
                         (eq (get-text-property start 'face)
                             'alonso-thinking-face)))))
      (alonso--stop-spinner))))

;;; turn_end scrolls a long answer back to its beginning

(defun alonso-ui-tests--long-answer ()
  "Return a long multi-line answer string (taller than the window)."
  (concat (mapconcat (lambda (i) (format "linha %d" i))
                     (number-sequence 1 80) "\n")
          "\n"))

(ert-deftest alonso-ui--turn-end-scrolls-long-answer-back ()
  :tags '(ui)
  (let ((win (selected-window))
        (buf (alonso--get-buffer)))
    (set-window-buffer win buf)
    (alonso-ui-tests--reset-conversation-state)
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (insert ">>> pergunta\n\n")))
    (setq alonso-show-thinking nil)
    (with-current-buffer buf
      (setq alonso--turn-answer-start (copy-marker (point-max))))
    (let ((answer-beg (marker-position alonso--turn-answer-start)))
      (alonso--on-chunk (alonso-ui-tests--long-answer))
      (alonso--on-turn-end (alonso-ui-tests--turn-end-event))
      (should (and (> answer-beg (point-min))
                   (= (window-start win) answer-beg)
                   (= (window-point win) answer-beg))))))

(ert-deftest alonso-ui--turn-end-scrolls-short-answer-back ()
  :tags '(ui)
  (let ((win (selected-window))
        (buf (alonso--get-buffer)))
    (set-window-buffer win buf)
    (alonso-ui-tests--reset-conversation-state)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (insert ">>> pergunta\n\n")
        (goto-char (point-max))))
    (setq alonso-show-thinking nil)
    (with-current-buffer buf
      (setq alonso--turn-answer-start (copy-marker (point-max))))
    (let ((answer-beg (marker-position alonso--turn-answer-start)))
      (alonso--on-chunk "resposta curta\n")
      (alonso--on-turn-end (alonso-ui-tests--turn-end-event))
      (should (and (> answer-beg (point-min))
                   (= (window-start win) answer-beg)
                   (= (window-point win) answer-beg))))))

;; When a turn is split into several answer segments (answer, thinking,
;; answer), turn_end scrolls back to the *last* segment (the final answer).

(ert-deftest alonso-ui--turn-end-scrolls-to-final-answer-segment ()
  :tags '(ui)
  (let ((win (selected-window))
        (buf (alonso--get-buffer)))
    (set-window-buffer win buf)
    (alonso-ui-tests--reset-conversation-state)
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (insert ">>> pergunta\n\n")))
    (setq alonso-show-thinking nil)
    (with-current-buffer buf
      (setq alonso--turn-answer-start (copy-marker (point-max))))
    (alonso--on-chunk
     (concat (mapconcat (lambda (i) (format "primeira %d" i))
                        (number-sequence 1 40) "\n")
             "\n"))
    (alonso--on-thinking "pensando...\n")
    (alonso--stop-spinner)
    (let ((final-beg (with-current-buffer buf (point-max))))
      (alonso--on-chunk
       (concat (mapconcat (lambda (i) (format "final %d" i))
                          (number-sequence 1 80) "\n")
               "\n"))
      (alonso--on-turn-end (alonso-ui-tests--turn-end-event))
      (should (and (> final-beg (point-min))
                   (= (window-start win) final-beg)
                   (= (window-point win) final-beg))))))

;;; a new prompt re-anchors the window at the end (follows streaming)

(defun alonso-ui-tests--run-long-turn (win buf)
  "Set up a long answer on WIN/BUF, end the turn; leave the window scrolled."
  (let ((alonso-show-thinking nil))
    (set-window-buffer win buf)
    (alonso-ui-tests--reset-conversation-state)
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (insert ">>> pergunta\n\n")))
    (setq alonso-in-turn nil
          alonso-pending-tools nil)
    (with-current-buffer buf
      (setq alonso--turn-answer-start (copy-marker (point-max))))
    (alonso--on-chunk (alonso-ui-tests--long-answer))
    (alonso--on-turn-end (alonso-ui-tests--turn-end-event))))

(ert-deftest alonso-ui--after-turn-end-window-not-at-end ()
  :tags '(ui)
  (let ((win (selected-window))
        (buf (alonso--get-buffer)))
    (alonso-ui-tests--run-long-turn win buf)
    (should (and (/= (window-point win) (with-current-buffer buf (point-max)))
                 (= (window-start win) (marker-position alonso--turn-answer-start))))))

(ert-deftest alonso-ui--new-prompt-re-anchors-window-at-end ()
  :tags '(ui)
  (let ((win (selected-window))
        (buf (alonso--get-buffer)))
    (alonso-ui-tests--run-long-turn win buf)
    (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ()))
              ((symbol-function 'alonso--start-spinner) (lambda ()))
              ((symbol-function 'alonso--send) (lambda (&rest _) nil)))
      (alonso--prompt-send "nova pergunta"))
    (alonso-ui-tests--spinner-cleanup)
    (should (= (window-point win) (with-current-buffer buf (point-max))))))

(ert-deftest alonso-ui--streamed-output-after-new-prompt-is-followed ()
  :tags '(ui)
  (let ((win (selected-window))
        (buf (alonso--get-buffer)))
    (alonso-ui-tests--run-long-turn win buf)
    (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ()))
              ((symbol-function 'alonso--start-spinner) (lambda ()))
              ((symbol-function 'alonso--send) (lambda (&rest _) nil)))
      (alonso--prompt-send "nova pergunta"))
    (unwind-protect
        (progn
          (alonso-ui-tests--reset-conversation-state)
          (alonso--on-chunk "resposta que segue\n")
          (should (= (window-point win) (with-current-buffer buf (point-max)))))
      (alonso-ui-tests--spinner-cleanup))))

;;; resuming after a tool call whose output scrolled the window follows again

(defun alonso-ui-tests--with-tool-scroll (fn)
  "Mimic a big tool output scrolling the (unselected) conversation window.
Call FN with (WIN BUF QPOS) where QPOS is the tool line, far from the end."
  (let ((win (selected-window))
        (buf (alonso--get-buffer))
        (other (split-window (selected-window)))
        (alonso-show-thinking nil))
    (set-window-buffer win buf)
    (set-window-buffer other (get-buffer-create "*alonso-tests-other*"))
    (unwind-protect
        (progn
          (select-window other)
          (alonso-ui-tests--reset-conversation-state)
          (with-current-buffer buf
            (let ((inhibit-read-only t)) (insert ">>> pergunta\n\n")))
          (setq alonso-in-turn nil
                alonso-pending-tools nil)
          (alonso--on-chunk
           (concat (mapconcat (lambda (i) (format "diff linha %d" i))
                              (number-sequence 1 80) "\n")
                   "\n"))
          (let ((qpos (with-current-buffer buf (point-min))))
            (set-window-point win qpos)
            (funcall fn win buf qpos)))
      (when (window-live-p other) (delete-window other))
      (select-window win)
      (alonso-ui-tests--spinner-cleanup))))

(ert-deftest alonso-ui--confirmation-leaves-window-away-from-end ()
  :tags '(ui)
  (alonso-ui-tests--with-tool-scroll
   (lambda (win buf _qpos)
     (should (and (not (eq win (selected-window)))
                  (/= (window-point win) (with-current-buffer buf (point-max))))))))

(ert-deftest alonso-ui--resuming-after-tool-chunk-is-followed ()
  :tags '(ui)
  (alonso-ui-tests--with-tool-scroll
   (lambda (win buf _qpos)
     (setq alonso--after-tool-separator-pending t)
     (alonso--on-chunk "retomando apos a tool\n")
     (should (= (window-point win) (with-current-buffer buf (point-max)))))))

(ert-deftest alonso-ui--resuming-thinking-after-tool-is-followed ()
  :tags '(ui)
  (alonso-ui-tests--with-tool-scroll
   (lambda (win buf qpos)
     (set-window-point win qpos)
     (setq alonso--after-tool-separator-pending t
           alonso-show-thinking t)
     (alonso--on-thinking "pensando de novo\n")
     (should (= (window-point win) (with-current-buffer buf (point-max)))))))

;;; Atomic window — the conversation and the input behave as a single window

(ert-deftest alonso-ui--window-atom-is-a-persistent-parameter ()
  :tags '(ui)
  (should (eq 'writable (cdr (assq 'window-atom window-persistent-parameters)))))

(ert-deftest alonso-ui--open-displays-conversation-and-input ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--open-pair)
        (should (and (get-buffer-window (alonso--get-buffer) t)
                     (get-buffer-window alonso-input-buffer-name t))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--open-binds-pair-as-one-atomic-window ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--open-pair)
        (let ((conv (get-buffer-window (alonso--get-buffer) t))
              (in (get-buffer-window alonso-input-buffer-name t)))
          (should (and conv in
                       (eq (window-parent conv) (window-parent in))
                       (window-parameter (window-parent conv) 'window-atom)))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--open-makes-both-windows-dedicated ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--open-pair)
        (should (and (window-dedicated-p (get-buffer-window (alonso--get-buffer) t))
                     (window-dedicated-p (get-buffer-window alonso-input-buffer-name t)))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--open-splits-right-hand-side ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--open-pair)
        (let ((conv (get-buffer-window (alonso--get-buffer) t))
              (in (get-buffer-window alonso-input-buffer-name t)))
          (should (and (= 3 (length (window-list)))
                       (eq (window-parent conv) (window-parent in))))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--open-reopening-keeps-three-window-layout ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-ui-tests--open-pair)
        (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ())))
          (alonso-open))
        (should (= 3 (length (window-list)))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--make-windows-atomic-no-op-without-input ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--reset-windows)
        (switch-to-buffer (alonso--get-buffer))
        (alonso--make-windows-atomic)
        (should (and (null (window-parameter (selected-window) 'window-atom))
                     (not (window-dedicated-p (selected-window))))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--deleting-input-window-closes-conversation ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--pair-layout)
        (delete-window (get-buffer-window alonso-input-buffer-name t))
        (should (and (null (get-buffer-window (alonso--get-buffer) t))
                     (null (get-buffer-window alonso-input-buffer-name t))
                     (= 1 (length (window-list))))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--quitting-input-window-hides-conversation ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--pair-layout)
        (quit-window nil (get-buffer-window alonso-input-buffer-name t))
        (should (and (null (get-buffer-window (alonso--get-buffer) t))
                     (null (get-buffer-window alonso-input-buffer-name t))
                     (= 1 (length (window-list))))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--delete-other-windows-keeps-both ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--pair-layout)
        (delete-other-windows (get-buffer-window (alonso--get-buffer) t))
        (should (and (get-buffer-window (alonso--get-buffer) t)
                     (get-buffer-window alonso-input-buffer-name t)
                     (= 2 (length (window-list))))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--killing-conversation-closes-input-window ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--pair-layout)
        (kill-buffer (get-buffer alonso-buffer-name))
        (should (and (null (get-buffer-window alonso-input-buffer-name t))
                     (= 1 (length (window-list))))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--killing-one-buffer-keeps-the-other-alive ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--pair-layout)
        (kill-buffer (get-buffer alonso-buffer-name))
        (should (buffer-live-p (get-buffer alonso-input-buffer-name))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--kill-hook-installed-on-conversation-buffer ()
  :tags '(ui)
  (should (with-current-buffer (alonso--get-buffer)
            (memq 'alonso--on-pair-buffer-killed kill-buffer-hook))))

(ert-deftest alonso-ui--kill-hook-installed-on-input-buffer ()
  :tags '(ui)
  (alonso--setup-input-mode-line)
  (should (with-current-buffer (get-buffer alonso-input-buffer-name)
            (memq 'alonso--on-pair-buffer-killed kill-buffer-hook))))

;;; Other buffers taking over the pair's column (display-buffer integration)

(ert-deftest alonso-ui--takeover-nil-when-pair-not-displayed ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--reset-windows)
        (let ((popup (get-buffer-create "*alonso-tests-popup*")))
          (should (null (alonso--pair-window-takeover-p (buffer-name popup) nil)))))
    (alonso-tests--reset-windows)))

(ert-deftest alonso-ui--takeover-claims-policy-less-buffer-outside-pair ()
  :tags '(ui)
  (alonso-ui-tests--with-pair
   (lambda (_left)
     (let ((popup (get-buffer-create "*alonso-tests-popup*")))
       (should (alonso--pair-window-takeover-p (buffer-name popup) nil))))))

(ert-deftest alonso-ui--takeover-claims-buffer-asking-another-window ()
  :tags '(ui)
  (alonso-ui-tests--with-pair
   (lambda (_left)
     (let ((popup (get-buffer-create "*alonso-tests-popup*")))
       (should (alonso--pair-window-takeover-p
                (buffer-name popup) '(nil (inhibit-same-window . t))))))))

(ert-deftest alonso-ui--takeover-defers-to-explicit-display-policy ()
  :tags '(ui)
  (alonso-ui-tests--with-pair
   (lambda (_left)
     (let ((popup (get-buffer-create "*alonso-tests-popup*")))
       (should (null (alonso--pair-window-takeover-p
                      (buffer-name popup) '(display-buffer-same-window))))))))

(ert-deftest alonso-ui--takeover-ignores-conversation-and-input ()
  :tags '(ui)
  (alonso-ui-tests--with-pair
   (lambda (_left)
     (should (and (null (alonso--pair-window-takeover-p alonso-buffer-name nil))
                  (null (alonso--pair-window-takeover-p
                         alonso-input-buffer-name nil)))))))

(ert-deftest alonso-ui--takeover-disabled-by-defcustom ()
  :tags '(ui)
  (alonso-ui-tests--with-pair
   (lambda (_left)
     (let ((popup (get-buffer-create "*alonso-tests-popup*"))
           (alonso-display-other-buffers-in-pair nil))
       (should (null (alonso--pair-window-takeover-p (buffer-name popup) nil)))))))

(ert-deftest alonso-ui--takeover-nil-when-selected-window-is-in-pair ()
  :tags '(ui)
  (alonso-ui-tests--with-pair
   (lambda (_left)
     (let ((popup (get-buffer-create "*alonso-tests-popup*")))
       (select-window (get-buffer-window alonso-input-buffer-name t))
       (should (null (alonso--pair-window-takeover-p (buffer-name popup) nil)))))))

(ert-deftest alonso-ui--takeover-does-not-claim-visible-buffer ()
  :tags '(ui)
  (alonso-ui-tests--with-pair
   (lambda (_left)
     (let ((popup (get-buffer-create "*alonso-tests-popup*")))
       (switch-to-buffer popup)
       (should (null (alonso--pair-window-takeover-p (buffer-name popup) nil)))))))

;; A policy-less `display-buffer' from outside the pair takes over the column.

(defun alonso-ui-tests--with-popup-display (fn)
  "Set up the pair, `display-buffer' a policy-less popup, call FN with
\(LEFT POPUP WIN); clean up afterwards."
  (alonso-tests--reset-windows)
  (let ((popup (get-buffer-create "*alonso-tests-popup*")))
    (select-window (alonso-tests--pair-layout))
    (let ((left (selected-window)))
      (display-buffer popup)
      (unwind-protect
          (funcall fn left popup (get-buffer-window popup t))
        (alonso-tests--reset-windows)))))

(ert-deftest alonso-ui--display-popup-takes-over-the-column ()
  :tags '(ui)
  (alonso-ui-tests--with-popup-display
   (lambda (_left _popup win)
     (should (and win
                  (null (get-buffer-window (alonso--get-buffer) t))
                  (null (get-buffer-window alonso-input-buffer-name t))
                  (= 2 (length (window-list))))))))

(ert-deftest alonso-ui--display-popup-fills-the-freed-column ()
  :tags '(ui)
  (alonso-ui-tests--with-popup-display
   (lambda (left _popup win)
     (should (and win (eq (window-parent win) (window-parent left)))))))

(ert-deftest alonso-ui--display-left-window-selected-and-unchanged ()
  :tags '(ui)
  (alonso-ui-tests--with-popup-display
   (lambda (left _popup _win)
     (should (and (eq (selected-window) left)
                  (eq (window-buffer left)
                      (get-buffer "*alonso-tests-left*")))))))

(ert-deftest alonso-ui--display-conversation-and-input-stay-alive ()
  :tags '(ui)
  (alonso-ui-tests--with-popup-display
   (lambda (_left _popup _win)
     (should (and (buffer-live-p (get-buffer alonso-buffer-name))
                  (buffer-live-p (get-buffer alonso-input-buffer-name)))))))

(ert-deftest alonso-ui--display-alonso-open-rebuilds-pair ()
  :tags '(ui)
  (alonso-ui-tests--with-popup-display
   (lambda (_left _popup _win)
     (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ())))
       (alonso-open))
     (should (and (get-buffer-window (alonso--get-buffer) t)
                  (get-buffer-window alonso-input-buffer-name t))))))

;;; Restoring the pair after a takeover

(ert-deftest alonso-ui--restore-no-op-without-stashed-state ()
  :tags '(ui)
  (should (progn (setq alonso--pair-restore nil) (alonso--pair-restore) t)))

(defun alonso-ui-tests--with-quit-takeover (fn)
  "Set up the pair, take it over with a popup, then `quit-window' the popup.
Call FN with LEFT; clean up afterwards."
  (alonso-tests--reset-windows)
  (let ((popup (get-buffer-create "*alonso-tests-popup*")))
    (select-window (alonso-tests--pair-layout))
    (let ((left (selected-window)))
      (display-buffer popup)
      (quit-window nil (get-buffer-window popup))
      (unwind-protect
          (funcall fn left)
        (alonso-tests--reset-windows)))))

(ert-deftest alonso-ui--restore-q-brings-conversation-back ()
  :tags '(ui)
  (alonso-ui-tests--with-quit-takeover
   (lambda (_left)
     (should (get-buffer-window (alonso--get-buffer) t)))))

(ert-deftest alonso-ui--restore-q-brings-input-back-too ()
  :tags '(ui)
  (alonso-ui-tests--with-quit-takeover
   (lambda (_left)
     (should (get-buffer-window alonso-input-buffer-name t)))))

(ert-deftest alonso-ui--restore-q-pair-atomic-and-dedicated-again ()
  :tags '(ui)
  (alonso-ui-tests--with-quit-takeover
   (lambda (_left)
     (let ((conv (get-buffer-window (alonso--get-buffer) t))
           (in (get-buffer-window alonso-input-buffer-name t)))
       (should (and conv in
                    (eq (window-parent conv) (window-parent in))
                    (window-parameter (window-parent conv) 'window-atom)
                    (window-dedicated-p conv)
                    (window-dedicated-p in)))))))

(ert-deftest alonso-ui--restore-q-left-window-selected ()
  :tags '(ui)
  (alonso-ui-tests--with-quit-takeover
   (lambda (left)
     (should (eq (selected-window) left)))))

(defun alonso-ui-tests--with-delete-takeover (fn)
  "Set up the pair, take it over with a popup, then `delete-window' it.
Call FN with LEFT; clean up afterwards."
  (alonso-tests--reset-windows)
  (let ((popup (get-buffer-create "*alonso-tests-popup*")))
    (select-window (alonso-tests--pair-layout))
    (let ((left (selected-window)))
      (display-buffer popup)
      (delete-window (get-buffer-window popup))
      (unwind-protect
          (funcall fn left)
        (alonso-tests--reset-windows)))))

(ert-deftest alonso-ui--restore-c-x-0-brings-pair-back ()
  :tags '(ui)
  (alonso-ui-tests--with-delete-takeover
   (lambda (_left)
     (should (and (get-buffer-window (alonso--get-buffer) t)
                  (get-buffer-window alonso-input-buffer-name t)
                  (= 3 (length (window-list))))))))

(ert-deftest alonso-ui--restore-c-x-0-pair-atomic-again ()
  :tags '(ui)
  (alonso-ui-tests--with-delete-takeover
   (lambda (_left)
     (let ((conv (get-buffer-window (alonso--get-buffer) t))
           (in (get-buffer-window alonso-input-buffer-name t)))
       (should (and conv in
                    (eq (window-parent conv) (window-parent in))
                    (window-parameter (window-parent conv) 'window-atom)))))))

(ert-deftest alonso-ui--restore-drops-stale-state-while-pair-displayed ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--reset-windows)
        (alonso-tests--pair-layout)
        (setq alonso--pair-restore
              (list :frame (selected-frame)
                    :state (window-state-get (frame-root-window))))
        (alonso--pair-restore)
        (should (null alonso--pair-restore)))
    (alonso-tests--reset-windows)))

;;; Magit-style follow-up buffers stay in the pair's column

(ert-deftest alonso-ui--follow-up-no-takeover-window-while-pair-up ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--reset-windows)
        (alonso-tests--pair-layout)
        (should (null (alonso--pair-takeover-window))))
    (alonso-tests--reset-windows)))

(defun alonso-ui-tests--with-magit (fn)
  "Set up the pair, take it over with MAGIT, select the takeover column.
Call FN with (LEFT MAGIT COL); clean up afterwards."
  (alonso-tests--reset-windows)
  (let ((magit (get-buffer-create "*alonso-tests-magit*")))
    (select-window (alonso-tests--pair-layout))
    (let ((left (selected-window)))
      (display-buffer magit)
      (let ((col (get-buffer-window magit t)))
        (select-window col)
        (unwind-protect
            (funcall fn left magit col)
          (alonso-tests--reset-windows))))))

(ert-deftest alonso-ui--follow-up-takeover-window-carries-state ()
  :tags '(ui)
  (alonso-ui-tests--with-magit
   (lambda (_left _magit col)
     (should (eq (alonso--pair-takeover-window) col)))))

(ert-deftest alonso-ui--follow-up-claims-action-nil-buffer ()
  :tags '(ui)
  (alonso-ui-tests--with-magit
   (lambda (_left _magit _col)
     (let ((followup (get-buffer-create "*alonso-tests-followup*")))
       (should (alonso--pair-window-takeover-p (buffer-name followup) nil))))))

(ert-deftest alonso-ui--follow-up-splits-column-below-takeover ()
  :tags '(ui)
  (alonso-ui-tests--with-magit
   (lambda (_left magit col)
     (let ((followup (get-buffer-create "*alonso-tests-followup*")))
       (display-buffer followup nil)
       (let ((fwin (get-buffer-window followup t)))
         (should (and fwin
                      (not (eq fwin col))
                      (eq (window-parent fwin) (window-parent col))
                      (window-parameter fwin 'alonso--pair-followup)
                      (> (nth 1 (window-edges fwin))
                         (nth 1 (window-edges col)))
                      (eq (window-buffer col) magit))))))))

(ert-deftest alonso-ui--follow-up-left-window-untouched ()
  :tags '(ui)
  (alonso-ui-tests--with-magit
   (lambda (left _magit _col)
     (let ((followup (get-buffer-create "*alonso-tests-followup*")))
       (display-buffer followup nil)
       (should (and (not (eq (selected-window) left))
                    (window-live-p left)
                    (eq (window-buffer left)
                        (get-buffer "*alonso-tests-left*"))))))))

(ert-deftest alonso-ui--follow-up-closing-does-not-restore-pair-yet ()
  :tags '(ui)
  (alonso-ui-tests--with-magit
   (lambda (_left _magit _col)
     (let ((followup (get-buffer-create "*alonso-tests-followup*")))
       (display-buffer followup nil)
       (quit-window nil (get-buffer-window followup t))
       (should (null (get-buffer-window (alonso--get-buffer) t)))))))

(defun alonso-ui-tests--with-magit-and-back (fn)
  "Set up MAGIT over the pair, open+close a follow-up, then dismiss MAGIT.
Call FN with LEFT; clean up afterwards."
  (alonso-tests--reset-windows)
  (let ((magit (get-buffer-create "*alonso-tests-magit*")))
    (select-window (alonso-tests--pair-layout))
    (let ((left (selected-window)))
      (display-buffer magit)
      (let ((col (get-buffer-window magit t)))
        (select-window col)
        (display-buffer (get-buffer-create "*alonso-tests-followup*") nil)
        ;; back out to the takeover buffer, then dismiss it
        (quit-window nil (get-buffer-window "*alonso-tests-followup*" t))
        (quit-window nil (alonso--pair-takeover-window))
        (unwind-protect
            (funcall fn left)
          (alonso-tests--reset-windows))))))

(ert-deftest alonso-ui--follow-up-q-back-through-takeover-restores-pair ()
  :tags '(ui)
  (alonso-ui-tests--with-magit-and-back
   (lambda (_left)
     (should (and (get-buffer-window (alonso--get-buffer) t)
                  (get-buffer-window alonso-input-buffer-name t))))))

(ert-deftest alonso-ui--follow-up-pair-atomic-again ()
  :tags '(ui)
  (alonso-ui-tests--with-magit-and-back
   (lambda (_left)
     (let ((conv (get-buffer-window (alonso--get-buffer) t))
           (in (get-buffer-window alonso-input-buffer-name t)))
       (should (and conv in
                    (eq (window-parent conv) (window-parent in))
                    (window-parameter (window-parent conv) 'window-atom)))))))

(ert-deftest alonso-ui--follow-up-left-window-left-selected ()
  :tags '(ui)
  (alonso-ui-tests--with-magit-and-back
   (lambda (left)
     (should (eq (selected-window) left)))))

(ert-deftest alonso-ui--follow-up-c-x-0-on-takeover-restores-pair ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--reset-windows)
        (let ((magit (get-buffer-create "*alonso-tests-magit2*")))
          (select-window (alonso-tests--pair-layout))
          (display-buffer magit)
          (delete-window (get-buffer-window magit t))
          (should (and (get-buffer-window (alonso--get-buffer) t)
                       (get-buffer-window alonso-input-buffer-name t)
                       (= 3 (length (window-list)))))))
    (alonso-tests--reset-windows)))

;;; Spinner tick and the files-changed event

(ert-deftest alonso-ui--spinner-tick-advances-and-wraps-around ()
  :tags '(ui)
  (let ((alonso--spinner-index 0))
    (alonso--spinner-tick)
    (should (= 1 alonso--spinner-index))
    (setq alonso--spinner-index (1- (length alonso--spinner-frames)))
    (alonso--spinner-tick)
    (should (= 0 alonso--spinner-index))))

(ert-deftest alonso-ui--on-files-changed-runs-hook-with-the-file-list ()
  :tags '(ui)
  (let* ((seen nil)
         (alonso-files-changed-hook
          (list (lambda (files) (setq seen files))))
         (ev (make-hash-table :test 'equal)))
    (puthash "files" '("a.el" "b.el") ev)
    (alonso--on-files-changed ev)
    (should (equal '("a.el" "b.el") seen))))

(ert-deftest alonso-ui--on-files-changed-does-nothing-without-files ()
  :tags '(ui)
  (let* ((called nil)
         (alonso-files-changed-hook
          (list (lambda (_files) (setq called t)))))
    (alonso--on-files-changed (make-hash-table :test 'equal))
    (should (null called))))

;;; Insertion helper `alonso--insert-propertized-at'

(ert-deftest alonso-ui--insert-propertized-at-inserts-at-pos-with-props ()
  :tags '(ui)
  (with-current-buffer (alonso--get-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "HEAD")
      (let ((pos (alonso--insert-propertized-at (point-min) "XX" 'face 'bold)))
        (should (and (equal "XXHEAD"
                            (buffer-substring-no-properties (point-min) (point-max)))
                     (eq 'bold (get-text-property (point-min) 'face))
                     (= (point-min) pos)))))))

;;; `--prompt-send' rejects a second prompt while a turn is in progress

(ert-deftest alonso-ui--prompt-send-rejects-while-turn-in-progress ()
  :tags '(ui)
  (let ((alonso-in-turn t) (alonso-pending-tools nil))
    (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ())))
      (should-error (alonso--prompt-send "hi") :type 'error))))

;;; `--prompt-echo-body' fallback when the segments hold no visible chunk

(ert-deftest alonso-ui--prompt-echo-body-falls-back-on-empty-segments ()
  :tags '(ui)
  (let ((body (alonso--prompt-echo-body
               "   " (list (list :url "https://example.com/a.png"))
               (list (cons 'text "   ")))))
    (should (string-prefix-p "(imagem)" body))))

(ert-deftest alonso-ui--prompt-echo-body-fallback-without-images ()
  :tags '(ui)
  ;; Same fallback path, but with no images: the fallback list is built from
  ;; the trimmed text (the `else' branch of the inner `if').
  (let ((body (alonso--prompt-echo-body
               "  " nil (list (cons 'text "  ")))))
    (should (equal "" body))))

;;; `--apply-project-dir-locals' loads an existing .dir-locals.el

(ert-deftest alonso-ui--apply-project-dir-locals-loads-dir-locals ()
  :tags '(ui)
  (let ((tmp (expand-file-name (make-temp-file "alonso-dirlocals" t)))
        (saved default-directory))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".dir-locals.el" tmp)
            (insert "((nil . ((indent-tabs-mode . nil))))"))
          (let ((enable-local-variables nil)
                (buf (generate-new-buffer " *alonso-dl*")))
            (unwind-protect
                (with-current-buffer buf
                  (alonso--apply-project-dir-locals tmp)
                  (should (equal (file-name-as-directory tmp) default-directory)))
              (kill-buffer buf))))
      (ignore-errors (delete-directory tmp t))
      (setq default-directory saved))))

;;; `/project' points at a directory that does not exist -> error

(ert-deftest alonso-ui--project-nonexistent-dir-errors ()
  :tags '(ui)
  (should-error (alonso-ui-tests--run-project "/project /nonexistent/alonso/xyz")
                :type 'error))

;;; Deeper follow-up popups in the displaced pair's column

(ert-deftest alonso-ui--follow-up-claims-deeper-buffer ()
  :tags '(ui)
  (alonso-ui-tests--with-magit
   (lambda (_left _magit _col)
     (let ((followup (get-buffer-create "*alonso-tests-followup*")))
       (display-buffer followup nil)
       ;; Select the follow-up window explicitly: the selected window must
       ;; carry the `alonso--pair-followup' parameter (not be the takeover
       ;; window itself) for a deeper popup to be claimed.
       (select-window (get-buffer-window followup t))
       (should (alonso--pair-window-takeover-p
                (buffer-name (get-buffer-create "*alonso-tests-deeper*")) nil))))))

(ert-deftest alonso-ui--follow-up-deeper-splits-below-followup ()
  :tags '(ui)
  (alonso-ui-tests--with-magit
   (lambda (_left _magit _col)
     (let ((followup (get-buffer-create "*alonso-tests-followup*"))
           (deeper (get-buffer-create "*alonso-tests-deeper*")))
       (display-buffer followup nil)
       (select-window (get-buffer-window followup t))
       (display-buffer deeper nil)
       (should (get-buffer-window deeper t))))))

;;; `alonso-open' recreates a missing input window when the conversation shows

(ert-deftest alonso-ui--open-recreates-missing-input-window ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--reset-windows)
        (switch-to-buffer (alonso--get-buffer))
        (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ())))
          (alonso-open))
        (should (and (get-buffer-window (alonso--get-buffer) t)
                     (get-buffer-window alonso-input-buffer-name t))))
    (alonso-tests--reset-windows)))

;;; User commands — prompt, cancel, cwd

(ert-deftest alonso-ui--prompt-command-forwards-to-prompt-send ()
  :tags '(ui)
  (let (sent)
    (cl-letf (((symbol-function 'alonso--prompt-send)
               (lambda (text) (setq sent text))))
      (alonso-prompt "oi"))
    (should (equal "oi" sent))))

(ert-deftest alonso-ui--cancel-without-process-sends-nothing ()
  :tags '(ui)
  (let ((alonso-process nil) sent)
    (cl-letf (((symbol-function 'alonso--send)
               (lambda (&rest _) (setq sent t))))
      (alonso-cancel))
    (should (null sent))))

(ert-deftest alonso-ui--cancel-sends-cancel-without-tool-procs ()
  :tags '(ui)
  (let ((alonso-process 'fake) sent)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'alonso--send)
               (lambda (method &optional _params) (setq sent method))))
      (alonso-cancel))
    (should (equal "cancel" sent))))

(ert-deftest alonso-ui--set-cwd-sends-expanded-dir ()
  :tags '(ui)
  (let (sent)
    (cl-letf (((symbol-function 'alonso--send)
               (lambda (method params) (setq sent (cons method params)))))
      (alonso-set-cwd "~/tmp"))
    (should (and (equal "set_cwd" (car sent))
                 (equal (expand-file-name "~/tmp")
                        (cadr (member "cwd" (cdr sent))))))))

;;; Interactive override commands (body + interactive spec)

(defun alonso-ui-tests--request-value (var)
  "Return the buffer-local value of VAR in the input buffer."
  (with-current-buffer (get-buffer-create alonso-input-buffer-name)
    (symbol-value var)))

(ert-deftest alonso-ui--set-provider-interactive-stores-override ()
  :tags '(ui)
  (unwind-protect
      (progn
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "google"))
                  ((symbol-function 'message) (lambda (&rest _) nil)))
          (call-interactively #'alonso-set-provider))
        (should (equal "google" (alonso-ui-tests--request-value
                                 'alonso-request-provider))))
    (with-current-buffer (get-buffer-create alonso-input-buffer-name)
      (setq alonso-request-provider ""))))

(ert-deftest alonso-ui--set-model-stores-override ()
  :tags '(ui)
  ;; NOTE: the interactive spec is the string "sModel ...", expanded by
  ;; `Fcall_interactively' which calls the `read-string' subr directly, so it
  ;; cannot be intercepted with `cl-letf' in batch (it would block on stdin).
  ;; The body is therefore covered by a direct call.
  (unwind-protect
      (progn
        (alonso-set-model "m1")
        (should (equal "m1" (alonso-ui-tests--request-value
                             'alonso-request-model))))
    (with-current-buffer (get-buffer-create alonso-input-buffer-name)
      (setq alonso-request-model ""))))

(ert-deftest alonso-ui--set-thinking-interactive-stores-override ()
  :tags '(ui)
  (unwind-protect
      (progn
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "on"))
                  ((symbol-function 'message) (lambda (&rest _) nil)))
          (call-interactively #'alonso-set-thinking))
        (should (eq 'on (alonso-ui-tests--request-value
                         'alonso-request-thinking))))
    (with-current-buffer (get-buffer-create alonso-input-buffer-name)
      (setq alonso-request-thinking 'unset))))

(ert-deftest alonso-ui--toggle-show-thinking-on-to-off ()
  :tags '(ui)
  (let ((alonso-show-thinking t))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (call-interactively #'alonso-toggle-show-thinking))
    (should-not alonso-show-thinking)))

(ert-deftest alonso-ui--toggle-show-thinking-off-to-on ()
  :tags '(ui)
  (let ((alonso-show-thinking nil))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (call-interactively #'alonso-toggle-show-thinking))
    (should alonso-show-thinking)))

(ert-deftest alonso-ui--set-reasoning-effort-interactive-stores-override ()
  :tags '(ui)
  (unwind-protect
      (progn
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "high"))
                  ((symbol-function 'message) (lambda (&rest _) nil)))
          (call-interactively #'alonso-set-reasoning-effort))
        (should (equal "high" (alonso-ui-tests--request-value
                               'alonso-request-reasoning-effort))))
    (with-current-buffer (get-buffer-create alonso-input-buffer-name)
      (setq alonso-request-reasoning-effort ""))))

(ert-deftest alonso-ui--set-knowledge-bases-sends-command ()
  :tags '(ui)
  (let (sent)
    (cl-letf (((symbol-function 'alonso--send)
               (lambda (method params) (setq sent (cons method params)))))
      (alonso-set-knowledge-bases (list (make-hash-table))))
    (should (equal "set_knowledge_bases" (car sent)))))

;;; `alonso-quit'

(ert-deftest alonso-ui--quit-sends-quit-when-process-live ()
  :tags '(ui)
  (let ((alonso-process 'p) sent)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'alonso--send) (lambda (method &rest _) (setq sent method))))
      (alonso-quit))
    (should (equal "quit" sent))))

(ert-deftest alonso-ui--quit-noop-without-live-process ()
  :tags '(ui)
  (let ((alonso-process nil) sent)
    (cl-letf (((symbol-function 'alonso--send) (lambda (&rest _) (setq sent t))))
      (alonso-quit))
    (should (null sent))))

;;; `alonso-kill'

(ert-deftest alonso-ui--kill-clears-state ()
  :tags '(ui)
  (let ((alonso-process nil) (alonso-ready t) (alonso-in-turn t)
        (alonso-pending-tools '((:id "x"))) (alonso-line-buffer "junk")
        (alonso--after-tool-separator-pending t)
        (alonso--answer-start nil) (alonso--turn-answer-start nil))
    (cl-letf (((symbol-function 'alonso--cancel-confirm) (lambda ())))
      (alonso-kill))
    (should (and (null alonso-process) (null alonso-ready)
                 (null alonso-in-turn) (null alonso-pending-tools)
                 (equal "" alonso-line-buffer)
                 (null alonso--after-tool-separator-pending)))))

(ert-deftest alonso-ui--kill-detaches-answer-markers ()
  :tags '(ui)
  (let ((alonso--answer-start (copy-marker 1))
        (alonso--turn-answer-start (copy-marker 1))
        (alonso-process nil))
    (cl-letf (((symbol-function 'alonso--cancel-confirm) (lambda ())))
      (alonso-kill))
    (should (and (null alonso--answer-start)
                 (null alonso--turn-answer-start)))))

(ert-deftest alonso-ui--kill-sends-quit-and-deletes-live-process ()
  :tags '(ui)
  (let ((alonso-process 'fake) sent (deleted nil))
    (cl-letf (((symbol-function 'alonso--cancel-confirm) (lambda ()))
              ((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'alonso--send) (lambda (method &rest _) (setq sent method)))
              ((symbol-function 'delete-process) (lambda (_p) (setq deleted t)))
              ((symbol-function 'sleep-for) (lambda (_s) nil)))
      (alonso-kill))
    (should (and (equal "quit" sent) deleted))))

;; (The kill-deletes-tool-procs test was removed: the client no longer spawns
;; tool subprocesses; the bridge runs the tools.)


;;; `alonso-restart'

(ert-deftest alonso-ui--restart-clears-buffers-and-reopens ()
  :tags '(ui)
  (unwind-protect
      (progn
        (alonso-tests--reset-windows)
        (switch-to-buffer (get-buffer-create "*alonso-tests-neutral*"))
        (let ((conv (alonso--get-buffer))
              (in (get-buffer-create alonso-input-buffer-name)))
          (with-current-buffer conv
            (let ((inhibit-read-only t)) (insert "old conversation")))
          (with-current-buffer in (insert "old input"))
          (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ()))
                    ((symbol-function 'alonso--cancel-confirm) (lambda ()))
                    ((symbol-function 'process-live-p) (lambda (_p) nil)))
            (let ((alonso-process nil))
              (alonso-restart)))
          (should (and (with-current-buffer (get-buffer alonso-buffer-name)
                         (string-empty-p (buffer-string)))
                       (get-buffer-window alonso-input-buffer-name t)))))
    (alonso-tests--reset-windows)))

;;; Thinking placeholder (when `alonso-show-thinking' is nil)

(defun alonso-ui-tests--placeholder-text ()
  "Return the whole conversation buffer text, without properties."
  (with-current-buffer (alonso--get-buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest alonso-ui--thinking-placeholder-hides-thinking-text ()
  :tags '(ui)
  (let ((alonso-show-thinking nil))
    (unwind-protect
        (progn
          (alonso-ui-tests--reset-conversation-state)
          (alonso--on-thinking "segredo do modelo")
          (should (equal alonso-thinking-placeholder
                         (alonso-ui-tests--placeholder-text)))
          (should (alonso--thinking-placeholder-active-p)))
      (alonso-ui-tests--spinner-cleanup)
      (alonso-ui-tests--reset-conversation-state))))

(ert-deftest alonso-ui--thinking-placeholder-has-spinner-on-the-left ()
  :tags '(ui)
  (let ((alonso-show-thinking nil)
        (alonso--spinner-index 0))
    (unwind-protect
        (progn
          (alonso-ui-tests--reset-conversation-state)
          (alonso--on-thinking "x")
          (should (equal (concat (aref alonso--spinner-frames 0) " ")
                       (overlay-get alonso--thinking-placeholder-overlay
                                    'before-string))))
      (alonso-ui-tests--spinner-cleanup)
      (alonso-ui-tests--reset-conversation-state))))

(ert-deftest alonso-ui--thinking-text-shown-when-enabled ()
  :tags '(ui)
  (let ((alonso-show-thinking t))
    (unwind-protect
        (progn
          (alonso-ui-tests--reset-conversation-state)
          (alonso--on-thinking "pensando muito")
          (should (string-match-p "pensando muito"
                                  (alonso-ui-tests--placeholder-text)))
          (should-not (alonso--thinking-placeholder-active-p)))
      (alonso-ui-tests--spinner-cleanup)
      (alonso-ui-tests--reset-conversation-state))))

(ert-deftest alonso-ui--spinner-tick-advances-placeholder-frame ()
  :tags '(ui)
  (let ((alonso-show-thinking nil)
        (alonso--spinner-index 0))
    (unwind-protect
        (progn
          (alonso-ui-tests--reset-conversation-state)
          (alonso--on-thinking "x")
          (alonso--spinner-tick)
          (should (equal (concat (aref alonso--spinner-frames 1) " ")
                       (overlay-get alonso--thinking-placeholder-overlay
                                    'before-string))))
      (alonso-ui-tests--spinner-cleanup)
      (alonso-ui-tests--reset-conversation-state))))

(ert-deftest alonso-ui--chunk-removes-thinking-placeholder ()
  :tags '(ui)
  (let ((alonso-show-thinking nil))
    (unwind-protect
        (progn
          (alonso-ui-tests--reset-conversation-state)
          (alonso--on-thinking "x")
          (alonso--on-chunk "resposta final")
          (should-not (alonso--thinking-placeholder-active-p))
          (should (equal "resposta final"
                         (alonso-ui-tests--placeholder-text))))
      (alonso-ui-tests--spinner-cleanup)
      (alonso-ui-tests--reset-conversation-state))))

(ert-deftest alonso-ui--stop-spinner-removes-thinking-placeholder ()
  :tags '(ui)
  (let ((alonso-show-thinking nil))
    (unwind-protect
        (progn
          (alonso-ui-tests--reset-conversation-state)
          (alonso--on-thinking "x")
          (should (alonso--thinking-placeholder-active-p))
          (alonso--stop-spinner)
          (should-not (alonso--thinking-placeholder-active-p)))
      (alonso-ui-tests--spinner-cleanup)
      (alonso-ui-tests--reset-conversation-state))))

(provide 'alonso-ui-tests)

;;; alonso-ui-tests.el ends here
