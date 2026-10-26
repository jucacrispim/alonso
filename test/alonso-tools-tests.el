;;; alonso-tools-tests.el --- Tests for the alonso tool-call display, confirmation and trust scope.  -*- lexical-binding: t; -*-

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

;; Tests for the alonso tool-call display, confirmation and trust scope.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT: one `ert-deftest' per
;; assertion, all tagged `tools'.  The two batch helpers that used to be
;; `cl-labels' locals are now top-level functions so the deftests can share
;; them.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'ert)
(require 'alonso-tests-lib)

;;; Shared helpers

(defun alonso-tools-tests--alonso-buffer ()
  "Return the conversation buffer, creating it (with its mode) if needed."
  (alonso--get-buffer))

;; A helper that runs `alonso--confirm-pending' over a queue of N
;; mutating tools with `alonso--confirm-ask' stubbed to answer
;; synchronously (ANSWERS, one per question asked, in order; 'run / 'deny),
;; `alonso--send' stubbed to record the method names, and
;; `alonso--dispatch-tool' stubbed to avoid side effects (no file
;; writes / shell spawns).  Returns a list: the number of questions asked, the
;; recorded send commands and the conversation text inserted during the run.
;; Stubbing `--confirm-ask' (rather than `--ask-user-trust') bypasses the
;; transient menu: the stub applies the answer via `--confirm-answer' exactly
;; like a menu suffix would (via its 0s timer), but synchronously.
(defun alonso-tools-tests--run-batch (queue answers)
  (let ((sent '())
        (asked 0)
        (start (with-current-buffer (alonso-tools-tests--alonso-buffer)
                 (point-max))))
    (cl-letf (((symbol-function 'alonso--send)
               (lambda (method &optional _params) (push method sent)))
              ((symbol-function 'alonso--confirm-ask)
               (lambda (&rest _)
                 (alonso--confirm-answer
                  (prog1 (pop answers) (cl-incf asked)))))
              ((symbol-function 'alonso--dispatch-tool)
               (lambda (_name _input _id)))
              ;; A denial cancels the turn via `alonso-cancel',
              ;; which only sends `cancel' when the bridge process is
              ;; alive (it does nothing otherwise).  Bind a fake live
              ;; process so the batch behaves like the real client, where
              ;; the bridge is running.
              (alonso-process (make-symbol "fake-bridge-proc"))
              ((symbol-function 'process-live-p) (lambda (_p) t))
              (alonso--trust-specific nil)
              (alonso--trust-class nil)
              (alonso--trust-tools nil)
              (alonso--trust-all nil))
      (setq alonso--confirm-queue queue)
      (setq alonso--confirm-timer nil)
      ;; Anchor every `[denied]'/'[allowed]' recorded by the run to the end
      ;; of the alonso buffer (the captured range) so the test can
      ;; count them below.
      (setq alonso--tool-call-pos
            (with-current-buffer (alonso-tools-tests--alonso-buffer) (point-max)))
      (alonso--confirm-pending))
    (list asked (nreverse sent)
          (with-current-buffer (alonso-tools-tests--alonso-buffer)
            (buffer-substring-no-properties start (point-max))))))

;; Runs `alonso--confirm-pending' recording the sequence of `show' (a tool call
;; displayed) and `ask' (a question asked) events.
(defun alonso-tools-tests--run-seq (queue answers)
  (let ((events '())
        (sent '()))
    (cl-letf (((symbol-function 'alonso--send)
               (lambda (method &optional _) (push method sent)))
              ((symbol-function 'alonso--confirm-ask)
               (lambda (&rest _)
                 (push 'ask events)
                 (alonso--confirm-answer (pop answers))))
              ((symbol-function 'alonso--show-tool-call)
               (lambda (&rest _) (push 'show events) nil))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (_n _i _a &optional _t) nil))
              ((symbol-function 'alonso--dispatch-tool)
               (lambda (_n _i _id) nil))
              (alonso--trust-specific nil)
              (alonso--trust-class nil)
              (alonso--trust-tools nil)
              (alonso--trust-all nil))
      (setq alonso--confirm-queue queue)
      (setq alonso--confirm-timer nil)
      (alonso--confirm-pending))
    (nreverse events)))

(defun alonso-tools-tests--count (regexp text)
  "Count non-overlapping occurrences of REGEXP in TEXT."
  (let ((n 0) (from 0))
    (while (string-match regexp text from)
      (setq from (match-end 0))
      (cl-incf n))
    n))

;;; Tool confirmation UI — unicode icons and command/pattern/path in blue

(ert-deftest alonso-tools--icon-shell ()
  :tags '(tools)
  (should (equal "🖥" (alonso--tool-icon "shell"))))

(ert-deftest alonso-tools--icon-grep ()
  :tags '(tools)
  (should (equal "🔎" (alonso--tool-icon "grep"))))

(ert-deftest alonso-tools--icon-glob ()
  :tags '(tools)
  (should (equal "🔎" (alonso--tool-icon "glob"))))

(ert-deftest alonso-tools--icon-unknown-falls-back-to-wrench ()
  :tags '(tools)
  (should (equal "🔧" (alonso--tool-icon "something_else"))))

(ert-deftest alonso-tools--confirm-question-shell-shows-command ()
  :tags '(tools)
  (should (string-match-p
           (regexp-quote "🖥 Run tool: shell · ps aux? ")
           (alonso--confirm-question
            "shell" (alonso--json-plist-to-hash (list "command" "ps aux"))))))

(ert-deftest alonso-tools--confirm-question-grep-shows-pattern ()
  :tags '(tools)
  (should (string-match-p
           (regexp-quote "🔎 Run tool: grep · TODO? ")
           (alonso--confirm-question
            "grep" (alonso--json-plist-to-hash (list "pattern" "TODO"))))))

(ert-deftest alonso-tools--confirm-question-write-shows-path ()
  :tags '(tools)
  (should (string-match-p
           (regexp-quote "✏️ Run tool: write · /tmp/x.el? ")
           (alonso--confirm-question
            "write" (alonso--json-plist-to-hash (list "path" "/tmp/x.el"))))))

(ert-deftest alonso-tools--confirm-question-without-detail-omits-separator ()
  :tags '(tools)
  (should (equal "🔧 Run tool: foo? "
                 (alonso--confirm-question "foo" (make-hash-table)))))

;;; Tool confirmation — the question line is shown from the start (before the
;;; parameters/diff) and the `[allowed]' / `[denied]' tag is prepended to the
;;; front of that same line after the user answers

(ert-deftest alonso-tools--insert-propertized-returns-start-position ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max)))
         (ret (alonso--insert-propertized "test-text\n")))
    (should (and (= start ret)
                 (string-match-p "test-text"
                                 (with-current-buffer buf (buffer-string)))))))

;; A search_replace with a large diff: the question line appears *before* the
;; parameters (at the top) and the `[allowed]' tag is prepended to it.

(ert-deftest alonso-tools--allowed-confirmation-recorded-in-buffer ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (sr-input (alonso--json-plist-to-hash
                    (list "path" "/tmp/x.txt"
                          "search" "aaaa\nbbbb\ncccc\n"
                          "replace" "XXXX\nYYYY\nZZZZ\n"))))
    (alonso--show-tool-call "call_1" "search_replace" sr-input)
    (alonso--record-tool-confirmation "search_replace" sr-input t)
    (should (string-match-p
             (regexp-quote "[allowed] 🔁 Run tool: search_replace? ")
             (with-current-buffer buf (buffer-string))))))

(ert-deftest alonso-tools--question-shown-before-parameters ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max)))
         (sr-input (alonso--json-plist-to-hash
                    (list "path" "/tmp/x.txt"
                          "search" "aaaa\nbbbb\ncccc\n"
                          "replace" "XXXX\nYYYY\nZZZZ\n"))))
    (alonso--show-tool-call "call_1" "search_replace" sr-input)
    (alonso--record-tool-confirmation "search_replace" sr-input t)
    (let ((text (with-current-buffer buf
                  (buffer-substring-no-properties start (point-max)))))
      (let ((qpos (string-match
                   (regexp-quote "[allowed] 🔁 Run tool: search_replace? ")
                   text))
            (dpos (string-match (regexp-quote "path: /tmp/x.txt") text)))
        (should (and qpos dpos (< qpos dpos)))))))

(ert-deftest alonso-tools--question-points-to-visible-confirmation-line ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (sr-input (alonso--json-plist-to-hash
                    (list "path" "/tmp/x.txt"
                          "search" "aaaa\nbbbb\ncccc\n"
                          "replace" "XXXX\nYYYY\nZZZZ\n"))))
    (alonso--show-tool-call "call_1" "search_replace" sr-input)
    (let ((pos (alonso--record-tool-confirmation "search_replace" sr-input t)))
      (should (equal "[allowed] 🔁 Run tool: search_replace? "
                     (with-current-buffer buf
                       (buffer-substring-no-properties
                        pos (+ pos (length "[allowed] 🔁 Run tool: search_replace? ")))))))))

(ert-deftest alonso-tools--keep-question-visible-no-window-with-preceding-call ()
  :tags '(tools)
  (let* ((_buf (alonso-tools-tests--alonso-buffer))
         (sr-input (alonso--json-plist-to-hash
                    (list "path" "/tmp/x.txt"
                          "search" "aaaa\nbbbb\ncccc\n"
                          "replace" "XXXX\nYYYY\nZZZZ\n"))))
    (alonso--show-tool-call "call_1" "search_replace" sr-input)
    (let ((pos (alonso--record-tool-confirmation "search_replace" sr-input t)))
      (should (progn (alonso--keep-question-visible pos) t)))))

;; A plain (generic) tool call: the header no longer repeats the command (which
;; used to duplicate the parameter block); the parameter is instead shown as a
;; bold `command:' label with its value indented on the following line, and the
;; value appears exactly once in the whole tool-call display.

