;;; alonso-ui.el --- llm-bridge UI shell: buffers, modes, windows -*- lexical-binding: t; -*-

;;; Commentary:

;; The "UI shell" of the Emacs llm-bridge integration: everything that touches
;; buffers and windows but is not a self-contained renderer.  Concretely: the
;; conversation/input buffers and their minor modes and keymaps, the insertion
;; helpers every renderer builds on, the shared conversation state, the braille
;; spinner and mode-line fragments, the event render handlers (chunks,
;; thinking, turn summaries, errors, hooks), the `/project' command, the window
;; layout (open/restart/kill) and the `C-c a' prefix map.
;;
;; The three rendering/UX pieces live in sibling files that build on top of
;; this one:
;;
;;   alonso-markdown.el — Markdown rendering of the model's answer (faces,
;;     hidden markers, clickable links, code-block fontification).
;;   alonso-image.el    — pasting/attaching images to a prompt (multimodal).
;;   alonso-tools.el    — tool-call display, per-call confirmation and the
;;     trust-scope menus.
;;
;; Those files require this one and reach back only through its public
;; helpers; this file reaches their functions only at runtime (declared below),
;; never at load time.  It requires alonso-client.el and talks to it through
;; its public API.
;;
;; See alonso.el (the entry point) and alonso-client.el.

;;; Code:

