;;; tagarela-tools.el --- Tool-call display and confirmation for tagarela  -*- lexical-binding: t; -*-

;;; Commentary:

;; Show tool calls in the conversation buffer and ask the user to confirm the
;; mutating ones, one at a time, recording the `[allowed]' / `[denied]' /
;; `[trusted]' tag.  This includes the trust-scope decision UX: the transient
;; menus for the per-call question and the trust scope, with a
;; `read-char-choice' fallback when transient is unavailable.
;;
;; Builds on tagarela-ui.el (insertion helpers, conversation state, faces) and
;; tagarela-client.el (tool metadata, the trust/dispatch helpers).
;;
;; See tagarela-ui.el.

;;; Code:

(require 'cl-lib)
(require 'tagarela-client)
(require 'tagarela-ui)

;;; Tool-call display helpers

(defvar tagarela-tool-icons
  '(("shell"         . "🖥")
    ("grep"          . "🔎")
    ("glob"          . "🔎")
    ("read"          . "📄")
    ("write"         . "✏️")
    ("search_replace" . "🔁")
    ("knowledge"     . "🧠"))
  "Alist of tool name → unicode icon, shown before the tool name in the
confirmation questions (the `Run tool: ...?' prompt and its recorded line).")

(defun tagarela--tool-icon (name)
  "Return the unicode icon for tool NAME (a generic wrench when unknown)."
  (or (cdr (assoc name tagarela-tool-icons)) "🔧"))

(defun tagarela--tool-detail-string (name input)
  "Return the plain-text detail of tool NAME with INPUT, for the minibuffer.
`shell' shows its command, `grep'/`glob' the pattern and the file tools the
path.  Used in the confirmation question prompt."
  (cond
   ((equal name "shell")
    (or (tagarela--hval input "command") ""))
   ((member name '("grep" "glob"))
    (or (tagarela--hval input "pattern") ""))
   ((member name '("read" "write" "search_replace"))
    (or (tagarela--hval input "path") ""))
   (t "")))

(defun tagarela--tool-detail-propertized (name input)
  "Return the tool NAME detail (command/pattern/path) propertized in
`tagarela-command-face' (blue), for the recorded confirmation line."
  (let ((v (tagarela--tool-detail-string name input)))
    (if (string-empty-p v)
        ""
      (propertize v 'face 'tagarela-command-face))))

(defun tagarela--confirm-question (name input)
  "Build the minibuffer confirmation question for tool NAME with INPUT.
Prefixes the tool's unicode icon and, when available, shows the command
(`shell'), pattern (`grep'/`glob') or path (file tools) right after the name,
e.g. \"🖥 Run tool: shell · ps aux? \".  The minibuffer itself cannot render
colors, so the detail is shown as plain text here (the recorded line in the
conversation buffer shows it in blue via
`tagarela--tool-detail-propertized')."
  (let ((detail (tagarela--tool-detail-string name input)))
    (if (string-empty-p detail)
        (format "%s Run tool: %s? " (tagarela--tool-icon name) name)
      (format "%s Run tool: %s · %s? "
              (tagarela--tool-icon name) name detail))))

(defun tagarela--tool-input-pairs (input)
  "Return INPUT (a hash-table) as a sorted list of (key . value) pairs."
  (when (hash-table-p input)
    (let (pairs)
      (maphash (lambda (k v) (push (cons k v) pairs)) input)
      (sort pairs (lambda (a b) (string< (car a) (car b)))))))

(defun tagarela--diff-lines (text prefix)
  "Return TEXT with each line prefixed by PREFIX, preserving a trailing newline."
  (let ((trimmed (string-trim-right text "\n"))
        (nl (and (string-suffix-p "\n" text) "\n")))
    (concat
     (mapconcat (lambda (line) (concat prefix line))
                (split-string trimmed "\n")
                "\n")
     nl)))

(defun tagarela--format-tool-call (name input)
  "Return a propertized string describing tool NAME with its INPUT.
For `search_replace' the search is shown in red prefixed with `-' and the
replace in dark green prefixed with `+', diff style.  Other tools show all
their parameters as `key: value' lines."
  (if (hash-table-p input)
      (cond
       ((equal name "search_replace")
        (let ((path (or (tagarela--hval input "path") ""))
              (search (or (tagarela--hval input "search") ""))
              (replace (or (tagarela--hval input "replace") "")))
          (concat
           (format "  path: %s\n" path)
           (propertize (tagarela--diff-lines search "-")
                       'face 'tagarela-search-face)
           (propertize (concat "\n"
                               (tagarela--diff-lines replace "+"))
                       'face 'tagarela-replace-face))))
       (t
        (let ((pairs (tagarela--tool-input-pairs input)))
          (mapconcat (lambda (pair)
                       (format "  %s: %s" (car pair) (cdr pair)))
                     pairs "\n"))))
    ""))

(defun tagarela--show-tool-call (_id name input)
  "Insert the tool-call line and its parameters for tool NAME with INPUT.

Read-only tools (which run without confirmation) get a title line with the
tool's icon and name, e.g. \"📄 read\".  Mutating tools (which ask for an
individual confirmation) show the confirmation question line right away —
the tool's icon and the `Run tool: <name> · <detail>?' prompt — followed by
the parameters beneath it.  The `[allowed]' / `[denied]' prefix is later
prepended to the front of that same question line by
`tagarela--record-tool-confirmation' once the user answers, so the
question is visible from the start (not only after the answer).  Returns the
buffer position of the visible title/parameters."
  (tagarela--render-answer)
  (let* ((read-only (tagarela--tool-read-only-p name))
         (detail (tagarela--tool-detail-propertized name input))
         (header (if read-only
                     (format "\n%s %s\n" (tagarela--tool-icon name) name)
                   (concat "\n"
                           (tagarela--tool-icon name)
                           " Run tool: " name
                           (if (string-empty-p detail) "" (concat " · " detail))
                           "? \n")))
         (pos (tagarela--insert-propertized header)))
    ;; point at the start of the visible line (title or question), where the
    ;; `[allowed]' / `[denied]' tag is prepended later
    (setq tagarela--tool-call-pos (1+ pos))
    (let ((desc (tagarela--format-tool-call name input)))
      (when (> (length desc) 0)
        (tagarela--insert-propertized desc)))
    (setq tagarela--tool-confirm-pos (point-max))
    (1+ pos)))

;;; Step 9 — Batch confirmation, trust scope and UX

(defun tagarela--cancel-confirm ()
  "Cancel any pending batch tool confirmation."
  (when (timerp tagarela--confirm-timer)
    (cancel-timer tagarela--confirm-timer)
    (setq tagarela--confirm-timer nil))
  (setq tagarela--confirm-queue nil)
  (setq tagarela--confirm-context nil)
  (setq tagarela--trust-context nil)
  (setq tagarela--menu-answered nil))

(defun tagarela--schedule-confirm ()
  "Schedule the batch tool confirmation 0.5s after the last tool_call."
  (when (timerp tagarela--confirm-timer)
    (cancel-timer tagarela--confirm-timer))
  (setq tagarela--confirm-timer
        (run-with-timer 0.5 nil #'tagarela--confirm-pending)))

(defun tagarela--keep-question-visible (pos)
  "Scroll the llm-bridge conversation window so that buffer position POS
stays visible, a few lines below the top of the window.

POS is normally the start of the tool-confirmation line just inserted, or
the start of the tool-call parameters while the confirmation question is
being asked (see `tagarela--confirm-pending').  After scrolling, that
line sits near the top — not centered — so the question and the beginning of
a large diff remain on screen together even when the diff is much taller
than the window."
  (let ((win (get-buffer-window tagarela-buffer-name t)))
    (when (and win pos (window-live-p win))
      (let ((sel (selected-window)))
        (unwind-protect
            (progn
              (select-window win)
              (goto-char (max (point-min) (min pos (point-max))))
              ;; a few lines of context above the line, the rest of the
              ;; (possibly large) diff fills the window below — never
              ;; centered mid-diff
              (recenter 3))
          (select-window sel))))))

(defun tagarela--record-tool-confirmation (_name _input allowed &optional trust)
  "Record the tool-confirmation decision for a mutating tool call in the
conversation buffer.  ALLOWED non-nil when the user permitted it.  The
confirmation question line (the `Run tool: <name> · <detail>?' prompt) was
already inserted by `tagarela--show-tool-call'; this function merely
prepends the visible `[allowed]' / `[denied]' tag (in the tool / error face)
to the front of that same line (at `tagarela--tool-call-pos'), so the
question is visible from the start and only the outcome is added after the
answer.  When TRUST is non-nil the tag is `[trusted]' instead (same face as
`[allowed]').  Keeps the line on screen (at least 2 lines from the top) via
`tagarela--keep-question-visible'.  Returns the buffer position of the
recorded line."
  (let* ((status-face (if allowed
                          'tagarela-tool-face
                        'tagarela-error-face))
         (prefix (propertize (cond (trust "[trusted] ")
                                   (allowed "[allowed] ")
                                   (t "[denied] "))
                             'face status-face)))
    (if tagarela--tool-call-pos
        (progn
          (tagarela--insert-propertized-at
           tagarela--tool-call-pos prefix)
          (tagarela--keep-question-visible tagarela--tool-call-pos)
          tagarela--tool-call-pos)
      ;; No preceding visible question line (only happens if the confirmation
      ;; is recorded without `tagarela--show-tool-call' having run);
      ;; fall back to appending the tag at the end of the buffer.
      (tagarela--insert-propertized-at nil prefix))))

(defun tagarela--ask-user-trust (prompt)
  "Ask the user PROMPT and return `run', `deny' or `trust'.
Reads a single char: y/Y runs the tool once, n/N denies it, ! opens the
trust-scope menu (run every time from then on)."
  (let ((ch (read-char-choice (concat prompt "(y)es / (n)o / (!)trust ")
                              '(?y ?Y ?n ?N ?!))))
    (pcase ch
      ((or ?y ?Y) 'run)
      ((or ?n ?N) 'deny)
      (_ 'trust))))

(defun tagarela--trust-pause (name input id rest denied)
  "Pause batch confirmation for tool NAME/INPUT/ID to pick a trust scope.
Saves the remaining REST of the queue and the DENIED flag in
`tagarela--trust-context' and opens the trust menu."
  (setq tagarela--trust-context
        (list :name name :input input :id id :rest rest :denied denied))
  (setq tagarela--menu-answered nil)
  (tagarela--trust-menu))

(defun tagarela--trust-finish (scope)
  "Record the trust chosen in SCOPE for the paused tool call and resume.
Reads the paused context, records the trust, marks the current tool as
`[trusted]' (or `[allowed]' when the scope could not record a trust, e.g. a
`class' on a tool without a class key), dispatches it guarded, and continues
confirming the rest of the batch."
  (let* ((ctx tagarela--trust-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (id (plist-get ctx :id))
         (rest (plist-get ctx :rest))
         (denied (plist-get ctx :denied)))
    (setq tagarela--trust-context nil)
    ;; Nothing paused (e.g. the turn was cancelled while the sub-menu was
    ;; open): do not dispatch a nil tool call.
    (when name
      (tagarela--trust-record scope name input)
      (if (tagarela--trusted-p name input)
          (tagarela--record-tool-confirmation name input t "trusted")
        (tagarela--record-tool-confirmation name input t))
      (tagarela--dispatch-tool-guarded name input id)
      (tagarela--confirm-next rest denied))))

(defun tagarela--trust-description (kind)
  "Return a menu description for the paused trust context of KIND.
KIND is one of the symbols `specific', `class' or `all'.  Reads the paused
tool call from `tagarela--trust-context' so the menu shows exactly
what is being approved: the concrete command/pattern/path for `specific',
the class key (e.g. the first `shell' command token or the file's
directory) for `class' and the tool name for `all' — so, for example, a
`sed' class is shown as \"This class of calls: sed\" instead of an
ambiguous label."
  (let ((name (plist-get tagarela--trust-context :name))
        (input (plist-get tagarela--trust-context :input)))
    (pcase kind
      ('all
       (if name
           (format "This whole tool: %s" name)
         "This whole tool"))
      ('class
       (if (and name input)
           (let ((key (tagarela--trust-class-key name input)))
             (if key
                 (format "This class of calls: %s" key)
               "This class of calls"))
         "This class of calls"))
      ('specific
       (let ((detail (if (and name input)
                         (tagarela--tool-detail-string name input)
                       "")))
         (if (string-empty-p detail)
             "This specific call"
           (format "This specific call: %s" detail))))
      (_ ""))))

(defun tagarela--trust-cancel ()
  "Abort a paused trust choice: deny the tool and abort the batch.
Called when the trust sub-menu is closed without picking a scope (e.g.
`C-g'): the paused tool call in `tagarela--trust-context' is recorded
`[denied]' and the remaining batch is auto-denied, ending in a `cancel' so
the turn does not hang."
  (let* ((ctx tagarela--trust-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (rest (plist-get ctx :rest)))
    (setq tagarela--trust-context nil)
    (when name
      (tagarela--record-tool-confirmation name input nil))
    (tagarela--confirm-next rest t)))

(defun tagarela--menu-exit-hook ()
  "Deny the pending tool call when a confirmation menu closes unanswered.
Runs on `transient-exit-hook'.  The batch confirmation is asked through a
transient menu whose suffixes record the answer (via
`tagarela--menu-answered') and consume the pending context; when the
user closes the menu WITHOUT picking an option (e.g. `C-g'), no suffix runs
and, without this, neither a `tool_result' nor a `cancel' would ever be sent
— the turn would hang waiting forever.  Detect that by the still-pending
context plus the unanswered flag and treat it as a deny: the current tool is
recorded `[denied]' and the batch is aborted with a `cancel'.  The answer is
applied from a 0s timer so the transient has fully exited before the batch
continues (a deny never reopens a menu, so this cannot recurse into a new
transient from inside the exit hook)."
  (unless tagarela--menu-answered
    (cond
     (tagarela--confirm-context
      (run-with-timer 0 nil #'tagarela--confirm-answer 'deny))
     (tagarela--trust-context
      (run-with-timer 0 nil #'tagarela--trust-cancel)))))

;;; Confirmation and trust menus (transient).  Transient is loaded first
;;; (top-level) so the guard below always sees `transient-define-prefix'
;;; defined — otherwise the chicken-and-egg (checking fboundp BEFORE requiring)
;;; would skip the menu definitions at startup and `--confirm-menu' /
;;; `--trust-menu' would end up void.  The guard remains for batch test
;;; environments (-Q) without transient; there `--ask-user-trust'
;;; (`read-char-choice') is the fallback question.

(require 'transient nil t)
(when (fboundp 'transient-define-prefix)
  ;; Run once / deny suffixes.  The batch is continued from a 0s timer so the
  ;; current menu is fully closed before the next tool's question is asked (it
  ;; may open another menu).  The trust choice is a sub-menu (`--trust-menu').
  (transient-define-suffix tagarela--confirm-run ()
    "Run the pending tool call once."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--confirm-answer 'run))
  (transient-define-suffix tagarela--confirm-deny ()
    "Deny the pending tool call (cancels the rest of the batch)."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--confirm-answer 'deny))
  (transient-define-suffix tagarela--confirm-trust ()
    "Open the trust-scope sub-menu for the pending tool call.
Routed through `tagarela--confirm-answer' (rather than binding the
menu key straight to `tagarela--trust-menu') so that
`tagarela--trust-pause' runs first and saves the paused tool call in
`tagarela--trust-context'; without it the trust sub-menu would read an
empty context and dispatch a nil tool call, leaving the turn hanging."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--confirm-answer 'trust))
  (transient-define-prefix tagarela--trust-menu ()
    "Choose how broadly to trust the pending tool call."
    [["Trust"
      ("s" (lambda () (tagarela--trust-description 'specific))
       tagarela--trust-finish-specific)
      ("c" (lambda () (tagarela--trust-description 'class))
       tagarela--trust-finish-class)
      ("a" (lambda () (tagarela--trust-description 'all))
       tagarela--trust-finish-all)]])
  (transient-define-suffix tagarela--trust-finish-specific ()
    "Trust only this exact call."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--trust-finish 'specific))
  (transient-define-suffix tagarela--trust-finish-class ()
    "Trust this whole class of calls (shell command token / path directory)."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--trust-finish 'class))
  (transient-define-suffix tagarela--trust-finish-all ()
    "Trust every call of this tool."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--trust-finish 'all))
  ;; The confirmation menu.  The question for the tool being confirmed (icon +
  ;; command/pattern/path) is shown as a dynamic `:info' line at the top of the
  ;; menu, rebuilt each time the menu opens from
  ;; `tagarela--confirm-context'.  (`(:info FUN)' with a function
  ;; description is used instead of a group description because the latter is
  ;; only supported by newer transients; `:info' works with the bundled Emacs
  ;; one too.)  `t' opens the trust sub-menu.
  (transient-define-prefix tagarela--confirm-menu ()
    "Run the pending tool call?"
    [["Confirm"
      (:info (lambda () (tagarela--confirm-menu-question)))
      ("r" "Run once" tagarela--confirm-run)
      ("d" "Deny" tagarela--confirm-deny)
      ("t" "Trust…" tagarela--confirm-trust)]])
  ;; A confirmation (or trust) menu closed without an answer — `C-g', or any
  ;; other exit that runs no suffix — must not leave the turn hanging: the
  ;; exit hook treats it as a deny and aborts the batch.
  (add-hook 'transient-exit-hook #'tagarela--menu-exit-hook))

(defun tagarela--confirm-menu-question ()
  "Return the question shown at the top of the confirmation menu.
Reads the pending tool call from `tagarela--confirm-context' so the
menu displays exactly what is about to run (icon + command/pattern/path)."
  (let ((name (plist-get tagarela--confirm-context :name))
        (input (plist-get tagarela--confirm-context :input)))
    (tagarela--confirm-question name input)))

(defun tagarela--confirm-pending (&optional queue)
  "Confirm and execute each tool queued for confirmation, one question per
tool call.  When the model responds with several tool calls the user is
asked once for each of them (rather than a single batch question covering
all), and each tool call is shown one at a time: the next one is only
displayed (and asked) after the previous one has been answered, so the
questions never pile up on screen together.  Before each question the
conversation window is scrolled so the top of the tool call (and the
beginning of a possibly large diff) is visible.  Each confirmation is
recorded in the conversation buffer and kept near the top after the user
answers, so the question and the start of the diff do not disappear.

When one tool call is denied, every tool call left in the batch is denied
automatically (without asking) and the turn is cancelled: the bridge stops
waiting for / running the pending tools, so the conversation falls back to
waiting for the user's next prompt.

The questions are asked through the transient `tagarela--confirm-menu'
(or, without transient, the `tagarela--ask-user-trust' char prompt).
Because the menu is asynchronous, the batch is driven by
`tagarela--confirm-next' / `tagarela--confirm-answer' rather than
by a single blocking loop."
  (setq tagarela--confirm-timer nil)
  (let ((queue (or queue
                   (prog1 tagarela--confirm-queue
                     (setq tagarela--confirm-queue nil)))))
    (tagarela--confirm-next queue nil)))

(defun tagarela--confirm-next (queue denied)
  "Show and process the first tool call in QUEUE, then continue the batch.
DENIED non-nil means an earlier tool of this batch was denied, so every
remaining tool is denied right away (no question).  Each tool is displayed
one at a time.  The first tool that must be asked is saved in
`tagarela--confirm-context' and its question opened; the batch is
resumed by `tagarela--confirm-answer'.  When the queue is exhausted,
a denial cancels the turn."
  (if (null queue)
      (when denied
        (tagarela-cancel))
    (let* ((tc (car queue))
           (rest (cdr queue))
           (id (plist-get tc :id))
           (name (plist-get tc :name))
           (input (plist-get tc :input)))
      ;; Show this tool call now (one at a time), so only the tool being
      ;; confirmed appears on screen — not every tool of the batch.
      (tagarela--show-tool-call id name input)
      (cond
       ;; A previous tool was denied: refuse this one too, no question.  No
       ;; tool_result is sent — the batch is aborted with a `cancel' at the end.
       (denied
        (tagarela--record-tool-confirmation name input nil)
        (tagarela--confirm-next rest t))
       ;; Already trusted: run directly, no question.
       ((tagarela--trusted-p name input)
        (tagarela--record-tool-confirmation name input t "trusted")
        (tagarela--dispatch-tool-guarded name input id)
        (tagarela--confirm-next rest nil))
       ;; Otherwise ask the user, saving the batch state for the answer.
       (t
        ;; Bring the top of the tool call into view before asking: with a large
        ;; diff the insertion left the window scrolled to the end, so without
        ;; this the user would not see the line being confirmed.
        (tagarela--keep-question-visible tagarela--tool-call-pos)
        (setq tagarela--confirm-context
              (list :name name :input input :id id :rest rest :denied denied))
        (tagarela--confirm-ask name input))))))

(defun tagarela--confirm-ask (name input)
  "Ask the user whether to run tool NAME with INPUT.
Opens the transient `tagarela--confirm-menu' when transient is
available; otherwise falls back to `tagarela--ask-user-trust' and
applies the answer synchronously via `tagarela--confirm-answer'.
This is the single seam the batch tests stub to answer without a menu.
Closing the question without answering is treated as a deny: the menu path
is handled by `tagarela--menu-exit-hook' and the char-prompt fallback
by the `quit' handler here, so the turn never hangs."
  (if (fboundp 'tagarela--confirm-menu)
      (progn
        (setq tagarela--menu-answered nil)
        (tagarela--confirm-menu))
    (condition-case nil
        (tagarela--confirm-answer
         (tagarela--ask-user-trust
          (tagarela--confirm-question name input)))
      (quit (tagarela--confirm-answer 'deny)))))

(defun tagarela--confirm-answer (answer)
  "Apply ANSWER (`run', `deny' or `trust') to the pending confirmation.
Reads the pending tool call and the remaining batch from
`tagarela--confirm-context' and continues via
`tagarela--confirm-next'.  Called by the confirmation menu suffixes
(via `tagarela--confirm-run'/`--confirm-deny') and by the fallback
path in `tagarela--confirm-ask'."
  (let* ((ctx tagarela--confirm-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (id (plist-get ctx :id))
         (rest (plist-get ctx :rest))
         (denied (plist-get ctx :denied)))
    ;; Consume the pending context: it has been read above and a stale
    ;; `--confirm-context' could otherwise be reused by a later menu rebuild.
    (setq tagarela--confirm-context nil)
    (pcase answer
      ('deny
       ;; Record the `[denied]' tag, but do NOT send a tool_result — the turn
       ;; is aborted with a `cancel' (once, at the end of the batch), so a
       ;; redundant tool_result would only race the cancel and make the bridge
       ;; error with \"tool_result without pending tool call\".
       (tagarela--record-tool-confirmation name input nil)
       (tagarela--confirm-next rest t))
      ('trust
       ;; Pause to pick a scope; `--trust-finish' runs this tool (as
       ;; `[trusted]') and continues the rest of the batch.
       (tagarela--trust-pause name input id rest denied))
      (_ ;; run once
       (tagarela--record-tool-confirmation name input t)
       (tagarela--dispatch-tool-guarded name input id)
       (tagarela--confirm-next rest denied)))))

(provide 'tagarela-tools)

;;; tagarela-tools.el ends here
