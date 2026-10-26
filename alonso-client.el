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
;; The trust class key of `curl' is the URL's host, and the URL is split by
;; the same function the display uses, so what is shown and what is trusted
;; can never disagree.
(declare-function alonso--curl-url-parts "alonso-tools")
(declare-function alonso--stop-spinner "alonso-ui")

;;;###autoload
(defgroup alonso nil
  "Client for the llm-bridge process."
  :group 'external)

(defcustom alonso-command "llm-bridge"
  "Command (or full path) used to start the llm-bridge binary."
  :type 'string
  :group 'alonso)

(defcustom alonso-sandbox t
  "Whether the bridge should confine itself (passed as `-disable-sandbox').
The bridge sandboxes itself by default: at startup it re-executes itself
under `caged' (the ceiling) and runs the external processes it spawns (the
`shell' and `grep' tools and the hooks) under a stricter policy with no
environment, no IPC and no network.  With this on, the directories in
`alonso-sandbox-ro-paths' and `alonso-sandbox-rw-paths' are passed to it
with `-sandbox-ro'/`-sandbox-rw'.

When nil, `-disable-sandbox' is passed and the bridge runs unconfined.

The client no longer wraps the bridge itself: the sandbox is the bridge's
job (see the llm-bridge documentation, section \"Sandbox\").  `caged' must
be installed and found on the variable `exec-path', or its path passed with
`alonso-sandbox-args' \(\"-caged-bin\" \"/path/to/caged\")."
  :type 'boolean
  :group 'alonso)

