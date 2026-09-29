;;; tagarela-ui.el --- llm-bridge UI shell: buffers, modes, windows -*- lexical-binding: t; -*-

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
;;   tagarela-markdown.el — Markdown rendering of the model's answer (faces,
;;     hidden markers, clickable links, code-block fontification).
;;   tagarela-image.el    — pasting/attaching images to a prompt (multimodal).
;;   tagarela-tools.el    — tool-call display, per-call confirmation and the
;;     trust-scope menus.
;;
;; Those files require this one and reach back only through its public
;; helpers; this file reaches their functions only at runtime (declared below),
;; never at load time.  It requires tagarela-client.el and talks to it through
;; its public API.
;;
;; See tagarela.el (the entry point) and tagarela-client.el.

;;; Code:

(require 'cl-lib)
(require 'tagarela-client)

;; Rendering/UX helpers defined in the sibling files, called at runtime.
(declare-function tagarela--render-markdown-region "tagarela-markdown" (start end))
(declare-function tagarela--buffer-collect "tagarela-image" ())
(declare-function tagarela--buffer-collect-segments "tagarela-image" ())
(declare-function tagarela--image-string "tagarela-image" (spec))
(declare-function tagarela--yank-media-image "tagarela-image" (type data))
(declare-function tagarela-yank "tagarela-image" ())
(declare-function tagarela-attach-image-file "tagarela-image" (file))
(declare-function tagarela-attach-image-url "tagarela-image" (url))
(declare-function tagarela--cancel-confirm "tagarela-tools" ())

;; Defcustoms owned by the sibling files but read/written here.
(defvar tagarela-render-markdown-live)

;; `yank-media' (Emacs 29+) is autoloaded; declared so the compiler/loader
;; knows the symbols used by `tagarela-yank' and the input-mode setup.
(declare-function yank-media "yank-media" ())
(declare-function yank-media-handler "yank-media" (types handler))

;;; Conversation/input buffers

(defcustom tagarela-buffer-name "*llm-bridge*"
  "Name of the conversation buffer."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-input-buffer-name "*llm-bridge-input*"
  "Name of the buffer where the user types prompts."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-files-changed-hook nil
  "Hook run when the bridge emits a `files_changed' event.
The hook is called with a single argument: the list of files (strings,
relative paths as the model called them, sorted alphabetically and
deduplicated) that were changed (written) by the model in the turn that just
finished.  Add functions with `add-hook'."
  :type 'hook
  :group 'tagarela)

;;; Faces

(defface tagarela-user-face
  '((t (:inherit font-lock-keyword-face :bold t)))
  "Face for the user's prompts in the conversation buffer."
  :group 'tagarela)

(defface tagarela-hook-face
  '((t (:inherit font-lock-builtin-face :bold t)))
  "Face for local hook commands (a prompt starting with \"#\")."
  :group 'tagarela)

(defface tagarela-tool-face
  '((t (:inherit font-lock-builtin-face)))
  "Face for tool_call lines."
  :group 'tagarela)

(defface tagarela-search-face
  '((t (:foreground "red")))
  "Face for the `search' part of a `search_replace' tool call (diff `-')."
  :group 'tagarela)

(defface tagarela-replace-face
  '((t (:foreground "dark green")))
  "Face for the `replace' part of a `search_replace' tool call (diff `+')."
  :group 'tagarela)

(defface tagarela-error-face
  '((t (:inherit error)))
  "Face for error lines."
  :group 'tagarela)

(defface tagarela-command-face
  '((t (:inherit font-lock-string-face :bold t)))
  "Face for the command/pattern/path highlighted in a tool confirmation."
  :group 'tagarela)

(defface tagarela-separator-face
  '((t (:inherit shadow)))
  "Face for turn separators and metadata lines."
  :group 'tagarela)

(defcustom tagarela-show-thinking t
  "Whether to display the model's chain-of-thought (thinking events)."
  :type 'boolean
  :group 'tagarela)

(defface tagarela-thinking-face
  '((t (:inherit font-lock-comment-face :italic t)))
  "Face used to display the model's chain-of-thought."
  :group 'tagarela)

;;; Conversation buffer state used by the render handlers

(defvar tagarela--thinking-separator-pending nil
  "Non-nil when thinking was shown in the current turn and the two blank
lines separating it from the response have not been inserted yet.
Set by `tagarela--on-thinking', consumed by the first `chunk'
and cleared at the start/end of every turn.")

(defvar tagarela--tool-call-pos nil
  "Buffer position of the start of the visible line (title for read-only
tools, `Run tool: ...?' question for mutating ones) of the last tool call
shown.  Used as the scroll anchor while the tool's confirmation question is
being asked (`tagarela--keep-question-visible'), so the beginning of a
possibly large diff stays visible, and as the spot where
`tagarela--record-tool-confirmation' prepends the `[allowed]' /
`[denied]' tag.")

(defvar tagarela--tool-confirm-pos nil
  "Buffer position just after the parameters of the last tool call shown,
kept as the lower scroll anchor while the confirmation is pending.")


;;; Answer segment (drives the Markdown renderer)

(defvar tagarela--answer-start nil
  "Marker at the start of the answer segment still to be rendered, or nil.
Set on the first `chunk' of a segment by `tagarela--answer-begin' and
cleared by `tagarela--render-answer' once the segment is rendered.")

(defvar tagarela--turn-answer-start nil
  "Marker at the start of the current turn's model output, or nil.
Set by `tagarela--prompt-send' just before the prompt is sent and used by
`tagarela--show-answer-start' when the turn ends, to scroll the window back
to the beginning of an answer taller than the window.")

(defun tagarela--answer-begin ()
  "Start a new answer segment if one is not already open."
  (unless tagarela--answer-start
    (setq tagarela--answer-start
          (with-current-buffer (tagarela--get-buffer)
            (copy-marker (point-max))))))

(defun tagarela--render-answer ()
  "Render the Markdown of the current answer segment and close it.
No-op when no segment is open.  Called at every boundary where the model
stops writing (thinking, tool call, end of turn)."
  (when tagarela--answer-start
    (let ((start (marker-position tagarela--answer-start)))
      (set-marker tagarela--answer-start nil)
      (setq tagarela--answer-start nil)
      (when start
        (with-current-buffer (tagarela--get-buffer)
          (let ((end (point-max)))
            (when (< start end)
              (tagarela--render-markdown-region start end))))))))

(defun tagarela--render-answer-live ()
  "Re-render the pending answer segment without closing it.
No-op when `tagarela-render-markdown-live' is nil or no segment is
open.  Called after every `chunk' so the formatting appears while the model
is still writing.  Only complete constructs are rendered, so the answer is
never shown with a half-written marker hidden."
  (when (and tagarela-render-markdown-live
             tagarela--answer-start)
    (let ((start (marker-position tagarela--answer-start)))
      (when start
        (with-current-buffer (tagarela--get-buffer)
          (let ((end (point-max)))
            (when (< start end)
              (tagarela--render-markdown-region start end))))))))

(defun tagarela--show-answer-start ()
  "Leave the conversation window showing the start of the turn's answer.
Called when the turn ends: while streaming the window stays glued to the
end (`tagarela--insert-propertized'), so for an answer taller than the
window the beginning ends up scrolled out of view.  Scroll back to the
beginning of the answer so the user sees where it started and can scroll
down at will.  No-op when the answer fits in the window (the end is then
already visible, i.e. the whole answer is on screen) or when the buffer is
not displayed."
  (let* ((buf (tagarela--get-buffer))
         (start tagarela--turn-answer-start)
         (win (get-buffer-window buf t)))
    (when (and win (markerp start) (marker-position start))
      (with-current-buffer buf
        (let ((beg (marker-position start))
              (end (point-max)))
          (when (> (count-screen-lines beg end nil win)
                   (window-body-height win))
            (set-window-start win beg)
            (set-window-point win beg)))))))

;;; Braille spinner animation during thinking

(defvar tagarela--spinner-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames for the braille spinner during thinking.")

(defvar tagarela--spinner-index 0
  "Current frame index of the braille spinner.")

(defvar tagarela--spinner-timer nil
  "Timer running the braille spinner animation.")

(defvar tagarela--spinner-interval 0.1
  "Interval in seconds between spinner frame updates (animation speed).")

(defvar tagarela--spinner-active nil
  "Non-nil while the turn spinner is active (from prompt to turn end).")

(defun tagarela--spinner-tick ()
  "Advance the spinner frame and update the mode-line."
  (setq tagarela--spinner-index
        (mod (1+ tagarela--spinner-index)
             (length tagarela--spinner-frames)))
  (force-mode-line-update t))

(defun tagarela--start-spinner ()
  "Start the braille spinner timer if not already running.
Keeps the animation frame when the timer is already running, so streaming
chunks do not restart the spinner from the beginning."
  (setq tagarela--spinner-active t)
  (unless (timerp tagarela--spinner-timer)
    (setq tagarela--spinner-index 0)
    (setq tagarela--spinner-timer
          (run-with-timer tagarela--spinner-interval
                          tagarela--spinner-interval
                          #'tagarela--spinner-tick))))

(defun tagarela--stop-spinner ()
  "Stop the braille spinner timer and clear the active state."
  (setq tagarela--spinner-active nil)
  (when (timerp tagarela--spinner-timer)
    (cancel-timer tagarela--spinner-timer)
    (setq tagarela--spinner-timer nil))
  (force-mode-line-update t))

(defun tagarela--mode-line-status ()
  "Return the mode-line status fragment for the conversation buffer.
Shows the braille spinner while a turn is in flight (from prompt to
turn_end/error/cancelled), or `[llm-bridge…]' during a turn with no spinner."
  (cond
   (tagarela--spinner-active
    (format " [%s]" (aref tagarela--spinner-frames
                          tagarela--spinner-index)))
   (tagarela-in-turn
    " [llm-bridge…]")
   (t "")))

;;; Event render handlers (dispatched by the client's `--handle-line')

(defun tagarela--on-chunk (text)
  "Handle a `chunk' event with TEXT (streaming fragment)."
  (when tagarela--after-tool-separator-pending
    ;; The tool output finished and the model resumed: separate it with
    ;; two blank lines (three newlines), only on the first transition.
    (setq tagarela--after-tool-separator-pending nil)
    (tagarela--insert "\n\n\n"))
  (when tagarela--thinking-separator-pending
    ;; The thinking finished and the answer started: separate it with two
    ;; blank lines (three newlines), only on the first transition.
    (setq tagarela--thinking-separator-pending nil)
    (tagarela--insert "\n\n\n"))
  (tagarela--answer-begin)
  (tagarela--insert text)
  (tagarela--render-answer-live))

(defun tagarela--on-thinking (text)
  "Handle a `thinking' event with TEXT (chain-of-thought fragment)."
  (tagarela--render-answer)
  (tagarela--start-spinner)
  (when tagarela-show-thinking
    (when tagarela--after-tool-separator-pending
      ;; The tool output finished and the model started thinking: separate
      ;; it with two blank lines, only on the first transition.
      (setq tagarela--after-tool-separator-pending nil)
      (tagarela--insert "\n\n\n"))
    (setq tagarela--thinking-separator-pending t)
    (tagarela--insert-propertized
     text 'face 'tagarela-thinking-face)))

(defun tagarela--on-turn-end (ev)
  "Handle a `turn_end' event EV: finalize turn tokens, accumulate session
usage and show a per-turn summary with the model."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela--turn-finalized t)
  (let ((input (gethash "input_tokens" ev 0))
        (output (gethash "output_tokens" ev 0))
        (cache-hit (gethash "cache_hit_tokens" ev 0))
        (cache-miss (gethash "cache_miss_tokens" ev 0))
        (model (gethash "model" ev)))
    (let ((inc-in (- input tagarela--current-turn-input-tokens))
          (inc-out (- output tagarela--current-turn-output-tokens)))
      (setq tagarela-session-input-tokens
            (+ tagarela-session-input-tokens (max 0 inc-in))
            tagarela-session-output-tokens
            (+ tagarela-session-output-tokens (max 0 inc-out))
            tagarela-session-cache-hit-tokens
            (+ tagarela-session-cache-hit-tokens (max 0 cache-hit))
            tagarela-session-cache-miss-tokens
            (+ tagarela-session-cache-miss-tokens (max 0 cache-miss))
            tagarela--current-turn-input-tokens 0
            tagarela--current-turn-output-tokens 0))
    (when model
      (setq tagarela-session-model model))
    (tagarela--insert-propertized
     (format "\n[stop_reason=%s model=%s | turn: sent %d, received %d, cache %d/%d | session: sent %d, received %d, cache %d/%d]\n"
             (gethash "stop_reason" ev)
             (or model "?")
             input output cache-hit cache-miss
             tagarela-session-input-tokens
             tagarela-session-output-tokens
             tagarela-session-cache-hit-tokens
             tagarela-session-cache-miss-tokens)
     'face 'tagarela-separator-face))
  (force-mode-line-update t)
  (tagarela--show-answer-start))

(defun tagarela--on-usage-delta (ev)
  "Handle a `usage_delta' event EV: update turn and session token usage."
  (unless tagarela--turn-finalized
    (let ((input (gethash "input_tokens" ev 0))
          (output (gethash "output_tokens" ev 0)))
      (let ((inc-in (- input tagarela--current-turn-input-tokens))
            (inc-out (- output tagarela--current-turn-output-tokens)))
        (when (> inc-in 0)
          (setq tagarela-session-input-tokens (+ tagarela-session-input-tokens inc-in)
                tagarela--current-turn-input-tokens input))
        (when (> inc-out 0)
          (setq tagarela-session-output-tokens (+ tagarela-session-output-tokens inc-out)
                tagarela--current-turn-output-tokens output)))
      (force-mode-line-update t))))

(defun tagarela--on-error (msg)
  "Handle an `error' event with MSG."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil)
  (tagarela--cancel-confirm)
  (tagarela--insert-propertized
   (format "\n[error] %s\n" msg)
   'face 'tagarela-error-face))

(defun tagarela--on-files-changed (ev)
  "Handle a `files_changed' event EV.
Runs `tagarela-files-changed-hook' with the list of files changed by
the model in the turn that just finished (the `files' field of EV)."
  (let ((changed (gethash "files" ev)))
    (when changed
      (run-hook-with-args 'tagarela-files-changed-hook changed))))

(defun tagarela--on-cancelled ()
  "Handle a `cancelled' event."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil)
  (tagarela--cancel-confirm)
  (tagarela--insert-propertized
   "\n[cancelled]\n"
   'face 'tagarela-separator-face))

(defun tagarela--on-hook-action (ev)
  "Handle a `hook_action' event EV: show a local hook's result.
A hook (a prompt starting with \"#\") runs a local script instead of calling
the LLM; the bridge replies with a single `hook_action' event and NO
`turn_end', so this handler also finalizes the client-side \"turn\" state
(stopping the spinner, clearing `tagarela-in-turn' and the separator
flags).  There is no token/model accounting here because there is no
`turn_end'.  When EV carries an `error' field (script missing, invalid name
or non-zero exit) the message is shown in the error face; otherwise the
script's combined output is inserted as plain text."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela--turn-finalized t)
  (tagarela--cancel-confirm)
  (let ((name (gethash "name" ev))
        (output (gethash "output" ev))
        (err (gethash "error" ev)))
    (if err
        (tagarela--insert-propertized
         (format "\n[hook %s] error: %s\n" name err)
         'face 'tagarela-error-face)
      (tagarela--insert-propertized
       (concat "\n" (or output "") "\n"))))
  (force-mode-line-update t))

;;; Step 5 — Conversation buffer and input buffer

(defvar tagarela-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a q") #'tagarela-quit)
    (define-key map (kbd "C-c a k") #'tagarela-kill)
    map)
  "Keymap for `tagarela-mode'.")

(define-minor-mode tagarela-mode
  "Minor mode for the llm-bridge conversation buffer."
  :lighter " LB")

(defun tagarela--get-buffer ()
  "Return the conversation buffer, creating it if needed."
  (let ((buf (get-buffer-create tagarela-buffer-name)))
    (with-current-buffer buf
      (unless buffer-read-only
        (setq buffer-read-only t))
      (unless tagarela-mode
        (tagarela-mode 1))
      (unless (cl-member '(:eval (tagarela--mode-line-status))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (tagarela--mode-line-status))))))
      ;; Hide the position (line/column/%) — the buffer is a chat log whose
      ;; size changes at every chunk, so the position counter would flicker
      ;; frantically during streaming and make the mode-line (and the
      ;; spinner) look unstable.
      (setq-local mode-line-position nil))
    buf))

(defun tagarela--insert-propertized (text &rest props)
  "Insert TEXT at the end of the conversation buffer with PROPS (plist).
The displayed window follows along when it was already showing the end.
Return the buffer position where TEXT was inserted (start of TEXT)."
  (let ((buf (tagarela--get-buffer)))
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

(defun tagarela--insert (text)
  "Insert TEXT at the end of the conversation buffer."
  (tagarela--insert-propertized text))

(defun tagarela--insert-propertized-at (pos text &rest props)
  "Insert TEXT at buffer position POS (or at the end if POS is nil) with PROPS.
Return the buffer position where TEXT was inserted (start of TEXT)."
  (let ((buf (tagarela--get-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (target (or pos (point-max))))
        (goto-char target)
        (insert (if props (apply #'propertize text props) text))
        target))))

(defun tagarela--prompt-send (text &optional images segments)
  "Core routine: echo TEXT in the conversation and send it as a prompt.
IMAGES, when non-nil, is a list of image specs collected from the input
buffer (see `tagarela--buffer-collect'); they are echoed inline and attached
to the prompt as the `images' array.  SEGMENTS, when non-nil, is the ordered
list of (KIND . VALUE) segments from `tagarela--buffer-collect-segments' and
is used to echo the images interleaved with the text the way the user typed
them (an image above a caption stays above it, and vice versa).  A message
whose trimmed text starts with \"#\" is sent as a local hook instead (images
are then ignored, as a hook is not an LLM call).  Rejects a new prompt while
a turn is in progress."
  (tagarela--ensure-ready)
  (when (or tagarela-in-turn tagarela-pending-tools)
    (error "There is a turn in progress; wait for it to finish"))
  (if (string-prefix-p "#" (string-trim-left text))
      (tagarela--hook-send text)
    (let ((text (if (and images (string-empty-p (string-trim text)))
                    "(imagem)" text)))
      (tagarela--render-answer)
      (setq tagarela-in-turn t
            tagarela--thinking-separator-pending nil
            tagarela--after-tool-separator-pending nil
            tagarela--current-turn-input-tokens 0
            tagarela--current-turn-output-tokens 0
            tagarela--turn-finalized nil)
      (tagarela--start-spinner)
      (tagarela--insert-propertized
       "\n──────────────────────────────\n"
       'face 'tagarela-separator-face)
      (tagarela--insert-propertized
       (concat ">>> " (tagarela--prompt-echo-body text images segments) "\n")
       'face 'tagarela-user-face)
      (tagarela--insert "\n")
      (when (markerp tagarela--turn-answer-start)
        (set-marker tagarela--turn-answer-start nil))
      (setq tagarela--turn-answer-start
            (with-current-buffer (tagarela--get-buffer)
              (copy-marker (point-max))))
      (tagarela--send "prompt" (tagarela--prompt-params text images)))))

(defun tagarela--prompt-echo-body (text images segments)
  "Return the echoing body (after the \">>> \") for a prompt.
TEXT is the raw prompt text and IMAGES its image specs.  SEGMENTS, when
non-nil, is the ordered list of (KIND . VALUE) segments typed in the input
buffer; the images are placed where the user put them and each text block is
trimmed for display.  When SEGMENTS is nil the images are appended after the
text (used by direct callers such as the slash-command prompt echo).  A
`[🖼 N]' badge and the per-request annotation trail the first line."
  (let ((suffix (concat (if images (format "  [🖼 %d]" (length images)) "")
                        (tagarela--request-annotation)))
        (chunks
         (if segments
             (delq nil
                   (mapcar (lambda (seg)
                             (let ((chunk (if (eq (car seg) 'image)
                                              (tagarela--image-string (cdr seg))
                                            (string-trim (cdr seg)))))
                               (unless (string-empty-p chunk) chunk)))
                           segments))
           (list (string-trim text)))))
    (when (null chunks)
      (setq chunks (list (if images "(imagem)" (string-trim text)))))
    (concat (car chunks) suffix
            (mapconcat (lambda (c) (concat "\n" c)) (cdr chunks) ""))))

(defun tagarela--hook-send (text)
  "Echo TEXT (a local hook command) and send it to the bridge as a prompt.
TEXT must start with \"#\" (the caller, `tagarela--prompt-send', has
already checked it and applied the shared turn-in-progress guard).  The
bridge runs the local script instead of calling the LLM and replies
asynchronously with a single `hook_action' event and no `turn_end'; the
client-side turn state is still marked in progress here and closed by
`tagarela--on-hook-action'."
  (tagarela--render-answer)
  (setq tagarela-in-turn t
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela--current-turn-input-tokens 0
        tagarela--current-turn-output-tokens 0
        tagarela--turn-finalized nil)
  (tagarela--start-spinner)
  (tagarela--insert-propertized
   "\n──────────────────────────────\n"
   'face 'tagarela-separator-face)
  (tagarela--insert-propertized
   (format ">>> %s\n\n" text)
   'face 'tagarela-hook-face)
  (tagarela--send "prompt" (tagarela--prompt-params text)))

(defcustom tagarela-project-dir nil
  "Base directory under which the `/project' command resolves its argument.

When non-nil (e.g. \"~/mysrc/\") the `/project' argument is taken as a
project NAME and resolved to BASE/NAME, so `/project tupi' means
`~/mysrc/tupi/'.  When nil (the default) the argument is taken as a PATH and
expanded with `expand-file-name' — an absolute path, a `~' path or a path
relative to `default-directory' all work."
  :type '(choice (const :tag "Argument is a path" nil)
                 (directory :tag "Base directory for project names"))
  :group 'tagarela)

(defcustom tagarela-project-change-hook nil
  "Hook run after the `/project' command switches the working directory.
The hook is called with a single argument: the new project directory.  Use
it to react to a project change (e.g. reload project-specific commands or
keybindings); the package itself knows nothing about projects."
  :type 'hook
  :group 'tagarela)

(defun tagarela--apply-project-dir-locals (dir)
  "Set `default-directory' of the current buffer to DIR and load its
.dir-locals.el, respecting `safe-local-variable-values'.

Uses `hack-dir-local-variables-non-file-buffer' so that only variables
present in `safe-local-variable-values' are applied silently; unsafe ones
prompt the user.  The `hack-local-variables-hook' runs afterwards, so any
hook it triggers (e.g. project keybindings) fires as usual."
  (setq default-directory (file-name-as-directory dir))
  (when (file-exists-p (expand-file-name ".dir-locals.el" dir))
    (hack-dir-local-variables-non-file-buffer)))

(defun tagarela--handle-slash-command (text)
  "Check if TEXT is a slash command (e.g. /project <name>), execute it and return non-nil if handled.

The `/project' argument is resolved against `tagarela-project-dir': when that
variable is non-nil the argument is a project NAME (resolved as BASE/NAME),
otherwise it is a PATH expanded with `expand-file-name'.  After switching the
new directory is passed to `tagarela-project-change-hook'."
  (cond
   ((string-match "^/project[[:space:]]+\\(.+\\)$" text)
    (let* ((arg (string-trim (match-string 1 text)))
           (base (and tagarela-project-dir
                      (file-name-as-directory
                       (expand-file-name tagarela-project-dir))))
           (dir (expand-file-name arg base)))
      (if (not (file-directory-p dir))
          (error "Project directory does not exist: %s" dir)
        (tagarela--apply-project-dir-locals dir)
        (with-current-buffer (tagarela--request-buffer)
          (tagarela--apply-project-dir-locals dir))
        (with-current-buffer (tagarela--get-buffer)
          (tagarela--apply-project-dir-locals dir))
        (tagarela--send "set_cwd" (list "cwd" dir))
        (run-hook-with-args 'tagarela-project-change-hook dir)
        (dolist (buf (list (get-buffer "*GNU Emacs*") (get-buffer "*scratch*")))
          (when buf
            (with-current-buffer buf
              (tagarela--apply-project-dir-locals dir))))
        (tagarela--insert-propertized
         (format "\n[project set to %s]\n" dir)
         'face 'tagarela-separator-face)
        (message "Project set to %s" dir))
      t))
   (t nil)))

(defun tagarela-send-input ()
  "Send the current input buffer contents to the bridge and clear it.
Images pasted/attached in the buffer are collected as attachments (see
`tagarela--buffer-collect') and sent with the prompt; a slash command never
carries images."
  (interactive)
  (let* ((segments (tagarela--buffer-collect-segments))
         (collected (tagarela--buffer-collect))
         (text (car collected))
         (images (cdr collected))
         (has-text (string-match-p "[^[:space:]]" text)))
    (when (or has-text images)
      (unless (and has-text (tagarela--handle-slash-command text))
        (tagarela--prompt-send text images segments))
      (erase-buffer))))

(define-minor-mode tagarela-input-mode
  "Minor mode for typing input destined to the llm-bridge.
C-c C-c sends the whole buffer; RET inserts a newline.  C-y yanks an image
from the clipboard when there is one (see `tagarela-yank')."
  :lighter " LBIn"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'tagarela-send-input)
            (define-key map (kbd "C-y") #'tagarela-yank)
            (define-key map (kbd "RET") #'newline)
            (define-key map (kbd "C-j") #'newline)
            map)
  (when tagarela-input-mode
    ;; Let `yank-media' (and `tagarela-yank', via it) insert clipboard
    ;; images inline in this buffer.
    (yank-media-handler "image/.*" #'tagarela--yank-media-image)))

(defun tagarela--mode-line-session ()
  "Return the mode-line fragment with the session token usage and model.
Shows tokens sent (↑, input), tokens received (↓, output), the prompt-cache
hit/miss totals (⚡, shown only when the provider reports any) and the model
of the current session, e.g. \" [↑12 ↓8 ⚡900/124 deepseek-chat]\"."
  (let* ((hit tagarela-session-cache-hit-tokens)
         (miss tagarela-session-cache-miss-tokens)
         (cache (if (> (+ hit miss) 0) (format "⚡%d/%d " hit miss) ""))
         (s (format " [↑%d ↓%d %s%s]"
                    tagarela-session-input-tokens
                    tagarela-session-output-tokens
                    cache
                    (or tagarela-session-model "?"))))
    (propertize s 'help-echo
                "↑ tokens sent · ↓ tokens received · ⚡ prompt-cache hit/miss · session model")))

(defun tagarela--mode-line-request ()
  "Return the mode-line fragment describing the per-request overrides.
Shows the model, thinking and effort overrides set for the next prompt,
e.g. \" [model=deepseek-reasoner thinking=on effort=high]\".  Empty when no
override is set."
  (let ((ann (tagarela--request-annotation)))
    (if (string-empty-p ann)
        ""
      (propertize ann 'help-echo "Per-request overrides (C-c a m / t / e)"))))

(defun tagarela--setup-input-mode-line ()
  "Install the session and request indicators in the input buffer's
mode-line (idempotent).  Creates the input buffer if it does not exist yet
(on a fresh open)."
  (let ((buf (or (get-buffer tagarela-input-buffer-name)
                 (get-buffer-create tagarela-input-buffer-name))))
    (with-current-buffer buf
      (unless (cl-member '(:eval (tagarela--mode-line-session))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (tagarela--mode-line-session))))))
      (unless (cl-member '(:eval (tagarela--mode-line-request))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (tagarela--mode-line-request)))))))))

;;;###autoload
(defun tagarela-open ()
  "Start the bridge and set up the llm-bridge window layout.
Divides the selected window in two: the left side keeps the buffer that
was already open and the right side shows the llm-bridge (conversation
on top, input buffer below, ~20% of the frame height)."
  (interactive)
  (tagarela--ensure-ready)
  (tagarela--setup-input-mode-line)
  (let ((conv (tagarela--get-buffer))
        (in (get-buffer-create tagarela-input-buffer-name)))
    (if (get-buffer-window conv)
        ;; Already open: focus the conversation and ensure the input below it.
        (progn
          (select-window (get-buffer-window conv))
          (unless (get-buffer-window tagarela-input-buffer-name)
            (split-window-below)
            (other-window 1)
            (switch-to-buffer in)
            (tagarela-input-mode 1)))
      ;; Split the current window in two: left = already-open buffer,
      ;; right = conversation (top) + input (bottom).
      (split-window-right)
      (other-window 1)                    ; right window
      (switch-to-buffer conv)
      (split-window-below)
      (other-window 1)                    ; bottom window of the right side
      (switch-to-buffer in)
      (tagarela-input-mode 1))
    ;; Adjust the bottom window (input) to ~20% of the total frame height
    (let* ((input-window (get-buffer-window tagarela-input-buffer-name))
           (frame-height (window-total-height (frame-root-window)))
           (target-height (max 1 (round (* frame-height 0.2))))
           (delta (- target-height (window-total-height input-window))))
      (when input-window
        (window-resize input-window delta nil t)))))

;;; Step 4 — User commands (basic interaction)

;;;###autoload
(defun tagarela-prompt (text)
  "Send TEXT as a prompt to the bridge."
  (interactive "sPrompt: ")
  (tagarela--prompt-send text))

;;;###autoload
(defun tagarela-cancel ()
  "Cancel the current in-flight turn and stop any running tool command."
  (interactive)
  ;; Stop any asynchronous tool command (shell/grep) still running: otherwise
  ;; it would keep running after the turn is cancelled and send a late
  ;; tool_result the bridge no longer expects.
  (dolist (p tagarela--tool-procs)
    (when (process-live-p p)
      (delete-process p)))
  (setq tagarela--tool-procs nil)
  (when (and tagarela-process (process-live-p tagarela-process))
    (tagarela--send "cancel")))

;;;###autoload
(defun tagarela-set-cwd (dir)
  "Set the bridge working directory to DIR."
  (interactive "DWorking dir: ")
  (tagarela--send "set_cwd" (list "cwd" (expand-file-name dir))))

;;;###autoload
(defun tagarela-set-provider (provider)
  "Set the provider override for the next prompt (empty = default).
The override is sent as the `provider' field of the next `prompt'."
  (interactive
   (list (completing-read
          "Provider for the next prompt (empty = default): "
          '("deepseek" "google") nil t)))
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-provider provider))
  (force-mode-line-update t)
  (message "Provider for the next prompt: %s"
           (if (string-empty-p provider) "(default)" provider)))

;;;###autoload
(defun tagarela-set-model (model)
  "Set the model override for the next prompt (empty = provider default).
The override is sent as the `model' field of the next `prompt' and stays
active for the following prompts until changed (mirrors the bridge)."
  (interactive "sModel for the next prompt (empty = provider default): ")
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-model model))
  (force-mode-line-update t)
  (message "Model for the next prompt: %s"
           (if (string-empty-p model) "(provider default)" model)))

;;;###autoload
(defun tagarela-set-thinking (thinking)
  "Set the thinking override for the next prompt: on, off or unset.
`on' forces thinking (deepseek-reasoner), `off' forces it off
(deepseek-chat) and `unset' restores the provider's configured mode."
  (interactive
   (list (intern (completing-read
                  "Thinking for the next prompt (unset/on/off): "
                  '("unset" "on" "off") nil t))))
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-thinking thinking))
  (force-mode-line-update t)
  (message "Thinking for the next prompt: %s"
           (pcase thinking
             ('t "on")
             ('off "off")
             (_ "unset (provider default)"))))

;;;###autoload
(defun tagarela-set-reasoning-effort (effort)
  "Set the thinking depth (reasoning_effort) for the next prompt.
One of \"low\", \"medium\" or \"high\"; empty = provider default."
  (interactive
   (list (completing-read
          "Reasoning effort for the next prompt (empty = default): "
          '("low" "medium" "high") nil t)))
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-reasoning-effort effort))
  (force-mode-line-update t)
  (message "Reasoning effort for the next prompt: %s"
           (if (string-empty-p effort) "(provider default)" effort)))

(defun tagarela-set-knowledge-bases (bases)
  "Set the bridge knowledge BASES (list of hash tables)."
  (tagarela--send "set_knowledge_bases" (list "bases" bases)))

;;;###autoload
(defun tagarela-quit ()
  "Send `quit' to the bridge, ending the process."
  (interactive)
  (when (and tagarela-process (process-live-p tagarela-process))
    (tagarela--send "quit")))

;;; Step 10 — Shutdown and robustness

;;;###autoload
(defun tagarela-kill ()
  "Terminate the bridge, kill any running tool processes and clean state."
  (interactive)
  (tagarela--cancel-confirm)
  (when (and tagarela-process (process-live-p tagarela-process))
    (tagarela--send "quit")
    (sleep-for 0.1)
    ;; the sentinel may have already cleared the process; only delete if alive
    (when (and tagarela-process (process-live-p tagarela-process))
      (delete-process tagarela-process)))
  (dolist (p tagarela--tool-procs)
    (when (process-live-p p)
      (delete-process p)))
  (setq tagarela--tool-procs nil)
  (setq tagarela-process nil
        tagarela-ready nil
        tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela-line-buffer ""
        tagarela--after-tool-separator-pending nil)
  ;; Detach the pending-answer marker: the buffers may be erased next
  ;; (`--restart'), and a stale marker would then re-render from position 1.
  (when (markerp tagarela--answer-start)
    (set-marker tagarela--answer-start nil))
  (setq tagarela--answer-start nil)
  (when (markerp tagarela--turn-answer-start)
    (set-marker tagarela--turn-answer-start nil))
  (setq tagarela--turn-answer-start nil)
  (tagarela--reset-session))

(add-hook 'kill-emacs-hook #'tagarela-kill)

;;; Step 11 — Prefix keymap and interactive commands

;;;###autoload
(defun tagarela-restart ()
  "Restart the bridge: kill it, clear the buffers and reset the state.
Then reopen the llm-bridge window layout."
  (interactive)
  (tagarela-kill)
  (dolist (b (list (get-buffer tagarela-buffer-name)
                   (get-buffer tagarela-input-buffer-name)))
    (when b
      (with-current-buffer b
        (let ((inhibit-read-only t))
          (erase-buffer)))))
  (tagarela-open))

(defvar tagarela-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "l") #'tagarela-open)
    (define-key map (kbd "o") #'tagarela-open)
    (define-key map (kbd "r") #'tagarela-restart)
    (define-key map (kbd "k") #'tagarela-kill)
    (define-key map (kbd "c") #'tagarela-cancel)
    (define-key map (kbd "q") #'tagarela-quit)
    (define-key map (kbd "p") #'tagarela-set-provider)
    (define-key map (kbd "m") #'tagarela-set-model)
    (define-key map (kbd "t") #'tagarela-set-thinking)
    (define-key map (kbd "e") #'tagarela-set-reasoning-effort)
    (define-key map (kbd "i") #'tagarela-attach-image-file)
    (define-key map (kbd "u") #'tagarela-attach-image-url)
    map)
  "Keymap for the `C-c a' prefix of the llm-bridge commands.")

;;;###autoload
(global-set-key (kbd "C-c a") tagarela-prefix-map)

(provide 'tagarela-ui)

;;; tagarela-ui.el ends here
