;;; alonso-client.el --- llm-bridge client: protocol, process and tools -*- lexical-binding: t; -*-

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

;; The "client" half of the Emacs llm-bridge integration.  It owns the JSON
;; protocol (serializing the commands sent to the bridge and parsing the
;; events it emits), the subprocess lifecycle (spawning, line filtering,
;; handshake), the handling of tool calls (display, approval and the
;; trust-scope decision logic) and the per-request overrides.
;;
;; The tools themselves are executed by the bridge, not here: read-only tools
;; run inline in the bridge, and mutating tools run once the client approves
;; them (a `tool_confirm' command).  The client never runs a tool.
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
  "Optional provider override (passed as -provider flag).  E.g. \"deepseek\" or \"google\".  Empty = default."
  :type 'string
  :group 'alonso)

(defcustom alonso-model ""
  "Optional model override (passed as -model flag).  Empty = provider default."
  :type 'string
  :group 'alonso)

(defcustom alonso-thinking 'unset
  "Thinking mode global/startup (passed as -thinking flag).
Value `unset' omits the flag (uses the bridge default); t forces thinking
on (-thinking, deepseek-reasoner when there is no explicit model) and
`off' forces it off (-thinking=false, deepseek-chat).  To override per
request, use `alonso-request-thinking'."
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
  "Whether to enable aggressive history pruning in the bridge.
Passed as the -aggressive-prune flag.  When on, the bridge collapses each
completed tool-calling turn into just the user prompt + final answer,
dropping the intermediate tool calls, tool results and chain-of-thought
from the history to save tokens and keep the prefix cacheable.
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

(defvar alonso--after-tool-separator-pending nil
  "Non-nil when a tool call was just displayed in the current turn.
The next model output (thinking or chunk) still needs the two blank lines
separating it from the tool's output.  Set by
`alonso--send-tool-confirm', consumed by the first `thinking'
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
(defvar alonso-session-context-pct nil
  "Context usage fraction (0..1) of the last turn, or nil when unknown.
Reported per turn (not accumulated); nil when the model's context window
is not known by the bridge.")
(defvar alonso-session-context-tokens nil
  "Context size (tokens) sent in the last turn, or nil when unknown.")
(defvar alonso-session-context-window nil
  "Static context window (tokens) of the model, or nil when unknown.")

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
        alonso-session-context-pct nil
        alonso-session-context-tokens nil
        alonso-session-context-window nil
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
Value t = on, `off' = off, `unset' = omit (provider default)."
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
\(a link passed through to the provider) or `:path' (a local file read by
the bridge).  An optional `:detail' (DeepSeek) is also honored."
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
\(see `alonso--image-json') attached as the `images' array."
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
Each value may be a string, number, boolean (t or `:json-false'), hash
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
  "Sentinel for the llm-bridge process PROC, called with the status EVENT."
  (when (memq (process-status proc) '(exit signal))
    (setq alonso-process nil
          alonso-ready nil
          alonso-in-turn nil
          alonso-pending-tools nil
          alonso--after-tool-separator-pending nil)
    (alonso--reset-session)
    (message "llm-bridge ended: %s" event)))

(defun alonso--process-filter (_proc output)
  "Filter for the llm-bridge process OUTPUT: accumulate lines, dispatch events."
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
          (tool_confirm (alonso--on-tool-confirm ev))
          (turn_end     (alonso--on-turn-end ev))
          (files_changed (alonso--on-files-changed ev))
          (usage_delta  (alonso--on-usage-delta ev))
          (hook_action  (alonso--on-hook-action ev))
          (error        (alonso--on-error (gethash "message" ev)))
          (cancelled    (alonso--on-cancelled))
          (t (message "alonso: unknown event: %s" event)))))))

;;; Tool-calling loop

(defun alonso--on-tool-call (ev)
  "Handle a `tool_call' event EV: a read-only tool the bridge already ran.

Read-only tools (read/grep/glob/knowledge) are executed by the bridge itself
in the same turn, so a `tool_call' needs no action from the client — it is
only displayed.  Mutating tools (shell/write/search_replace) arrive as
`tool_confirm' events instead (see `alonso--on-tool-confirm')."
  (let ((id (gethash "id" ev))
        (name (gethash "name" ev))
        (input (gethash "input" ev)))
    (alonso--show-tool-call id name input)
    ;; Mark the pending separator so the model's next output (thinking or
    ;; response) is separated from the tool display by two blank lines —
    ;; same as the mutating path does in `alonso--send-tool-confirm'.  The
    ;; flag is cleared on the first resumed output and at `turn_end'.
    (setq alonso--after-tool-separator-pending t)))

(defun alonso--on-tool-confirm (ev)
  "Handle a `tool_confirm' event EV: a mutating tool to approve.

The bridge offers the tool for approval; the client confirms it (or applies
trust) and answers by sending a `tool_confirm' command, upon which the bridge
executes the tool itself.  With confirmation disabled the tool is approved
right away.  The tool is tracked in `alonso-pending-tools' until the client
answers (removed when approved, or via `cancel' when denied)."
  (let ((id (gethash "id" ev))
        (name (gethash "name" ev))
        (input (gethash "input" ev)))
    (push (list :id id :name name :input input) alonso-pending-tools)
    (if (not alonso-confirm-tools)
        (progn
          ;; confirmation disabled: show and approve right away
          (alonso--show-tool-call id name input)
          (alonso--dispatch-tool-guarded name input id))
      ;; queue it and schedule its (individual) confirmation.  It is shown one
      ;; at a time in `--confirm-pending', not here.
      (push (list :id id :name name :input input) alonso--confirm-queue)
      (alonso--schedule-confirm))))

(defun alonso--send-tool-confirm (id)
  "Ask the bridge to execute the approved tool call ID.

The bridge is the sole executor — the client never runs tools anymore; this
only sends the approval.  The tool is removed from `alonso-pending-tools' and
the separator flag is set so the next model output is separated from the tool
by two blank lines."
  (when (and alonso-process (process-live-p alonso-process))
    (alonso--send "tool_confirm" (list "id" id)))
  (setq alonso-pending-tools
        (cl-remove-if (lambda (tc) (equal (plist-get tc :id) id))
                      alonso-pending-tools))
  (setq alonso--after-tool-separator-pending t))

(defun alonso--dispatch-tool (_name _input id)
  "Approve tool call ID, asking the bridge to run it.

NAME and INPUT are unused (kept so the confirmation/trust call sites, which
pass them, stay unchanged); only the id matters, since the bridge already
holds the pending tool call."
  (alonso--send-tool-confirm id))

;;; Tool-call argument helpers

(defun alonso--hval (input key)
  "Get KEY from INPUT (a hash-table parsed from JSON), or nil."
  (when (hash-table-p input)
    (gethash key input)))

;;; Tool execution lives in the bridge (llm-bridge), not in the client.
;;
;; The tools (read/write/shell/grep/glob/search_replace) are now implemented in
;; Go inside llm-bridge and executed there: read-only tools run inline, and
;; mutating ones run once the client approves them (via `tool_confirm').  The
;; client only displays tool calls and answers the bridge's confirmations, so
;; the local tool implementations that used to live here were removed.

(defun alonso--resolve-command (cmd)
  "Resolve the bridge command CMD for `make-process'.
Expands a leading ~ or a relative path (strings containing a slash).
A bare command name is left untouched so it is found via PATH."
  (if (string-match-p "/" cmd)
      (expand-file-name cmd)
    cmd))

(defun alonso--start-args ()
  "Build the command-line args for starting the bridge.
The args come from the startup defcustoms (`-provider', `-model',
`-thinking', `-reasoning-effort', `-logfile', `-prune' and
`-aggressive-prune')."
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
  "Return non-nil if tool NAME is read-only (needs no confirmation)."
  (memq (intern name) '(read grep glob knowledge)))

(defun alonso--dispatch-tool-guarded (name input id)
  "Approve tool NAME with INPUT and ID, asking the bridge to run it.
`alonso--dispatch-tool' only sends the approval (the bridge executes the
tool), so there is no local execution error to report."
  (alonso--dispatch-tool name input id))

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