(defcustom alonso-sandbox-ro-paths nil
  "Extra read-only directories given to the bridge (one `-sandbox-ro' each).
A leading ~ is expanded.

The bridge already grants the system trees (`/usr', `/lib', `/lib64',
`/bin', `/etc'), `/dev/urandom', the knowledge-base assets
\(`~/.cache/llm-bridge') and the global context/hooks (`~/.llm-bridge'),
so this is only for extras such as `~/.gitconfig'.

Every path has to exist when the bridge starts (its sandbox opens each one
before restricting itself)."
  :type '(repeat directory)
  :group 'alonso)

(defcustom alonso-sandbox-rw-paths '("~/mysrc")
  "Directories the bridge and its tools may read and write (one `-sandbox-rw').
A leading ~ is expanded.

The bridge grants no project directory on its own — the sandbox is frozen
when it starts and the project changes at runtime — so the projects root
belongs here.  Anything outside these paths is denied to the tools by the
kernel (`EACCES'), which shows up as the tool failing, not as a sandbox
error.

Every path has to exist when the bridge starts."
  :type '(repeat directory)
  :group 'alonso)

(defcustom alonso-sandbox-args nil
  "Extra flags passed verbatim to the bridge, after the sandbox paths.
For the bridge's sandbox flags that have no dedicated defcustom, e.g.
\(\"-caged-bin\" \"/opt/caged/bin/caged\"), \"-sandbox-network\" or
\(\"-sandbox-connect-port\" \"443\").

The tools have no network by default \(the bridge itself always may reach
its provider), so these are rarely needed."
  :type '(repeat string)
  :group 'alonso)

(defcustom alonso-provider ""
  "Optional provider override (passed as the -provider flag).
E.g. \"deepseek\" or \"google\".  Empty = default."
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

;; `alonso-prune' and `alonso-aggressive-prune' reset each other from their
;; :set functions, so one of the two is always defined after the one that
;; touches it.  Declare the later one here (with no value, so the defcustom
;; below remains the single source of truth) to keep the :set from triggering
;; a free-variable warning.
(defvar alonso-aggressive-prune)

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
  "Alist of tool calls awaiting results.
Each entry is (:id id :name name :input input . meta), where META is the
confirmation detail the bridge sends along with a `tool_confirm'
\(:segments :risk :tainted); see `alonso--confirm-meta'.")

(defvar alonso--confirm-queue nil
  "Queue of (:id :name :input . meta) tool calls awaiting confirmation.
Each tool call in the queue is confirmed individually (one question per
tool), even when several arrive together.")

(defvar alonso--confirm-timer nil
  "Timer used to batch tool confirmations.")

(defvar alonso--confirm-context nil
  "Pending tool call while the confirmation menu is open.
A plist (:name :input :id :rest :denied :risk) saved by
`alonso--confirm-next' just before asking and consumed by
`alonso--confirm-answer'.  :rest is the remaining queue (the
tool calls after the current one), :denied is non-nil when an earlier
tool call of the same batch was denied (so the rest are auto-denied) and
:risk is the level the bridge reported (`high' forces a typed answer, see
`alonso--confirm-ask').")

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
  "Alist of (tool-name . input-key) trusted for this specific call only.
A mutating tool call is run without asking when its canonical input (see
`alonso--input-key') is `equal' to the one recorded here under its name.")

(defvar alonso--trust-class nil
  "Alist of (tool-name . class-key) trusted for a whole class of calls.
The class key is computed by `alonso--trust-class-key' (`shell' uses the
program of a single-command line; the path tools the file's directory;
`curl' the URL's host).")

(defvar alonso--trust-tools nil
  "List of tool names trusted for every call in this session.
This is what the menu's `all' scope records: the trust was picked from one
tool's confirmation menu, so it covers that tool only, never the tools the
user was not looking at.  `alonso-trust-reset' clears it.")

(defvar alonso--trust-all nil
  "Non-nil when EVERY tool call is trusted without asking.
An escape hatch for Lisp callers and tests only: no menu offers it, because
a scope picked while confirming one tool must not silently vouch for every
other tool of the session.")

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
        alonso--trust-tools nil
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

(defvar alonso--process-output ""
  "Non-JSON output collected from the llm-bridge process.
Anything the process writes that is not a JSON event line (typically
stderr: the sandbox launcher's errors, a crash message, ...) is appended
here, so a launch failure can be reported instead of a bare timeout.")

(defvar alonso--last-exit-status nil
  "Exit status of the last llm-bridge process that terminated, or nil.")

(defun alonso--process-sentinel (proc event)
  "Sentinel for the llm-bridge process PROC, called with the status EVENT."
  (when (memq (process-status proc) '(exit signal))
    (setq alonso--last-exit-status (process-exit-status proc)
          alonso-process nil
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
    (if (null ev)
        ;; Not a JSON event: typically stderr (the sandbox launcher's error,
        ;; a crash message).  Keep it so `alonso--ensure-ready' can explain a
        ;; failed launch instead of reporting a bare timeout.
        (setq alonso--process-output
              (concat alonso--process-output line "\n"))
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
only displayed.  Mutating tools (shell/write/search_replace/curl, and a
`knowledge' write) arrive as `tool_confirm' events instead (see
`alonso--on-tool-confirm')."
  (let ((id (gethash "id" ev))
        (name (gethash "name" ev))
        (input (gethash "input" ev)))
    (alonso--show-tool-call id name input (alonso--confirm-meta ev))
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
  (let* ((id (gethash "id" ev))
         (name (gethash "name" ev))
         (input (gethash "input" ev))
         (meta (alonso--confirm-meta ev))
         (tc (append (list :id id :name name :input input) meta)))
    (push tc alonso-pending-tools)
    (if (not alonso-confirm-tools)
        (progn
          ;; confirmation disabled: show and approve right away
          (alonso--show-tool-call id name input meta)
          (alonso--dispatch-tool-guarded name input id))
      ;; Queue it and schedule its (individual) confirmation.  It is shown one
      ;; at a time in `--confirm-pending', not here.  Appending (rather than
      ;; pushing) keeps the model's order: the bridge emits every
      ;; `tool_confirm' of the turn in one go, so the questions would
      ;; otherwise be asked in reverse.
      (setq alonso--confirm-queue (append alonso--confirm-queue (list tc)))
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

(defun alonso--hval-true (input key)
  "Return non-nil when KEY of INPUT (a JSON hash table) is a true boolean.
`json-parse-string' yields the symbol `:false' for JSON false (it is not
nil), so a plain `gethash' test would take a false value for true."
  (let ((value (alonso--hval input key)))
    (and value (not (eq value :false)) (not (eq value :json-false)))))

(defun alonso--confirm-meta (ev)
  "Return the confirmation metadata of the tool event EV.
A plist (:segments :risk :tainted) with the detail the bridge attaches to a
tool call since the prompt-injection hardening: the commands a `shell'
one-liner actually runs, its coarse risk level and whether its arguments
repeat content fetched earlier in the session.  All of them are optional
\(`omitempty' on the bridge), so an older bridge yields an all-nil plist."
  (list :segments (alonso--hval ev "segments")
        :risk (alonso--hval ev "risk")
        :tainted (alonso--hval-true ev "tainted")))

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


(defun alonso--call-with-caged-env (fn)
  "Call FN with CAGED_DISABLE_WARNINGS set, restoring the old value after.
The bridge forwards the environment it inherits to the `caged' instance it
re-executes itself under, so setting the variable here silences caged's
\"Landlock ABI N does not support some features\" warning.  That warning goes
to stderr and `alonso-client' treats any stderr line as a launch failure, so
it would surface as a bogus error.  Nothing reads the variable when the
sandbox is off, so it is always set."
  (let ((old (getenv "CAGED_DISABLE_WARNINGS")))
    (unwind-protect
        (progn
          (setenv "CAGED_DISABLE_WARNINGS" "1")
          (funcall fn))
      (setenv "CAGED_DISABLE_WARNINGS" old))))

(defun alonso--sandbox-args ()
  "Build the sandbox flags passed to the bridge.
With `alonso-sandbox' nil it is just (\"-disable-sandbox\").  Otherwise one
`-sandbox-ro'/`-sandbox-rw' per directory in `alonso-sandbox-ro-paths' /
`alonso-sandbox-rw-paths' (expanded, empty entries skipped), followed by
`alonso-sandbox-args' verbatim.

The paths simply add to what the bridge grants on its own: it already gives
itself the system trees, `/dev/urandom', the KB assets and the global
context, so the list here is about the projects and about extras."
  (if (not alonso-sandbox)
      (list "-disable-sandbox")
    (let (args)
      (dolist (dir alonso-sandbox-ro-paths)
        (unless (or (null dir) (string-empty-p dir))
          (setq args (append args (list "-sandbox-ro" (expand-file-name dir))))))
      (dolist (dir alonso-sandbox-rw-paths)
        (unless (or (null dir) (string-empty-p dir))
          (setq args (append args (list "-sandbox-rw" (expand-file-name dir))))))
      (append args alonso-sandbox-args))))

(defun alonso--start-command ()
  "Build the full argv used to start the bridge.
It is `alonso-command', followed by the startup args (`alonso--start-args')
and the sandbox flags (`alonso--sandbox-args').  There is no launcher
wrapper and no `--': the bridge applies the sandbox to itself."
  (append (list (alonso--resolve-command alonso-command))
          (alonso--start-args)
          (alonso--sandbox-args)))

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
actually inherits.

`alonso-sandbox' is applied by the bridge itself; the client only passes
the `-sandbox-ro'/`-sandbox-rw' paths (and `-disable-sandbox' when it is
off).  The one environment detail that still comes from here is
CAGED_DISABLE_WARNINGS, set by `alonso--call-with-caged-env' around the
spawn: the bridge forwards it to the caged instance it re-executes itself
under, which keeps caged's ABI warning off stderr."
  (if (and alonso-process (process-live-p alonso-process))
      alonso-process
    (let* ((old-lib (getenv "LLM_BRIDGE_ONNXRUNTIME_LIB"))
           (set-lib (and alonso-onnxruntime-lib
                         (not (string-empty-p alonso-onnxruntime-lib)))))
      (when set-lib
        (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" alonso-onnxruntime-lib))
      (unwind-protect
          (alonso--call-with-caged-env
           (lambda ()
             (let ((cmd (alonso--start-command)))
               (setq alonso-process
                     (make-process :name "llm-bridge"
                                   :buffer nil
                                   :command cmd
                                   :connection-type 'pipe
                                   :filter #'alonso--process-filter
                                   :sentinel #'alonso--process-sentinel)))))
        (if old-lib
            (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" old-lib)
          (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" nil))))
    (setq alonso-line-buffer ""
          alonso--process-output ""
          alonso--last-exit-status nil)
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
      (let ((detail (alonso--ready-failure-detail)))
        (error "Bridge failed to become ready%s"
               (if detail (concat ": " detail)
                 " (no `ready' within 10s)"))))))

(defun alonso--ready-failure-detail ()
  "Explain why the bridge did not emit `ready', or nil.
Combines the process exit status and any non-JSON output (stderr) captured
while waiting, so a launch failure (e.g. the sandbox denying `exec') is not
reported as a bare timeout."
  (let (parts)
    (unless (process-live-p alonso-process)
      (when alonso--last-exit-status
        (push (format "process exited with code %s" alonso--last-exit-status)
              parts)))
    (let ((out (string-trim alonso--process-output)))
      (unless (string-empty-p out)
        (push out parts)))
    (when parts
      (mapconcat #'identity (nreverse parts) "; "))))

;;; Tool decision logic — read-only classification and trust scope

(defun alonso--tool-read-only-p (name &optional input)
  "Return non-nil if tool NAME with INPUT is read-only (needs no confirmation).
The static list is `read', `grep' and `glob'.  `knowledge' is classified
per call, mirroring the bridge: `show' and `search' only read the store,
while `add', `delete' and `reset' write to it.  Anything we cannot classify
\(no command, a non-string command, an unknown one) counts as mutating, so
a note planted by an injected page is always offered to the human.  `curl'
fetches from the network, so it is never read-only either."
  (cond
   ((equal name "knowledge")
    (let ((cmd (alonso--hval input "command")))
      (and (stringp cmd)
           (member (downcase (string-trim cmd)) '("show" "search")))))
   (t (and (memq (intern-soft name) '(read grep glob)) t))))

(defun alonso--dispatch-tool-guarded (name input id)
  "Approve tool NAME with INPUT and ID, asking the bridge to run it.
`alonso--dispatch-tool' only sends the approval (the bridge executes the
tool), so there is no local execution error to report."
  (alonso--dispatch-tool name input id))

(defun alonso--curl-host-key (url)
  "Return the host of URL, the class key trusted for `curl'.
The scheme, a `user:password@' prefix, the port and the path/query are
dropped, and the result is downcased, so
\"https://user:pw@Example.COM:8443/a?b=c\" yields \"example.com\"; a URL
without a scheme (\"example.com/a\") yields \"example.com\" as well.  The
port is dropped on purpose: the host is what identifies where the data goes,
and a public port is noise.  Returns nil when URL is missing, is not a
string, or yields no host at all, so a call nobody can pin to a single host
is never covered by a host trust."
  (when (and (stringp url) (not (string-empty-p (string-trim url))))
    (let ((authority (nth 1 (alonso--curl-url-parts (string-trim url)))))
      ;; A schemeless URL arrives whole in AUTHORITY: keep the authority only.
      (setq authority (car (split-string (or authority "") "[/?#]")))
      ;; Drop `user:password@' — the host is what follows the last `@'.
      (when (string-match "@\\(.*\\)\\'" authority)
        (setq authority (match-string 1 authority)))
      ;; Drop the port, honoring the bracketed IPv6 form (`[::1]:8080').
      (setq authority
            (if (string-prefix-p "[" authority)
                (if (string-match "\\`\\(\\[[^]]*\\]\\)" authority)
                    (match-string 1 authority)
                  authority)
              (car (split-string authority ":"))))
      (setq authority (downcase authority))
      (unless (string-empty-p authority) authority))))

(defconst alonso--shell-inert-tokens
  '("cd" "pushd" "popd" "set" "unset" "export" "source" "." ":"
    "true" "false" "alias" "umask" "ulimit" "shift" "exit" "return")
  "First tokens of a `shell' command that name nothing worth trusting.
`cd ~/x' says where to run, not what: a class trust on `cd' would cover
every command that merely changes directory first.  A line whose first
token is one of these gets no class key, so the menu offers no `c' for it.")

(defun alonso--shell-single-command-p (cmd)
  "Return non-nil when CMD is a single shell command.
A separator (`;', `&&', `||', `|', `|&', a lone `&' or a newline) makes the
line run more than one command, and the first token is then a poor name for
it — `cd /tmp && rm -rf x' would be trusted as `cd', which covers every
command that starts with a `cd'.  The `&' of a redirect (`2>&1', `>&2',
`<&3', `&>', `&>>') is not a separator, and neither is a separator inside
quotes or behind a backslash."
  (let ((i 0) (n (length cmd)) (quote nil) (escape nil) (single t))
    (while (and single (< i n))
      (let ((ch (aref cmd i)))
        (cond
         (escape (setq escape nil))
         ((and (eq ch ?\\) (not (eq quote ?\'))) (setq escape t))
         (quote (when (eq ch quote) (setq quote nil)))
         ((memq ch '(?\' ?\")) (setq quote ch))
         ((memq ch '(?\; ?\n ?|)) (setq single nil))
         ((eq ch ?&)
          ;; A `&' starts another command unless it belongs to a redirect.
          (unless (or (and (> i 0) (memq (aref cmd (1- i)) '(?< ?>)))
                      (and (> n (1+ i)) (eq (aref cmd (1+ i)) ?>)))
            (setq single nil)))))
      (setq i (1+ i)))
    single))

(defun alonso--shell-class-key (input)
  "Return the class key of a `shell' INPUT, or nil when it has none.
The key is the program of a single-command line (`git' for `git status'),
so that \"This class of calls: git\" covers exactly that program.  A line
that runs several commands, an assignment prefix (`FOO=1 ...') and a line
whose first token is inert (see `alonso--shell-inert-tokens') have no key:
the menu then offers no `c' and the call can be trusted only per call
\(`s') or per tool (`a')."
  (let ((cmd (alonso--hval input "command")))
    (when (stringp cmd)
      (setq cmd (string-trim cmd))
      (when (and (not (string-empty-p cmd))
                 (alonso--shell-single-command-p cmd)
                 (string-match "\\`\\([^[:space:]]+\\)" cmd))
        (let ((token (match-string 1 cmd)))
          (unless (or (member (downcase token) alonso--shell-inert-tokens)
                      (string-match-p "=" token))
            token))))))

(defun alonso--trust-class-key (name input &optional risk)
  "Return the class key for tool NAME with INPUT, or nil when no class.
`shell' uses the program of a single-command line (see
`alonso--shell-class-key'); `write' and `search_replace' use the directory
of `path' (sub-directories are covered by the prefix match in
`--class-prefix-p'); `curl' uses the host of its `url' (see
`alonso--curl-host-key'); every other tool has no class key.

RISK is the level the bridge reported for the call, when known.  A `shell'
line that is not `low' risk gets no class: `git commit' is medium and
`git push --force' is high, and the class of `git' should be offered on a
harmless `git status', not on the command that raised the tag.  On the
comparison path (`alonso--trusted-p') RISK is nil and only the shape of the
command decides, which is what keeps recording and matching consistent —
a stricter recording can only make a trust rarer, never mismatched.

`knowledge' deliberately has no class: trusting a whole class of KB writes
would let a note planted by an injected page skip the human (and the KB is
read by every later session).  For `curl' the unit is the host, not the
tool: trusting `example.com' must not trust `elsevil.example.com'."
  (cond
   ((equal name "shell")
    (when (or (null risk) (equal risk "low"))
      (alonso--shell-class-key input)))
   ((equal name "curl")
    (alonso--curl-host-key (alonso--hval input "url")))
   ((member name '("write" "search_replace"))
    (let ((path (alonso--hval input "path")))
      (when path
        (file-name-directory (expand-file-name path)))))
   (t nil)))

(defun alonso--class-prefix-p (name key candidate)
  "Return non-nil if the stored class KEY covers CANDIDATE for tool NAME.
For `shell' (a command token) and `curl' (a host) the two must be `equal' —
exactly that token, exactly that host: `sed' does not cover `sedx' and
`example.com' does not cover `example.com.evil.tld'.  For the path tools
\(`write', `search_replace') CANDIDATE is covered when KEY is a directory
prefix of it, so sub-directories are trusted too."
  (and key candidate
       (if (member name '("shell" "curl"))
           (equal key candidate)
         (string-prefix-p key candidate))))

(defun alonso--input-key (input)
  "Return a canonical form of tool INPUT for the `specific' trust scope.
Every `tool_confirm' arrives as a freshly parsed hash table, and `equal' on
hash tables is true only for the very same object — so recording the payload
itself would never match the next confirmation, and \"this exact call\"
would silently ask again.  This rebuilds the payload as a key-sorted alist
\(recursing into nested tables and conses) so that two distinct objects
with the same content compare `equal'."
  (cond
   ((hash-table-p input)
    (cons :hash-table
          (mapcar (lambda (key)
                    (cons key (alonso--input-key (gethash key input))))
                  (sort (let (keys)
                          (maphash (lambda (key _value) (push key keys)) input)
                          keys)
                        (lambda (a b)
                          (string< (format "%s" a) (format "%s" b)))))))
   ((consp input)
    (cons (alonso--input-key (car input))
          (alonso--input-key (cdr input))))
   (t input)))

(defun alonso--trusted-p (name input)
  "Return non-nil when tool NAME with INPUT is trusted.
Trusted when `alonso--trust-all' is set, or NAME was trusted for every call
\(the `all' scope), or the tool's class key is covered by a recorded class
trust, or this exact input was recorded for the tool."
  (or alonso--trust-all
      (member name alonso--trust-tools)
      (let* ((key (alonso--trust-class-key name input))
             (class (cdr (assoc name alonso--trust-class))))
        (and key (alonso--class-prefix-p name class key)))
      (let ((specific (cdr (assoc name alonso--trust-specific))))
        (and specific (equal specific (alonso--input-key input))))))

(defun alonso--trust-record (scope name input &optional risk)
  "Record a trust for tool NAME with INPUT in SCOPE ('specific/'class/'all).
RISK is the level the bridge reported, when known; it can only make a
`class' trust rarer (see `alonso--trust-class-key').  Returns non-nil when
a trust was actually recorded.  For `class' a non-nil class key is
required, otherwise nothing is recorded; `all' records the single tool
NAME (not every tool), so it needs a name."
  (pcase scope
    ('all
     (when (stringp name)
       (setq alonso--trust-tools (cons name alonso--trust-tools))
       (force-mode-line-update t)
       t))
    ('specific
     (setq alonso--trust-specific
           (cons (cons name (alonso--input-key input))
                 (cl-remove-if (lambda (p) (equal (car p) name))
                               alonso--trust-specific)))
     (force-mode-line-update t)
     t)
    ('class
     (let ((key (alonso--trust-class-key name input risk)))
       (when key
         (setq alonso--trust-class
               (cons (cons name key)
                     (cl-remove-if (lambda (p) (equal (car p) name))
                                   alonso--trust-class)))
         (force-mode-line-update t)
         t)))
    (_ nil)))

(defun alonso-trust-reset ()
  "Forget every tool trust granted in this session.
A trust silences the confirmation for the tools it covers (see
`alonso--trusted-p'), and one picked by accident would keep doing so for
the rest of the session — hence this way out, also reachable from the
mode-line (which names the active grants).  Returns the number of grants
forgotten."
  (interactive)
  (let ((n (+ (length alonso--trust-specific)
              (length alonso--trust-class)
              (length alonso--trust-tools)
              (if alonso--trust-all 1 0))))
    (setq alonso--trust-specific nil
          alonso--trust-class nil
          alonso--trust-tools nil
          alonso--trust-all nil)
    (force-mode-line-update t)
    (message "alonso: cleared %d trust grant(s)" n)
    n))

(provide 'alonso-client)

;;; alonso-client.el ends here
