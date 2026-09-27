;;; tagarela.el --- Emacs client for llm-bridge (entry point)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs client for llm-bridge, a long-running Go process that bridges an
;; editor and the DeepSeek LLM over JSON lines (stdin/stdout).  This package
;; starts the bridge as a subprocess, reads its events asynchronously, displays
;; the conversation in a dedicated buffer and executes the tools locally.
;;
;; The bridge protocol is documented in
;; ~/mysrc/llm-bridge/docs/cliente-impl-guide.md.
;;
;; Since the client grew large it was split in two halves, both alongside
;; this file in the package root:
;;
;;   tagarela-client.el — the "client": JSON protocol (serializing the
;;     commands to the bridge and parsing its events), the subprocess
;;     lifecycle (spawning, line filtering, handshake) and the tool
;;     implementations plus the trust-scope decision logic.  It knows nothing
;;     about buffers/windows.
;;
;;   tagarela-ui.el — the "UI": the conversation and input buffers,
;;     rendering of model output, the braille spinner, the mode-line
;;     fragments, the window layout (open/restart/kill) and the
;;     tool-confirmation UX (individual questions, `[allowed]' / `[denied]'
;;     tags, the transient trust-scope menu).
;;
;; This file is the thin entry point: it requires both halves.  `(require
;; 'tagarela)' gives you everything.
;;
;;; Usage:
;;
;;   C-c a l  tagarela-open      start the client: divides the window in
;;   C-c a o                           two (left keeps the current buffer; right
;;                                     shows the conversation on top and the
;;                                     input buffer below, ~20% of the frame)
;;   C-c a r  tagarela-restart   kill the bridge, clear the buffers,
;;                                     reset the state and reopen
;;   C-c a k  tagarela-kill      terminate the bridge and clean up
;;   C-c a c  tagarela-cancel    cancel the current in-flight turn
;;   C-c a q  tagarela-quit      send quit to the bridge and stop
;;   C-c a m  tagarela-set-model set the model override for the next
;;                                     prompt (empty = provider default)
;;   C-c a t  tagarela-set-thinking
;;                                     toggle thinking on/off/unset per request
;;   C-c a e  tagarela-set-reasoning-effort
;;                                     set the thinking depth (low/medium/high,
;;                                     empty = provider default) per request
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

(require 'tagarela-client)
(require 'tagarela-ui)

(provide 'tagarela)

;;; tagarela.el ends here
