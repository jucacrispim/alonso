;;; tagarela-tools-tests.el --- Tests for the tagarela tool-call display, confirmation and trust scope.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the tagarela tool-call display, confirmation and trust scope.
;;
;; Part of the tagarela test suite; `tagarela-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'tagarela-tests-lib)

;;; Tool confirmation UI — unicode icons and command/pattern/path in blue

(tagarela-tests--assert
 "shell gets a terminal icon"
 (equal "🖥" (tagarela--tool-icon "shell")))
(tagarela-tests--assert
 "grep gets a magnifying glass"
 (equal "🔎" (tagarela--tool-icon "grep")))
(tagarela-tests--assert
 "glob gets a magnifying glass"
 (equal "🔎" (tagarela--tool-icon "glob")))
(tagarela-tests--assert
 "unknown tool falls back to a wrench"
 (equal "🔧" (tagarela--tool-icon "something_else")))

(let ((shell-in (tagarela--json-plist-to-hash (list "command" "ps aux")))
      (pat-in (tagarela--json-plist-to-hash (list "pattern" "TODO")))
      (path-in (tagarela--json-plist-to-hash (list "path" "/tmp/x.el"))))
  (tagarela-tests--assert
   "confirm question for shell shows the command"
   (string-match-p (regexp-quote "🖥 Run tool: shell · ps aux? ")
                   (tagarela--confirm-question "shell" shell-in)))
  (tagarela-tests--assert
   "confirm question for grep shows the pattern"
   (string-match-p (regexp-quote "🔎 Run tool: grep · TODO? ")
                   (tagarela--confirm-question "grep" pat-in)))
  (tagarela-tests--assert
   "confirm question for write shows the path"
   (string-match-p (regexp-quote "✏️ Run tool: write · /tmp/x.el? ")
                   (tagarela--confirm-question "write" path-in)))
  (tagarela-tests--assert
   "confirm question without detail omits the separator"
   (equal "🔧 Run tool: foo? "
          (tagarela--confirm-question "foo" (make-hash-table)))))

;;; Tool confirmation — the question line is shown from the start (before the
;;; parameters/diff) and the `[allowed]' / `[denied]' tag is prepended to the
;;; front of that same line after the user answers

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max)))
       (ret (tagarela--insert-propertized "test-text\n")))
  (tagarela-tests--assert
   "insert-propertized returns the start position of the text"
   (and (= start ret)
        (string-match-p "test-text"
                        (with-current-buffer buf (buffer-string))))))

