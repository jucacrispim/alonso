;;; alonso-tools.el --- Tool-call display and confirmation for alonso  -*- lexical-binding: t; -*-

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

;; Show tool calls in the conversation buffer and ask the user to confirm the
;; mutating ones, one at a time, recording the `[allowed]' / `[denied]' /
;; `[trusted]' tag.  This includes the trust-scope decision UX: the transient
;; menus for the per-call question and the trust scope, with a
;; `read-char-choice' fallback when transient is unavailable.
;;
;; Builds on alonso-ui.el (insertion helpers, conversation state, faces) and
;; alonso-client.el (tool metadata, the trust/dispatch helpers).
;;
;; See alonso-ui.el.

;;; Code:

(require 'cl-lib)
(require 'alonso-client)
(require 'alonso-ui)

;;; Tool-call display helpers

(defvar alonso-tool-icons
  '(("shell"         . "🖥")
    ("grep"          . "🔎")
    ("glob"          . "🔎")
    ("read"          . "📄")
    ("write"         . "✏️")
    ("search_replace" . "🔁")
    ("knowledge"     . "🧠"))
  "Alist of tool name → unicode icon, shown before the tool name in the
confirmation questions (the `Run tool: ...?' prompt and its recorded line).")

(defun alonso--tool-icon (name)
  "Return the unicode icon for tool NAME (a generic wrench when unknown)."
  (or (cdr (assoc name alonso-tool-icons)) "🔧"))

(defun alonso--tool-detail-string (name input)
  "Return the plain-text detail of tool NAME with INPUT, for the minibuffer.
`shell' shows its command, `grep'/`glob' the pattern and the file tools the
path.  Used in the confirmation question prompt."
  (cond
   ((equal name "shell")
    (or (alonso--hval input "command") ""))
   ((member name '("grep" "glob"))
    (or (alonso--hval input "pattern") ""))
   ((member name '("read" "write" "search_replace"))
    (or (alonso--hval input "path") ""))
   (t "")))

(defun alonso--confirm-question (name input)
  "Build the minibuffer confirmation question for tool NAME with INPUT.
Prefixes the tool's unicode icon and, when available, shows the command
(`shell'), pattern (`grep'/`glob') or path (file tools) right after the name,
e.g. \"🖥 Run tool: shell · ps aux? \".  The minibuffer itself cannot render
colors, so the detail is shown as plain text here."
  (let ((detail (alonso--tool-detail-string name input)))
    (if (string-empty-p detail)
        (format "%s Run tool: %s? " (alonso--tool-icon name) name)
      (format "%s Run tool: %s · %s? "
              (alonso--tool-icon name) name detail))))

(defun alonso--tool-input-pairs (input)
  "Return INPUT (a hash-table) as a sorted list of (key . value) pairs."
  (when (hash-table-p input)
    (let (pairs)
      (maphash (lambda (k v) (push (cons k v) pairs)) input)
      (sort pairs (lambda (a b) (string< (car a) (car b)))))))

(defun alonso--diff-lines (text prefix)
  "Return TEXT with each line prefixed by PREFIX, preserving a trailing newline."
  (let ((trimmed (string-trim-right text "\n"))
        (nl (and (string-suffix-p "\n" text) "\n")))
    (concat
     (mapconcat (lambda (line) (concat prefix line))
                (split-string trimmed "\n")
                "\n")
     nl)))

(defun alonso--indent-lines (text prefix)
  "Return TEXT with each of its lines prefixed by PREFIX."
  (mapconcat (lambda (line) (concat prefix line))
             (split-string (format "%s" text) "\n")
             "\n"))

(defun alonso--format-tool-call (name input)
  "Return a propertized string describing tool NAME with its INPUT.
For `search_replace' the search is shown in red prefixed with `-' and the
replace in dark green prefixed with `+', diff style.  Other tools show each
parameter as a `key:' label (in `alonso-command-face', bold) followed by its
value indented on the line below."
  (if (hash-table-p input)
      (cond
       ((equal name "search_replace")
        (let ((path (or (alonso--hval input "path") ""))
              (search (or (alonso--hval input "search") ""))
              (replace (or (alonso--hval input "replace") "")))
          (concat
           (format "  path: %s\n" path)
           (propertize (alonso--diff-lines search "-")
                       'face 'alonso-search-face)
           (propertize (concat "\n"
                               (alonso--diff-lines replace "+"))
                       'face 'alonso-replace-face))))
       (t
        (let ((pairs (alonso--tool-input-pairs input)))
          (mapconcat
           (lambda (pair)
             (format "  %s\n%s"
                     (propertize (format "%s:" (car pair))
                                 'face 'alonso-command-face)
                     (alonso--indent-lines (cdr pair) "    ")))
           pairs "\n"))))
    ""))

(defun alonso--show-tool-call (_id name input)
  "Insert the tool-call line and its parameters for tool NAME with INPUT.

Read-only tools (which run without confirmation) get a title line with the
tool's icon and name, e.g. \"📄 read\".  Mutating tools (which ask for an
individual confirmation) show the confirmation question line right away —
the tool's icon and the `Run tool: <name>?' prompt — followed by
the parameters beneath it.  The `[allowed]' / `[denied]' prefix is later
prepended to the front of that same question line by
`alonso--record-tool-confirmation' once the user answers, so the
question is visible from the start (not only after the answer).  Returns the
buffer position of the visible title/parameters."
  (alonso--render-answer)
  (alonso--thinking-placeholder-end)
  (let* ((read-only (alonso--tool-read-only-p name))
         (header (if read-only
                     (format "\n%s %s\n" (alonso--tool-icon name) name)
                   (concat "\n"
                           (alonso--tool-icon name)
                           " Run tool: " name
                           "? \n")))
         (pos (alonso--insert-propertized header)))
    ;; point at the start of the visible line (title or question), where the
    ;; `[allowed]' / `[denied]' tag is prepended later
    (setq alonso--tool-call-pos (1+ pos))
    (let ((desc (alonso--format-tool-call name input)))
      (when (> (length desc) 0)
        (alonso--insert-propertized desc)))
    (setq alonso--tool-confirm-pos (point-max))
    (1+ pos)))