(ert-deftest alonso-tools--header-does-not-repeat-the-command-detail ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max))))
    (alonso--show-tool-call
     "call_2" "shell" (alonso--json-plist-to-hash (list "command" "ls -la")))
    (let ((text (with-current-buffer buf
                  (buffer-substring-no-properties start (point-max)))))
      (should (and (string-match-p (regexp-quote "🖥 Run tool: shell? ") text)
                   (not (string-match-p (regexp-quote "Run tool: shell · ") text)))))))

(ert-deftest alonso-tools--command-appears-exactly-once ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max))))
    (alonso--show-tool-call
     "call_2" "shell" (alonso--json-plist-to-hash (list "command" "ls -la")))
    (let ((text (with-current-buffer buf
                  (buffer-substring-no-properties start (point-max)))))
      (should (= 1 (alonso-tools-tests--count (regexp-quote "ls -la") text))))))

(ert-deftest alonso-tools--command-label-and-value-on-separate-lines ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max))))
    (alonso--show-tool-call
     "call_2" "shell" (alonso--json-plist-to-hash (list "command" "ls -la")))
    (let ((text (with-current-buffer buf
                  (buffer-substring-no-properties start (point-max)))))
      (should (string-match-p (regexp-quote "  command:\n    ls -la") text)))))

(ert-deftest alonso-tools--command-label-propertized-in-bold-face ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max))))
    (alonso--show-tool-call
     "call_2" "shell" (alonso--json-plist-to-hash (list "command" "ls -la")))
    (let ((lpos (with-current-buffer buf
                  (- (save-excursion
                       (goto-char start)
                       (search-forward "command:" nil t))
                     (length "command:")))))
      (should (eq 'alonso-command-face (get-text-property lpos 'face buf))))))

;; No preceding tool call: the confirmation falls back to the end of the buffer.

(ert-deftest alonso-tools--denied-fallback-appended-to-buffer ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max)))
         (alonso--tool-call-pos nil)
         (shell-input (alonso--json-plist-to-hash (list "command" "ps aux"))))
    (alonso--record-tool-confirmation "shell" shell-input nil)
    (should (string-match-p "\\[denied\\] "
                            (with-current-buffer buf
                              (buffer-substring-no-properties start (point-max)))))))

(ert-deftest alonso-tools--confirmation-recorded-at-captured-start ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max)))
         (alonso--tool-call-pos nil)
         (shell-input (alonso--json-plist-to-hash (list "command" "ps aux"))))
    (should (>= (alonso--record-tool-confirmation "shell" shell-input nil) start))))

(ert-deftest alonso-tools--keep-question-visible-no-window-at-end-fallback ()
  :tags '(tools)
  (let* ((_buf (alonso-tools-tests--alonso-buffer))
         (alonso--tool-call-pos nil)
         (shell-input (alonso--json-plist-to-hash (list "command" "ps aux"))))
    (let ((pos (alonso--record-tool-confirmation "shell" shell-input nil)))
      (should (progn (alonso--keep-question-visible pos) t)))))

;;; Batch confirmation — one denied tool refuses the rest without asking and
;;; cancels the turn (the conversation stops waiting for the user's input)

(defun alonso-tools-tests--batch-queue-a ()
  (list (list :id "a" :name "write"
              :input (alonso--json-plist-to-hash (list "path" "/tmp/a" "content" "x")))
        (list :id "b" :name "search_replace"
              :input (alonso--json-plist-to-hash (list "path" "/tmp/b" "search" "s" "replace" "r")))
        (list :id "c" :name "shell"
              :input (alonso--json-plist-to-hash (list "command" "echo hi")))))

(defun alonso-tools-tests--batch-queue-ab ()
  (list (list :id "a" :name "write"
              :input (alonso--json-plist-to-hash (list "path" "/tmp/a" "content" "x")))
        (list :id "b" :name "search_replace"
              :input (alonso--json-plist-to-hash (list "path" "/tmp/b" "search" "s" "replace" "r")))))

;; 1) Deny the first of three tools: no further questions, every remaining
;; tool is auto-denied and the turn is cancelled.