;; A search_replace with a large diff: the question line appears *before* the
;; parameters (at the top) and the `[allowed]' tag is prepended to it.
(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max)))
       (sr-input (tagarela--json-plist-to-hash
                  (list "path" "/tmp/x.txt"
                        "search" "aaaa\nbbbb\ncccc\n"
                        "replace" "XXXX\nYYYY\nZZZZ\n")))
       (pos (progn
              (tagarela--show-tool-call "call_1" "search_replace" sr-input)
              (tagarela--record-tool-confirmation "search_replace" sr-input t))))
  (tagarela-tests--assert
   "allowed confirmation is recorded in the buffer (icon + path in blue)"
   (string-match-p
    (regexp-quote "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? ")
    (with-current-buffer buf (buffer-string))))
  (let ((text (with-current-buffer buf
                (buffer-substring-no-properties start (point-max)))))
    (tagarela-tests--assert
     "question is shown before the parameters (top of the tool call)"
     (let ((qpos (string-match
                  (regexp-quote "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? ")
                  text))
           (dpos (string-match (regexp-quote "path: /tmp/x.txt") text)))
       (and qpos dpos (< qpos dpos)))))
  (tagarela-tests--assert
   "question points to the visible confirmation line"
   (equal "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? "
          (with-current-buffer buf
            (buffer-substring-no-properties
             pos (+ pos (length "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? "))))))
  (tagarela-tests--assert
   "command fragment is propertized in blue"
   (get-text-property
    (+ pos (length "[allowed] 🔁 Run tool: search_replace · ")) 'face buf))
  (tagarela-tests--assert
   "keep-question-visible does not break without a visible window (batch)"
   (progn (tagarela--keep-question-visible pos) t)))

;; No preceding tool call: the confirmation falls back to the end of the buffer.
(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max)))
       (tagarela--tool-call-pos nil)
       (shell-input (tagarela--json-plist-to-hash (list "command" "ps aux")))
       (pos (tagarela--record-tool-confirmation "shell" shell-input nil)))
  (tagarela-tests--assert
   "denied fallback is appended to the buffer"
   (string-match-p "\\[denied\\] "
                   (with-current-buffer buf
                     (buffer-substring-no-properties start (point-max)))))
  (tagarela-tests--assert
   "confirmation recorded at the captured start point (end fallback)"
   (>= pos start))
  (tagarela-tests--assert
   "keep-question-visible does not break without a visible window (batch)"
   (progn (tagarela--keep-question-visible pos) t)))

;;; Batch confirmation — one denied tool refuses the rest without asking and
;;; cancels the turn (the conversation stops waiting for the user's input)

;; A helper that runs `tagarela--confirm-pending' over a queue of N
;; mutating tools with `tagarela--confirm-ask' stubbed to answer
;; synchronously (ANSWERS, one per question asked, in order; 'run / 'deny),
;; `tagarela--send' stubbed to record the method names, and
;; `tagarela--dispatch-tool' stubbed to avoid side effects (no file
;; writes / shell spawns).  Returns a list: the number of questions asked, the
;; recorded send commands and the conversation text inserted during the run.
;; Stubbing `--confirm-ask' (rather than `--ask-user-trust') bypasses the
;; transient menu: the stub applies the answer via `--confirm-answer' exactly
;; like a menu suffix would (via its 0s timer), but synchronously.
(cl-labels
    ((run-batch (queue answers)
       (let ((sent '())
             (asked 0)
             (start (with-current-buffer (get-buffer "*llm-bridge*")
                      (point-max))))
         (cl-letf (((symbol-function 'tagarela--send)
                    (lambda (method &optional _params) (push method sent)))
                   ((symbol-function 'tagarela--confirm-ask)
                    (lambda (&rest _)
                      (tagarela--confirm-answer
                       (prog1 (pop answers) (cl-incf asked)))))
                   ((symbol-function 'tagarela--dispatch-tool)
                    (lambda (_name _input _id)))
                   ;; A denial cancels the turn via `tagarela-cancel',
                   ;; which only sends `cancel' when the bridge process is
                   ;; alive (it does nothing otherwise).  Bind a fake live
                   ;; process so the batch behaves like the real client, where
                   ;; the bridge is running.
                   (tagarela-process (make-symbol "fake-bridge-proc"))
                   ((symbol-function 'process-live-p) (lambda (_p) t))
                   (tagarela--tool-procs nil)
                   (tagarela--trust-specific nil)
                   (tagarela--trust-class nil)
                   (tagarela--trust-all nil))
           (setq tagarela--confirm-queue queue)
           (setq tagarela--confirm-timer nil)
           ;; Anchor every `[denied]'/'[allowed]' recorded by the run to the end
           ;; of the *llm-bridge* buffer (the captured range) so the test can
           ;; count them below.
           (setq tagarela--tool-call-pos
                 (with-current-buffer (get-buffer "*llm-bridge*") (point-max)))
           (tagarela--confirm-pending))
         (list asked (nreverse sent)
               (with-current-buffer (get-buffer "*llm-bridge*")
                 (buffer-substring-no-properties start (point-max)))))))
  ;; 1) Deny the first of three tools: no further questions, every remaining
  ;; tool is auto-denied and the turn is cancelled.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (res (run-batch queue '(deny))))
    (tagarela-tests--assert
     "denying the first tool asks only once (no questions for the rest)"
     (= 1 (car res)))
    (tagarela-tests--assert
     "a denied tool sends cancel to stop the turn"
     (member "cancel" (cadr res)))
    (let ((text (nth 2 res))
          (n 0))
      (let ((from 0))
        (while (string-match "\\[denied\\] " text from)
          (setq from (match-end 0))
          (cl-incf n)))
      (tagarela-tests--assert
       "every tool of the batch shows a [denied] tag, nothing allowed"
       (and (= 3 n)
            (not (string-match-p "\\[allowed\\] " text))))))
  ;; 2) Deny the second of three tools: the first is allowed, the second is
  ;; asked and denied, the third is auto-denied (no question) and the turn is
  ;; cancelled.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (res (run-batch queue '(run deny))))
    (tagarela-tests--assert
     "denying the second tool asks only twice (third auto-denied)"
     (= 2 (car res)))
    (tagarela-tests--assert
     "denying the second tool also cancels the turn"
     (member "cancel" (cadr res))))
  ;; 3) All tools allowed: no cancel, every question asked.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))))
         (res (run-batch queue '(run run))))
    (tagarela-tests--assert
     "when all tools are allowed, each is asked"
     (= 2 (car res)))
    (tagarela-tests--assert
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
         (cl-letf (((symbol-function 'tagarela--send)
                    (lambda (method &optional _) (push method sent)))
                   ((symbol-function 'tagarela--confirm-ask)
                    (lambda (&rest _)
                      (push 'ask events)
                      (tagarela--confirm-answer (pop answers))))
                   ((symbol-function 'tagarela--show-tool-call)
                    (lambda (&rest _) (push 'show events) nil))
                   ((symbol-function 'tagarela--record-tool-confirmation)
                    (lambda (_n _i _a &optional _t) nil))
                   ((symbol-function 'tagarela--dispatch-tool)
                    (lambda (_n _i _id) nil))
                   (tagarela--trust-specific nil)
                   (tagarela--trust-class nil)
                   (tagarela--trust-all nil))
           (setq tagarela--confirm-queue queue)
           (setq tagarela--confirm-timer nil)
           (tagarela--confirm-pending))
         (nreverse events))))
  ;; Two tools, both allowed: show, ask, show, ask (each tool is displayed
  ;; only right before its own question).
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (events (run-seq queue '(run run))))
    (tagarela-tests--assert
     "two allowed tools: show/ask interleaved (not both shown up front)"
     (equal '(show ask show ask) events)))
  ;; Three tools, first denied: show, ask, show, show (the rest are shown and
  ;; auto-denied one after the other, no further questions).
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (events (run-seq queue '(deny))))
    (tagarela-tests--assert
     "denied first tool: shown+asked first, the rest shown (auto-denied) after"
     (equal '(show ask show show) events))))

;;; Confirmation menu — the question is asked through the transient
;;; `tagarela--confirm-menu' when transient is available, and through the
;;; `read-char-choice' prompt (`tagarela--ask-user-trust') otherwise.
;;; `tagarela--confirm-ask' is the seam that chooses (and that the batch
;;; helpers above stub to answer synchronously).

;; The question shown at the top of the menu is rebuilt from the pending
;; confirmation context (icon + command/pattern/path).
(let ((tagarela--confirm-context
       (list :name "shell"
             :input (tagarela--json-plist-to-hash (list "command" "ps aux")))))
  (tagarela-tests--assert
   "the confirmation menu question shows the tool detail"
   (equal "🖥 Run tool: shell · ps aux? "
          (tagarela--confirm-menu-question))))

;; With the menu available, `--confirm-ask' opens it and does NOT fall back to
;; the minibuffer prompt.
(let ((opened nil))
  (cl-letf (((symbol-function 'tagarela--confirm-menu)
             (lambda () (setq opened t)))
            ((symbol-function 'tagarela--ask-user-trust)
             (lambda (_) (error "should not fall back to the char prompt"))))
    (tagarela--confirm-ask "shell" (make-hash-table)))
  (tagarela-tests--assert
   "confirm-ask opens the transient menu when it is available" opened))

;; Without the menu (transient absent), `--confirm-ask' reads a char and
;; forwards the answer to `--confirm-answer' (the fallback path).
(let ((answer nil))
  (cl-letf (((symbol-function 'tagarela--confirm-menu) nil)
            ((symbol-function 'tagarela--ask-user-trust)
             (lambda (_) 'run))
            ((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (setq answer a))))
    (tagarela--confirm-ask "shell" (make-hash-table)))
  (tagarela-tests--assert
   "confirm-ask falls back to the char prompt and forwards the answer"
   (eq answer 'run)))

;; When transient is available at runtime (not in `emacs -Q --batch'), the
;; confirmation menu and its run/deny/trust suffixes are defined.
(when (fboundp 'transient-define-prefix)
  (tagarela-tests--assert
   "the transient confirmation menu and its suffixes are defined"
   (and (fboundp 'tagarela--confirm-menu)
        (fboundp 'tagarela--confirm-run)
        (fboundp 'tagarela--confirm-deny)
        (fboundp 'tagarela--confirm-trust)
        (fboundp 'tagarela--trust-menu)))
  ;; Wiring of the menu keys.  `t'/`!' must open the Trust sub-menu THROUGH
  ;; `tagarela--confirm-trust' (which routes to
  ;; `tagarela--confirm-answer' -> `--trust-pause'), NOT by binding the
  ;; key straight to `tagarela--trust-menu': the direct binding skipped
  ;; `--trust-pause', so the sub-menu read an empty `--trust-context' and
  ;; dispatched a nil tool call, leaving the turn hanging (regression).
  (setq tagarela--confirm-context
        (list :name "shell" :input (make-hash-table :test 'equal)))
  (tagarela--confirm-menu)
  (let ((key->cmd '()))
    (when (boundp 'transient--suffixes)
      (dolist (s transient--suffixes)
        (push (cons (oref s key) (oref s command)) key->cmd)))
    (tagarela-tests--assert
     "the menu's t key routes the trust choice through --confirm-trust"
     (and (eq 'tagarela--confirm-trust (cdr (assoc "t" key->cmd)))
          (eq 'tagarela--confirm-run (cdr (assoc "r" key->cmd)))
          (eq 'tagarela--confirm-deny (cdr (assoc "d" key->cmd)))))
    (transient--pre-exit)))

;; Regression: the Trust choice (`t' in the menu, `!' in the char-prompt
;; fallback) goes through `tagarela--confirm-answer' with `trust', which
;; calls `--trust-pause' — that is what saves the paused tool call in
;; `tagarela--trust-context'.  The sub-menu then reads a fully populated
;; context (previously it was nil, so the tool was dispatched with nil
;; name/input/id and nothing ran).
(let ((opened 0))
  (setq tagarela--trust-context nil
        tagarela--confirm-context
        (list :name "shell" :id "7"
              :input (tagarela--json-plist-to-hash
                      (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--trust-menu)
             (lambda () (cl-incf opened))))
    (tagarela--confirm-answer 'trust))
  (tagarela-tests--assert
   "confirm-answer 'trust pauses and saves the tool in the trust context"
   (and (= 1 opened)
        (equal "shell" (plist-get tagarela--trust-context :name))
        (equal "7" (plist-get tagarela--trust-context :id))))
  (tagarela-tests--assert
   "confirm-answer consumes the pending confirmation context"
   (null tagarela--confirm-context)))

;; Regression: answering the trust sub-menu dispatches the REAL paused tool
;; (not a nil one), reading name/input/id from `--trust-context'.
(let ((dispatched nil)
      (recorded nil))
  (setq tagarela--trust-context
        (list :name "shell" :id "7"
              :input (tagarela--json-plist-to-hash
                      (list "command" "echo hi"))
              :rest '() :denied nil)
        tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (cl-letf (((symbol-function 'tagarela--dispatch-tool)
             (lambda (name input id) (setq dispatched (list name input id))))
            ((symbol-function 'tagarela--record-tool-confirmation)
             (lambda (&rest args) (push args recorded))))
    (tagarela--trust-finish 'specific))
  (tagarela-tests--assert
   "trust-finish dispatches the paused tool (not a nil one)"
   (and (equal "shell" (car dispatched))
        (equal "7" (nth 2 dispatched))))
  (tagarela-tests--assert
   "trust-finish clears the trust context after resuming"
   (null tagarela--trust-context)))

;;; Closing a menu unanswered (C-g) must not hang the turn
;;
;; The confirmation and trust menus are answered by their suffixes, which set
;; `tagarela--menu-answered' and consume the pending context.  If the
;; menu is merely closed (C-g, or any exit that runs no suffix) nothing is
;; sent to the bridge, so the turn would wait forever.  `--menu-exit-hook'
;; detects the still-pending, unanswered context and applies a deny.

;; confirm closed unanswered -> deny, via `--confirm-answer'
(let ((answered '()))
  (setq tagarela--menu-answered nil
        tagarela--trust-context nil
        tagarela--confirm-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (push a answered)))
            ((symbol-function 'tagarela--trust-cancel)
             (lambda () (push 'trust-cancel answered))))
    (tagarela--menu-exit-hook)
    (sit-for 0.05))
  (tagarela-tests--assert
   "menu closed unanswered denies the pending confirmation"
   (equal '(deny) answered)))

;; answered menu -> the exit hook does nothing
(let ((answered '()))
  (setq tagarela--menu-answered t
        tagarela--trust-context nil
        tagarela--confirm-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (push a answered)))
            ((symbol-function 'tagarela--trust-cancel)
             (lambda () (push 'trust-cancel answered))))
    (tagarela--menu-exit-hook)
    (sit-for 0.05))
  (tagarela-tests--assert
   "an answered menu is not treated as an abort"
   (null answered)))

;; trust sub-menu closed unanswered -> --trust-cancel
(let ((called nil))
  (setq tagarela--menu-answered nil
        tagarela--confirm-context nil
        tagarela--trust-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-answer)
             (lambda (_a) nil))
            ((symbol-function 'tagarela--trust-cancel)
             (lambda () (setq called t))))
    (tagarela--menu-exit-hook)
    (sit-for 0.05))
  (tagarela-tests--assert
   "trust sub-menu closed unanswered cancels the paused choice"
   called))

;; --trust-cancel denies the paused tool and aborts the batch (rest, denied=t)
(let ((recorded '())
      (next-args nil))
  (setq tagarela--trust-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '(:name "write") :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-next)
             (lambda (q d) (setq next-args (list q d))))
            ((symbol-function 'tagarela--record-tool-confirmation)
             (lambda (&rest a) (push a recorded))))
    (tagarela--trust-cancel))
  (tagarela-tests--assert
   "trust-cancel records the paused tool as denied"
   (and (= 1 (length recorded))
        (equal "shell" (car (car recorded)))
        (null (nth 2 (car recorded)))))
  (tagarela-tests--assert
   "trust-cancel continues the batch with the deny cascade"
   (and (null tagarela--trust-context)
        (equal '((:name "write") t) next-args))))

;; --trust-finish is a no-op (no nil-tool dispatch) without a paused context
(let ((dispatched nil))
  (setq tagarela--trust-context nil)
  (cl-letf (((symbol-function 'tagarela--dispatch-tool)
             (lambda (&rest _a) (setq dispatched t))))
    (tagarela--trust-finish 'specific))
  (tagarela-tests--assert
   "trust-finish does nothing when no tool is paused"
   (null dispatched)))

;; char-prompt fallback aborted with C-g -> deny
(let ((ans '()))
  (setq tagarela--confirm-context
        (list :name "shell" :input (make-hash-table :test 'equal)))
  (cl-letf (((symbol-function 'tagarela--confirm-menu) nil)
            ((symbol-function 'tagarela--ask-user-trust)
             (lambda (_p) (signal 'quit nil)))
            ((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (push a ans))))
    (tagarela--confirm-ask "shell" (make-hash-table :test 'equal)))
  (tagarela-tests--assert
   "aborting the char-prompt fallback denies the confirmation"
   (equal '(deny) ans)))

;;; Trust scope — class keys, prefix matching, recording and reset

(tagarela-tests--assert
 "shell class key is the first command token"
 (equal "sed"
        (tagarela--trust-class-key
         "shell" (tagarela--json-plist-to-hash (list "command" "sed -i s/a/b/ f")))))
(tagarela-tests--assert
 "shell class key is nil without a command"
 (null (tagarela--trust-class-key "shell" (make-hash-table))))
(tagarela-tests--assert
 "write class key is the path directory"
 (equal "/tmp/sub/"
        (tagarela--trust-class-key
         "write" (tagarela--json-plist-to-hash (list "path" "/tmp/sub/x.txt" "content" "x")))))
(tagarela-tests--assert
 "search_replace class key is the path directory"
 (equal "/etc/conf/"
        (tagarela--trust-class-key
         "search_replace" (tagarela--json-plist-to-hash (list "path" "/etc/conf/y.txt")))))
(tagarela-tests--assert
 "unknown tools have no class key"
 (null (tagarela--trust-class-key
        "read" (tagarela--json-plist-to-hash (list "path" "/tmp/z.txt")))))

(tagarela-tests--assert
 "shell class matches exactly (not by prefix)"
 (and (tagarela--class-prefix-p "shell" "sed" "sed")
      (not (tagarela--class-prefix-p "shell" "sed" "sedx"))))
(tagarela-tests--assert
 "path class trusts sub-directories"
 (and (tagarela--class-prefix-p "write" "/tmp/" "/tmp/sub/")
      (not (tagarela--class-prefix-p "write" "/tmp/sub/" "/tmp/"))))

(let ((input (tagarela--json-plist-to-hash (list "command" "ls -la /tmp"))))
  (setq tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (tagarela--trust-record 'specific "shell" input)
  (tagarela-tests--assert
   "specific trust matches the exact same input"
   (tagarela--trusted-p "shell" input))
  (tagarela-tests--assert
   "specific trust does not cover a different input"
   (not (tagarela--trusted-p
         "shell"
         (tagarela--json-plist-to-hash (list "command" "ls -la /other"))))))

(let ((input (tagarela--json-plist-to-hash (list "command" "sed s/a/b/ f"))))
  (setq tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (tagarela--trust-record 'class "shell" input)
  (tagarela-tests--assert
   "class trust covers other commands starting with the same token"
   (tagarela--trusted-p
    "shell" (tagarela--json-plist-to-hash (list "command" "sed s/c/d/ g"))))
  (tagarela-tests--assert
   "class trust does not cover a different command token"
   (not (tagarela--trusted-p
         "shell" (tagarela--json-plist-to-hash (list "command" "awk ..."))))))

(let ((in (tagarela--json-plist-to-hash (list "path" "/tmp/x"))))
  (setq tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (tagarela-tests--assert
   "class trust is not recorded without a class key"
   (and (null (tagarela--trust-record 'class "read" in))
        (null tagarela--trust-class))))

(let ((input (tagarela--json-plist-to-hash (list "command" "echo hi"))))
  (setq tagarela--trust-all nil)
  (tagarela--trust-record 'all "shell" input)
  (tagarela-tests--assert
   "all-tool trust makes every call trusted"
   (tagarela--trusted-p
    "shell" (tagarela--json-plist-to-hash (list "command" "anything"))))
  (setq tagarela--trust-all nil))

(let ((in (tagarela--json-plist-to-hash (list "command" "sed x"))))
  (setq tagarela--trust-specific (list (cons "shell" in))
        tagarela--trust-class (list (cons "shell" "sed"))
        tagarela--trust-all t
        tagarela--trust-context (list :name "shell"))
  (tagarela--reset-session)
  (tagarela-tests--assert
   "reset-session clears the trust state"
   (and (null tagarela--trust-specific)
        (null tagarela--trust-class)
        (null tagarela--trust-all)
        (null tagarela--trust-context))))

(provide 'tagarela-tools-tests)

;;; tagarela-tools-tests.el ends here