;;; Step 9 — Batch confirmation, trust scope and UX

(defun alonso--cancel-confirm ()
  "Cancel any pending batch tool confirmation."
  (when (timerp alonso--confirm-timer)
    (cancel-timer alonso--confirm-timer)
    (setq alonso--confirm-timer nil))
  (setq alonso--confirm-queue nil)
  (setq alonso--confirm-context nil)
  (setq alonso--trust-context nil)
  (setq alonso--menu-answered nil))

(defun alonso--schedule-confirm ()
  "Schedule the batch tool confirmation 0.5s after the last tool_call."
  (when (timerp alonso--confirm-timer)
    (cancel-timer alonso--confirm-timer))
  (setq alonso--confirm-timer
        (run-with-timer 0.5 nil #'alonso--confirm-pending)))

(defun alonso--keep-question-visible (pos)
  "Scroll the llm-bridge conversation window so that buffer position POS
stays visible, a few lines below the top of the window.

POS is normally the start of the tool-confirmation line just inserted, or
the start of the tool-call parameters while the confirmation question is
being asked (see `alonso--confirm-pending').  After scrolling, that
line sits near the top — not centered — so the question and the beginning of
a large diff remain on screen together even when the diff is much taller
than the window."
  (let ((win (get-buffer-window alonso-buffer-name t)))
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

(defun alonso--record-tool-confirmation (_name _input allowed &optional trust)
  "Record the tool-confirmation decision for a mutating tool call in the
conversation buffer.  ALLOWED non-nil when the user permitted it.  The
confirmation question line (the `Run tool: <name>?' prompt) was
already inserted by `alonso--show-tool-call'; this function merely
prepends the visible `[allowed]' / `[denied]' tag (in the tool / error face)
to the front of that same line (at `alonso--tool-call-pos'), so the
question is visible from the start and only the outcome is added after the
answer.  When TRUST is non-nil the tag is `[trusted]' instead (same face as
`[allowed]').  Keeps the line on screen (at least 2 lines from the top) via
`alonso--keep-question-visible'.  Returns the buffer position of the
recorded line."
  (let* ((status-face (if allowed
                          'alonso-tool-face
                        'alonso-error-face))
         (prefix (propertize (cond (trust "[trusted] ")
                                   (allowed "[allowed] ")
                                   (t "[denied] "))
                             'face status-face)))
    (if alonso--tool-call-pos
        (progn
          (alonso--insert-propertized-at
           alonso--tool-call-pos prefix)
          (alonso--keep-question-visible alonso--tool-call-pos)
          alonso--tool-call-pos)
      ;; No preceding visible question line (only happens if the confirmation
      ;; is recorded without `alonso--show-tool-call' having run);
      ;; fall back to appending the tag at the end of the buffer.
      (alonso--insert-propertized-at nil prefix))))

(defun alonso--ask-user-trust (prompt)
  "Ask the user PROMPT and return `run', `deny' or `trust'.
Reads a single char: y/Y runs the tool once, n/N denies it, ! opens the
trust-scope menu (run every time from then on)."
  (let ((ch (read-char-choice (concat prompt "(y)es / (n)o / (!)trust ")
                              '(?y ?Y ?n ?N ?!))))
    (pcase ch
      ((or ?y ?Y) 'run)
      ((or ?n ?N) 'deny)
      (_ 'trust))))

(defun alonso--trust-pause (name input id rest denied)
  "Pause batch confirmation for tool NAME/INPUT/ID to pick a trust scope.
Saves the remaining REST of the queue and the DENIED flag in
`alonso--trust-context' and opens the trust menu."
  (setq alonso--trust-context
        (list :name name :input input :id id :rest rest :denied denied))
  (setq alonso--menu-answered nil)
  (alonso--trust-menu))

(defun alonso--trust-finish (scope)
  "Record the trust chosen in SCOPE for the paused tool call and resume.
Reads the paused context, records the trust, marks the current tool as
`[trusted]' (or `[allowed]' when the scope could not record a trust, e.g. a
`class' on a tool without a class key), dispatches it guarded, and continues
confirming the rest of the batch."
  (let* ((ctx alonso--trust-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (id (plist-get ctx :id))
         (rest (plist-get ctx :rest))
         (denied (plist-get ctx :denied)))
    (setq alonso--trust-context nil)
    ;; Nothing paused (e.g. the turn was cancelled while the sub-menu was
    ;; open): do not dispatch a nil tool call.
    (when name
      (alonso--trust-record scope name input)
      (if (alonso--trusted-p name input)
          (alonso--record-tool-confirmation name input t "trusted")
        (alonso--record-tool-confirmation name input t))
      (alonso--dispatch-tool-guarded name input id)
      (alonso--confirm-next rest denied))))

(defun alonso--trust-description (kind)
  "Return a menu description for the paused trust context of KIND.
KIND is one of the symbols `specific', `class' or `all'.  Reads the paused
tool call from `alonso--trust-context' so the menu shows exactly
what is being approved: the concrete command/pattern/path for `specific',
the class key (e.g. the first `shell' command token or the file's
directory) for `class' and the tool name for `all' — so, for example, a
`sed' class is shown as \"This class of calls: sed\" instead of an
ambiguous label."
  (let ((name (plist-get alonso--trust-context :name))
        (input (plist-get alonso--trust-context :input)))
    (pcase kind
      ('all
       (if name
           (format "This whole tool: %s" name)
         "This whole tool"))
      ('class
       (if (and name input)
           (let ((key (alonso--trust-class-key name input)))
             (if key
                 (format "This class of calls: %s" key)
               "This class of calls"))
         "This class of calls"))
      ('specific
       (let ((detail (if (and name input)
                         (alonso--tool-detail-string name input)
                       "")))
         (if (string-empty-p detail)
             "This specific call"
           (format "This specific call: %s" detail))))
      (_ ""))))

(defun alonso--trust-cancel ()
  "Abort a paused trust choice: deny the tool and abort the batch.
Called when the trust sub-menu is closed without picking a scope (e.g.
`C-g'): the paused tool call in `alonso--trust-context' is recorded
`[denied]' and the remaining batch is auto-denied, ending in a `cancel' so
the turn does not hang."
  (let* ((ctx alonso--trust-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (rest (plist-get ctx :rest)))
    (setq alonso--trust-context nil)
    (when name
      (alonso--record-tool-confirmation name input nil))
    (alonso--confirm-next rest t)))

(defun alonso--menu-exit-hook ()
  "Deny the pending tool call when a confirmation menu closes unanswered.
Runs on `transient-exit-hook'.  The batch confirmation is asked through a
transient menu whose suffixes record the answer (via
`alonso--menu-answered') and consume the pending context; when the
user closes the menu WITHOUT picking an option (e.g. `C-g'), no suffix runs
and, without this, neither a `tool_result' nor a `cancel' would ever be sent
— the turn would hang waiting forever.  Detect that by the still-pending
context plus the unanswered flag and treat it as a deny: the current tool is
recorded `[denied]' and the batch is aborted with a `cancel'.  The answer is
applied from a 0s timer so the transient has fully exited before the batch
continues (a deny never reopens a menu, so this cannot recurse into a new
transient from inside the exit hook)."
  (unless alonso--menu-answered
    (cond
     (alonso--confirm-context
      (run-with-timer 0 nil #'alonso--confirm-answer 'deny))
     (alonso--trust-context
      (run-with-timer 0 nil #'alonso--trust-cancel)))))

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
  (transient-define-suffix alonso--confirm-run ()
    "Run the pending tool call once."
    (interactive)
    (setq alonso--menu-answered t)
    (run-with-timer 0 nil #'alonso--confirm-answer 'run))
  (transient-define-suffix alonso--confirm-deny ()
    "Deny the pending tool call (cancels the rest of the batch)."
    (interactive)
    (setq alonso--menu-answered t)
    (run-with-timer 0 nil #'alonso--confirm-answer 'deny))
  (transient-define-suffix alonso--confirm-trust ()
    "Open the trust-scope sub-menu for the pending tool call.
Routed through `alonso--confirm-answer' (rather than binding the
menu key straight to `alonso--trust-menu') so that
`alonso--trust-pause' runs first and saves the paused tool call in
`alonso--trust-context'; without it the trust sub-menu would read an
empty context and dispatch a nil tool call, leaving the turn hanging."
    (interactive)
    (setq alonso--menu-answered t)
    (run-with-timer 0 nil #'alonso--confirm-answer 'trust))
  (transient-define-prefix alonso--trust-menu ()
    "Choose how broadly to trust the pending tool call."
    [["Trust"
      ("s" (lambda () (alonso--trust-description 'specific))
       alonso--trust-finish-specific)
      ("c" (lambda () (alonso--trust-description 'class))
       alonso--trust-finish-class)
      ("a" (lambda () (alonso--trust-description 'all))
       alonso--trust-finish-all)]])
  (transient-define-suffix alonso--trust-finish-specific ()
    "Trust only this exact call."
    (interactive)
    (setq alonso--menu-answered t)
    (run-with-timer 0 nil #'alonso--trust-finish 'specific))
  (transient-define-suffix alonso--trust-finish-class ()
    "Trust this whole class of calls (shell command token / path directory)."
    (interactive)
    (setq alonso--menu-answered t)
    (run-with-timer 0 nil #'alonso--trust-finish 'class))
  (transient-define-suffix alonso--trust-finish-all ()
    "Trust every call of this tool."
    (interactive)
    (setq alonso--menu-answered t)
    (run-with-timer 0 nil #'alonso--trust-finish 'all))
  ;; The confirmation menu.  The question for the tool being confirmed (icon +
  ;; command/pattern/path) is shown as a dynamic `:info' line at the top of the
  ;; menu, rebuilt each time the menu opens from
  ;; `alonso--confirm-context'.  (`(:info FUN)' with a function
  ;; description is used instead of a group description because the latter is
  ;; only supported by newer transients; `:info' works with the bundled Emacs
  ;; one too.)  `t' opens the trust sub-menu.
  (transient-define-prefix alonso--confirm-menu ()
    "Run the pending tool call?"
    [["Confirm"
      (:info (lambda () (alonso--confirm-menu-question)))
      ("r" "Run once" alonso--confirm-run)
      ("d" "Deny" alonso--confirm-deny)
      ("t" "Trust…" alonso--confirm-trust)]])
  ;; A confirmation (or trust) menu closed without an answer — `C-g', or any
  ;; other exit that runs no suffix — must not leave the turn hanging: the
  ;; exit hook treats it as a deny and aborts the batch.
  (add-hook 'transient-exit-hook #'alonso--menu-exit-hook))

(defun alonso--confirm-menu-question ()
  "Return the question shown at the top of the confirmation menu.
Reads the pending tool call from `alonso--confirm-context' so the
menu displays exactly what is about to run (icon + command/pattern/path)."
  (let ((name (plist-get alonso--confirm-context :name))
        (input (plist-get alonso--confirm-context :input)))
    (alonso--confirm-question name input)))

(defun alonso--confirm-pending (&optional queue)
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

The questions are asked through the transient `alonso--confirm-menu'
(or, without transient, the `alonso--ask-user-trust' char prompt).
Because the menu is asynchronous, the batch is driven by
`alonso--confirm-next' / `alonso--confirm-answer' rather than
by a single blocking loop."
  (setq alonso--confirm-timer nil)
  (let ((queue (or queue
                   (prog1 alonso--confirm-queue
                     (setq alonso--confirm-queue nil)))))
    (alonso--confirm-next queue nil)))

(defun alonso--confirm-next (queue denied)
  "Show and process the first tool call in QUEUE, then continue the batch.
DENIED non-nil means an earlier tool of this batch was denied, so every
remaining tool is denied right away (no question).  Each tool is displayed
one at a time.  The first tool that must be asked is saved in
`alonso--confirm-context' and its question opened; the batch is
resumed by `alonso--confirm-answer'.  When the queue is exhausted,
a denial cancels the turn."
  (if (null queue)
      (when denied
        (alonso-cancel))
    (let* ((tc (car queue))
           (rest (cdr queue))
           (id (plist-get tc :id))
           (name (plist-get tc :name))
           (input (plist-get tc :input)))
      ;; Show this tool call now (one at a time), so only the tool being
      ;; confirmed appears on screen — not every tool of the batch.
      (alonso--show-tool-call id name input)
      (cond
       ;; A previous tool was denied: refuse this one too, no question.  No
       ;; tool_result is sent — the batch is aborted with a `cancel' at the end.
       (denied
        (alonso--record-tool-confirmation name input nil)
        (alonso--confirm-next rest t))
       ;; Already trusted: run directly, no question.
       ((alonso--trusted-p name input)
        (alonso--record-tool-confirmation name input t "trusted")
        (alonso--dispatch-tool-guarded name input id)
        (alonso--confirm-next rest nil))
       ;; Otherwise ask the user, saving the batch state for the answer.
       (t
        ;; Bring the top of the tool call into view before asking: with a large
        ;; diff the insertion left the window scrolled to the end, so without
        ;; this the user would not see the line being confirmed.
        (alonso--keep-question-visible alonso--tool-call-pos)
        (setq alonso--confirm-context
              (list :name name :input input :id id :rest rest :denied denied))
        (alonso--confirm-ask name input))))))

(defun alonso--confirm-ask (name input)
  "Ask the user whether to run tool NAME with INPUT.
Opens the transient `alonso--confirm-menu' when transient is
available; otherwise falls back to `alonso--ask-user-trust' and
applies the answer synchronously via `alonso--confirm-answer'.
This is the single seam the batch tests stub to answer without a menu.
Closing the question without answering is treated as a deny: the menu path
is handled by `alonso--menu-exit-hook' and the char-prompt fallback
by the `quit' handler here, so the turn never hangs."
  (if (fboundp 'alonso--confirm-menu)
      (progn
        (setq alonso--menu-answered nil)
        (alonso--confirm-menu))
    (condition-case nil
        (alonso--confirm-answer
         (alonso--ask-user-trust
          (alonso--confirm-question name input)))
      (quit (alonso--confirm-answer 'deny)))))

(defun alonso--confirm-answer (answer)
  "Apply ANSWER (`run', `deny' or `trust') to the pending confirmation.
Reads the pending tool call and the remaining batch from
`alonso--confirm-context' and continues via
`alonso--confirm-next'.  Called by the confirmation menu suffixes
(via `alonso--confirm-run'/`--confirm-deny') and by the fallback
path in `alonso--confirm-ask'."
  (let* ((ctx alonso--confirm-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (id (plist-get ctx :id))
         (rest (plist-get ctx :rest))
         (denied (plist-get ctx :denied)))
    ;; Consume the pending context: it has been read above and a stale
    ;; `--confirm-context' could otherwise be reused by a later menu rebuild.
    (setq alonso--confirm-context nil)
    (pcase answer
      ('deny
       ;; Record the `[denied]' tag, but do NOT send a tool_result — the turn
       ;; is aborted with a `cancel' (once, at the end of the batch), so a
       ;; redundant tool_result would only race the cancel and make the bridge
       ;; error with \"tool_result without pending tool call\".
       (alonso--record-tool-confirmation name input nil)
       (alonso--confirm-next rest t))
      ('trust
       ;; Pause to pick a scope; `--trust-finish' runs this tool (as
       ;; `[trusted]') and continues the rest of the batch.
       (alonso--trust-pause name input id rest denied))
      (_ ;; run once
       (alonso--record-tool-confirmation name input t)
       (alonso--dispatch-tool-guarded name input id)
       (alonso--confirm-next rest denied)))))

(provide 'alonso-tools)

;;; alonso-tools.el ends here
