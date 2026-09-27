;;; tagarela-client.el --- llm-bridge client: protocol, process and tools -*- lexical-binding: t; -*-

;;; Commentary:

;; The "client" half of the Emacs llm-bridge integration.  It owns the JSON
;; protocol (serializing the commands sent to the bridge and parsing the
;; events it emits), the subprocess lifecycle (spawning, line filtering,
;; handshake) and the implementation of the tools (read, write, glob,
;; search_replace, shell, grep) plus the trust-scope decision logic.
;;
;; It deliberately knows nothing about buffers/windows: every event it
;; dispatches is handed to a rendering handler living in
;; tagarela-ui.el, reached via `declare-function' (those handlers are
;; only called at runtime, never at load time).  The UI side requires this
;; file, so there is a single one-way dependency (ui -> client).
;;
;; See tagarela.el (the entry point) and tagarela-ui.el for the
;; rest of the integration.

;;; Code:

(require 'cl-lib)

;; Render handlers defined in tagarela-ui.el, called at runtime while
;; dispatching bridge events / tool calls.  The UI file requires this one, so
;; by the time any of these is called the symbol is defined.
(declare-function tagarela--on-chunk "tagarela-ui")
(declare-function tagarela--on-thinking "tagarela-ui")
(declare-function tagarela--on-turn-end "tagarela-ui")
(declare-function tagarela--on-usage-delta "tagarela-ui")
(declare-function tagarela--on-files-changed "tagarela-ui")
(declare-function tagarela--on-hook-action "tagarela-ui")
(declare-function tagarela--on-error "tagarela-ui")
(declare-function tagarela--on-cancelled "tagarela-ui")
(declare-function tagarela--show-tool-call "tagarela-ui")
(declare-function tagarela--schedule-confirm "tagarela-ui")
(declare-function tagarela--stop-spinner "tagarela-ui")

;;;###autoload
(defgroup tagarela nil
  "Client for the llm-bridge process."
  :group 'external)

(defcustom tagarela-command "llm-bridge"
  "Command (or full path) used to start the llm-bridge binary."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-provider ""
  "Optional provider override (passed as -provider flag). E.g. \"deepseek\" or \"google\". Empty = default."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-model ""
  "Optional model override (passed as -model flag). Empty = provider default."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-thinking 'unset
  "Thinking mode global/startup (passed as -thinking flag).
`unset' omits the flag (uses the bridge default), `t' forces thinking on
(-thinking, deepseek-reasoner when there is no explicit model) and `off'
forces it off (-thinking=false, deepseek-chat).  To override per request,
use `tagarela-request-thinking'."
  :type '(choice (const :tag "Unset (bridge default)" unset)
                 (const :tag "On (deepseek-reasoner)" t)
                 (const :tag "Off (deepseek-chat)" off))
  :group 'tagarela)

