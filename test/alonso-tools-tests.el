;;; alonso-tools-tests.el --- Tests for the alonso tool-call display, confirmation and trust scope.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso tool-call display, confirmation and trust scope.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT (phase 3 of ERT-MIGRATION.md): one `ert-deftest' per
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
              (alonso--tool-procs nil)
              (alonso--trust-specific nil)
              (alonso--trust-class nil)
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
  (let ((opened nil))
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
  (let ((answer nil))
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

(ert-deftest alonso-tools--all-tool-trust-makes-every-call-trusted ()
  :tags '(tools)
  (let ((input (alonso--json-plist-to-hash (list "command" "echo hi"))))
    (setq alonso--trust-all nil)
    (alonso--trust-record 'all "shell" input)
    (unwind-protect
        (should (alonso--trusted-p
                 "shell" (alonso--json-plist-to-hash (list "command" "anything"))))
      (setq alonso--trust-all nil))))

(ert-deftest alonso-tools--reset-session-clears-trust-state ()
  :tags '(tools)
  (let ((in (alonso--json-plist-to-hash (list "command" "sed x"))))
    (setq alonso--trust-specific (list (cons "shell" in))
          alonso--trust-class (list (cons "shell" "sed"))
          alonso--trust-all t
          alonso--trust-context (list :name "shell"))
    (alonso--reset-session)
    (should (and (null alonso--trust-specific)
                 (null alonso--trust-class)
                 (null alonso--trust-all)
                 (null alonso--trust-context)))))

(provide 'alonso-tools-tests)

;;; alonso-tools-tests.el ends here