(require 'cl-lib)
(require 'alonso-client)

;; Rendering/UX helpers defined in the sibling files, called at runtime.
(declare-function alonso--render-markdown-region "alonso-markdown" (start end))
(declare-function alonso--buffer-collect "alonso-image" ())
(declare-function alonso--buffer-collect-segments "alonso-image" ())
(declare-function alonso--image-string "alonso-image" (spec))
(declare-function alonso--yank-media-image "alonso-image" (type data))
(declare-function alonso-yank "alonso-image" ())
(declare-function alonso-attach-image-file "alonso-image" (file))
(declare-function alonso-attach-image-url "alonso-image" (url))
(declare-function alonso--cancel-confirm "alonso-tools" ())

;; Defcustoms owned by the sibling files but read/written here.
(defvar alonso-render-markdown-live)

;; `yank-media' (Emacs 29+) is autoloaded; declared so the compiler/loader
;; knows the symbols used by `alonso-yank' and the input-mode setup.
(declare-function yank-media "yank-media" ())
(declare-function yank-media-handler "yank-media" (types handler))

;;; Conversation/input buffers

(defcustom alonso-buffer-name "*llm-bridge*"
  "Name of the conversation buffer."
  :type 'string
  :group 'alonso)

(defcustom alonso-input-buffer-name "*llm-bridge-input*"
  "Name of the buffer where the user types prompts."
  :type 'string
  :group 'alonso)

(defcustom alonso-files-changed-hook nil
  "Hook run when the bridge emits a `files_changed' event.
The hook is called with a single argument: the list of files (strings,
relative paths as the model called them, sorted alphabetically and
deduplicated) that were changed (written) by the model in the turn that just
finished.  Add functions with `add-hook'."
  :type 'hook
  :group 'alonso)

;;; Faces

(defface alonso-user-face
  '((t (:inherit font-lock-keyword-face :bold t)))
  "Face for the user's prompts in the conversation buffer."
  :group 'alonso)

(defface alonso-hook-face
  '((t (:inherit font-lock-builtin-face :bold t)))
  "Face for local hook commands (a prompt starting with \"#\")."
  :group 'alonso)

(defface alonso-tool-face
  '((t (:inherit font-lock-builtin-face)))
  "Face for tool_call lines."
  :group 'alonso)

(defface alonso-search-face
  '((t (:foreground "red")))
  "Face for the `search' part of a `search_replace' tool call (diff `-')."
  :group 'alonso)

(defface alonso-replace-face
  '((t (:foreground "dark green")))
  "Face for the `replace' part of a `search_replace' tool call (diff `+')."
  :group 'alonso)

(defface alonso-error-face
  '((t (:inherit error)))
  "Face for error lines."
  :group 'alonso)

(defface alonso-command-face
  '((t (:inherit font-lock-string-face :bold t)))
  "Face for the command/pattern/path highlighted in a tool confirmation."
  :group 'alonso)

(defface alonso-separator-face
  '((t (:inherit shadow)))
  "Face for turn separators and metadata lines."
  :group 'alonso)

(defcustom alonso-show-thinking t
  "Whether to display the model's chain-of-thought (thinking events)."
  :type 'boolean
  :group 'alonso)

(defface alonso-thinking-face
  '((t (:inherit font-lock-comment-face :italic t)))
  "Face used to display the model's chain-of-thought."
  :group 'alonso)

;;; Conversation buffer state used by the render handlers

(defvar alonso--thinking-separator-pending nil
  "Non-nil when thinking was shown in the current turn and the two blank
lines separating it from the response have not been inserted yet.
Set by `alonso--on-thinking', consumed by the first `chunk'
and cleared at the start/end of every turn.")

(defvar alonso--tool-call-pos nil
  "Buffer position of the start of the visible line (title for read-only
tools, `Run tool: ...?' question for mutating ones) of the last tool call
shown.  Used as the scroll anchor while the tool's confirmation question is
being asked (`alonso--keep-question-visible'), so the beginning of a
possibly large diff stays visible, and as the spot where
`alonso--record-tool-confirmation' prepends the `[allowed]' /
`[denied]' tag.")

(defvar alonso--tool-confirm-pos nil
  "Buffer position just after the parameters of the last tool call shown,
kept as the lower scroll anchor while the confirmation is pending.")


;;; Answer segment (drives the Markdown renderer)

(defvar alonso--answer-start nil
  "Marker at the start of the answer segment still to be rendered, or nil.
Set on the first `chunk' of a segment by `alonso--answer-begin' and
cleared by `alonso--render-answer' once the segment is rendered.")

(defvar alonso--turn-answer-start nil
  "Marker at the start of the current turn's last answer segment, or nil.
Set by `alonso--prompt-send' just before the prompt is sent (as a fallback,
in case the turn produces no answer segment at all) and re-pointed by
`alonso--answer-begin' at the start of every new answer segment.  Used by
`alonso--show-answer-start' when the turn ends, to scroll the window back
to the beginning of the final answer taller than the window.")

(defun alonso--answer-begin ()
  "Start a new answer segment if one is not already open.
Also re-points `alonso--turn-answer-start' at this segment's start, so
that a turn whose output is split (answer, thinking, answer) marks its
*last* answer segment — the final answer — as the one to scroll back to
when the turn ends."
  (unless alonso--answer-start
    (with-current-buffer (alonso--get-buffer)
      (let ((pos (point-max)))
        (setq alonso--answer-start (copy-marker pos))
        (when (markerp alonso--turn-answer-start)
          (set-marker alonso--turn-answer-start nil))
        (setq alonso--turn-answer-start (copy-marker pos))))))

(defun alonso--render-answer ()
  "Render the Markdown of the current answer segment and close it.
No-op when no segment is open.  Called at every boundary where the model
stops writing (thinking, tool call, end of turn)."
  (when alonso--answer-start
    (let ((start (marker-position alonso--answer-start)))
      (set-marker alonso--answer-start nil)
      (setq alonso--answer-start nil)
      (when start
        (with-current-buffer (alonso--get-buffer)
          (let ((end (point-max)))
            (when (< start end)
              (alonso--render-markdown-region start end))))))))

(defun alonso--render-answer-live ()
  "Re-render the pending answer segment without closing it.
No-op when `alonso-render-markdown-live' is nil or no segment is
open.  Called after every `chunk' so the formatting appears while the model
is still writing.  Only complete constructs are rendered, so the answer is
never shown with a half-written marker hidden."
  (when (and alonso-render-markdown-live
             alonso--answer-start)
    (let ((start (marker-position alonso--answer-start)))
      (when start
        (with-current-buffer (alonso--get-buffer)
          (let ((end (point-max)))
            (when (< start end)
              (alonso--render-markdown-region start end))))))))

(defun alonso--show-answer-start ()
  "Leave the conversation window showing the start of the turn's answer.
Called when the turn ends: while streaming the window stays glued to the
end (`alonso--insert-propertized'), so the beginning of the answer ends up
scrolled out of view.  Scroll back to the beginning of the *last* answer
segment (see `alonso--turn-answer-start'), so that a turn split into
several segments leaves the final answer at the top rather than the first
one, and a short answer is shown from its start (with blank space below)
instead of glued to the bottom.  No-op when the buffer is not displayed or
when there is no answer segment to scroll to."
  (let* ((buf (alonso--get-buffer))
         (start alonso--turn-answer-start)
         (win (get-buffer-window buf t)))
    (when (and win (markerp start) (marker-position start))
      (with-current-buffer buf
        (let ((beg (marker-position start)))
          (when (< beg (point-max))
            (set-window-start win beg)
            (set-window-point win beg)))))))

;;; Braille spinner animation during thinking

(defvar alonso--spinner-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames for the braille spinner during thinking.")

(defvar alonso--spinner-index 0
  "Current frame index of the braille spinner.")

(defvar alonso--spinner-timer nil
  "Timer running the braille spinner animation.")

(defvar alonso--spinner-interval 0.1
  "Interval in seconds between spinner frame updates (animation speed).")

(defvar alonso--spinner-active nil
  "Non-nil while the turn spinner is active (from prompt to turn end).")

(defun alonso--spinner-tick ()
  "Advance the spinner frame and update the mode-line."
  (setq alonso--spinner-index
        (mod (1+ alonso--spinner-index)
             (length alonso--spinner-frames)))
  (force-mode-line-update t))

(defun alonso--start-spinner ()
  "Start the braille spinner timer if not already running.
Keeps the animation frame when the timer is already running, so streaming
chunks do not restart the spinner from the beginning."
  (setq alonso--spinner-active t)
  (unless (timerp alonso--spinner-timer)
    (setq alonso--spinner-index 0)
    (setq alonso--spinner-timer
          (run-with-timer alonso--spinner-interval
                          alonso--spinner-interval
                          #'alonso--spinner-tick))))

(defun alonso--stop-spinner ()
  "Stop the braille spinner timer and clear the active state."
  (setq alonso--spinner-active nil)
  (when (timerp alonso--spinner-timer)
    (cancel-timer alonso--spinner-timer)
    (setq alonso--spinner-timer nil))
  (force-mode-line-update t))

(defun alonso--mode-line-status ()
  "Return the mode-line status fragment for the conversation buffer.
Shows the braille spinner while a turn is in flight (from prompt to
turn_end/error/cancelled), or `[llm-bridge…]' during a turn with no spinner."
  (cond
   (alonso--spinner-active
    (format " [%s]" (aref alonso--spinner-frames
                          alonso--spinner-index)))
   (alonso-in-turn
    " [llm-bridge…]")
   (t "")))

;;; Event render handlers (dispatched by the client's `--handle-line')

(defun alonso--on-chunk (text)
  "Handle a `chunk' event with TEXT (streaming fragment)."
  (when alonso--after-tool-separator-pending
    ;; The tool output finished and the model resumed: separate it with
    ;; two blank lines (three newlines), only on the first transition.
    (setq alonso--after-tool-separator-pending nil)
    (alonso--insert "\n\n\n"))
  (when alonso--thinking-separator-pending
    ;; The thinking finished and the answer started: separate it with two
    ;; blank lines (three newlines), only on the first transition.
    (setq alonso--thinking-separator-pending nil)
    (alonso--insert "\n\n\n"))
  (alonso--answer-begin)
  (alonso--insert text)
  (alonso--render-answer-live))

(defun alonso--on-thinking (text)
  "Handle a `thinking' event with TEXT (chain-of-thought fragment)."
  (alonso--render-answer)
  (alonso--start-spinner)
  (when alonso-show-thinking
    (when alonso--after-tool-separator-pending
      ;; The tool output finished and the model started thinking: separate
      ;; it with two blank lines, only on the first transition.
      (setq alonso--after-tool-separator-pending nil)
      (alonso--insert "\n\n\n"))
    (setq alonso--thinking-separator-pending t)
    (alonso--insert-propertized
     text 'face 'alonso-thinking-face)))

(defun alonso--on-turn-end (ev)
  "Handle a `turn_end' event EV: finalize turn tokens, accumulate session
usage and show a per-turn summary with the model."
  (alonso--render-answer)
  (alonso--stop-spinner)
  (setq alonso-in-turn nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil
        alonso--turn-finalized t)
  (let ((input (gethash "input_tokens" ev 0))
        (output (gethash "output_tokens" ev 0))
        (cache-hit (gethash "cache_hit_tokens" ev 0))
        (cache-miss (gethash "cache_miss_tokens" ev 0))
        (model (gethash "model" ev)))
    (let ((inc-in (- input alonso--current-turn-input-tokens))
          (inc-out (- output alonso--current-turn-output-tokens)))
      (setq alonso-session-input-tokens
            (+ alonso-session-input-tokens (max 0 inc-in))
            alonso-session-output-tokens
            (+ alonso-session-output-tokens (max 0 inc-out))
            alonso-session-cache-hit-tokens
            (+ alonso-session-cache-hit-tokens (max 0 cache-hit))
            alonso-session-cache-miss-tokens
            (+ alonso-session-cache-miss-tokens (max 0 cache-miss))
            alonso--current-turn-input-tokens 0
            alonso--current-turn-output-tokens 0))
    (when model
      (setq alonso-session-model model))
    (alonso--insert-propertized
     (format "\n[stop_reason=%s model=%s | turn: sent %d, received %d, cache %d/%d | session: sent %d, received %d, cache %d/%d]\n"
             (gethash "stop_reason" ev)
             (or model "?")
             input output cache-hit cache-miss
             alonso-session-input-tokens
             alonso-session-output-tokens
             alonso-session-cache-hit-tokens
             alonso-session-cache-miss-tokens)
     'face 'alonso-separator-face))
  (force-mode-line-update t)
  (alonso--show-answer-start))

(defun alonso--on-usage-delta (ev)
  "Handle a `usage_delta' event EV: update turn and session token usage."
  (unless alonso--turn-finalized
    (let ((input (gethash "input_tokens" ev 0))
          (output (gethash "output_tokens" ev 0)))
      (let ((inc-in (- input alonso--current-turn-input-tokens))
            (inc-out (- output alonso--current-turn-output-tokens)))
        (when (> inc-in 0)
          (setq alonso-session-input-tokens (+ alonso-session-input-tokens inc-in)
                alonso--current-turn-input-tokens input))
        (when (> inc-out 0)
          (setq alonso-session-output-tokens (+ alonso-session-output-tokens inc-out)
                alonso--current-turn-output-tokens output)))
      (force-mode-line-update t))))

(defun alonso--on-error (msg)
  "Handle an `error' event with MSG."
  (alonso--render-answer)
  (alonso--stop-spinner)
  (setq alonso-in-turn nil
        alonso-pending-tools nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil)
  (alonso--cancel-confirm)
  (alonso--insert-propertized
   (format "\n[error] %s\n" msg)
   'face 'alonso-error-face))

(defun alonso--on-files-changed (ev)
  "Handle a `files_changed' event EV.
Runs `alonso-files-changed-hook' with the list of files changed by
the model in the turn that just finished (the `files' field of EV)."
  (let ((changed (gethash "files" ev)))
    (when changed
      (run-hook-with-args 'alonso-files-changed-hook changed))))

(defun alonso--on-cancelled ()
  "Handle a `cancelled' event."
  (alonso--render-answer)
  (alonso--stop-spinner)
  (setq alonso-in-turn nil
        alonso-pending-tools nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil)
  (alonso--cancel-confirm)
  (alonso--insert-propertized
   "\n[cancelled]\n"
   'face 'alonso-separator-face))

(defun alonso--on-hook-action (ev)
  "Handle a `hook_action' event EV: show a local hook's result.
A hook (a prompt starting with \"#\") runs a local script instead of calling
the LLM; the bridge replies with a single `hook_action' event and NO
`turn_end', so this handler also finalizes the client-side \"turn\" state
(stopping the spinner, clearing `alonso-in-turn' and the separator
flags).  There is no token/model accounting here because there is no
`turn_end'.  When EV carries an `error' field (script missing, invalid name
or non-zero exit) the message is shown in the error face; otherwise the
script's combined output is inserted as plain text."
  (alonso--render-answer)
  (alonso--stop-spinner)
  (setq alonso-in-turn nil
        alonso-pending-tools nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil
        alonso--turn-finalized t)
  (alonso--cancel-confirm)
  (let ((name (gethash "name" ev))
        (output (gethash "output" ev))
        (err (gethash "error" ev)))
    (if err
        (alonso--insert-propertized
         (format "\n[hook %s] error: %s\n" name err)
         'face 'alonso-error-face)
      (alonso--insert-propertized
       (concat "\n" (or output "") "\n"))))
  (force-mode-line-update t))

;;; Step 5 — Conversation buffer and input buffer

(defvar alonso-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a q") #'alonso-quit)
    (define-key map (kbd "C-c a k") #'alonso-kill)
    map)
  "Keymap for `alonso-mode'.")

(define-minor-mode alonso-mode
  "Minor mode for the llm-bridge conversation buffer."
  :lighter " LB")

(defun alonso--get-buffer ()
  "Return the conversation buffer, creating it if needed."
  (let ((buf (get-buffer-create alonso-buffer-name)))
    (with-current-buffer buf
      (unless buffer-read-only
        (setq buffer-read-only t))
      (unless alonso-mode
        (alonso-mode 1))
      (unless (cl-member '(:eval (alonso--mode-line-status))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (alonso--mode-line-status))))))
      ;; Hide the position (line/column/%) — the buffer is a chat log whose
      ;; size changes at every chunk, so the position counter would flicker
      ;; frantically during streaming and make the mode-line (and the
      ;; spinner) look unstable.
      (setq-local mode-line-position nil))
    buf))

(defun alonso--insert-propertized (text &rest props)
  "Insert TEXT at the end of the conversation buffer with PROPS (plist).
The displayed window follows along when it was already showing the end.
Return the buffer position where TEXT was inserted (start of TEXT)."
  (let ((buf (alonso--get-buffer)))
    (with-current-buffer buf
      (let* ((win (get-buffer-window buf t))
             (at-bottom (or (null win)
                            (>= (window-point win) (1- (point-max)))))
             (inhibit-read-only t)
             (start (point-max)))
        (goto-char (point-max))
        (insert (if props (apply #'propertize text props) text))
        (goto-char (point-max))
        (when (and win at-bottom)
          (set-window-point win (point-max)))
        start))))

(defun alonso--insert (text)
  "Insert TEXT at the end of the conversation buffer."
  (alonso--insert-propertized text))

(defun alonso--insert-propertized-at (pos text &rest props)
  "Insert TEXT at buffer position POS (or at the end if POS is nil) with PROPS.
Return the buffer position where TEXT was inserted (start of TEXT)."
  (let ((buf (alonso--get-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (target (or pos (point-max))))
        (goto-char target)
        (insert (if props (apply #'propertize text props) text))
        target))))

(defun alonso--prompt-send (text &optional images segments)
  "Core routine: echo TEXT in the conversation and send it as a prompt.
IMAGES, when non-nil, is a list of image specs collected from the input
buffer (see `alonso--buffer-collect'); they are echoed inline and attached
to the prompt as the `images' array.  SEGMENTS, when non-nil, is the ordered
list of (KIND . VALUE) segments from `alonso--buffer-collect-segments' and
is used to echo the images interleaved with the text the way the user typed
them (an image above a caption stays above it, and vice versa).  A message
whose trimmed text starts with \"#\" is sent as a local hook instead (images
are then ignored, as a hook is not an LLM call).  Rejects a new prompt while
a turn is in progress."
  (alonso--ensure-ready)
  (when (or alonso-in-turn alonso-pending-tools)
    (error "There is a turn in progress; wait for it to finish"))
  (if (string-prefix-p "#" (string-trim-left text))
      (alonso--hook-send text)
    (let ((text (if (and images (string-empty-p (string-trim text)))
                    "(imagem)" text)))
      (alonso--render-answer)
      (setq alonso-in-turn t
            alonso--thinking-separator-pending nil
            alonso--after-tool-separator-pending nil
            alonso--current-turn-input-tokens 0
            alonso--current-turn-output-tokens 0
            alonso--turn-finalized nil)
      (alonso--start-spinner)
      (alonso--insert-propertized
       "\n──────────────────────────────\n"
       'face 'alonso-separator-face)
      (alonso--insert-propertized
       (concat ">>> " (alonso--prompt-echo-body text images segments) "\n")
       'face 'alonso-user-face)
      (alonso--insert "\n")
      (when (markerp alonso--turn-answer-start)
        (set-marker alonso--turn-answer-start nil))
      (setq alonso--turn-answer-start
            (with-current-buffer (alonso--get-buffer)
              (copy-marker (point-max))))
      (alonso--send "prompt" (alonso--prompt-params text images)))))

(defun alonso--prompt-echo-body (text images segments)
  "Return the echoing body (after the \">>> \") for a prompt.
TEXT is the raw prompt text and IMAGES its image specs.  SEGMENTS, when
non-nil, is the ordered list of (KIND . VALUE) segments typed in the input
buffer; the images are placed where the user put them and each text block is
trimmed for display.  When SEGMENTS is nil the images are appended after the
text (used by direct callers such as the slash-command prompt echo).  A
`[🖼 N]' badge and the per-request annotation trail the first line."
  (let ((suffix (concat (if images (format "  [🖼 %d]" (length images)) "")
                        (alonso--request-annotation)))
        (chunks
         (if segments
             (delq nil
                   (mapcar (lambda (seg)
                             (let ((chunk (if (eq (car seg) 'image)
                                              (alonso--image-string (cdr seg))
                                            (string-trim (cdr seg)))))
                               (unless (string-empty-p chunk) chunk)))
                           segments))
           (list (string-trim text)))))
    (when (null chunks)
      (setq chunks (list (if images "(imagem)" (string-trim text)))))
    (concat (car chunks) suffix
            (mapconcat (lambda (c) (concat "\n" c)) (cdr chunks) ""))))

(defun alonso--hook-send (text)
  "Echo TEXT (a local hook command) and send it to the bridge as a prompt.
TEXT must start with \"#\" (the caller, `alonso--prompt-send', has
already checked it and applied the shared turn-in-progress guard).  The
bridge runs the local script instead of calling the LLM and replies
asynchronously with a single `hook_action' event and no `turn_end'; the
client-side turn state is still marked in progress here and closed by
`alonso--on-hook-action'."
  (alonso--render-answer)
  (setq alonso-in-turn t
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil
        alonso--current-turn-input-tokens 0
        alonso--current-turn-output-tokens 0
        alonso--turn-finalized nil)
  (alonso--start-spinner)
  (alonso--insert-propertized
   "\n──────────────────────────────\n"
   'face 'alonso-separator-face)
  (alonso--insert-propertized
   (format ">>> %s\n\n" text)
   'face 'alonso-hook-face)
  (alonso--send "prompt" (alonso--prompt-params text)))

(defcustom alonso-project-dir nil
  "Base directory under which the `/project' command resolves its argument.

When non-nil (e.g. \"~/mysrc/\") the `/project' argument is taken as a
project NAME and resolved to BASE/NAME, so `/project tupi' means
`~/mysrc/tupi/'.  When nil (the default) the argument is taken as a PATH and
expanded with `expand-file-name' — an absolute path, a `~' path or a path
relative to `default-directory' all work."
  :type '(choice (const :tag "Argument is a path" nil)
                 (directory :tag "Base directory for project names"))
  :group 'alonso)

(defcustom alonso-project-change-hook nil
  "Hook run after the `/project' command switches the working directory.
The hook is called with a single argument: the new project directory.  Use
it to react to a project change (e.g. reload project-specific commands or
keybindings); the package itself knows nothing about projects."
  :type 'hook
  :group 'alonso)

(defun alonso--apply-project-dir-locals (dir)
  "Set `default-directory' of the current buffer to DIR and load its
.dir-locals.el, respecting `safe-local-variable-values'.

Uses `hack-dir-local-variables-non-file-buffer' so that only variables
present in `safe-local-variable-values' are applied silently; unsafe ones
prompt the user.  The `hack-local-variables-hook' runs afterwards, so any
hook it triggers (e.g. project keybindings) fires as usual."
  (setq default-directory (file-name-as-directory dir))
  (when (file-exists-p (expand-file-name ".dir-locals.el" dir))
    (hack-dir-local-variables-non-file-buffer)))

(defun alonso--handle-slash-command (text)
  "Check if TEXT is a slash command (e.g. /project <name>), execute it and return non-nil if handled.

The `/project' argument is resolved against `alonso-project-dir': when that
variable is non-nil the argument is a project NAME (resolved as BASE/NAME),
otherwise it is a PATH expanded with `expand-file-name'.  After switching the
new directory is passed to `alonso-project-change-hook'."
  (cond
   ((string-match "^/project[[:space:]]+\\(.+\\)$" text)
    (let* ((arg (string-trim (match-string 1 text)))
           (base (and alonso-project-dir
                      (file-name-as-directory
                       (expand-file-name alonso-project-dir))))
           (dir (expand-file-name arg base)))
      (if (not (file-directory-p dir))
          (error "Project directory does not exist: %s" dir)
        (alonso--apply-project-dir-locals dir)
        (with-current-buffer (alonso--request-buffer)
          (alonso--apply-project-dir-locals dir))
        (with-current-buffer (alonso--get-buffer)
          (alonso--apply-project-dir-locals dir))
        (alonso--send "set_cwd" (list "cwd" dir))
        (run-hook-with-args 'alonso-project-change-hook dir)
        (dolist (buf (list (get-buffer "*GNU Emacs*") (get-buffer "*scratch*")))
          (when buf
            (with-current-buffer buf
              (alonso--apply-project-dir-locals dir))))
        (alonso--insert-propertized
         (format "\n[project set to %s]\n" dir)
         'face 'alonso-separator-face)
        (message "Project set to %s" dir))
      t))
   (t nil)))

(defun alonso-send-input ()
  "Send the current input buffer contents to the bridge and clear it.
Images pasted/attached in the buffer are collected as attachments (see
`alonso--buffer-collect') and sent with the prompt; a slash command never
carries images."
  (interactive)
  (let* ((segments (alonso--buffer-collect-segments))
         (collected (alonso--buffer-collect))
         (text (car collected))
         (images (cdr collected))
         (has-text (string-match-p "[^[:space:]]" text)))
    (when (or has-text images)
      (unless (and has-text (alonso--handle-slash-command text))
        (alonso--prompt-send text images segments))
      (erase-buffer))))

(define-minor-mode alonso-input-mode
  "Minor mode for typing input destined to the llm-bridge.
C-c C-c sends the whole buffer; RET inserts a newline.  C-y yanks an image
from the clipboard when there is one (see `alonso-yank')."
  :lighter " LBIn"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'alonso-send-input)
            (define-key map (kbd "C-y") #'alonso-yank)
            (define-key map (kbd "RET") #'newline)
            (define-key map (kbd "C-j") #'newline)
            map)
  (when alonso-input-mode
    ;; Let `yank-media' (and `alonso-yank', via it) insert clipboard
    ;; images inline in this buffer.
    (yank-media-handler "image/.*" #'alonso--yank-media-image)))

(defun alonso--mode-line-session ()
  "Return the mode-line fragment with the session token usage and model.
Shows tokens sent (↑, input), tokens received (↓, output), the prompt-cache
hit/miss totals (⚡, shown only when the provider reports any) and the model
of the current session, e.g. \" [↑12 ↓8 ⚡900/124 deepseek-chat]\"."
  (let* ((hit alonso-session-cache-hit-tokens)
         (miss alonso-session-cache-miss-tokens)
         (cache (if (> (+ hit miss) 0) (format "⚡%d/%d " hit miss) ""))
         (s (format " [↑%d ↓%d %s%s]"
                    alonso-session-input-tokens
                    alonso-session-output-tokens
                    cache
                    (or alonso-session-model "?"))))
    (propertize s 'help-echo
                "↑ tokens sent · ↓ tokens received · ⚡ prompt-cache hit/miss · session model")))

(defun alonso--mode-line-request ()
  "Return the mode-line fragment describing the per-request overrides.
Shows the model, thinking and effort overrides set for the next prompt,
e.g. \" [model=deepseek-reasoner thinking=on effort=high]\".  Empty when no
override is set."
  (let ((ann (alonso--request-annotation)))
    (if (string-empty-p ann)
        ""
      (propertize ann 'help-echo "Per-request overrides (C-c a m / t / e)"))))

(defun alonso--setup-input-mode-line ()
  "Install the session and request indicators in the input buffer's
mode-line (idempotent).  Creates the input buffer if it does not exist yet
(on a fresh open)."
  (let ((buf (or (get-buffer alonso-input-buffer-name)
                 (get-buffer-create alonso-input-buffer-name))))
    (with-current-buffer buf
      (unless (cl-member '(:eval (alonso--mode-line-session))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (alonso--mode-line-session))))))
      (unless (cl-member '(:eval (alonso--mode-line-request))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (alonso--mode-line-request)))))))))

;;;###autoload
(defun alonso-open ()
  "Start the bridge and set up the llm-bridge window layout.
Divides the selected window in two: the left side keeps the buffer that
was already open and the right side shows the llm-bridge (conversation
on top, input buffer below, ~20% of the frame height)."
  (interactive)
  (alonso--ensure-ready)
  (alonso--setup-input-mode-line)
  (let ((conv (alonso--get-buffer))
        (in (get-buffer-create alonso-input-buffer-name)))
    (if (get-buffer-window conv)
        ;; Already open: focus the conversation and ensure the input below it.
        (progn
          (select-window (get-buffer-window conv))
          (unless (get-buffer-window alonso-input-buffer-name)
            (split-window-below)
            (other-window 1)
            (switch-to-buffer in)
            (alonso-input-mode 1)))
      ;; Split the current window in two: left = already-open buffer,
      ;; right = conversation (top) + input (bottom).
      (split-window-right)
      (other-window 1)                    ; right window
      (switch-to-buffer conv)
      (split-window-below)
      (other-window 1)                    ; bottom window of the right side
      (switch-to-buffer in)
      (alonso-input-mode 1))
    ;; Adjust the bottom window (input) to ~20% of the total frame height
    (let* ((input-window (get-buffer-window alonso-input-buffer-name))
           (frame-height (window-total-height (frame-root-window)))
           (target-height (max 1 (round (* frame-height 0.2))))
           (delta (- target-height (window-total-height input-window))))
      (when input-window
        (window-resize input-window delta nil t)))))

;;; Step 4 — User commands (basic interaction)

;;;###autoload
(defun alonso-prompt (text)
  "Send TEXT as a prompt to the bridge."
  (interactive "sPrompt: ")
  (alonso--prompt-send text))

;;;###autoload
(defun alonso-cancel ()
  "Cancel the current in-flight turn and stop any running tool command."
  (interactive)
  ;; Stop any asynchronous tool command (shell/grep) still running: otherwise
  ;; it would keep running after the turn is cancelled and send a late
  ;; tool_result the bridge no longer expects.
  (dolist (p alonso--tool-procs)
    (when (process-live-p p)
      (delete-process p)))
  (setq alonso--tool-procs nil)
  (when (and alonso-process (process-live-p alonso-process))
    (alonso--send "cancel")))

;;;###autoload
(defun alonso-set-cwd (dir)
  "Set the bridge working directory to DIR."
  (interactive "DWorking dir: ")
  (alonso--send "set_cwd" (list "cwd" (expand-file-name dir))))

;;;###autoload
(defun alonso-set-provider (provider)
  "Set the provider override for the next prompt (empty = default).
The override is sent as the `provider' field of the next `prompt'."
  (interactive
   (list (completing-read
          "Provider for the next prompt (empty = default): "
          '("deepseek" "google") nil t)))
  (with-current-buffer (alonso--request-buffer)
    (setq-local alonso-request-provider provider))
  (force-mode-line-update t)
  (message "Provider for the next prompt: %s"
           (if (string-empty-p provider) "(default)" provider)))

;;;###autoload
(defun alonso-set-model (model)
  "Set the model override for the next prompt (empty = provider default).
The override is sent as the `model' field of the next `prompt' and stays
active for the following prompts until changed (mirrors the bridge)."
  (interactive "sModel for the next prompt (empty = provider default): ")
  (with-current-buffer (alonso--request-buffer)
    (setq-local alonso-request-model model))
  (force-mode-line-update t)
  (message "Model for the next prompt: %s"
           (if (string-empty-p model) "(provider default)" model)))

;;;###autoload
(defun alonso-set-thinking (thinking)
  "Set the thinking override for the next prompt: on, off or unset.
`on' forces thinking (deepseek-reasoner), `off' forces it off
(deepseek-chat) and `unset' restores the provider's configured mode."
  (interactive
   (list (intern (completing-read
                  "Thinking for the next prompt (unset/on/off): "
                  '("unset" "on" "off") nil t))))
  (with-current-buffer (alonso--request-buffer)
    (setq-local alonso-request-thinking thinking))
  (force-mode-line-update t)
  (message "Thinking for the next prompt: %s"
           (pcase thinking
             ('t "on")
             ('off "off")
             (_ "unset (provider default)"))))

;;;###autoload
(defun alonso-set-reasoning-effort (effort)
  "Set the thinking depth (reasoning_effort) for the next prompt.
One of \"low\", \"medium\" or \"high\"; empty = provider default."
  (interactive
   (list (completing-read
          "Reasoning effort for the next prompt (empty = default): "
          '("low" "medium" "high") nil t)))
  (with-current-buffer (alonso--request-buffer)
    (setq-local alonso-request-reasoning-effort effort))
  (force-mode-line-update t)
  (message "Reasoning effort for the next prompt: %s"
           (if (string-empty-p effort) "(provider default)" effort)))

(defun alonso-set-knowledge-bases (bases)
  "Set the bridge knowledge BASES (list of hash tables)."
  (alonso--send "set_knowledge_bases" (list "bases" bases)))

;;;###autoload
(defun alonso-quit ()
  "Send `quit' to the bridge, ending the process."
  (interactive)
  (when (and alonso-process (process-live-p alonso-process))
    (alonso--send "quit")))

;;; Step 10 — Shutdown and robustness

;;;###autoload
(defun alonso-kill ()
  "Terminate the bridge, kill any running tool processes and clean state."
  (interactive)
  (alonso--cancel-confirm)
  (when (and alonso-process (process-live-p alonso-process))
    (alonso--send "quit")
    (sleep-for 0.1)
    ;; the sentinel may have already cleared the process; only delete if alive
    (when (and alonso-process (process-live-p alonso-process))
      (delete-process alonso-process)))
  (dolist (p alonso--tool-procs)
    (when (process-live-p p)
      (delete-process p)))
  (setq alonso--tool-procs nil)
  (setq alonso-process nil
        alonso-ready nil
        alonso-in-turn nil
        alonso-pending-tools nil
        alonso-line-buffer ""
        alonso--after-tool-separator-pending nil)
  ;; Detach the pending-answer marker: the buffers may be erased next
  ;; (`--restart'), and a stale marker would then re-render from position 1.
  (when (markerp alonso--answer-start)
    (set-marker alonso--answer-start nil))
  (setq alonso--answer-start nil)
  (when (markerp alonso--turn-answer-start)
    (set-marker alonso--turn-answer-start nil))
  (setq alonso--turn-answer-start nil)
  (alonso--reset-session))

(add-hook 'kill-emacs-hook #'alonso-kill)

;;; Step 11 — Prefix keymap and interactive commands

;;;###autoload
(defun alonso-restart ()
  "Restart the bridge: kill it, clear the buffers and reset the state.
Then reopen the llm-bridge window layout."
  (interactive)
  (alonso-kill)
  (dolist (b (list (get-buffer alonso-buffer-name)
                   (get-buffer alonso-input-buffer-name)))
    (when b
      (with-current-buffer b
        (let ((inhibit-read-only t))
          (erase-buffer)))))
  (alonso-open))

(defvar alonso-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "l") #'alonso-open)
    (define-key map (kbd "o") #'alonso-open)
    (define-key map (kbd "r") #'alonso-restart)
    (define-key map (kbd "k") #'alonso-kill)
    (define-key map (kbd "c") #'alonso-cancel)
    (define-key map (kbd "q") #'alonso-quit)
    (define-key map (kbd "p") #'alonso-set-provider)
    (define-key map (kbd "m") #'alonso-set-model)
    (define-key map (kbd "t") #'alonso-set-thinking)
    (define-key map (kbd "e") #'alonso-set-reasoning-effort)
    (define-key map (kbd "i") #'alonso-attach-image-file)
    (define-key map (kbd "u") #'alonso-attach-image-url)
    map)
  "Keymap for the `C-c a' prefix of the llm-bridge commands.")

;;;###autoload
(global-set-key (kbd "C-c a") alonso-prefix-map)

(provide 'alonso-ui)

;;; alonso-ui.el ends here