(defcustom tagarela-reasoning-effort ""
  "Optional reasoning effort / thinking depth (passed as -reasoning-effort flag).
E.g. \"low\", \"medium\", \"high\".  Empty = provider default.  Only takes
effect with thinking on.  To override per request, use
`tagarela-request-reasoning-effort'."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-onnxruntime-lib
  (expand-file-name "~/.cache/llm-bridge/libonnxruntime.so")
  "Path to libonnxruntime.so used by the bridge's knowledge base embedder.
Passed to the subprocess as `LLM_BRIDGE_ONNXRUNTIME_LIB'.  Empty disables the
override (the bridge falls back to its default `onnxruntime.so').  Only needed
when the bridge was built with `make build-kb' and you want the KB on."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-logfile ""
  "Path of the log file for the bridge subprocess (passed as -logfile flag).
When non-empty, the bridge redirects all of its logs (trace level) to this
file, keeping the JSON-lines protocol on stdout clean (the bridge's default
when no log file is given is to disable logging entirely).  Empty (the
default) starts the bridge without a log file, so nothing is logged."
  :type 'file
  :group 'tagarela)

(defcustom tagarela-prune nil
  "Whether to enable history pruning in the bridge (passed as the -prune flag).
When on, the bridge prunes older conversation turns or messages.
Mutually exclusive with `tagarela-aggressive-prune'.  Off by default."
  :type 'boolean
  :group 'tagarela
  :set (lambda (symbol value)
         (set-default symbol value)
         (when value
           (setq tagarela-aggressive-prune nil))))

(defcustom tagarela-aggressive-prune nil
  "Whether to enable aggressive history pruning in the bridge (passed as
the -aggressive-prune flag).  When on, the bridge collapses each completed
tool-calling turn into just the user prompt + final answer, dropping the
intermediate tool calls, tool results and chain-of-thought from the history
to save tokens and keep the prefix cacheable.
Mutually exclusive with `tagarela-prune'.  Off by default."
  :type 'boolean
  :group 'tagarela
  :set (lambda (symbol value)
         (set-default symbol value)
         (when value
           (setq tagarela-prune nil))))

(defcustom tagarela-confirm-tools t
  "Whether to ask the user before executing a tool call."
  :type 'boolean
  :group 'tagarela)

;;; Step 1 — State structures and JSON construction

(defvar tagarela-process nil
  "The llm-bridge subprocess.")

(defvar tagarela-pending-tools nil
  "Alist of (:id id :name name :input input) for tool calls awaiting results.")

(defvar tagarela--confirm-queue nil
  "Queue of (:id :name :input) tool calls awaiting confirmation.
Each tool call in the queue is confirmed individually (one question per
tool), even when several arrive together.")

(defvar tagarela--confirm-timer nil
  "Timer used to batch tool confirmations.")

(defvar tagarela--confirm-context nil
  "Pending tool call while the confirmation menu is open.
A plist (:name :input :id :rest :denied) saved by
`tagarela--confirm-next' just before asking and consumed by
`tagarela--confirm-answer'.  :rest is the remaining queue (the
tool calls after the current one) and :denied is non-nil when an earlier
tool call of the same batch was denied (so the rest are auto-denied).")

(defvar tagarela--menu-answered nil
  "Non-nil when the last confirmation/trust menu key was pressed.
Set synchronously by the confirmation menu suffixes (`run'/`deny'/`trust')
and by the trust sub-menu suffixes, and reset to nil by
`tagarela--confirm-ask' / `tagarela--trust-pause' each time a
menu is opened.  `tagarela--menu-exit-hook' uses it to tell a menu
that was answered from one that was merely closed (e.g. with `C-g'), which
must be treated as a deny so the turn does not hang waiting forever.")

(defvar tagarela-in-turn nil
  "Non-nil while a turn (prompt) is in progress or awaiting tool results.")

(defvar tagarela-line-buffer ""
  "Partial JSON line buffer while assembling multi-chunk reads.")

(defvar tagarela--tool-procs nil
  "List of active tool subprocesses (shell/grep), cleaned up on kill.")

(defvar tagarela--after-tool-separator-pending nil
  "Non-nil when a tool call/result was just displayed in the current turn
and the next model output (thinking or chunk) still needs the two blank
lines separating it from the tool's output.
Set by `tagarela--send-tool-result', consumed by the first `thinking'
or `chunk' that follows, and cleared at the start/end of every turn.")

(defvar tagarela-session-input-tokens 0
  "Total input tokens (sent) accumulated across all turns of the session.")
(defvar tagarela-session-output-tokens 0
  "Total output tokens (received) accumulated across all turns of the session.")
(defvar tagarela-session-model nil
  "Model used in the current session (nil until the first `turn_end').")

(defvar tagarela--current-turn-input-tokens 0
  "Input tokens accumulated in the current turn.")
(defvar tagarela--current-turn-output-tokens 0
  "Output tokens accumulated in the current turn.")
(defvar tagarela--turn-finalized nil
  "Non-nil when the current turn has received its `turn_end' event.")

;;; Trust scope — tools the user decided to run without asking again

(defvar tagarela--trust-specific nil
  "Alist of (tool-name . input-hash) trusted for this specific call only.
A mutating tool call is run without asking when its input hash is `equal'
to the one recorded here under its name.")

(defvar tagarela--trust-class nil
  "Alist of (tool-name . class-key) trusted for a whole class of calls.
The class key is computed by `tagarela--trust-class-key' (`shell'
uses the first command token; the path tools the file's directory).")

(defvar tagarela--trust-all nil
  "Non-nil when every tool call is trusted without asking.")

(defvar tagarela--trust-context nil
  "Paused batch-confirmation context while the user picks a trust scope.
A plist (:name :input :id :rest :denied) saved by
`tagarela--trust-pause' and consumed by
`tagarela--trust-finish'.")

(defun tagarela--reset-session ()
  "Reset the session token counters, model and trust state.
Called when the bridge is restarted or shut down, ending the session."
  (tagarela--stop-spinner)
  (setq tagarela-session-input-tokens 0
        tagarela-session-output-tokens 0
        tagarela-session-model nil
        tagarela--current-turn-input-tokens 0
        tagarela--current-turn-output-tokens 0
        tagarela--turn-finalized nil
        tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil
        tagarela--trust-context nil))

;;; Per-request overrides (model, thinking and thinking depth)

;; The Go bridge accepts, in the `prompt' command, the optional fields:
;;   model            — string, explicit model (overrides provider/derivation)
;;   thinking         — bool, turns thinking on (deepseek-reasoner) or off
;;                      (deepseek-chat)
;;   reasoning_effort — string ("low"/"medium"/"high"), thinking depth
;; All three are buffer-local to the input buffer: the user sets them before
;; the prompt and the value is sent in the following request (they persist
;; until changed, mirroring the bridge, which keeps overrides between prompts).

(defcustom tagarela-request-provider ""
  "Provider override for the next prompt (buffer-local to the input buffer).
Empty string = omits the `provider' field."
  :type 'string
  :group 'tagarela)
(make-variable-buffer-local 'tagarela-request-provider)

(defcustom tagarela-request-model ""
  "Model override for the next prompt (buffer-local to the input buffer).
Empty string = omits the `model' field (uses the provider default)."
  :type 'string
  :group 'tagarela)
(make-variable-buffer-local 'tagarela-request-model)

(defcustom tagarela-request-thinking 'unset
  "Thinking override for the next prompt (buffer-local to the input buffer).
`t' = on, `off' = off, `unset' = omit (provider default)."
  :type '(choice (const :tag "Unset (provider default)" unset)
                 (const :tag "On (deepseek-reasoner)" t)
                 (const :tag "Off (deepseek-chat)" off))
  :group 'tagarela)
(make-variable-buffer-local 'tagarela-request-thinking)

(defcustom tagarela-request-reasoning-effort ""
  "Reasoning effort (thinking depth) for the next prompt.
E.g. \"low\", \"medium\", \"high\".  Empty string = omit (provider default)."
  :type 'string
  :group 'tagarela)
(make-variable-buffer-local 'tagarela-request-reasoning-effort)

;; The input buffer name is a defcustom defined in tagarela-ui.el;
;; declare it here first so the per-request override helpers do not trigger
;; free-variable warnings.
(defvar tagarela-input-buffer-name "*llm-bridge-input*")

(defun tagarela--request-buffer ()
  "Return the input buffer (creating it if needed)."
  (get-buffer-create tagarela-input-buffer-name))

(defun tagarela--request-annotation ()
  "Return a short string describing the per-request overrides to send.
Returns \"\" when no override is set."
  (with-current-buffer (tagarela--request-buffer)
    (let (parts)
      (unless (string-empty-p tagarela-request-provider)
        (push (format "provider=%s" tagarela-request-provider) parts))
      (unless (string-empty-p tagarela-request-model)
        (push (format "model=%s" tagarela-request-model) parts))
      (pcase tagarela-request-thinking
        ('t    (push "thinking=on" parts))
        ('off  (push "thinking=off" parts)))
      (unless (string-empty-p tagarela-request-reasoning-effort)
        (push (format "effort=%s" tagarela-request-reasoning-effort) parts))
      (if parts
          (concat "  [" (mapconcat #'identity (nreverse parts) " ") "]")
        ""))))

(defun tagarela--prompt-params (text)
  "Build the `prompt' params plist from TEXT and the per-request overrides.
Only the fields that were set are included, so the bridge keeps the provider
defaults for the rest."
  (let ((params (list "text" text)))
    (let ((buf (get-buffer tagarela-input-buffer-name)))
      (when buf
        (with-current-buffer buf
          (unless (string-empty-p tagarela-request-provider)
            (setq params (append params (list "provider" tagarela-request-provider))))
          (unless (string-empty-p tagarela-request-model)
            (setq params (append params (list "model" tagarela-request-model))))
          (when (memq tagarela-request-thinking '(t off))
            (setq params (append params (list "thinking"
                                               (if (eq tagarela-request-thinking 'off)
                                                   :json-false t)))))
          (unless (string-empty-p tagarela-request-reasoning-effort)
            (setq params (append params (list "reasoning_effort"
                                               tagarela-request-reasoning-effort))))))
    params)))

(defun tagarela--json-plist-to-hash (plist)
  "Convert PLIST (flat alternating keys/values) into a hash table."
  (let ((tbl (make-hash-table :test 'equal)))
    (cl-loop for (k v) on plist by #'cddr
             do (puthash k v tbl))
    tbl))

(defun tagarela--json-object (&rest args)
  "Build a JSON object string from ARGS as alternating key/value pairs.
Each value may be a string, number, boolean (`t' or `:json-false'), hash
table, or nil (serialized as null)."
  (let ((tbl (make-hash-table :test 'equal)))
    (cl-loop for (k v) on args by #'cddr
             do (puthash k v tbl))
    (json-serialize tbl :null-object nil :false-object :json-false)))

(defun tagarela--send (method &optional params)
  "Send a command METHOD to the bridge with optional PARAMS (a plist).
PARAMS is a flat plist of alternating keys/values, e.g. (\"text\" \"oi\")."
  (process-send-string tagarela-process
                       (concat (apply #'tagarela--json-object
                                      "method" method
                                      (and params
                                           (list "params"
                                                 (tagarela--json-plist-to-hash params))))
                               "\n")))

;;; Step 2 — Process management (subprocess + handshake)

(defvar tagarela-ready nil
  "Non-nil after the bridge sends the `ready' event (handshake done).")

(defun tagarela--process-sentinel (proc event)
  "Sentinel for the llm-bridge process."
  (when (memq (process-status proc) '(exit signal))
    (setq tagarela-process nil
          tagarela-ready nil
          tagarela-in-turn nil
          tagarela-pending-tools nil
          tagarela--after-tool-separator-pending nil)
    (tagarela--reset-session)
    (message "llm-bridge ended: %s" event)))

(defun tagarela--process-filter (_proc output)
  "Filter for the llm-bridge process: accumulate lines and dispatch events."
  (setq tagarela-line-buffer (concat tagarela-line-buffer output))
  (let ((start 0) nl line)
    (while (setq nl (string-match-p "\n" tagarela-line-buffer start))
      (setq line (substring tagarela-line-buffer start nl))
      (setq start (1+ nl))
      (when (string-match-p "[^[:space:]]" line)
        (tagarela--handle-line line)))
    (setq tagarela-line-buffer (substring tagarela-line-buffer start))))

;;; Step 3 — Event dispatcher

(defun tagarela--handle-line (line)
  "Parse and dispatch a single JSON event LINE from the bridge."
  (let ((ev (ignore-errors (json-parse-string line
                               :object-type 'hash-table :array-type 'list))))
    (when ev
      (let ((event (gethash "event" ev)))
        (cl-case (intern event)
          (ready        (setq tagarela-ready t))
          (chunk        (tagarela--on-chunk (gethash "text" ev)))
          (thinking     (tagarela--on-thinking (gethash "text" ev)))
          (tool_call    (tagarela--on-tool-call ev))
          (turn_end     (tagarela--on-turn-end ev))
          (files_changed (tagarela--on-files-changed ev))
          (usage_delta  (tagarela--on-usage-delta ev))
          (hook_action  (tagarela--on-hook-action ev))
          (error        (tagarela--on-error (gethash "message" ev)))
          (cancelled    (tagarela--on-cancelled))
          (t (message "tagarela: unknown event: %s" event)))))))

;;; Step 7 — Tool-calling loop

(defun tagarela--on-tool-call (ev)
  "Handle a `tool_call' event EV.
Read-only tools are shown and execute right away.  Mutating tools are only
queued (not shown yet): each one is displayed and asked for its individual
confirmation inside `tagarela--confirm-pending', one at a time — only
the tool being asked about appears on screen, and the next one appears only
after the previous one has been answered."
  (let ((id (gethash "id" ev))
        (name (gethash "name" ev))
        (input (gethash "input" ev)))
    (if (equal name "knowledge")
        ;; The `knowledge' tool is resolved INTERNALLY by the bridge
        ;; (fire-and-forget): it never waits for a tool_result, so we only
        ;; surface it as an informational line and send nothing back —
        ;; confirming/running it here would error and a late tool_result would
        ;; just be ignored by the bridge.  Crucially, it is NOT added to
        ;; `tagarela-pending-tools': nothing would ever remove that entry
        ;; (no tool_result is ever sent for it), and a leftover entry would make
        ;; every following `prompt' be rejected as \"turn in progress\".
        (tagarela--show-tool-call id name input)
      ;; Every other tool is tracked in `tagarela-pending-tools' (its
      ;; entry is removed by `tagarela--send-tool-result' once the tool
      ;; reports back).
      (push (list :id id :name name :input input) tagarela-pending-tools)
      (if (or (tagarela--tool-read-only-p name)
              (not tagarela-confirm-tools))
        (progn
          ;; read-only (or confirmation disabled): show and run right away
          (tagarela--show-tool-call id name input)
          (condition-case err
              (tagarela--dispatch-tool name input id)
            (error
             (tagarela--send-tool-result
              id (error-message-string err) "error"))))
      ;; mutating: queue it and schedule its (individual) confirmation.  It is
      ;; shown one at a time in `--confirm-pending', not here.
      (push (list :id id :name name :input input) tagarela--confirm-queue)
      (tagarela--schedule-confirm)))))

(defun tagarela--send-tool-result (id result status)
  "Send a tool_result for ID with RESULT and STATUS."
  (when (and tagarela-process (process-live-p tagarela-process))
    (tagarela--send "tool_result"
                          (list "id" id "result" result "status" status)))
  (setq tagarela-pending-tools
        (cl-remove-if (lambda (tc) (equal (plist-get tc :id) id))
                      tagarela-pending-tools))
  ;; The tool output finished: the next thinking/chunk of the model must
  ;; be separated from it by two blank lines.
  (setq tagarela--after-tool-separator-pending t))

(defun tagarela--dispatch-tool (name input id)
  "Dispatch tool NAME with INPUT and ID for execution.
`shell' and `grep' run asynchronously via `make-process'; the remaining tools
execute synchronously (they are fast file operations)."
  (cl-case (intern name)
    (shell (tagarela--tool-shell-async input id))
    (grep  (tagarela--tool-grep-async input id))
    (t (tagarela--send-tool-result
        id (tagarela--execute-tool name input) "success"))))

;;; Step 8 — Implementation of the 6 tools

(defun tagarela--hval (input key)
  "Get KEY from INPUT (a hash-table parsed from JSON), or nil."
  (when (hash-table-p input)
    (gethash key input)))

(defun tagarela--tool-proc-filter (proc out)
  "Accumulate OUT from a tool subprocess PROC into its :output property."
  (process-put proc :output (concat (process-get proc :output) out)))

(defun tagarela--tool-read (input)
  "Tool `read': return the contents of the file at PATH.
When the optional OFFSET (0-based line index) and/or LIMIT (max number of
lines) are given, return only that slice of the file (lines from OFFSET, up
to LIMIT lines); otherwise return the whole file."
  (let ((path (tagarela--hval input "path")))
    (unless path (error "read: missing 'path'"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name path))
      (let* ((lines (split-string (buffer-string) "\n"))
             (offset (tagarela--hval input "offset"))
             (limit (tagarela--hval input "limit")))
        (if (and (null offset) (null limit))
            (buffer-string)
          (let* ((nlines (length lines))
                 (start (min nlines (if (numberp offset) (max 0 offset) 0)))
                 (end (if (numberp limit)
                          (min nlines (+ start limit))
                        nlines)))
            (mapconcat #'identity (cl-subseq lines start end) "\n")))))))

(defun tagarela--tool-write (input)
  "Tool `write': write CONTENT to the file at PATH."
  (let ((path (tagarela--hval input "path"))
        (content (tagarela--hval input "content")))
    (unless (and path content) (error "write: missing 'path' or 'content'"))
    (with-temp-buffer
      (insert content)
      (write-region (point-min) (point-max) (expand-file-name path) nil 'quiet))
    "ok"))

(defun tagarela--tool-shell-async (input id)
  "Run the `shell' tool COMMAND asynchronously via bash -c.
Sends the tool_result when the process exits."
  (let ((command (tagarela--hval input "command")))
    (unless command (error "shell: missing 'command'"))
    (let ((proc (make-process
                 :name (format "llm-bridge-shell-%s" id)
                 :buffer nil
                 :command (list "bash" "-c" command)
                 :connection-type 'pipe
                 :filter #'tagarela--tool-proc-filter
                 :sentinel (lambda (proc _event)
                             (setq tagarela--tool-procs
                                   (delq proc tagarela--tool-procs))
                             (when (and (memq (process-status proc) '(exit signal))
                                        (not (process-get proc :cancelled)))
                               (let* ((status (process-exit-status proc))
                                      (out (or (process-get proc :output) "")))
                                 (tagarela--send-tool-result
                                  id
                                  (concat out (when (/= status 0)
                                                (format "\n[exited with status %d]" status)))
                                  "success")))))))
      (push proc tagarela--tool-procs))))

(defun tagarela--tool-grep-async (input id)
  "Run the `grep' tool PATTERN under PATH asynchronously.
The pattern is a POSIX extended regular expression (like `grep -E'), so a
literal string must have its regex metacharacters escaped; output is one
`file:line:text' entry per match.  Sends the tool_result when the process
exits (0 = matches, 1 = no matches)."
  (let ((pattern (tagarela--hval input "pattern"))
        (path (or (tagarela--hval input "path") ".")))
    (unless pattern (error "grep: missing 'pattern'"))
    (let ((proc (make-process
                 :name (format "llm-bridge-grep-%s" id)
                 :buffer nil
                 :command (list "grep" "-rnEI" "--include=*" pattern (expand-file-name path))
                 :connection-type 'pipe
                 :filter #'tagarela--tool-proc-filter
                 :sentinel (lambda (proc _event)
                             (setq tagarela--tool-procs
                                   (delq proc tagarela--tool-procs))
                             (when (and (memq (process-status proc) '(exit signal))
                                        (not (process-get proc :cancelled)))
                               (let* ((status (process-exit-status proc))
                                      (out (or (process-get proc :output) "")))
                                 (tagarela--send-tool-result
                                  id out (if (<= status 1) "success" "error"))))))))
      (push proc tagarela--tool-procs))))

(defun tagarela--kill-tool-procs ()
  "Kill any in-flight asynchronous tool processes (shell/grep).

Called when a turn is cancelled so a long-running command stops instead of
keeping running after the turn ended, and so its late tool_result is never
sent (the bridge no longer waits for it).  Each process is marked
`:cancelled' before being killed so its sentinel skips sending a
tool_result."
  (dolist (proc tagarela--tool-procs)
    (when (process-live-p proc)
      (process-put proc :cancelled t)
      (delete-process proc)))
  (setq tagarela--tool-procs nil))

(defun tagarela--tool-glob (input)
  "Tool `glob': find files matching PATTERN under PATH."
  (let ((pattern (tagarela--hval input "pattern"))
        (base (or (tagarela--hval input "path") default-directory)))
    (unless pattern (error "glob: missing 'pattern'"))
    (let ((default-directory (expand-file-name base)))
      (mapconcat #'identity (file-expand-wildcards pattern) "\n"))))

(defun tagarela--tool-search-replace (input)
  "Tool `search_replace': replace the first exact SEARCH in PATH with REPLACE."
  (let ((path (tagarela--hval input "path"))
        (search (tagarela--hval input "search"))
        (replace (tagarela--hval input "replace")))
    (unless (and path search replace)
      (error "search_replace: missing 'path', 'search' or 'replace'"))
    (let* ((full (expand-file-name path))
           (content (with-temp-buffer
                      (insert-file-contents full)
                      (buffer-string)))
           (pos (string-match (regexp-quote search) content)))
      (unless pos
        (error "string %S not found in %s" search path))
      (let ((new (concat (substring content 0 pos)
                         replace
                         (substring content (+ pos (length search))))))
        (with-temp-buffer
          (insert new)
          (write-region (point-min) (point-max) full nil 'quiet)))
      "ok")))

(defun tagarela--execute-tool (name input)
  "Execute tool NAME with INPUT synchronously, returning the result string.
Only the fast file tools run here; `shell' and `grep' are dispatched
asynchronously by `tagarela--dispatch-tool'."
  (cl-case (intern name)
    (read           (tagarela--tool-read input))
    (write          (tagarela--tool-write input))
    (glob           (tagarela--tool-glob input))
    (search_replace (tagarela--tool-search-replace input))
    (t (error "Unknown tool: %s" name))))

(defun tagarela--resolve-command (cmd)
  "Resolve the bridge command CMD for `make-process'.
Expands a leading ~ or a relative path (strings containing a slash).
A bare command name is left untouched so it is found via PATH."
  (if (string-match-p "/" cmd)
      (expand-file-name cmd)
    cmd))

(defun tagarela--start-args ()
  "Build the command-line args for starting the bridge from the startup
defcustoms (`-provider', `-model', `-thinking', `-reasoning-effort',
`-logfile', `-prune' and `-aggressive-prune')."
  (let (args)
    (unless (string-empty-p tagarela-provider)
      (setq args (append args (list "-provider" tagarela-provider))))
    (unless (string-empty-p tagarela-model)
      (setq args (append args (list "-model" tagarela-model))))
    (pcase tagarela-thinking
      ('t   (setq args (append args (list "-thinking"))))
      ('off (setq args (append args (list "-thinking=false")))))
    (unless (string-empty-p tagarela-reasoning-effort)
      (setq args (append args (list "-reasoning-effort" tagarela-reasoning-effort))))
    (unless (string-empty-p tagarela-logfile)
      (setq args (append args (list "-logfile" tagarela-logfile))))
    (when tagarela-prune
      (setq args (append args (list "-prune"))))
    (when tagarela-aggressive-prune
      (setq args (append args (list "-aggressive-prune"))))
    args))

(defun tagarela--start-process ()
  "Start the llm-bridge subprocess if not already running.
When `tagarela-onnxruntime-lib' is non-empty, the subprocess is started
with `LLM_BRIDGE_ONNXRUNTIME_LIB' set to it (via `setenv' before spawning, so
a `make build-kb' bridge can dlopen the runtime lib and use the project
knowledge base), then the previous value is restored.  Note: we cannot use the
`make-process' `:environment' keyword because in some Emacs builds it is
silently ignored — `setenv' against `process-environment' is what the child
actually inherits."
  (if (and tagarela-process (process-live-p tagarela-process))
      tagarela-process
    (let* ((old-lib (getenv "LLM_BRIDGE_ONNXRUNTIME_LIB"))
           (set-lib (and tagarela-onnxruntime-lib
                         (not (string-empty-p tagarela-onnxruntime-lib)))))
      (when set-lib
        (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" tagarela-onnxruntime-lib))
      (unwind-protect
          (let ((cmd (cons (tagarela--resolve-command tagarela-command)
                           (tagarela--start-args))))
            (setq tagarela-process
                  (make-process :name "llm-bridge"
                                :buffer nil
                                :command cmd
                                :connection-type 'pipe
                                :filter #'tagarela--process-filter
                                :sentinel #'tagarela--process-sentinel)))
        (if old-lib
            (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" old-lib)
          (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" nil))))
    (setq tagarela-line-buffer "")
    tagarela-process))

(defun tagarela--ensure-ready ()
  "Start the bridge and block until it emits the `ready' event.
Raises an error if the process dies or the handshake times out (10s)."
  (unless tagarela-ready
    (tagarela--start-process)
    (let ((deadline (time-add (current-time) (seconds-to-time 10))))
      (while (and (not tagarela-ready)
                  (process-live-p tagarela-process)
                  (time-less-p (current-time) deadline))
        (accept-process-output nil 0.1)))
    (unless tagarela-ready
      (error "Timeout waiting for 'ready' from llm-bridge"))))

;;; Tool decision logic — read-only classification and trust scope

(defun tagarela--tool-read-only-p (name)
  "Return non-nil if tool NAME only reads data (runs without confirmation)."
  (memq (intern name) '(read grep glob knowledge)))

(defun tagarela--dispatch-tool-guarded (name input id)
  "Dispatch tool NAME with INPUT and ID, reporting any error as a tool_result.
Wraps `tagarela--dispatch-tool' so an execution error is sent back to
the bridge instead of interrupting the client."
  (condition-case err
      (tagarela--dispatch-tool name input id)
    (error
     (tagarela--send-tool-result id (error-message-string err) "error"))))

(defun tagarela--trust-class-key (name input)
  "Return the class key for tool NAME with INPUT, or nil when no class.
`shell' uses the first token of its `command' (e.g. `sed'); `write' and
`search_replace' use the directory of `path' (sub-directories are covered
by the prefix match in `--class-prefix-p'); every other tool has no class
key."
  (cond
   ((equal name "shell")
    (let ((cmd (tagarela--hval input "command")))
      (when (and cmd (string-match "\\([^[:space:]]+\\)" cmd))
        (match-string 1 cmd))))
   ((member name '("write" "search_replace"))
    (let ((path (tagarela--hval input "path")))
      (when path
        (file-name-directory (expand-file-name path)))))
   (t nil)))

(defun tagarela--class-prefix-p (name key candidate)
  "Return non-nil if the stored class KEY covers CANDIDATE for tool NAME.
For `shell' the two must be `equal' (exact command token).  For the path
tools (`write', `search_replace') CANDIDATE is covered when KEY is a
directory prefix of it, so sub-directories are trusted too."
  (and key candidate
       (if (equal name "shell")
           (equal key candidate)
         (string-prefix-p key candidate))))

(defun tagarela--trusted-p (name input)
  "Return non-nil when tool NAME with INPUT is trusted.
Trusted when `tagarela--trust-all' is set, or the tool's class key is
covered by a recorded class trust, or this exact input was recorded for the
tool."
  (or tagarela--trust-all
      (let* ((key (tagarela--trust-class-key name input))
             (class (cdr (assoc name tagarela--trust-class))))
        (and key (tagarela--class-prefix-p name class key)))
      (let ((specific (cdr (assoc name tagarela--trust-specific))))
        (and specific (equal specific input)))))

(defun tagarela--trust-record (scope name input)
  "Record a trust for tool NAME with INPUT in SCOPE ('specific/'class/'all).
Returns non-nil when a trust was actually recorded.  For `class' a non-nil
class key is required, otherwise nothing is recorded."
  (pcase scope
    ('all
     (setq tagarela--trust-all t))
    ('specific
     (setq tagarela--trust-specific
           (cons (cons name input)
                 (cl-remove-if (lambda (p) (equal (car p) name))
                               tagarela--trust-specific)))
     t)
    ('class
     (let ((key (tagarela--trust-class-key name input)))
       (when key
         (setq tagarela--trust-class
               (cons (cons name key)
                     (cl-remove-if (lambda (p) (equal (car p) name))
                                   tagarela--trust-class))))))
    (_ nil)))

(provide 'tagarela-client)

;;; tagarela-client.el ends here
