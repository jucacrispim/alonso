;;; alonso-tools-tests.el --- Tests for the alonso tool-call display, confirmation and trust scope.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso tool-call display, confirmation and trust scope.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'alonso-tests-lib)

;;; Tool confirmation UI — unicode icons and command/pattern/path in blue

(alonso-tests--assert
 "shell gets a terminal icon"
 (equal "🖥" (alonso--tool-icon "shell")))
(alonso-tests--assert
 "grep gets a magnifying glass"
 (equal "🔎" (alonso--tool-icon "grep")))
(alonso-tests--assert
 "glob gets a magnifying glass"
 (equal "🔎" (alonso--tool-icon "glob")))
(alonso-tests--assert
 "unknown tool falls back to a wrench"
 (equal "🔧" (alonso--tool-icon "something_else")))

(let ((shell-in (alonso--json-plist-to-hash (list "command" "ps aux")))
      (pat-in (alonso--json-plist-to-hash (list "pattern" "TODO")))
      (path-in (alonso--json-plist-to-hash (list "path" "/tmp/x.el"))))
  (alonso-tests--assert
   "confirm question for shell shows the command"
   (string-match-p (regexp-quote "🖥 Run tool: shell · ps aux? ")
                   (alonso--confirm-question "shell" shell-in)))
  (alonso-tests--assert
   "confirm question for grep shows the pattern"
   (string-match-p (regexp-quote "🔎 Run tool: grep · TODO? ")
                   (alonso--confirm-question "grep" pat-in)))
  (alonso-tests--assert
   "confirm question for write shows the path"
   (string-match-p (regexp-quote "✏️ Run tool: write · /tmp/x.el? ")
                   (alonso--confirm-question "write" path-in)))
  (alonso-tests--assert
   "confirm question without detail omits the separator"
   (equal "🔧 Run tool: foo? "
          (alonso--confirm-question "foo" (make-hash-table)))))

;;; Tool confirmation — the question line is shown from the start (before the
;;; parameters/diff) and the `[allowed]' / `[denied]' tag is prepended to the
;;; front of that same line after the user answers

(let* ((buf (get-buffer "alonso"))
       (start (with-current-buffer buf (point-max)))
       (ret (alonso--insert-propertized "test-text\n")))
  (alonso-tests--assert
   "insert-propertized returns the start position of the text"
   (and (= start ret)
        (string-match-p "test-text"
                        (with-current-buffer buf (buffer-string))))))

;; A search_replace with a large diff: the question line appears *before* the
;; parameters (at the top) and the `[allowed]' tag is prepended to it.
(let* ((buf (get-buffer "alonso"))
       (start (with-current-buffer buf (point-max)))
       (sr-input (alonso--json-plist-to-hash
                  (list "path" "/tmp/x.txt"
                        "search" "aaaa\nbbbb\ncccc\n"
                        "replace" "XXXX\nYYYY\nZZZZ\n")))
       (pos (progn
              (alonso--show-tool-call "call_1" "search_replace" sr-input)
              (alonso--record-tool-confirmation "search_replace" sr-input t))))
  (alonso-tests--assert
   "allowed confirmation is recorded in the buffer (icon + tool name)"
   (string-match-p
    (regexp-quote "[allowed] 🔁 Run tool: search_replace? ")
    (with-current-buffer buf (buffer-string))))
  (let ((text (with-current-buffer buf
                (buffer-substring-no-properties start (point-max)))))
    (alonso-tests--assert
     "question is shown before the parameters (top of the tool call)"
     (let ((qpos (string-match
                  (regexp-quote "[allowed] 🔁 Run tool: search_replace? ")
                  text))
           (dpos (string-match (regexp-quote "path: /tmp/x.txt") text)))
       (and qpos dpos (< qpos dpos)))))
  (alonso-tests--assert
   "question points to the visible confirmation line"
   (equal "[allowed] 🔁 Run tool: search_replace? "
          (with-current-buffer buf
            (buffer-substring-no-properties
             pos (+ pos (length "[allowed] 🔁 Run tool: search_replace? "))))))
  (alonso-tests--assert
   "keep-question-visible does not break without a visible window (batch)"
   (progn (alonso--keep-question-visible pos) t)))

;; A plain (generic) tool call: the header no longer repeats the command (which
;; used to duplicate the parameter block); the parameter is instead shown as a
;; bold `command:' label with its value indented on the following line, and the
;; value appears exactly once in the whole tool-call display.
(let* ((buf (get-buffer "alonso"))
       (start (with-current-buffer buf (point-max)))
       (shell-input (alonso--json-plist-to-hash (list "command" "ls -la"))))
  (alonso--show-tool-call "call_2" "shell" shell-input)
  (let ((text (with-current-buffer buf
                (buffer-substring-no-properties start (point-max)))))
    (alonso-tests--assert
     "mutating tool header does not repeat the command detail"
     (and (string-match-p (regexp-quote "🖥 Run tool: shell? ") text)
          (not (string-match-p (regexp-quote "Run tool: shell · ") text))))
    (alonso-tests--assert
     "the command appears exactly once (only in the parameter block)"
     (let ((n 0) (from 0))
       (while (string-match (regexp-quote "ls -la") text from)
         (setq from (match-end 0))
         (cl-incf n))
       (= 1 n)))
    (alonso-tests--assert
     "the command label and value are on separate lines, value indented"
     (string-match-p (regexp-quote "  command:\n    ls -la") text)))
  (alonso-tests--assert
   "the command label is propertized in the bold command face"
   (let ((lpos (with-current-buffer buf
                 (- (save-excursion
                      (goto-char start)
                      (search-forward "command:" nil t))
                    (length "command:")))))
     (eq 'alonso-command-face (get-text-property lpos 'face buf)))))

