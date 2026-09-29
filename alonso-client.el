;;; alonso-client.el --- llm-bridge client: protocol, process and tools -*- lexical-binding: t; -*-

;;; Commentary:

;; The "client" half of the Emacs llm-bridge integration.  It owns the JSON
;; protocol (serializing the commands sent to the bridge and parsing the
;; events it emits), the subprocess lifecycle (spawning, line filtering,
;; handshake) and the implementation of the tools (read, write, glob,
;; search_replace, shell, grep) plus the trust-scope decision logic.
;;
;; It deliberately knows nothing about buffers/windows: every event it
;; dispatches is handed to a rendering handler living in
;; alonso-ui.el, reached via `declare-function' (those handlers are
;; only called at runtime, never at load time).  The UI side requires this
;; file, so there is a single one-way dependency (ui -> client).
;;
;; See alonso.el (the entry point) and alonso-ui.el for the
;; rest of the integration.

;;; Code:

(require 'cl-lib)

;; Render handlers defined in alonso-ui.el, called at runtime while
;; dispatching bridge events / tool calls.  The UI file requires this one, so
;; by the time any of these is called the symbol is defined.
(declare-function alonso--on-chunk "alonso-ui")
(declare-function alonso--on-thinking "alonso-ui")
(declare-function alonso--on-turn-end "alonso-ui")
(declare-function alonso--on-usage-delta "alonso-ui")
(declare-function alonso--on-files-changed "alonso-ui")
(declare-function alonso--on-hook-action "alonso-ui")
(declare-function alonso--on-error "alonso-ui")
(declare-function alonso--on-cancelled "alonso-ui")
(declare-function alonso--show-tool-call "alonso-tools")
(declare-function alonso--schedule-confirm "alonso-tools")
(declare-function alonso--stop-spinner "alonso-ui")

;;;###autoload
(defgroup alonso nil
  "Client for the llm-bridge process."
  :group 'external)

(defcustom alonso-command "llm-bridge"
  "Command (or full path) used to start the llm-bridge binary."
  :type 'string
  :group 'alonso)

(defcustom alonso-provider ""
  "Optional provider override (passed as -provider flag). E.g. \"deepseek\" or \"google\". Empty = default."
  :type 'string
  :group 'alonso)

(defcustom alonso-model ""
  "Optional model override (passed as -model flag). Empty = provider default."
  :type 'string
  :group 'alonso)

(defcustom alonso-thinking 'unset
  "Thinking mode global/startup (passed as -thinking flag).
`unset' omits the flag (uses the bridge default), `t' forces thinking on
(-thinking, deepseek-reasoner when there is no explicit model) and `off'
forces it off (-thinking=false, deepseek-chat).  To override per request,
use `alonso-request-thinking'."
  :type '(choice (const :tag "Unset (bridge default)" unset)
                 (const :tag "On (deepseek-reasoner)" t)
                 (const :tag "Off (deepseek-chat)" off))
  :group 'alonso)