(ert-deftest alonso-tools--denying-first-tool-asks-only-once ()
  :tags '(tools)
  (let ((res (alonso-tools-tests--run-batch
              (alonso-tools-tests--batch-queue-a) '(deny))))
    (should (= 1 (car res)))))

(ert-deftest alonso-tools--denied-tool-sends-cancel ()
  :tags '(tools)
  (let ((res (alonso-tools-tests--run-batch
              (alonso-tools-tests--batch-queue-a) '(deny))))
    (should (member "cancel" (cadr res)))))

(ert-deftest alonso-tools--every-tool-of-denied-batch-shows-denied-tag ()
  :tags '(tools)
  (let ((res (alonso-tools-tests--run-batch
              (alonso-tools-tests--batch-queue-a) '(deny))))
    (let ((text (nth 2 res)))
      (should (and (= 3 (alonso-tools-tests--count "\\[denied\\] " text))
                   (not (string-match-p "\\[allowed\\] " text)))))))

;; 2) Deny the second of three tools: the first is allowed, the second is
;; asked and denied, the third is auto-denied (no question) and the turn is
;; cancelled.

(ert-deftest alonso-tools--denying-second-tool-asks-only-twice ()
  :tags '(tools)
  (let ((res (alonso-tools-tests--run-batch
              (alonso-tools-tests--batch-queue-a) '(run deny))))
    (should (= 2 (car res)))))

(ert-deftest alonso-tools--denying-second-tool-cancels-turn ()
  :tags '(tools)
  (let ((res (alonso-tools-tests--run-batch
              (alonso-tools-tests--batch-queue-a) '(run deny))))
    (should (member "cancel" (cadr res)))))

;; 3) All tools allowed: no cancel, every question asked.

(ert-deftest alonso-tools--all-allowed-each-is-asked ()
  :tags '(tools)
  (let ((res (alonso-tools-tests--run-batch
              (alonso-tools-tests--batch-queue-ab) '(run run))))
    (should (= 2 (car res)))))

(ert-deftest alonso-tools--all-allowed-turn-not-cancelled ()
  :tags '(tools)
  (let ((res (alonso-tools-tests--run-batch
              (alonso-tools-tests--batch-queue-ab) '(run run))))
    (should (not (member "cancel" (cadr res))))))

;;; One-at-a-time display — each mutating tool call is shown (via
;;; `--show-tool-call') interleaved with its own confirmation question, not all
;;; at once before any question.  So with N tools, the event sequence alternates
;;; show/ask (show/ask ... show) — the questions never pile up on screen.

(defun alonso-tools-tests--seq-queue-ab ()
  (list (list :id "a" :name "write"
              :input (alonso--json-plist-to-hash (list "path" "/tmp/a" "content" "x")))
        (list :id "b" :name "shell"
              :input (alonso--json-plist-to-hash (list "command" "echo hi")))))

;; Two tools, both allowed: show, ask, show, ask (each tool is displayed
;; only right before its own question).

(ert-deftest alonso-tools--two-allowed-tools-show-ask-interleaved ()
  :tags '(tools)
  (should (equal '(show ask show ask)
                 (alonso-tools-tests--run-seq
                  (alonso-tools-tests--seq-queue-ab) '(run run)))))

;; Three tools, first denied: show, ask, show, show (the rest are shown and
;; auto-denied one after the other, no further questions).

(ert-deftest alonso-tools--denied-first-tool-show-ask-then-shown ()
  :tags '(tools)
  (should (equal '(show ask show show)
                 (alonso-tools-tests--run-seq
                  (alonso-tools-tests--batch-queue-a) '(deny)))))

;;; Confirmation menu — the question is asked through the transient
;;; `alonso--confirm-menu' when transient is available, and through the
;;; `read-char-choice' prompt (`alonso--ask-user-trust') otherwise.
;;; `alonso--confirm-ask' is the seam that chooses (and that the batch
;;; helpers above stub to answer synchronously).

;; The question shown at the top of the menu is rebuilt from the pending
;; confirmation context (icon + command/pattern/path).

(ert-deftest alonso-tools--confirmation-menu-question-shows-detail ()
  :tags '(tools)
  (let ((alonso--confirm-context
         (list :name "shell"
               :input (alonso--json-plist-to-hash (list "command" "ps aux")))))
    (should (equal "🖥 Run tool: shell · ps aux? "
                   (alonso--confirm-menu-question)))))

;; With the menu available, `--confirm-ask' opens it and does NOT fall back to
;; the minibuffer prompt.

(ert-deftest alonso-tools--confirm-ask-opens-transient-menu ()
  :tags '(tools)
  (let ((opened nil)
        (alonso--confirm-context nil))
    (cl-letf (((symbol-function 'alonso--confirm-menu)
               (lambda () (setq opened t)))
              ((symbol-function 'alonso--ask-user-trust)
               (lambda (_) (error "should not fall back to the char prompt"))))
      (alonso--confirm-ask "shell" (make-hash-table)))
    (should opened)))

;; Without the menu (transient absent), `--confirm-ask' reads a char and
;; forwards the answer to `--confirm-answer' (the fallback path).

(ert-deftest alonso-tools--confirm-ask-falls-back-to-char-prompt ()
  :tags '(tools)
  (let ((answer nil)
        (alonso--confirm-context nil))
    (cl-letf (((symbol-function 'alonso--confirm-menu) nil)
              ((symbol-function 'alonso--ask-user-trust)
               (lambda (_) 'run))
              ((symbol-function 'alonso--confirm-answer)
               (lambda (a) (setq answer a))))
      (alonso--confirm-ask "shell" (make-hash-table)))
    (should (eq answer 'run))))

;; When transient is available at runtime (not in `emacs -Q --batch'), the
;; confirmation menu and its run/deny/trust suffixes are defined.

(ert-deftest alonso-tools--transient-menu-and-suffixes-defined ()
  :tags '(tools)
  (skip-unless (fboundp 'transient-define-prefix))
  (should (and (fboundp 'alonso--confirm-menu)
               (fboundp 'alonso--confirm-run)
               (fboundp 'alonso--confirm-deny)
               (fboundp 'alonso--confirm-trust)
               (fboundp 'alonso--trust-menu))))

;; Wiring of the menu keys.  `t'/`!' must open the Trust sub-menu THROUGH
;; `alonso--confirm-trust' (which routes to
;; `alonso--confirm-answer' -> `--trust-pause'), NOT by binding the
;; key straight to `alonso--trust-menu': the direct binding skipped
;; `--trust-pause', so the sub-menu read an empty `--trust-context' and
;; dispatched a nil tool call, leaving the turn hanging (regression).

(ert-deftest alonso-tools--menu-keys-route-trust-through-confirm-trust ()
  :tags '(tools)
  (skip-unless (fboundp 'transient-define-prefix))
  (setq alonso--confirm-context
        (list :name "shell" :input (make-hash-table :test 'equal)))
  (alonso--confirm-menu)
  (unwind-protect
      (let ((key->cmd '()))
        (when (boundp 'transient--suffixes)
          (dolist (s transient--suffixes)
            (push (cons (oref s key) (oref s command)) key->cmd)))
        (should (and (eq 'alonso--confirm-trust (cdr (assoc "t" key->cmd)))
                     (eq 'alonso--confirm-run (cdr (assoc "r" key->cmd)))
                     (eq 'alonso--confirm-deny (cdr (assoc "d" key->cmd))))))
    (transient--pre-exit)))

;; Regression: the Trust choice (`t' in the menu, `!' in the char-prompt
;; fallback) goes through `alonso--confirm-answer' with `trust', which
;; calls `--trust-pause' — that is what saves the paused tool call in
;; `alonso--trust-context'.  The sub-menu then reads a fully populated
;; context (previously it was nil, so the tool was dispatched with nil
;; name/input/id and nothing ran).

(ert-deftest alonso-tools--confirm-answer-trust-pauses-and-saves-tool ()
  :tags '(tools)
  (let ((opened 0))
    (setq alonso--trust-context nil
          alonso--confirm-context
          (list :name "shell" :id "7"
                :input (alonso--json-plist-to-hash
                        (list "command" "echo hi"))
                :rest '() :denied nil))
    (cl-letf (((symbol-function 'alonso--trust-menu)
               (lambda () (cl-incf opened))))
      (alonso--confirm-answer 'trust))
    (should (and (= 1 opened)
                 (equal "shell" (plist-get alonso--trust-context :name))
                 (equal "7" (plist-get alonso--trust-context :id))))))

(ert-deftest alonso-tools--confirm-answer-trust-consumes-context ()
  :tags '(tools)
  (setq alonso--trust-context nil
        alonso--confirm-context
        (list :name "shell" :id "7"
              :input (alonso--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'alonso--trust-menu)
             (lambda () nil)))
    (alonso--confirm-answer 'trust))
  (should (null alonso--confirm-context)))

;; Regression: answering the trust sub-menu dispatches the REAL paused tool
;; (not a nil one), reading name/input/id from `--trust-context'.

(ert-deftest alonso-tools--trust-finish-dispatches-paused-tool ()
  :tags '(tools)
  (let ((dispatched nil))
    (setq alonso--trust-context
          (list :name "shell" :id "7"
                :input (alonso--json-plist-to-hash
                        (list "command" "echo hi"))
                :rest '() :denied nil)
          alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (cl-letf (((symbol-function 'alonso--dispatch-tool)
               (lambda (name input id) (setq dispatched (list name input id))))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _args) nil)))
      (alonso--trust-finish 'specific))
    (should (and (equal "shell" (car dispatched))
                 (equal "7" (nth 2 dispatched))))))

(ert-deftest alonso-tools--trust-finish-clears-trust-context ()
  :tags '(tools)
  (setq alonso--trust-context
        (list :name "shell" :id "7"
              :input (alonso--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil)
        alonso--trust-specific nil
        alonso--trust-class nil
        alonso--trust-all nil)
  (cl-letf (((symbol-function 'alonso--dispatch-tool) (lambda (&rest _) nil))
            ((symbol-function 'alonso--record-tool-confirmation)
             (lambda (&rest _) nil)))
    (alonso--trust-finish 'specific))
  (should (null alonso--trust-context)))

;;; Closing a menu unanswered (C-g) must not hang the turn
;;
;; The confirmation and trust menus are answered by their suffixes, which set
;; `alonso--menu-answered' and consume the pending context.  If the
;; menu is merely closed (C-g, or any exit that runs no suffix) nothing is
;; sent to the bridge, so the turn would wait forever.  `--menu-exit-hook'
;; detects the still-pending, unanswered context and applies a deny.

;; confirm closed unanswered -> deny, via `--confirm-answer'

(ert-deftest alonso-tools--menu-closed-unanswered-denies-pending ()
  :tags '(tools)
  (let ((answered '()))
    (setq alonso--menu-answered nil
          alonso--trust-context nil
          alonso--confirm-context
          (list :name "shell" :id "1"
                :input (alonso--json-plist-to-hash (list "command" "echo hi"))
                :rest '() :denied nil))
    (cl-letf (((symbol-function 'alonso--confirm-answer)
               (lambda (a) (push a answered)))
              ((symbol-function 'alonso--trust-cancel)
               (lambda () (push 'trust-cancel answered))))
      (alonso--menu-exit-hook)
      (sit-for 0.05))
    (should (equal '(deny) answered))))

;; answered menu -> the exit hook does nothing

(ert-deftest alonso-tools--answered-menu-not-treated-as-abort ()
  :tags '(tools)
  (let ((answered '()))
    (setq alonso--menu-answered t
          alonso--trust-context nil
          alonso--confirm-context
          (list :name "shell" :id "1"
                :input (alonso--json-plist-to-hash (list "command" "echo hi"))
                :rest '() :denied nil))
    (cl-letf (((symbol-function 'alonso--confirm-answer)
               (lambda (a) (push a answered)))
              ((symbol-function 'alonso--trust-cancel)
               (lambda () (push 'trust-cancel answered))))
      (alonso--menu-exit-hook)
      (sit-for 0.05))
    (should (null answered))))

;; trust sub-menu closed unanswered -> --trust-cancel

(ert-deftest alonso-tools--trust-submenu-closed-unanswered-cancels ()
  :tags '(tools)
  (let ((called nil))
    (setq alonso--menu-answered nil
          alonso--confirm-context nil
          alonso--trust-context
          (list :name "shell" :id "1"
                :input (alonso--json-plist-to-hash (list "command" "echo hi"))
                :rest '() :denied nil))
    (cl-letf (((symbol-function 'alonso--confirm-answer)
               (lambda (_a) nil))
              ((symbol-function 'alonso--trust-cancel)
               (lambda () (setq called t))))
      (alonso--menu-exit-hook)
      (sit-for 0.05))
    (should called)))

;; --trust-cancel denies the paused tool and aborts the batch (rest, denied=t)

(ert-deftest alonso-tools--trust-cancel-records-paused-tool-as-denied ()
  :tags '(tools)
  (let ((recorded '()))
    (setq alonso--trust-context
          (list :name "shell" :id "1"
                :input (alonso--json-plist-to-hash (list "command" "echo hi"))
                :rest '(:name "write") :denied nil))
    (cl-letf (((symbol-function 'alonso--confirm-next)
               (lambda (_q _d) nil))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest a) (push a recorded))))
      (alonso--trust-cancel))
    (should (and (= 1 (length recorded))
                 (equal "shell" (car (car recorded)))
                 (null (nth 2 (car recorded)))))))

(ert-deftest alonso-tools--trust-cancel-continues-batch-with-deny-cascade ()
  :tags '(tools)
  (let ((next-args nil))
    (setq alonso--trust-context
          (list :name "shell" :id "1"
                :input (alonso--json-plist-to-hash (list "command" "echo hi"))
                :rest '(:name "write") :denied nil))
    (cl-letf (((symbol-function 'alonso--confirm-next)
               (lambda (q d) (setq next-args (list q d))))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _) nil)))
      (alonso--trust-cancel))
    (should (and (null alonso--trust-context)
                 (equal '((:name "write") t) next-args)))))

;; --trust-finish is a no-op (no nil-tool dispatch) without a paused context

(ert-deftest alonso-tools--trust-finish-no-op-without-paused-tool ()
  :tags '(tools)
  (let ((dispatched nil))
    (setq alonso--trust-context nil)
    (cl-letf (((symbol-function 'alonso--dispatch-tool)
               (lambda (&rest _a) (setq dispatched t))))
      (alonso--trust-finish 'specific))
    (should (null dispatched))))

;; char-prompt fallback aborted with C-g -> deny

(ert-deftest alonso-tools--aborting-char-prompt-denies-confirmation ()
  :tags '(tools)
  (let ((ans '()))
    (setq alonso--confirm-context
          (list :name "shell" :input (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'alonso--confirm-menu) nil)
              ((symbol-function 'alonso--ask-user-trust)
               (lambda (_p) (signal 'quit nil)))
              ((symbol-function 'alonso--confirm-answer)
               (lambda (a) (push a ans))))
      (alonso--confirm-ask "shell" (make-hash-table :test 'equal)))
    (should (equal '(deny) ans))))

;;; Trust scope — class keys, prefix matching, recording and reset

(ert-deftest alonso-tools--shell-class-key-first-command-token ()
  :tags '(tools)
  (should (equal "sed"
                 (alonso--trust-class-key
                  "shell" (alonso--json-plist-to-hash (list "command" "sed -i s/a/b/ f"))))))

(ert-deftest alonso-tools--shell-class-key-nil-without-command ()
  :tags '(tools)
  (should (null (alonso--trust-class-key "shell" (make-hash-table)))))

;; A one-liner that runs several commands has no class: its first token names
;; the first command only, so trusting `cd /tmp && rm -rf x' as `cd' would
;; then cover every command that merely changes directory first.
(ert-deftest alonso-tools--shell-class-key-nil-for-a-compound-line ()
  :tags '(tools)
  (dolist (cmd '("cd /tmp && git status"
                 "git status; git log"
                 "git log | head -1"
                 "git log |& head -1"
                 "git log & sleep 1"
                 "git status\nls"
                 "cd /tmp"
                 "FOO=1 git status"))
    (should (null (alonso--trust-class-key
                   "shell" (alonso--json-plist-to-hash
                            (list "command" cmd)))))))

;; A redirect is not a separator, so a single command that redirects still has
;; its program as the class key (the bridge used to report the `2>&1' as two
;; more commands — see the llm-bridge `Segments' tests).
(ert-deftest alonso-tools--shell-class-key-survives-a-redirect ()
  :tags '(tools)
  (dolist (cmd '("git describe --tags 2>&1"
                 "git log > /tmp/out 2>&1"
                 "git log &> /tmp/out"
                 "cat < /tmp/in"))
    (should (equal (if (string-prefix-p "cat" cmd) "cat" "git")
                   (alonso--trust-class-key
                    "shell" (alonso--json-plist-to-hash
                             (list "command" cmd))))))
  ;; A quoted separator is data, not a second command.
  (should (equal "echo"
                 (alonso--trust-class-key
                  "shell" (alonso--json-plist-to-hash
                           (list "command" "echo \"a && b\""))))))

;; An escaped or single-quoted separator is data too.
(ert-deftest alonso-tools--shell-class-key-ignores-an-escaped-separator ()
  :tags '(tools)
  (dolist (cmd '("echo a\\;b" "echo 'a;b'" "echo a\\&b"))
    (should (equal "echo"
                   (alonso--trust-class-key
                    "shell" (alonso--json-plist-to-hash
                             (list "command" cmd)))))))

;; The class of `git' is offered on a harmless `git status', not on the
;; command that made the risk tag appear.
(ert-deftest alonso-tools--shell-class-key-requires-a-low-risk ()
  :tags '(tools)
  (let ((status (alonso--json-plist-to-hash (list "command" "git status")))
        (commit (alonso--json-plist-to-hash (list "command" "git commit -m x")))
        (push (alonso--json-plist-to-hash (list "command" "git push --force"))))
    (should (equal "git" (alonso--trust-class-key "shell" status "low")))
    (should (null (alonso--trust-class-key "shell" commit "medium")))
    (should (null (alonso--trust-class-key "shell" push "high")))
    ;; Unknown risk (the comparison path in `alonso--trusted-p') still yields
    ;; the key, so a class recorded on a low risk call keeps matching.
    (should (equal "git" (alonso--trust-class-key "shell" status)))))

(ert-deftest alonso-tools--trust-record-refuses-a-high-risk-shell-class ()
  :tags '(tools)
  (let ((alonso--trust-class nil)
        (alonso--trust-all nil))
    (should (null (alonso--trust-record
                   'class "shell"
                   (alonso--json-plist-to-hash (list "command" "git push"))
                   "high")))
    (should (null alonso--trust-class))))

(ert-deftest alonso-tools--trust-class-unavailable-for-a-compound-shell-line ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "shell" :risk "low"
               :input (alonso--json-plist-to-hash
                       (list "command" "cd /tmp && rm -rf x")))))
    (should (null (alonso--trust-class-available-p))))
  (let ((alonso--trust-context
         (list :name "shell" :risk "low"
               :input (alonso--json-plist-to-hash
                       (list "command" "git status")))))
    (should (alonso--trust-class-available-p))))

(ert-deftest alonso-tools--write-class-key-is-path-directory ()
  :tags '(tools)
  (should (equal "/tmp/sub/"
                 (alonso--trust-class-key
                  "write" (alonso--json-plist-to-hash
                           (list "path" "/tmp/sub/x.txt" "content" "x"))))))

(ert-deftest alonso-tools--search-replace-class-key-is-path-directory ()
  :tags '(tools)
  (should (equal "/etc/conf/"
                 (alonso--trust-class-key
                  "search_replace" (alonso--json-plist-to-hash
                                    (list "path" "/etc/conf/y.txt"))))))

(ert-deftest alonso-tools--unknown-tools-have-no-class-key ()
  :tags '(tools)
  (should (null (alonso--trust-class-key
                 "read" (alonso--json-plist-to-hash (list "path" "/tmp/z.txt"))))))

(ert-deftest alonso-tools--shell-class-matches-exactly-not-by-prefix ()
  :tags '(tools)
  (should (and (alonso--class-prefix-p "shell" "sed" "sed")
               (not (alonso--class-prefix-p "shell" "sed" "sedx")))))

(ert-deftest alonso-tools--path-class-trusts-sub-directories ()
  :tags '(tools)
  (should (and (alonso--class-prefix-p "write" "/tmp/" "/tmp/sub/")
               (not (alonso--class-prefix-p "write" "/tmp/sub/" "/tmp/")))))

(ert-deftest alonso-tools--specific-trust-matches-exact-input ()
  :tags '(tools)
  (let ((input (alonso--json-plist-to-hash (list "command" "ls -la /tmp"))))
    (setq alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (alonso--trust-record 'specific "shell" input)
    (should (alonso--trusted-p "shell" input))))

;; The real case: the bridge parses the payload afresh on every
;; `tool_confirm', so the recorded input and the one being checked are two
;; distinct hash tables with the same content (`equal' on hash tables is true
;; only for the same object).

(ert-deftest alonso-tools--specific-trust-matches-an-equal-distinct-input ()
  :tags '(tools)
  (let ((alonso--trust-specific nil)
        (alonso--trust-class nil)
        (alonso--trust-tools nil)
        (alonso--trust-all nil))
    (alonso--trust-record
     'specific "shell" (alonso--json-plist-to-hash (list "command" "ls -la /tmp")))
    (should (alonso--trusted-p
             "shell"
             (alonso--json-plist-to-hash (list "command" "ls -la /tmp"))))))

(ert-deftest alonso-tools--specific-trust-not-cover-different-input ()
  :tags '(tools)
  (let ((input (alonso--json-plist-to-hash (list "command" "ls -la /tmp"))))
    (setq alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (alonso--trust-record 'specific "shell" input)
    (should (not (alonso--trusted-p
                  "shell"
                  (alonso--json-plist-to-hash (list "command" "ls -la /other")))))))

(ert-deftest alonso-tools--class-trust-covers-same-token-commands ()
  :tags '(tools)
  (let ((input (alonso--json-plist-to-hash (list "command" "sed s/a/b/ f"))))
    (setq alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (alonso--trust-record 'class "shell" input)
    (should (alonso--trusted-p
             "shell" (alonso--json-plist-to-hash (list "command" "sed s/c/d/ g"))))))

(ert-deftest alonso-tools--class-trust-not-cover-different-token ()
  :tags '(tools)
  (let ((input (alonso--json-plist-to-hash (list "command" "sed s/a/b/ f"))))
    (setq alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (alonso--trust-record 'class "shell" input)
    (should (not (alonso--trusted-p
                  "shell" (alonso--json-plist-to-hash (list "command" "awk ...")))))))

(ert-deftest alonso-tools--class-trust-not-recorded-without-class-key ()
  :tags '(tools)
  (let ((in (alonso--json-plist-to-hash (list "path" "/tmp/x"))))
    (setq alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (should (and (null (alonso--trust-record 'class "read" in))
                 (null alonso--trust-class)))))

;; The `all' scope covers the tool it was picked FROM, never every tool: the
;; user was looking at that tool's question when choosing it, so a `shell'
;; trust must not vouch for `curl' (let alone for a KB write).

(ert-deftest alonso-tools--all-tool-trust-covers-only-that-tool ()
  :tags '(tools)
  (let ((alonso--trust-tools nil)
        (alonso--trust-all nil)
        (alonso--trust-class nil)
        (alonso--trust-specific nil))
    (alonso--trust-record
     'all "shell" (alonso--json-plist-to-hash (list "command" "echo hi")))
    (should (alonso--trusted-p
             "shell" (alonso--json-plist-to-hash (list "command" "anything"))))
    (should (not (alonso--trusted-p
                  "curl"
                  (alonso--json-plist-to-hash (list "url" "https://example.com/")))))
    (should (null alonso--trust-all))
    (should (equal '("shell") alonso--trust-tools))))

;; `all' needs a tool to trust: without a name nothing is recorded.

(ert-deftest alonso-tools--all-tool-trust-needs-a-tool-name ()
  :tags '(tools)
  (let ((alonso--trust-tools nil))
    (should (null (alonso--trust-record 'all nil nil)))
    (should (null alonso--trust-tools))))

(ert-deftest alonso-tools--reset-session-clears-trust-state ()
  :tags '(tools)
  (let ((in (alonso--json-plist-to-hash (list "command" "sed x"))))
    (setq alonso--trust-specific (list (cons "shell" in))
          alonso--trust-class (list (cons "shell" "sed"))
          alonso--trust-tools (list "shell")
          alonso--trust-all t
          alonso--trust-context (list :name "shell"))
    (alonso--reset-session)
    (should (and (null alonso--trust-specific)
                 (null alonso--trust-class)
                 (null alonso--trust-tools)
                 (null alonso--trust-all)
                 (null alonso--trust-context)))))

;;; `alonso--cancel-confirm' and `alonso--schedule-confirm' — timer handling

;; A pending confirmation timer is cancelled and every pending batch state is
;; cleared.

(ert-deftest alonso-tools--cancel-confirm-cancels-the-timer ()
  :tags '(tools)
  (let* ((timer (run-with-timer 5 nil (lambda () nil)))
         (alonso--confirm-timer timer)
         (alonso--confirm-queue '((:id "a")))
         (alonso--confirm-context (list :name "x"))
         (alonso--trust-context (list :name "y"))
         (alonso--menu-answered t))
    (unwind-protect
        (progn
          (alonso--cancel-confirm)
          (should (and (null alonso--confirm-timer)
                       (null alonso--confirm-queue)
                       (null alonso--confirm-context)
                       (null alonso--trust-context)
                       (null alonso--menu-answered))))
      (when (timerp alonso--confirm-timer)
        (cancel-timer alonso--confirm-timer)))))

;; With no timer there is nothing to cancel; the batch state is still cleared.

(ert-deftest alonso-tools--cancel-confirm-without-timer-clears-state ()
  :tags '(tools)
  (let ((alonso--confirm-timer nil)
        (alonso--confirm-queue '((:id "a"))))
    (alonso--cancel-confirm)
    (should (and (null alonso--confirm-timer)
                 (null alonso--confirm-queue)))))

;; `--schedule-confirm' arms a fresh timer when none is pending ...

(ert-deftest alonso-tools--schedule-confirm-creates-a-timer ()
  :tags '(tools)
  (let ((alonso--confirm-timer nil))
    (unwind-protect
        (progn
          (alonso--schedule-confirm)
          (should (timerp alonso--confirm-timer)))
      (when (timerp alonso--confirm-timer)
        (cancel-timer alonso--confirm-timer)))))

;; ... and replaces a timer still pending from a previous tool_call.

(ert-deftest alonso-tools--schedule-confirm-replaces-an-existing-timer ()
  :tags '(tools)
  (let* ((old (run-with-timer 5 nil (lambda () nil)))
         (alonso--confirm-timer old))
    (unwind-protect
        (progn
          (alonso--schedule-confirm)
          (should (and (timerp alonso--confirm-timer)
                       (not (eq old alonso--confirm-timer)))))
      (when (timerp alonso--confirm-timer)
        (cancel-timer alonso--confirm-timer)))))

;;; `alonso--keep-question-visible' — scrolling a live conversation window

;; With the conversation buffer displayed in a window, the function selects
;; that window, moves to POS and recenters (leaving the original window
;; selected again).

(ert-deftest alonso-tools--keep-question-visible-scrolls-a-live-window ()
  :tags '(tools)
  (let ((buf (alonso-tools-tests--alonso-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "anchor-line\n")))
    (save-window-excursion
      (let ((win (display-buffer buf)))
        (should (window-live-p win))
        (should (progn (alonso--keep-question-visible (point-min)) t))))))

;;; `alonso--ask-user-trust' — the read-char-choice fallback

;; y/Y run once, n/N deny and anything else (`!') opens the trust sub-menu.

(ert-deftest alonso-tools--ask-user-trust-maps-characters ()
  :tags '(tools)
  (let (ch)
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (&rest _) ch)))
      (setq ch ?y) (should (eq 'run (alonso--ask-user-trust "p")))
      (setq ch ?Y) (should (eq 'run (alonso--ask-user-trust "p")))
      (setq ch ?n) (should (eq 'deny (alonso--ask-user-trust "p")))
      (setq ch ?N) (should (eq 'deny (alonso--ask-user-trust "p")))
      (setq ch ?!) (should (eq 'trust (alonso--ask-user-trust "p"))))))

;;; `alonso--trust-description' — the trust sub-menu labels

(ert-deftest alonso-tools--trust-description-all-with-name ()
  :tags '(tools)
  (let ((alonso--trust-context (list :name "shell")))
    (should (equal "This whole tool: shell"
                   (alonso--trust-description 'all)))))

(ert-deftest alonso-tools--trust-description-all-without-name ()
  :tags '(tools)
  (let ((alonso--trust-context nil))
    (should (equal "This whole tool"
                   (alonso--trust-description 'all)))))

;; A `class' with a class key (here: the shell command token) shows the key.

(ert-deftest alonso-tools--trust-description-class-with-key ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "shell"
               :input (alonso--json-plist-to-hash
                       (list "command" "sed -i s/a/b/ f")))))
    (should (equal "This class of calls: sed"
                   (alonso--trust-description 'class)))))

;; A tool without a class key (here: `read') falls back to the bare label.

(ert-deftest alonso-tools--trust-description-class-without-key ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "read"
               :input (alonso--json-plist-to-hash (list "path" "/tmp/x")))))
    (should (equal "This class of calls"
                   (alonso--trust-description 'class)))))

(ert-deftest alonso-tools--trust-description-class-without-input ()
  :tags '(tools)
  (let ((alonso--trust-context (list :name "shell")))
    (should (equal "This class of calls"
                   (alonso--trust-description 'class)))))

(ert-deftest alonso-tools--trust-description-specific-with-detail ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "shell"
               :input (alonso--json-plist-to-hash (list "command" "echo hi")))))
    (should (equal "This specific call: echo hi"
                   (alonso--trust-description 'specific)))))

(ert-deftest alonso-tools--trust-description-specific-without-detail ()
  :tags '(tools)
  (let ((alonso--trust-context nil))
    (should (equal "This specific call"
                   (alonso--trust-description 'specific)))))

(ert-deftest alonso-tools--trust-description-unknown-kind-is-empty ()
  :tags '(tools)
  (let ((alonso--trust-context (list :name "shell")))
    (should (equal "" (alonso--trust-description 'weird)))))

;;; `alonso--trust-finish' — the `[allowed]' fallback when no trust is recorded

;; A `class' scope on a tool without a class key records no trust, so the tool
;; is marked `[allowed]' (not `[trusted]'), dispatched and the batch continues.

(ert-deftest alonso-tools--trust-finish-allowed-when-not-actually-trusted ()
  :tags '(tools)
  (let ((recorded '()))
    (setq alonso--trust-context
          (list :name "read" :id "1"
                :input (alonso--json-plist-to-hash (list "path" "/tmp/x"))
                :rest '() :denied nil)
          alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (cl-letf (((symbol-function 'alonso--dispatch-tool) (lambda (&rest _) nil))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (name _input allowed &optional trust)
                 (push (list name allowed trust) recorded))))
      (alonso--trust-finish 'class))
    (should (equal '(("read" t nil)) recorded))))

;; The `[allowed]' fallback is no longer silent: a `class' scope that records
;; nothing says so, so the user does not think the trust took effect.

(ert-deftest alonso-tools--trust-finish-warns-when-class-not-recorded ()
  :tags '(tools)
  (let ((messages '()))
    (setq alonso--trust-context
          (list :name "knowledge" :id "1"
                :input (alonso-tools-tests--input "command" "add")
                :rest '() :denied nil)
          alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (cl-letf (((symbol-function 'alonso--dispatch-tool) (lambda (&rest _) nil))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (alonso--trust-finish 'class))
    (should (string-match-p "no class to trust" (car messages)))))

;; A `class' trust that DID record announces what it now covers: the trust
;; silences a question the user would otherwise be asked, so it must not be
;; silent itself.

(ert-deftest alonso-tools--trust-finish-announces-a-recorded-class ()
  :tags '(tools)
  (let ((messages '())
        (alonso--trust-specific nil)
        (alonso--trust-class nil)
        (alonso--trust-tools nil)
        (alonso--trust-all nil))
    (setq alonso--trust-context
          (list :name "curl" :id "1"
                :input (alonso-tools-tests--input "url" "https://example.com/x")
                :rest '() :denied nil))
    (cl-letf (((symbol-function 'alonso--dispatch-tool) (lambda (&rest _) nil))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (alonso--trust-finish 'class))
    (should (equal '("curl" . "example.com") (assoc "curl" alonso--trust-class)))
    (should (string-match-p "curl.*example\\.com" (car messages)))))

;; The `all' scope announces the tool it trusts (and only that one).

(ert-deftest alonso-tools--trust-finish-announces-an-all-tool-trust ()
  :tags '(tools)
  (let ((messages '())
        (alonso--trust-specific nil)
        (alonso--trust-class nil)
        (alonso--trust-tools nil)
        (alonso--trust-all nil))
    (setq alonso--trust-context
          (list :name "shell" :id "1"
                :input (alonso-tools-tests--input "command" "echo hi")
                :rest '() :denied nil))
    (cl-letf (((symbol-function 'alonso--dispatch-tool) (lambda (&rest _) nil))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (alonso--trust-finish 'all))
    (should (equal '("shell") alonso--trust-tools))
    (should (string-match-p "trusting every .shell. call" (car messages)))))

;;; `alonso--confirm-next' — an already-trusted tool runs without asking

(ert-deftest alonso-tools--confirm-next-runs-trusted-tool-without-asking ()
  :tags '(tools)
  (let ((asked nil) (dispatched nil))
    (cl-letf (((symbol-function 'alonso--send) (lambda (&rest _) nil))
              ((symbol-function 'alonso--confirm-ask)
               (lambda (&rest _) (setq asked t)))
              ((symbol-function 'alonso--show-tool-call) (lambda (&rest _) nil))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _) nil))
              ((symbol-function 'alonso--dispatch-tool)
               (lambda (name _input _id) (setq dispatched name)))
              (alonso--trust-all t))
      (alonso--confirm-next
       (list (list :id "a" :name "write"
                   :input (alonso--json-plist-to-hash
                           (list "path" "/tmp/a" "content" "x"))))
       nil))
    (should (and (null asked) (equal "write" dispatched)))))

;;; Confirmation metadata — segments, risk and taint
;;
;; Since the prompt-injection hardening the bridge attaches `segments', `risk'
;; and `tainted' to a `tool_confirm'.  They are advisory: they tell the human
;; what an approval really runs, how bad it looks and whether the arguments
;; repeat content fetched earlier.

(defun alonso-tools-tests--input (&rest kv)
  "Build a tool input hash table from KV (alternating key/value pairs)."
  (let ((h (make-hash-table :test 'equal)))
    (cl-loop for (k v) on kv by #'cddr do (puthash k v h))
    h))

(ert-deftest alonso-tools--confirm-meta-nil-without-warnings ()
  :tags '(tools)
  (should (null (alonso--format-confirm-meta nil)))
  (should (null (alonso--format-confirm-meta '(:risk "low")))))

;; A single command is already the parameter block: only a one-liner that runs
;; several commands is spelled out line by line.

(ert-deftest alonso-tools--confirm-meta-single-segment-is-not-listed ()
  :tags '(tools)
  (should (null (alonso--format-confirm-meta '(:segments ("ls"))))))

(ert-deftest alonso-tools--confirm-meta-lists-multiple-segments ()
  :tags '(tools)
  (let ((s (alonso--format-confirm-meta '(:segments ("make" "sudo make install")))))
    (should (string-match-p
             (regexp-quote "runs 2 commands:\n    make\n    sudo make install")
             s))))

(ert-deftest alonso-tools--confirm-meta-high-risk-is-an-error-line ()
  :tags '(tools)
  (let ((s (alonso--format-confirm-meta '(:risk "high"))))
    (should (string-match-p "high risk" s))
    (should (eq 'alonso-error-face (get-text-property 0 'face s)))))

(ert-deftest alonso-tools--confirm-meta-medium-risk ()
  :tags '(tools)
  (should (string-match-p "medium risk"
                          (alonso--format-confirm-meta '(:risk "medium")))))

(ert-deftest alonso-tools--confirm-meta-tainted-warns ()
  :tags '(tools)
  (let ((s (alonso--format-confirm-meta '(:tainted t))))
    (should (string-match-p "possible injection" s))
    (should (eq 'alonso-error-face (get-text-property 0 'face s)))))

;; The warnings are inserted between the header and the parameters.

(ert-deftest alonso-tools--show-tool-call-renders-the-confirm-meta ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max))))
    (alonso--show-tool-call
     "call_meta" "shell" (alonso-tools-tests--input "command" "ls && rm -rf /tmp/x")
     '(:segments ("ls" "rm -rf /tmp/x") :risk "high" :tainted t))
    (let ((text (with-current-buffer buf
                  (buffer-substring-no-properties start (point-max)))))
      (should (and (string-match-p (regexp-quote "runs 2 commands:") text)
                   (string-match-p "high risk" text)
                   (string-match-p "possible injection" text))))))

;; A `knowledge' read is displayed as a read-only title line; a write asks.

(ert-deftest alonso-tools--knowledge-read-is-shown-as-read-only ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max))))
    (alonso--show-tool-call
     "call_k" "knowledge"
     (alonso-tools-tests--input "command" "search" "query" "x"))
    (let ((text (with-current-buffer buf
                  (buffer-substring-no-properties start (point-max)))))
      (should (and (string-match-p (regexp-quote "🧠 knowledge") text)
                   (not (string-match-p (regexp-quote "Run tool:") text)))))))

(ert-deftest alonso-tools--knowledge-write-asks-for-confirmation ()
  :tags '(tools)
  (let* ((buf (alonso-tools-tests--alonso-buffer))
         (start (with-current-buffer buf (point-max))))
    (alonso--show-tool-call
     "call_k" "knowledge"
     (alonso-tools-tests--input "command" "add" "label" "x" "text" "y"))
    (let ((text (with-current-buffer buf
                  (buffer-substring-no-properties start (point-max)))))
      (should (string-match-p (regexp-quote "🧠 Run tool: knowledge?") text)))))

;;; `curl' — a network tool: URL (host highlighted) and request args

(ert-deftest alonso-tools--icon-curl ()
  :tags '(tools)
  (should (equal "🌐" (alonso--tool-icon "curl"))))

(ert-deftest alonso-tools--confirm-question-curl-shows-the-url ()
  :tags '(tools)
  (should (string-match-p
           (regexp-quote "🌐 Run tool: curl · https://example.com/x? ")
           (alonso--confirm-question
            "curl" (alonso-tools-tests--input "url" "https://example.com/x")))))

(ert-deftest alonso-tools--curl-url-parts-splits-an-absolute-url ()
  :tags '(tools)
  (should (equal '("https://" "example.com" "/a/b?q=1")
                 (alonso--curl-url-parts "https://example.com/a/b?q=1"))))

(ert-deftest alonso-tools--curl-url-parts-without-scheme ()
  :tags '(tools)
  (should (equal '("" "example.com/x" "")
                 (alonso--curl-url-parts "example.com/x"))))

(ert-deftest alonso-tools--format-curl-url-highlights-the-host ()
  :tags '(tools)
  (let ((s (alonso--format-curl-url "https://example.com/path")))
    (should (equal "https://example.com/path" (substring-no-properties s)))
    (should (eq 'alonso-command-face (get-text-property 0 'face s)))
    ;; the path stays plain: only the destination is highlighted
    (should (null (get-text-property (length "https://example.com") 'face s)))))

(ert-deftest alonso-tools--format-curl-url-without-scheme-is-plain ()
  :tags '(tools)
  (let ((s (alonso--format-curl-url "example.com/x")))
    (should (equal "example.com/x" s))
    (should (null (get-text-property 0 'face s)))))

(ert-deftest alonso-tools--curl-args-string-lists-each-arg ()
  :tags '(tools)
  (should (equal "  args:\n    -sS\n    -L"
                 (alonso--curl-args-string '("-sS" "-L")))))

(ert-deftest alonso-tools--curl-args-string-nil-when-empty ()
  :tags '(tools)
  (should (null (alonso--curl-args-string nil)))
  (should (null (alonso--curl-args-string "-sS")))
  (should (null (alonso--curl-args-string '("" nil)))))

(ert-deftest alonso-tools--format-curl-shows-url-and-args ()
  :tags '(tools)
  (let ((s (alonso--format-tool-call
            "curl" (alonso-tools-tests--input
                    "url" "https://example.com/x" "args" '("-sS")))))
    (should (string-match-p
             (regexp-quote "url:\n    https://example.com/x") s))
    (should (string-match-p (regexp-quote "args:\n    -sS") s))))

(ert-deftest alonso-tools--format-curl-omits-args-without-them ()
  :tags '(tools)
  (let ((s (alonso--format-tool-call
            "curl" (alonso-tools-tests--input "url" "https://example.com/x"))))
    (should (not (string-match-p "args:" s)))))

(ert-deftest alonso-tools--format-curl-without-url-keeps-the-label ()
  :tags '(tools)
  (should (equal "  url:\n    "
                 (alonso--format-tool-call "curl" (make-hash-table)))))

;; `knowledge' has no trust class on purpose: a class trust on KB writes would
;; let a note planted by an injected page skip the human, and the KB is read by
;; every later session.  `curl' does have one — the URL's host — because that
;; is the meaningful unit for a network fetch.

(ert-deftest alonso-tools--knowledge-has-no-class-key ()
  :tags '(tools)
  (should (null (alonso--trust-class-key
                 "knowledge" (alonso-tools-tests--input "command" "add")))))

;;; `curl' trust class — the URL's host

(ert-deftest alonso-tools--curl-class-key-is-the-host ()
  :tags '(tools)
  (should (equal "example.com"
                 (alonso--trust-class-key
                  "curl" (alonso-tools-tests--input
                          "url" "https://example.com/a/b?q=1")))))

;; The scheme, `user:password@' and the port are all dropped, and the host is
;; lowercased: the port is noise and a host is case-insensitive.
(ert-deftest alonso-tools--curl-class-key-drops-userinfo-port-and-case ()
  :tags '(tools)
  (should (equal "example.com"
                 (alonso--trust-class-key
                  "curl" (alonso-tools-tests--input
                          "url" "https://user:pw@Example.COM:8443/a?b=1")))))

(ert-deftest alonso-tools--curl-class-key-without-scheme ()
  :tags '(tools)
  (should (equal "example.com"
                 (alonso--trust-class-key
                  "curl" (alonso-tools-tests--input "url" "example.com/x")))))

;; A bracketed IPv6 literal keeps its brackets (the port after them goes).
(ert-deftest alonso-tools--curl-class-key-keeps-bracketed-ipv6 ()
  :tags '(tools)
  (should (equal "[::1]"
                 (alonso--trust-class-key
                  "curl" (alonso-tools-tests--input "url" "http://[::1]:8080/x")))))

;; A malformed bracketed authority (no closing bracket) is kept verbatim
;; instead of being mangled — it can only ever trust itself.
(ert-deftest alonso-tools--curl-class-key-tolerates-a-broken-ipv6-literal ()
  :tags '(tools)
  (should (equal "["
                 (alonso--trust-class-key
                  "curl" (alonso-tools-tests--input "url" "http://[")))))

(ert-deftest alonso-tools--curl-class-key-nil-without-a-usable-host ()
  :tags '(tools)
  (should (null (alonso--trust-class-key "curl" (make-hash-table))))
  (should (null (alonso--trust-class-key
                 "curl" (alonso-tools-tests--input "url" ""))))
  (should (null (alonso--trust-class-key
                 "curl" (alonso-tools-tests--input "url" "https://"))))
  (should (null (alonso--trust-class-key "curl" (alonso-tools-tests--input
                                                 "url" 42)))))

;; The host match is exact — a trusted host must not cover a lookalike domain
;; that merely starts with it (the classic `example.com.evil.tld' trap).
(ert-deftest alonso-tools--curl-host-class-matches-exactly-not-by-prefix ()
  :tags '(tools)
  (should (and (alonso--class-prefix-p "curl" "example.com" "example.com")
               (not (alonso--class-prefix-p
                     "curl" "example.com" "example.com.evil.tld")))))

(ert-deftest alonso-tools--curl-class-trust-covers-the-same-host ()
  :tags '(tools)
  (let ((trusted (alonso-tools-tests--input
                  "url" "https://example.com/a"))
         (same-host (alonso-tools-tests--input
                     "url" "http://user@example.com:8080/b?c=d"))
         (other-host (alonso-tools-tests--input
                      "url" "https://example.com.evil.tld/a")))
    (setq alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-all nil)
    (alonso--trust-record 'class "curl" trusted)
    (should (and (alonso--trusted-p "curl" same-host)
                 (not (alonso--trusted-p "curl" other-host))))))

(ert-deftest alonso-tools--trust-description-class-curl-is-the-host ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "curl"
               :input (alonso-tools-tests--input
                       "url" "https://user@example.com:8443/x"))))
    (should (equal "This host, any URL: example.com"
                   (alonso--trust-description 'class)))))

;; The `class' scope is only offered when there is something to trust.
(ert-deftest alonso-tools--trust-class-available-p-for-a-host ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "curl" :input (alonso-tools-tests--input
                                    "url" "https://example.com/x"))))
    (should (alonso--trust-class-available-p))))

(ert-deftest alonso-tools--trust-class-unavailable-for-knowledge ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "knowledge"
               :input (alonso-tools-tests--input "command" "add"))))
    (should (null (alonso--trust-class-available-p)))))

(ert-deftest alonso-tools--trust-class-unavailable-for-a-hostless-curl ()
  :tags '(tools)
  (let ((alonso--trust-context
         (list :name "curl" :input (alonso-tools-tests--input "url" ""))))
    (should (null (alonso--trust-class-available-p))))
  (should (null (alonso--trust-class-available-p))))

;;; Risk — the menu question carries it and `high' forces a typed answer

(ert-deftest alonso-tools--confirm-question-medium-risk-tag ()
  :tags '(tools)
  (should (equal "🔧 Run tool: foo [medium risk]? "
                 (alonso--confirm-question "foo" (make-hash-table) "medium"))))

(ert-deftest alonso-tools--confirm-question-low-risk-omits-the-tag ()
  :tags '(tools)
  (should (equal "🔧 Run tool: foo? "
                 (alonso--confirm-question "foo" (make-hash-table) "low"))))

(ert-deftest alonso-tools--confirmation-menu-question-shows-the-risk ()
  :tags '(tools)
  (let ((alonso--confirm-context
         (list :name "shell" :risk "high"
               :input (alonso-tools-tests--input "command" "rm -rf /"))))
    (should (string-match-p "\\[high risk\\]"
                            (alonso--confirm-menu-question)))))

(ert-deftest alonso-tools--confirm-risk-reads-the-context ()
  :tags '(tools)
  (let ((alonso--confirm-context (list :name "shell" :risk "high")))
    (should (equal "high" (alonso--confirm-risk))))
  (let ((alonso--confirm-context nil))
    (should (null (alonso--confirm-risk)))))

;; The typed prompt only runs on an explicit "yes"; "!" opens the trust menu
;; and anything else (including an empty answer) denies the call.

(ert-deftest alonso-tools--ask-user-typed-maps-the-answer ()
  :tags '(tools)
  (let (answer)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) answer)))
      (setq answer "yes") (should (eq 'run (alonso--ask-user-typed "p")))
      (setq answer " YES ") (should (eq 'run (alonso--ask-user-typed "p")))
      (setq answer "!") (should (eq 'trust (alonso--ask-user-typed "p")))
      (setq answer "y") (should (eq 'deny (alonso--ask-user-typed "p")))
      (setq answer nil) (should (eq 'deny (alonso--ask-user-typed "p"))))))

(ert-deftest alonso-tools--confirm-ask-high-risk-requires-a-typed-answer ()
  :tags '(tools)
  (let ((alonso--confirm-context
         (list :name "shell" :risk "high"
               :input (alonso-tools-tests--input "command" "rm -rf /")))
        (typed nil) (answer nil))
    (cl-letf (((symbol-function 'alonso--confirm-menu)
               (lambda () (error "should not open the menu")))
              ((symbol-function 'alonso--ask-user-typed)
               (lambda (prompt) (setq typed prompt) 'run))
              ((symbol-function 'alonso--confirm-answer)
               (lambda (a) (setq answer a))))
      (alonso--confirm-ask "shell" (alonso-tools-tests--input "command" "rm -rf /")))
    (should (and (string-match-p "high risk" typed) (eq answer 'run)))))

(ert-deftest alonso-tools--confirm-ask-high-risk-abort-denies ()
  :tags '(tools)
  (let ((alonso--confirm-context (list :name "shell" :risk "high"))
        (answer nil))
    (cl-letf (((symbol-function 'alonso--ask-user-typed)
               (lambda (_prompt) (signal 'quit nil)))
              ((symbol-function 'alonso--confirm-answer)
               (lambda (a) (setq answer a))))
      (alonso--confirm-ask "shell" nil))
    (should (eq answer 'deny))))

;;; The queue entry carries the metadata into the display and the context

(ert-deftest alonso-tools--tool-meta-picks-the-queue-fields ()
  :tags '(tools)
  (should (equal '(:segments ("a" "b") :risk "high" :tainted t)
                 (alonso--tool-meta (list :id "1" :segments '("a" "b")
                                          :risk "high" :tainted t)))))

(ert-deftest alonso-tools--confirm-next-passes-the-meta-and-risk ()
  :tags '(tools)
  (let (shown ctx)
    (cl-letf (((symbol-function 'alonso--show-tool-call)
               (lambda (_id _name _input &optional meta) (setq shown meta)))
              ((symbol-function 'alonso--confirm-ask)
               (lambda (&rest _) (setq ctx alonso--confirm-context)))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _) nil))
              ((symbol-function 'alonso--keep-question-visible)
               (lambda (&rest _) nil))
              (alonso--trust-specific nil)
              (alonso--trust-class nil)
              (alonso--trust-all nil))
      (alonso--confirm-next
       (list (list :id "1" :name "shell" :input (make-hash-table)
                   :segments '("a" "b") :risk "high" :tainted t))
       nil))
    (should (equal "high" (plist-get shown :risk)))
    (should (equal '("a" "b") (plist-get shown :segments)))
    (should (plist-get shown :tainted))
    (should (equal "high" (plist-get ctx :risk)))))

;;; A trust never approves a `high' risk call by itself

;; A trust silences the questions that come after it, not the typed `yes' that
;; makes a `high' risk call safe: a `git' class trust must not turn
;; `git push --force' into a silent run.
(ert-deftest alonso-tools--trusted-high-risk-is-still-asked ()
  :tags '(tools)
  (let ((asked nil) (dispatched nil) (tag nil)
        (alonso--trust-tools '("shell"))
        (alonso--trust-all nil)
        (alonso--trust-class nil)
        (alonso--trust-specific nil))
    (cl-letf (((symbol-function 'alonso--show-tool-call)
               (lambda (&rest _) nil))
              ((symbol-function 'alonso--confirm-ask)
               (lambda (&rest _) (setq asked t)))
              ((symbol-function 'alonso--dispatch-tool-guarded)
               (lambda (&rest _) (setq dispatched t)))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest a) (setq tag (nth 2 a))))
              ((symbol-function 'alonso--keep-question-visible)
               (lambda (&rest _) nil)))
      (alonso--confirm-next
       (list (list :id "1" :name "shell"
                   :input (alonso--json-plist-to-hash
                           (list "command" "git push --force"))
                   :risk "high"))
       nil))
    (should (and asked (not dispatched) (null tag)))))

;; The same trust does skip the question for a low risk call.
(ert-deftest alonso-tools--trusted-low-risk-is-not-asked ()
  :tags '(tools)
  (let ((asked nil) (dispatched nil)
        (alonso--trust-tools '("shell"))
        (alonso--trust-all nil)
        (alonso--trust-class nil)
        (alonso--trust-specific nil))
    (cl-letf (((symbol-function 'alonso--show-tool-call)
               (lambda (&rest _) nil))
              ((symbol-function 'alonso--confirm-ask)
               (lambda (&rest _) (setq asked t)))
              ((symbol-function 'alonso--dispatch-tool-guarded)
               (lambda (&rest _) (setq dispatched t)))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest _) nil)))
      (alonso--confirm-next
       (list (list :id "1" :name "shell"
                   :input (alonso--json-plist-to-hash
                           (list "command" "git status"))
                   :risk "low"))
       nil))
    (should (and dispatched (not asked)))))

;; Picking a trust scope while confirming a `high' risk call records the trust
;; and still asks for the typed `yes' this time.
(ert-deftest alonso-tools--trust-finish-high-risk-still-asks-typed ()
  :tags '(tools)
  (let ((asked nil) (dispatched nil) (tag nil)
        (alonso--trust-tools nil)
        (alonso--trust-all nil)
        (alonso--trust-class nil)
        (alonso--trust-specific nil))
    (setq alonso--trust-context
          (list :name "shell" :id "1" :risk "high"
                :input (alonso--json-plist-to-hash (list "command" "git push"))
                :rest nil :denied nil))
    (cl-letf (((symbol-function 'alonso--confirm-ask)
               (lambda (&rest _) (setq asked t)))
              ((symbol-function 'alonso--dispatch-tool-guarded)
               (lambda (&rest _) (setq dispatched t)))
              ((symbol-function 'alonso--record-tool-confirmation)
               (lambda (&rest a) (setq tag (nth 2 a)))))
      (alonso--trust-finish 'all))
    ;; The trust was recorded (it covers the calls that follow)...
    (should (member "shell" alonso--trust-tools))
    ;; ...but this call is not run on the strength of it, and it is not tagged
    ;; `[trusted]' before the typed answer says so.
    (should (and asked (not dispatched) (null tag)))))

(provide 'alonso-tools-tests)

;;; alonso-tools-tests.el ends here