;; No preceding tool call: the confirmation falls back to the end of the buffer.
(let* ((buf (get-buffer "alonso"))
       (start (with-current-buffer buf (point-max)))
       (alonso--tool-call-pos nil)
       (shell-input (alonso--json-plist-to-hash (list "command" "ps aux")))
       (pos (alonso--record-tool-confirmation "shell" shell-input nil)))
  (alonso-tests--assert
   "denied fallback is appended to the buffer"
   (string-match-p "\\[denied\\] "
                   (with-current-buffer buf
                     (buffer-substring-no-properties start (point-max)))))
  (alonso-tests--assert
   "confirmation recorded at the captured start point (end fallback)"
   (>= pos start))
  (alonso-tests--assert
   "keep-question-visible does not break without a visible window (batch)"
   (progn (alonso--keep-question-visible pos) t)))

;;; Batch confirmation — one denied tool refuses the rest without asking and
;;; cancels the turn (the conversation stops waiting for the user's input)

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
(cl-labels
    ((run-batch (queue answers)
       (let ((sent '())
             (asked 0)
             (start (with-current-buffer (get-buffer "alonso")
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
                 (with-current-buffer (get-buffer "alonso") (point-max)))
           (alonso--confirm-pending))
         (list asked (nreverse sent)
               (with-current-buffer (get-buffer "alonso")
                 (buffer-substring-no-properties start (point-max)))))))
  ;; 1) Deny the first of three tools: no further questions, every remaining
  ;; tool is auto-denied and the turn is cancelled.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (alonso--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (res (run-batch queue '(deny))))
    (alonso-tests--assert
     "denying the first tool asks only once (no questions for the rest)"
     (= 1 (car res)))
    (alonso-tests--assert
     "a denied tool sends cancel to stop the turn"
     (member "cancel" (cadr res)))
    (let ((text (nth 2 res))
          (n 0))
      (let ((from 0))
        (while (string-match "\\[denied\\] " text from)
          (setq from (match-end 0))
          (cl-incf n)))
      (alonso-tests--assert
       "every tool of the batch shows a [denied] tag, nothing allowed"
       (and (= 3 n)
            (not (string-match-p "\\[allowed\\] " text))))))
  ;; 2) Deny the second of three tools: the first is allowed, the second is
  ;; asked and denied, the third is auto-denied (no question) and the turn is
  ;; cancelled.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (alonso--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (res (run-batch queue '(run deny))))
    (alonso-tests--assert
     "denying the second tool asks only twice (third auto-denied)"
     (= 2 (car res)))
    (alonso-tests--assert
     "denying the second tool also cancels the turn"
     (member "cancel" (cadr res))))
  ;; 3) All tools allowed: no cancel, every question asked.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))))
         (res (run-batch queue '(run run))))
    (alonso-tests--assert
     "when all tools are allowed, each is asked"
     (= 2 (car res)))
    (alonso-tests--assert
     "when all tools are allowed, the turn is NOT cancelled"
     (not (member "cancel" (cadr res))))))

;;; One-at-a-time display — each mutating tool call is shown (via
;;; `--show-tool-call') interleaved with its own confirmation question, not all
;;; at once before any question.  So with N tools, the event sequence alternates
;;; show/ask (show/ask ... show) — the questions never pile up on screen.

(cl-labels
    ((run-seq (queue answers)
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
         (nreverse events))))
  ;; Two tools, both allowed: show, ask, show, ask (each tool is displayed
  ;; only right before its own question).
  (let* ((queue (list (list :id "a" :name "write"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "shell"
                            :input (alonso--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (events (run-seq queue '(run run))))
    (alonso-tests--assert
     "two allowed tools: show/ask interleaved (not both shown up front)"
     (equal '(show ask show ask) events)))
  ;; Three tools, first denied: show, ask, show, show (the rest are shown and
  ;; auto-denied one after the other, no further questions).
  (let* ((queue (list (list :id "a" :name "write"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (alonso--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (alonso--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (events (run-seq queue '(deny))))
    (alonso-tests--assert
     "denied first tool: shown+asked first, the rest shown (auto-denied) after"
     (equal '(show ask show show) events))))

;;; Confirmation menu — the question is asked through the transient
;;; `alonso--confirm-menu' when transient is available, and through the
;;; `read-char-choice' prompt (`alonso--ask-user-trust') otherwise.
;;; `alonso--confirm-ask' is the seam that chooses (and that the batch
;;; helpers above stub to answer synchronously).

;; The question shown at the top of the menu is rebuilt from the pending
;; confirmation context (icon + command/pattern/path).
(let ((alonso--confirm-context
       (list :name "shell"
             :input (alonso--json-plist-to-hash (list "command" "ps aux")))))
  (alonso-tests--assert
   "the confirmation menu question shows the tool detail"
   (equal "🖥 Run tool: shell · ps aux? "
          (alonso--confirm-menu-question))))

;; With the menu available, `--confirm-ask' opens it and does NOT fall back to
;; the minibuffer prompt.
(let ((opened nil))
  (cl-letf (((symbol-function 'alonso--confirm-menu)
             (lambda () (setq opened t)))
            ((symbol-function 'alonso--ask-user-trust)
             (lambda (_) (error "should not fall back to the char prompt"))))
    (alonso--confirm-ask "shell" (make-hash-table)))
  (alonso-tests--assert
   "confirm-ask opens the transient menu when it is available" opened))

;; Without the menu (transient absent), `--confirm-ask' reads a char and
;; forwards the answer to `--confirm-answer' (the fallback path).
(let ((answer nil))
  (cl-letf (((symbol-function 'alonso--confirm-menu) nil)
            ((symbol-function 'alonso--ask-user-trust)
             (lambda (_) 'run))
            ((symbol-function 'alonso--confirm-answer)
             (lambda (a) (setq answer a))))
    (alonso--confirm-ask "shell" (make-hash-table)))
  (alonso-tests--assert
   "confirm-ask falls back to the char prompt and forwards the answer"
   (eq answer 'run)))

;; When transient is available at runtime (not in `emacs -Q --batch'), the
;; confirmation menu and its run/deny/trust suffixes are defined.
(when (fboundp 'transient-define-prefix)
  (alonso-tests--assert
   "the transient confirmation menu and its suffixes are defined"
   (and (fboundp 'alonso--confirm-menu)
        (fboundp 'alonso--confirm-run)
        (fboundp 'alonso--confirm-deny)
        (fboundp 'alonso--confirm-trust)
        (fboundp 'alonso--trust-menu)))
  ;; Wiring of the menu keys.  `t'/`!' must open the Trust sub-menu THROUGH
  ;; `alonso--confirm-trust' (which routes to
  ;; `alonso--confirm-answer' -> `--trust-pause'), NOT by binding the
  ;; key straight to `alonso--trust-menu': the direct binding skipped
  ;; `--trust-pause', so the sub-menu read an empty `--trust-context' and
  ;; dispatched a nil tool call, leaving the turn hanging (regression).
  (setq alonso--confirm-context
        (list :name "shell" :input (make-hash-table :test 'equal)))
  (alonso--confirm-menu)
  (let ((key->cmd '()))
    (when (boundp 'transient--suffixes)
      (dolist (s transient--suffixes)
        (push (cons (oref s key) (oref s command)) key->cmd)))
    (alonso-tests--assert
     "the menu's t key routes the trust choice through --confirm-trust"
     (and (eq 'alonso--confirm-trust (cdr (assoc "t" key->cmd)))
          (eq 'alonso--confirm-run (cdr (assoc "r" key->cmd)))
          (eq 'alonso--confirm-deny (cdr (assoc "d" key->cmd)))))
    (transient--pre-exit)))

;; Regression: the Trust choice (`t' in the menu, `!' in the char-prompt
;; fallback) goes through `alonso--confirm-answer' with `trust', which
;; calls `--trust-pause' — that is what saves the paused tool call in
;; `alonso--trust-context'.  The sub-menu then reads a fully populated
;; context (previously it was nil, so the tool was dispatched with nil
;; name/input/id and nothing ran).
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
  (alonso-tests--assert
   "confirm-answer 'trust pauses and saves the tool in the trust context"
   (and (= 1 opened)
        (equal "shell" (plist-get alonso--trust-context :name))
        (equal "7" (plist-get alonso--trust-context :id))))
  (alonso-tests--assert
   "confirm-answer consumes the pending confirmation context"
   (null alonso--confirm-context)))

;; Regression: answering the trust sub-menu dispatches the REAL paused tool
;; (not a nil one), reading name/input/id from `--trust-context'.
(let ((dispatched nil)
      (recorded nil))
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
             (lambda (&rest args) (push args recorded))))
    (alonso--trust-finish 'specific))
  (alonso-tests--assert
   "trust-finish dispatches the paused tool (not a nil one)"
   (and (equal "shell" (car dispatched))
        (equal "7" (nth 2 dispatched))))
  (alonso-tests--assert
   "trust-finish clears the trust context after resuming"
   (null alonso--trust-context)))

;;; Closing a menu unanswered (C-g) must not hang the turn
;;
;; The confirmation and trust menus are answered by their suffixes, which set
;; `alonso--menu-answered' and consume the pending context.  If the
;; menu is merely closed (C-g, or any exit that runs no suffix) nothing is
;; sent to the bridge, so the turn would wait forever.  `--menu-exit-hook'
;; detects the still-pending, unanswered context and applies a deny.

;; confirm closed unanswered -> deny, via `--confirm-answer'
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
  (alonso-tests--assert
   "menu closed unanswered denies the pending confirmation"
   (equal '(deny) answered)))

;; answered menu -> the exit hook does nothing
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
  (alonso-tests--assert
   "an answered menu is not treated as an abort"
   (null answered)))

;; trust sub-menu closed unanswered -> --trust-cancel
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
  (alonso-tests--assert
   "trust sub-menu closed unanswered cancels the paused choice"
   called))

;; --trust-cancel denies the paused tool and aborts the batch (rest, denied=t)
(let ((recorded '())
      (next-args nil))
  (setq alonso--trust-context
        (list :name "shell" :id "1"
              :input (alonso--json-plist-to-hash (list "command" "echo hi"))
              :rest '(:name "write") :denied nil))
  (cl-letf (((symbol-function 'alonso--confirm-next)
             (lambda (q d) (setq next-args (list q d))))
            ((symbol-function 'alonso--record-tool-confirmation)
             (lambda (&rest a) (push a recorded))))
    (alonso--trust-cancel))
  (alonso-tests--assert
   "trust-cancel records the paused tool as denied"
   (and (= 1 (length recorded))
        (equal "shell" (car (car recorded)))
        (null (nth 2 (car recorded)))))
  (alonso-tests--assert
   "trust-cancel continues the batch with the deny cascade"
   (and (null alonso--trust-context)
        (equal '((:name "write") t) next-args))))

;; --trust-finish is a no-op (no nil-tool dispatch) without a paused context
(let ((dispatched nil))
  (setq alonso--trust-context nil)
  (cl-letf (((symbol-function 'alonso--dispatch-tool)
             (lambda (&rest _a) (setq dispatched t))))
    (alonso--trust-finish 'specific))
  (alonso-tests--assert
   "trust-finish does nothing when no tool is paused"
   (null dispatched)))

;; char-prompt fallback aborted with C-g -> deny
(let ((ans '()))
  (setq alonso--confirm-context
        (list :name "shell" :input (make-hash-table :test 'equal)))
  (cl-letf (((symbol-function 'alonso--confirm-menu) nil)
            ((symbol-function 'alonso--ask-user-trust)
             (lambda (_p) (signal 'quit nil)))
            ((symbol-function 'alonso--confirm-answer)
             (lambda (a) (push a ans))))
    (alonso--confirm-ask "shell" (make-hash-table :test 'equal)))
  (alonso-tests--assert
   "aborting the char-prompt fallback denies the confirmation"
   (equal '(deny) ans)))

;;; Trust scope — class keys, prefix matching, recording and reset

(alonso-tests--assert
 "shell class key is the first command token"
 (equal "sed"
        (alonso--trust-class-key
         "shell" (alonso--json-plist-to-hash (list "command" "sed -i s/a/b/ f")))))
(alonso-tests--assert
 "shell class key is nil without a command"
 (null (alonso--trust-class-key "shell" (make-hash-table))))
(alonso-tests--assert
 "write class key is the path directory"
 (equal "/tmp/sub/"
        (alonso--trust-class-key
         "write" (alonso--json-plist-to-hash (list "path" "/tmp/sub/x.txt" "content" "x")))))
(alonso-tests--assert
 "search_replace class key is the path directory"
 (equal "/etc/conf/"
        (alonso--trust-class-key
         "search_replace" (alonso--json-plist-to-hash (list "path" "/etc/conf/y.txt")))))
(alonso-tests--assert
 "unknown tools have no class key"
 (null (alonso--trust-class-key
        "read" (alonso--json-plist-to-hash (list "path" "/tmp/z.txt")))))

(alonso-tests--assert
 "shell class matches exactly (not by prefix)"
 (and (alonso--class-prefix-p "shell" "sed" "sed")
      (not (alonso--class-prefix-p "shell" "sed" "sedx"))))
(alonso-tests--assert
 "path class trusts sub-directories"
 (and (alonso--class-prefix-p "write" "/tmp/" "/tmp/sub/")
      (not (alonso--class-prefix-p "write" "/tmp/sub/" "/tmp/"))))

(let ((input (alonso--json-plist-to-hash (list "command" "ls -la /tmp"))))
  (setq alonso--trust-specific nil
        alonso--trust-class nil
        alonso--trust-all nil)
  (alonso--trust-record 'specific "shell" input)
  (alonso-tests--assert
   "specific trust matches the exact same input"
   (alonso--trusted-p "shell" input))
  (alonso-tests--assert
   "specific trust does not cover a different input"
   (not (alonso--trusted-p
         "shell"
         (alonso--json-plist-to-hash (list "command" "ls -la /other"))))))

(let ((input (alonso--json-plist-to-hash (list "command" "sed s/a/b/ f"))))
  (setq alonso--trust-specific nil
        alonso--trust-class nil
        alonso--trust-all nil)
  (alonso--trust-record 'class "shell" input)
  (alonso-tests--assert
   "class trust covers other commands starting with the same token"
   (alonso--trusted-p
    "shell" (alonso--json-plist-to-hash (list "command" "sed s/c/d/ g"))))
  (alonso-tests--assert
   "class trust does not cover a different command token"
   (not (alonso--trusted-p
         "shell" (alonso--json-plist-to-hash (list "command" "awk ..."))))))

(let ((in (alonso--json-plist-to-hash (list "path" "/tmp/x"))))
  (setq alonso--trust-specific nil
        alonso--trust-class nil
        alonso--trust-all nil)
  (alonso-tests--assert
   "class trust is not recorded without a class key"
   (and (null (alonso--trust-record 'class "read" in))
        (null alonso--trust-class))))

(let ((input (alonso--json-plist-to-hash (list "command" "echo hi"))))
  (setq alonso--trust-all nil)
  (alonso--trust-record 'all "shell" input)
  (alonso-tests--assert
   "all-tool trust makes every call trusted"
   (alonso--trusted-p
    "shell" (alonso--json-plist-to-hash (list "command" "anything"))))
  (setq alonso--trust-all nil))

(let ((in (alonso--json-plist-to-hash (list "command" "sed x"))))
  (setq alonso--trust-specific (list (cons "shell" in))
        alonso--trust-class (list (cons "shell" "sed"))
        alonso--trust-all t
        alonso--trust-context (list :name "shell"))
  (alonso--reset-session)
  (alonso-tests--assert
   "reset-session clears the trust state"
   (and (null alonso--trust-specific)
        (null alonso--trust-class)
        (null alonso--trust-all)
        (null alonso--trust-context))))

(provide 'alonso-tools-tests)

;;; alonso-tools-tests.el ends here