(defcustom alonso-reasoning-effort ""
  "Optional reasoning effort / thinking depth (passed as -reasoning-effort flag).
E.g. \"low\", \"medium\", \"high\".  Empty = provider default.  Only takes
effect with thinking on.  To override per request, use
`alonso-request-reasoning-effort'."
  :type 'string
  :group 'alonso)

(defcustom alonso-onnxruntime-lib
  (expand-file-name "~/.cache/llm-bridge/libonnxruntime.so")
  "Path to libonnxruntime.so used by the bridge's knowledge base embedder.
Passed to the subprocess as `LLM_BRIDGE_ONNXRUNTIME_LIB'.  Empty disables the
override (the bridge falls back to its default `onnxruntime.so').  Only needed
when the bridge was built with `make build-kb' and you want the KB on."
  :type 'string
  :group 'alonso)

(defcustom alonso-logfile ""
  "Path of the log file for the bridge subprocess (passed as -logfile flag).
When non-empty, the bridge redirects all of its logs (trace level) to this
file, keeping the JSON-lines protocol on stdout clean (the bridge's default
when no log file is given is to disable logging entirely).  Empty (the
default) starts the bridge without a log file, so nothing is logged."
  :type 'file
  :group 'alonso)

(defcustom alonso-prune nil
  "Whether to enable history pruning in the bridge (passed as the -prune flag).
When on, the bridge prunes older conversation turns or messages.
Mutually exclusive with `alonso-aggressive-prune'.  Off by default."
  :type 'boolean
  :group 'alonso
  :set (lambda (symbol value)
         (set-default symbol value)
         (when value
           (setq alonso-aggressive-prune nil))))

(defcustom alonso-aggressive-prune nil
  "Whether to enable aggressive history pruning in the bridge (passed as
the -aggressive-prune flag).  When on, the bridge collapses each completed
tool-calling turn into just the user prompt + final answer, dropping the
intermediate tool calls, tool results and chain-of-thought from the history
to save tokens and keep the prefix cacheable.
Mutually exclusive with `alonso-prune'.  Off by default."
  :type 'boolean
  :group 'alonso
  :set (lambda (symbol value)
         (set-default symbol value)
         (when value
           (setq alonso-prune nil))))

(defcustom alonso-confirm-tools t
  "Whether to ask the user before executing a tool call."
  :type 'boolean
  :group 'alonso)

;;; State structures and JSON construction

(defvar alonso-process nil
  "The llm-bridge subprocess.")

(defvar alonso-pending-tools nil
  "Alist of (:id id :name name :input input) for tool calls awaiting results.")

(defvar alonso--confirm-queue nil
  "Queue of (:id :name :input) tool calls awaiting confirmation.
Each tool call in the queue is confirmed individually (one question per
tool), even when several arrive together.")

(defvar alonso--confirm-timer nil
  "Timer used to batch tool confirmations.")

(defvar alonso--confirm-context nil
  "Pending tool call while the confirmation menu is open.
A plist (:name :input :id :rest :denied) saved by
`alonso--confirm-next' just before asking and consumed by
`alonso--confirm-answer'.  :rest is the remaining queue (the
tool calls after the current one) and :denied is non-nil when an earlier
tool call of the same batch was denied (so the rest are auto-denied).")

(defvar alonso--menu-answered nil
  "Non-nil when the last confirmation/trust menu key was pressed.
Set synchronously by the confirmation menu suffixes (`run'/`deny'/`trust')
and by the trust sub-menu suffixes, and reset to nil by
`alonso--confirm-ask' / `alonso--trust-pause' each time a
menu is opened.  `alonso--menu-exit-hook' uses it to tell a menu
that was answered from one that was merely closed (e.g. with `C-g'), which
must be treated as a deny so the turn does not hang waiting forever.")

(defvar alonso-in-turn nil
  "Non-nil while a turn (prompt) is in progress or awaiting tool results.")

(defvar alonso-line-buffer ""
  "Partial JSON line buffer while assembling multi-chunk reads.")

(defvar alonso--tool-procs nil
  "List of active tool subprocesses (shell/grep), cleaned up on kill.")

(defvar alonso--after-tool-separator-pending nil
  "Non-nil when a tool call/result was just displayed in the current turn
and the next model output (thinking or chunk) still needs the two blank
lines separating it from the tool's output.
Set by `alonso--send-tool-result', consumed by the first `thinking'
or `chunk' that follows, and cleared at the start/end of every turn.")

(defvar alonso-session-input-tokens 0
  "Total input tokens (sent) accumulated across all turns of the session.")
(defvar alonso-session-output-tokens 0
  "Total output tokens (received) accumulated across all turns of the session.")
(defvar alonso-session-cache-hit-tokens 0
  "Total prompt-cache hit tokens accumulated across all turns of the session.")
(defvar alonso-session-cache-miss-tokens 0
  "Total prompt-cache miss tokens accumulated across all turns of the session.")
(defvar alonso-session-model nil
  "Model used in the current session (nil until the first `turn_end').")

(defvar alonso--current-turn-input-tokens 0
  "Input tokens accumulated in the current turn.")
(defvar alonso--current-turn-output-tokens 0
  "Output tokens accumulated in the current turn.")
(defvar alonso--turn-finalized nil
  "Non-nil when the current turn has received its `turn_end' event.")

;;; Trust scope — tools the user decided to run without asking again

(defvar alonso--trust-specific nil
  "Alist of (tool-name . input-hash) trusted for this specific call only.
A mutating tool call is run without asking when its input hash is `equal'
to the one recorded here under its name.")

(defvar alonso--trust-class nil
  "Alist of (tool-name . class-key) trusted for a whole class of calls.
The class key is computed by `alonso--trust-class-key' (`shell'
uses the first command token; the path tools the file's directory).")

(defvar alonso--trust-all nil
  "Non-nil when every tool call is trusted without asking.")

(defvar alonso--trust-context nil
  "Paused batch-confirmation context while the user picks a trust scope.
A plist (:name :input :id :rest :denied) saved by
`alonso--trust-pause' and consumed by
`alonso--trust-finish'.")

(defun alonso--reset-session ()
  "Reset the session token counters, model and trust state.
Called when the bridge is restarted or shut down, ending the session."
  (alonso--stop-spinner)
  (setq alonso-session-input-tokens 0
        alonso-session-output-tokens 0
        alonso-session-cache-hit-tokens 0
        alonso-session-cache-miss-tokens 0
        alonso-session-model nil
        alonso--current-turn-input-tokens 0
        alonso--current-turn-output-tokens 0
        alonso--turn-finalized nil
        alonso--trust-specific nil
        alonso--trust-class nil
        alonso--trust-all nil
        alonso--trust-context nil))

;;; Per-request overrides (model, thinking and thinking depth)

;; The Go bridge accepts, in the `prompt' command, the optional fields:
;;   model            — string, explicit model (overrides provider/derivation)
;;   thinking         — bool, turns thinking on (deepseek-reasoner) or off
;;                      (deepseek-chat)
;;   reasoning_effort — string ("low"/"medium"/"high"), thinking depth
;; All three are buffer-local to the input buffer: the user sets them before
;; the prompt and the value is sent in the following request (they persist
;; until changed, mirroring the bridge, which keeps overrides between prompts).

(defcustom alonso-request-provider ""
  "Provider override for the next prompt (buffer-local to the input buffer).
Empty string = omits the `provider' field."
  :type 'string
  :group 'alonso)
(make-variable-buffer-local 'alonso-request-provider)

(defcustom alonso-request-model ""
  "Model override for the next prompt (buffer-local to the input buffer).
Empty string = omits the `model' field (uses the provider default)."
  :type 'string
  :group 'alonso)
(make-variable-buffer-local 'alonso-request-model)

(defcustom alonso-request-thinking 'unset
  "Thinking override for the next prompt (buffer-local to the input buffer).
`t' = on, `off' = off, `unset' = omit (provider default)."
  :type '(choice (const :tag "Unset (provider default)" unset)
                 (const :tag "On (deepseek-reasoner)" t)
                 (const :tag "Off (deepseek-chat)" off))
  :group 'alonso)
(make-variable-buffer-local 'alonso-request-thinking)

(defcustom alonso-request-reasoning-effort ""
  "Reasoning effort (thinking depth) for the next prompt.
E.g. \"low\", \"medium\", \"high\".  Empty string = omit (provider default)."
  :type 'string
  :group 'alonso)
(make-variable-buffer-local 'alonso-request-reasoning-effort)

;; The input buffer name is a defcustom defined in alonso-ui.el; declare it
;; here (with no value, so the defcustom remains the single source of truth)
;; so the per-request override helpers do not trigger free-variable warnings.
(defvar alonso-input-buffer-name)

(defun alonso--request-buffer ()
  "Return the input buffer (creating it if needed)."
  (get-buffer-create alonso-input-buffer-name))

(defun alonso--request-annotation ()
  "Return a short string describing the per-request overrides to send.
Returns \"\" when no override is set."
  (with-current-buffer (alonso--request-buffer)
    (let (parts)
      (unless (string-empty-p alonso-request-provider)
        (push (format "provider=%s" alonso-request-provider) parts))
      (unless (string-empty-p alonso-request-model)
        (push (format "model=%s" alonso-request-model) parts))
      (pcase alonso-request-thinking
        ('t    (push "thinking=on" parts))
        ('off  (push "thinking=off" parts)))
      (unless (string-empty-p alonso-request-reasoning-effort)
        (push (format "effort=%s" alonso-request-reasoning-effort) parts))
      (if parts
          (concat "  [" (mapconcat #'identity (nreverse parts) " ") "]")
        ""))))

(defun alonso--image-json (spec)
  "Convert an image SPEC plist into a JSON-ready hash table.
SPEC is a plist matching one `images' entry the bridge accepts in a `prompt':
either `:data' (inline base64, with an optional `:mime' media type), `:url'
(a link passed through to the provider) or `:path' (a local file read by the
bridge).  An optional `:detail' (DeepSeek) is also honored."
  (let ((tbl (make-hash-table :test 'equal))
        (data (plist-get spec :data))
        (url (plist-get spec :url))
        (path (plist-get spec :path))
        (mime (plist-get spec :mime))
        (detail (plist-get spec :detail)))
    (cond
     (data
      (puthash "data" data tbl)
      (when mime (puthash "mime_type" mime tbl)))
     (url
      (puthash "url" url tbl))
     (path
      (puthash "path" path tbl)))
    (when detail
      (puthash "detail" detail tbl))
    tbl))

(defun alonso--images-json (specs)
  "Convert a list of image SPECS (plists) into a JSON array (a vector)."
  (vconcat (mapcar #'alonso--image-json specs)))

(defun alonso--prompt-params (text &optional images)
  "Build the `prompt' params plist from TEXT and the per-request overrides.
Only the fields that were set are included, so the bridge keeps the provider
defaults for the rest.  IMAGES, when non-nil, is a list of image spec plists
(see `alonso--image-json') attached as the `images' array."
  (let ((params (list "text" text)))
    (let ((buf (get-buffer alonso-input-buffer-name)))
      (when buf
        (with-current-buffer buf
          (unless (string-empty-p alonso-request-provider)
            (setq params (append params (list "provider" alonso-request-provider))))
          (unless (string-empty-p alonso-request-model)
            (setq params (append params (list "model" alonso-request-model))))
          (when (memq alonso-request-thinking '(t off))
            (setq params (append params (list "thinking"
                                               (if (eq alonso-request-thinking 'off)
                                                   :json-false t)))))
          (unless (string-empty-p alonso-request-reasoning-effort)
            (setq params (append params (list "reasoning_effort"
                                               alonso-request-reasoning-effort)))))))
    (when images
      (setq params (append params (list "images" (alonso--images-json images)))))
    params))

(defun alonso--json-plist-to-hash (plist)
  "Convert PLIST (flat alternating keys/values) into a hash table."
  (let ((tbl (make-hash-table :test 'equal)))
    (cl-loop for (k v) on plist by #'cddr
             do (puthash k v tbl))
    tbl))

(defun alonso--json-object (&rest args)
  "Build a JSON object string from ARGS as alternating key/value pairs.
Each value may be a string, number, boolean (`t' or `:json-false'), hash
table, or nil (serialized as null)."
  (let ((tbl (make-hash-table :test 'equal)))
    (cl-loop for (k v) on args by #'cddr
             do (puthash k v tbl))
    (json-serialize tbl :null-object nil :false-object :json-false)))

(defun alonso--send (method &optional params)
  "Send a command METHOD to the bridge with optional PARAMS (a plist).
PARAMS is a flat plist of alternating keys/values, e.g. (\"text\" \"oi\")."
  (process-send-string alonso-process
                       (concat (apply #'alonso--json-object
                                      "method" method
                                      (and params
                                           (list "params"
                                                 (alonso--json-plist-to-hash params))))
                               "\n")))

;;; Process management (subprocess + handshake)

(defvar alonso-ready nil
  "Non-nil after the bridge sends the `ready' event (handshake done).")

(defun alonso--process-sentinel (proc event)
  "Sentinel for the llm-bridge process."
  (when (memq (process-status proc) '(exit signal))
    (setq alonso-process nil
          alonso-ready nil
          alonso-in-turn nil
          alonso-pending-tools nil
          alonso--after-tool-separator-pending nil)
    (alonso--reset-session)
    (message "llm-bridge ended: %s" event)))

(defun alonso--process-filter (_proc output)
  "Filter for the llm-bridge process: accumulate lines and dispatch events."
  (setq alonso-line-buffer (concat alonso-line-buffer output))
  (let ((start 0) nl line)
    (while (setq nl (string-match-p "\n" alonso-line-buffer start))
      (setq line (substring alonso-line-buffer start nl))
      (setq start (1+ nl))
      (when (string-match-p "[^[:space:]]" line)
        (alonso--handle-line line)))
    (setq alonso-line-buffer (substring alonso-line-buffer start))))

;;; Event dispatcher

(defun alonso--handle-line (line)
  "Parse and dispatch a single JSON event LINE from the bridge."
  (let ((ev (ignore-errors (json-parse-string line
                               :object-type 'hash-table :array-type 'list))))
    (when ev
      (let ((event (gethash "event" ev)))
        (cl-case (intern event)
          (ready        (setq alonso-ready t))
          (chunk        (alonso--on-chunk (gethash "text" ev)))
          (thinking     (alonso--on-thinking (gethash "text" ev)))
          (tool_call    (alonso--on-tool-call ev))
          (turn_end     (alonso--on-turn-end ev))
          (files_changed (alonso--on-files-changed ev))
          (usage_delta  (alonso--on-usage-delta ev))
          (hook_action  (alonso--on-hook-action ev))
          (error        (alonso--on-error (gethash "message" ev)))
          (cancelled    (alonso--on-cancelled))
          (t (message "alonso: unknown event: %s" event)))))))

;;; Tool-calling loop

(defun alonso--on-tool-call (ev)
  "Handle a `tool_call' event EV.
Read-only tools are shown and execute right away.  Mutating tools are only
queued (not shown yet): each one is displayed and asked for its individual
confirmation inside `alonso--confirm-pending', one at a time — only
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
        ;; `alonso-pending-tools': nothing would ever remove that entry
        ;; (no tool_result is ever sent for it), and a leftover entry would make
        ;; every following `prompt' be rejected as \"turn in progress\".
        (alonso--show-tool-call id name input)
      ;; Every other tool is tracked in `alonso-pending-tools' (its
      ;; entry is removed by `alonso--send-tool-result' once the tool
      ;; reports back).
      (push (list :id id :name name :input input) alonso-pending-tools)
      (if (or (alonso--tool-read-only-p name)
              (not alonso-confirm-tools))
        (progn
          ;; read-only (or confirmation disabled): show and run right away
          (alonso--show-tool-call id name input)
          (condition-case err
              (alonso--dispatch-tool name input id)
            (error
             (alonso--send-tool-result
              id (error-message-string err) "error"))))
      ;; mutating: queue it and schedule its (individual) confirmation.  It is
      ;; shown one at a time in `--confirm-pending', not here.
      (push (list :id id :name name :input input) alonso--confirm-queue)
      (alonso--schedule-confirm)))))

(defun alonso--send-tool-result (id result status)
  "Send a tool_result for ID with RESULT and STATUS."
  (when (and alonso-process (process-live-p alonso-process))
    (alonso--send "tool_result"
                          (list "id" id "result" result "status" status)))
  (setq alonso-pending-tools
        (cl-remove-if (lambda (tc) (equal (plist-get tc :id) id))
                      alonso-pending-tools))
  ;; The tool output finished: the next thinking/chunk of the model must
  ;; be separated from it by two blank lines.
  (setq alonso--after-tool-separator-pending t))

(defun alonso--dispatch-tool (name input id)
  "Dispatch tool NAME with INPUT and ID for execution.
`shell' and `grep' run asynchronously via `make-process'; the remaining tools
execute synchronously (they are fast file operations)."
  (cl-case (intern name)
    (shell (alonso--tool-shell-async input id))
    (grep  (alonso--tool-grep-async input id))
    (t (alonso--send-tool-result
        id (alonso--execute-tool name input) "success"))))

;;; Implementation of the 6 tools

(defun alonso--hval (input key)
  "Get KEY from INPUT (a hash-table parsed from JSON), or nil."
  (when (hash-table-p input)
    (gethash key input)))

(defun alonso--tool-proc-filter (proc out)
  "Accumulate OUT from a tool subprocess PROC into its :output property."
  (process-put proc :output (concat (process-get proc :output) out)))

(defun alonso--tool-read (input)
  "Tool `read': return the contents of the file at PATH.
When the optional OFFSET (0-based line index) and/or LIMIT (max number of
lines) are given, return only that slice of the file (lines from OFFSET, up
to LIMIT lines); otherwise return the whole file."
  (let ((path (alonso--hval input "path")))
    (unless path (error "read: missing 'path'"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name path))
      (let* ((lines (split-string (buffer-string) "\n"))
             (offset (alonso--hval input "offset"))
             (limit (alonso--hval input "limit")))
        (if (and (null offset) (null limit))
            (buffer-string)
          (let* ((nlines (length lines))
                 (start (min nlines (if (numberp offset) (max 0 offset) 0)))
                 (end (if (numberp limit)
                          (min nlines (+ start limit))
                        nlines)))
            (mapconcat #'identity (cl-subseq lines start end) "\n")))))))

(defun alonso--tool-write (input)
  "Tool `write': write CONTENT to the file at PATH."
  (let ((path (alonso--hval input "path"))
        (content (alonso--hval input "content")))
    (unless (and path content) (error "write: missing 'path' or 'content'"))
    (with-temp-buffer
      (insert content)
      (write-region (point-min) (point-max) (expand-file-name path) nil 'quiet))
    "ok"))

(defun alonso--tool-shell-async (input id)
  "Run the `shell' tool COMMAND asynchronously via bash -c.
Sends the tool_result when the process exits."
  (let ((command (alonso--hval input "command")))
    (unless command (error "shell: missing 'command'"))
    (let ((proc (make-process
                 :name (format "llm-bridge-shell-%s" id)
                 :buffer nil
                 :command (list "bash" "-c" command)
                 :connection-type 'pipe
                 :filter #'alonso--tool-proc-filter
                 :sentinel (lambda (proc _event)
                             (setq alonso--tool-procs
                                   (delq proc alonso--tool-procs))
                             (when (and (memq (process-status proc) '(exit signal))
                                        (not (process-get proc :cancelled)))
                               (let* ((status (process-exit-status proc))
                                      (out (or (process-get proc :output) "")))
                                 (alonso--send-tool-result
                                  id
                                  (concat out (when (/= status 0)
                                                (format "\n[exited with status %d]" status)))
                                  "success")))))))
      (push proc alonso--tool-procs))))

(defun alonso--tool-grep-async (input id)
  "Run the `grep' tool PATTERN under PATH asynchronously.
The pattern is a POSIX extended regular expression (like `grep -E'), so a
literal string must have its regex metacharacters escaped; output is one
`file:line:text' entry per match.  Sends the tool_result when the process
exits (0 = matches, 1 = no matches)."
  (let ((pattern (alonso--hval input "pattern"))
        (path (or (alonso--hval input "path") ".")))
    (unless pattern (error "grep: missing 'pattern'"))
    (let ((proc (make-process
                 :name (format "llm-bridge-grep-%s" id)
                 :buffer nil
                 :command (list "grep" "-rnEI" "--include=*" pattern (expand-file-name path))
                 :connection-type 'pipe
                 :filter #'alonso--tool-proc-filter
                 :sentinel (lambda (proc _event)
                             (setq alonso--tool-procs
                                   (delq proc alonso--tool-procs))
                             (when (and (memq (process-status proc) '(exit signal))
                                        (not (process-get proc :cancelled)))
                               (let* ((status (process-exit-status proc))
                                      (out (or (process-get proc :output) "")))
                                 (alonso--send-tool-result
                                  id out (if (<= status 1) "success" "error"))))))))
      (push proc alonso--tool-procs))))

(defun alonso--kill-tool-procs ()
  "Kill any in-flight asynchronous tool processes (shell/grep).

Called when a turn is cancelled so a long-running command stops instead of
keeping running after the turn ended, and so its late tool_result is never
sent (the bridge no longer waits for it).  Each process is marked
`:cancelled' before being killed so its sentinel skips sending a
tool_result."
  (dolist (proc alonso--tool-procs)
    (when (process-live-p proc)
      (process-put proc :cancelled t)
      (delete-process proc)))
  (setq alonso--tool-procs nil))

(defun alonso--tool-glob (input)
  "Tool `glob': find files matching PATTERN under PATH."
  (let ((pattern (alonso--hval input "pattern"))
        (base (or (alonso--hval input "path") default-directory)))
    (unless pattern (error "glob: missing 'pattern'"))
    (let ((default-directory (expand-file-name base)))
      (mapconcat #'identity (file-expand-wildcards pattern) "\n"))))

(defun alonso--tool-search-replace (input)
  "Tool `search_replace': replace the first exact SEARCH in PATH with REPLACE."
  (let ((path (alonso--hval input "path"))
        (search (alonso--hval input "search"))
        (replace (alonso--hval input "replace")))
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

(defun alonso--execute-tool (name input)
  "Execute tool NAME with INPUT synchronously, returning the result string.
Only the fast file tools run here; `shell' and `grep' are dispatched
asynchronously by `alonso--dispatch-tool'."
  (cl-case (intern name)
    (read           (alonso--tool-read input))
    (write          (alonso--tool-write input))
    (glob           (alonso--tool-glob input))
    (search_replace (alonso--tool-search-replace input))
    (t (error "Unknown tool: %s" name))))

(defun alonso--resolve-command (cmd)
  "Resolve the bridge command CMD for `make-process'.
Expands a leading ~ or a relative path (strings containing a slash).
A bare command name is left untouched so it is found via PATH."
  (if (string-match-p "/" cmd)
      (expand-file-name cmd)
    cmd))

(defun alonso--start-args ()
  "Build the command-line args for starting the bridge from the startup
defcustoms (`-provider', `-model', `-thinking', `-reasoning-effort',
`-logfile', `-prune' and `-aggressive-prune')."
  (let (args)
    (unless (string-empty-p alonso-provider)
      (setq args (append args (list "-provider" alonso-provider))))
    (unless (string-empty-p alonso-model)
      (setq args (append args (list "-model" alonso-model))))
    (pcase alonso-thinking
      ('t   (setq args (append args (list "-thinking"))))
      ('off (setq args (append args (list "-thinking=false")))))
    (unless (string-empty-p alonso-reasoning-effort)
      (setq args (append args (list "-reasoning-effort" alonso-reasoning-effort))))
    (unless (string-empty-p alonso-logfile)
      (setq args (append args (list "-logfile" alonso-logfile))))
    (when alonso-prune
      (setq args (append args (list "-prune"))))
    (when alonso-aggressive-prune
      (setq args (append args (list "-aggressive-prune"))))
    args))

(defun alonso--start-process ()
  "Start the llm-bridge subprocess if not already running.
When `alonso-onnxruntime-lib' is non-empty, the subprocess is started
with `LLM_BRIDGE_ONNXRUNTIME_LIB' set to it (via `setenv' before spawning, so
a `make build-kb' bridge can dlopen the runtime lib and use the project
knowledge base), then the previous value is restored.  Note: we cannot use the
`make-process' `:environment' keyword because in some Emacs builds it is
silently ignored — `setenv' against `process-environment' is what the child
actually inherits."
  (if (and alonso-process (process-live-p alonso-process))
      alonso-process
    (let* ((old-lib (getenv "LLM_BRIDGE_ONNXRUNTIME_LIB"))
           (set-lib (and alonso-onnxruntime-lib
                         (not (string-empty-p alonso-onnxruntime-lib)))))
      (when set-lib
        (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" alonso-onnxruntime-lib))
      (unwind-protect
          (let ((cmd (cons (alonso--resolve-command alonso-command)
                           (alonso--start-args))))
            (setq alonso-process
                  (make-process :name "llm-bridge"
                                :buffer nil
                                :command cmd
                                :connection-type 'pipe
                                :filter #'alonso--process-filter
                                :sentinel #'alonso--process-sentinel)))
        (if old-lib
            (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" old-lib)
          (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" nil))))
    (setq alonso-line-buffer "")
    alonso-process))

(defun alonso--ensure-ready ()
  "Start the bridge and block until it emits the `ready' event.
Raises an error if the process dies or the handshake times out (10s)."
  (unless alonso-ready
    (alonso--start-process)
    (let ((deadline (time-add (current-time) (seconds-to-time 10))))
      (while (and (not alonso-ready)
                  (process-live-p alonso-process)
                  (time-less-p (current-time) deadline))
        (accept-process-output nil 0.1)))
    (unless alonso-ready
      (error "Timeout waiting for 'ready' from llm-bridge"))))

;;; Tool decision logic — read-only classification and trust scope

(defun alonso--tool-read-only-p (name)
  "Return non-nil if tool NAME only reads data (runs without confirmation)."
  (memq (intern name) '(read grep glob knowledge)))

(defun alonso--dispatch-tool-guarded (name input id)
  "Dispatch tool NAME with INPUT and ID, reporting any error as a tool_result.
Wraps `alonso--dispatch-tool' so an execution error is sent back to
the bridge instead of interrupting the client."
  (condition-case err
      (alonso--dispatch-tool name input id)
    (error
     (alonso--send-tool-result id (error-message-string err) "error"))))

(defun alonso--trust-class-key (name input)
  "Return the class key for tool NAME with INPUT, or nil when no class.
`shell' uses the first token of its `command' (e.g. `sed'); `write' and
`search_replace' use the directory of `path' (sub-directories are covered
by the prefix match in `--class-prefix-p'); every other tool has no class
key."
  (cond
   ((equal name "shell")
    (let ((cmd (alonso--hval input "command")))
      (when (and cmd (string-match "\\([^[:space:]]+\\)" cmd))
        (match-string 1 cmd))))
   ((member name '("write" "search_replace"))
    (let ((path (alonso--hval input "path")))
      (when path
        (file-name-directory (expand-file-name path)))))
   (t nil)))

(defun alonso--class-prefix-p (name key candidate)
  "Return non-nil if the stored class KEY covers CANDIDATE for tool NAME.
For `shell' the two must be `equal' (exact command token).  For the path
tools (`write', `search_replace') CANDIDATE is covered when KEY is a
directory prefix of it, so sub-directories are trusted too."
  (and key candidate
       (if (equal name "shell")
           (equal key candidate)
         (string-prefix-p key candidate))))

(defun alonso--trusted-p (name input)
  "Return non-nil when tool NAME with INPUT is trusted.
Trusted when `alonso--trust-all' is set, or the tool's class key is
covered by a recorded class trust, or this exact input was recorded for the
tool."
  (or alonso--trust-all
      (let* ((key (alonso--trust-class-key name input))
             (class (cdr (assoc name alonso--trust-class))))
        (and key (alonso--class-prefix-p name class key)))
      (let ((specific (cdr (assoc name alonso--trust-specific))))
        (and specific (equal specific input)))))

(defun alonso--trust-record (scope name input)
  "Record a trust for tool NAME with INPUT in SCOPE ('specific/'class/'all).
Returns non-nil when a trust was actually recorded.  For `class' a non-nil
class key is required, otherwise nothing is recorded."
  (pcase scope
    ('all
     (setq alonso--trust-all t))
    ('specific
     (setq alonso--trust-specific
           (cons (cons name input)
                 (cl-remove-if (lambda (p) (equal (car p) name))
                               alonso--trust-specific)))
     t)
    ('class
     (let ((key (alonso--trust-class-key name input)))
       (when key
         (setq alonso--trust-class
               (cons (cons name key)
                     (cl-remove-if (lambda (p) (equal (car p) name))
                                   alonso--trust-class))))))
    (_ nil)))

(provide 'alonso-client)

;;; alonso-client.el ends here
