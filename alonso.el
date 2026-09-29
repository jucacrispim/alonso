;;; alonso.el --- Emacs client for llm-bridge (entry point)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs client for llm-bridge, a long-running Go process that bridges an
;; editor and the DeepSeek LLM over JSON lines (stdin/stdout).  This package
;; starts the bridge as a subprocess, reads its events asynchronously, displays
;; the conversation in a dedicated buffer and executes the tools locally.
;;
;; The bridge protocol is documented in
;; ~/mysrc/llm-bridge/docs/source/.
;;
;; Since the client grew large it was split, all files alongside this one in
;; the package root:
;;
;;   alonso-client.el — the "client": JSON protocol (serializing the
;;     commands to the bridge and parsing its events), the subprocess
;;     lifecycle (spawning, line filtering, handshake) and the tool
;;     implementations plus the trust-scope decision logic.  It knows nothing
;;     about buffers/windows.
;;
;;   alonso-ui.el — the "UI shell": the conversation and input buffers,
;;     their minor modes and keymaps, the insertion helpers, the shared
;;     conversation state, the braille spinner, the mode-line fragments, the
;;     event render handlers, the `/project' command, the window layout
;;     (open/restart/kill) and the `C-c a' prefix map.
;;
;; and the rendering/UX pieces that build on the shell (each requires
;; alonso-ui.el):
;;
;;   alonso-markdown.el — Markdown rendering of the model's answer.
;;   alonso-image.el    — pasting/attaching images to a prompt.
;;   alonso-tools.el    — tool-call display and the confirmation/trust UX.
;;
;; The dependency is one-way: the shell talks to alonso-client.el, and the
;; three leaf files talk to the shell (which reaches their functions only at
;; runtime, via `declare-function').
;;
;; This file is the thin entry point: it requires all of them.  `(require
;; 'alonso)' gives you everything.
;;
;;; Usage:
;;
;;   C-c a l  alonso-open      start the client: divides the window in
;;   C-c a o                           two (left keeps the current buffer; right
;;                                     shows the conversation on top and the
;;                                     input buffer below, ~20% of the frame)
;;   C-c a r  alonso-restart   kill the bridge, clear the buffers,
;;                                     reset the state and reopen
;;   C-c a k  alonso-kill      terminate the bridge and clean up
;;   C-c a c  alonso-cancel    cancel the current in-flight turn
;;   C-c a q  alonso-quit      send quit to the bridge and stop
;;   C-c a m  alonso-set-model set the model override for the next
;;                                     prompt (empty = provider default)
;;   C-c a t  alonso-set-thinking
;;                                     toggle thinking on/off/unset per request
;;   C-c a e  alonso-set-reasoning-effort
;;                                     set the thinking depth (low/medium/high,
;;                                     empty = provider default) per request
;;   C-c a i  alonso-attach-image-file
;;                                     attach an image (by path) to the next
;;                                     prompt
;;   C-c a u  alonso-attach-image-url
;;                                     attach an image (by URL) to the next
;;                                     prompt
;;
;; Images are attached inline in the input buffer (the image shows in the
;; buffer) and sent with the prompt as the bridge's `images' array.  In the
;; input buffer, C-y (`alonso-yank') pastes an image from the clipboard when
;; there is one, otherwise it yanks text as usual.
;;
;; In the input buffer, C-c C-c sends the prompt (RET inserts a newline). In the
;; conversation buffer, C-c a q quits, C-c a k kills and C-c a c cancels.
;; The conversation shows user prompts prefixed with ">>> " and the model's
;; response streams into it, with thinking (chain-of-thought) rendered in
;; PaleVioletRed4 (#8b475d, set in pdj-theme.el) and separated from the
;; answer by two blank lines. Mutating tool calls show their confirmation
;; question right away, one at a time — the tool's icon and the
;; `Run tool: <name> · <detail>?' prompt, e.g. "🖥 Run tool: shell · ps aux?",
;; followed by the parameters beneath it; once the user answers, the
;; `[allowed]' / `[denied]' tag is prepended to the front of that same line.
;;
;; A prompt whose text starts with "#" is treated as a local hook: the bridge
;; runs the script .llm-bridge/hooks/<name>.sh (project dir first, then
;; ~/.llm-bridge/hooks/) instead of calling the LLM, and replies asynchronously
;; with a single `hook_action' event (no `turn_end').

;;; Code:

(require 'cl-lib)

;; The two halves live alongside this file in the package root; make sure
;; that directory is loadable (the original added its llm-bridge/ subdirectory
;; to load-path, this flattened layout uses the package root itself).
(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir
    (add-to-list 'load-path dir)))

(require 'alonso-client)
(require 'alonso-ui)
(require 'alonso-markdown)
(require 'alonso-image)
(require 'alonso-tools)

(provide 'alonso)

;;; alonso.el ends here
