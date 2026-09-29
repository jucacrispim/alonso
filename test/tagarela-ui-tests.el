;;; tagarela-ui-tests.el --- Tests for the tagarela UI shell: session/usage, separators, spinner, project, hooks and the answer glue.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the tagarela UI shell: session/usage, separators, spinner, project, hooks and the answer glue.
;;
;; Part of the tagarela test suite; `tagarela-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'tagarela-tests-lib)

;;; Kill hook registered

(tagarela-tests--assert
 "kill-emacs-hook registered" (memq 'tagarela-kill kill-emacs-hook))

;;; Session — token accumulation, per-turn summary and input mode-line

(let ((ev (make-hash-table :test 'equal)))
  (tagarela--reset-session)
  (dolist (turn '((12 8 100 4) (30 15 900 120)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "deepseek-chat" ev)
    (puthash "input_tokens" (nth 0 turn) ev)
    (puthash "output_tokens" (nth 1 turn) ev)
    (puthash "cache_hit_tokens" (nth 2 turn) ev)
    (puthash "cache_miss_tokens" (nth 3 turn) ev)
    (puthash "total_tokens" (+ (nth 0 turn) (nth 1 turn)) ev)
    (tagarela--on-turn-end ev))
  (tagarela-tests--assert
   "session accumulates sent/received tokens"
   (and (= 42 tagarela-session-input-tokens)
        (= 23 tagarela-session-output-tokens)))
  (tagarela-tests--assert
   "session accumulates prompt-cache hit/miss tokens"
   (and (= 1000 tagarela-session-cache-hit-tokens)
        (= 124 tagarela-session-cache-miss-tokens)))
  (tagarela-tests--assert
   "session model comes from turn_end"
   (equal "deepseek-chat" tagarela-session-model))
  (tagarela-tests--assert
   "mode-line shows sent/received/cache/model"
   (string-match-p "↑42 ↓23 ⚡1000/124 deepseek-chat"
                   (tagarela--mode-line-session)))
  (tagarela-tests--assert
   "turn inserts a summary into the conversation"
   (string-match-p "turn: sent 30, received 15, cache 900/120"
                   (with-current-buffer (get-buffer "*llm-bridge*")
                     (buffer-string))))
  (tagarela--reset-session)
  (tagarela-tests--assert
   "reset clears the session"
   (and (zerop tagarela-session-input-tokens)
        (zerop tagarela-session-output-tokens)
        (zerop tagarela-session-cache-hit-tokens)
        (zerop tagarela-session-cache-miss-tokens)
        (null tagarela-session-model))))

;; A provider without prompt cache reports 0 hit / 0 miss: the mode-line must
;; omit the ⚡ fragment entirely (nothing to show).
(let ((ev (make-hash-table :test 'equal)))
  (tagarela--reset-session)
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "gemini" ev)
  (puthash "input_tokens" 5 ev)
  (puthash "output_tokens" 3 ev)
  (puthash "cache_hit_tokens" 0 ev)
  (puthash "cache_miss_tokens" 0 ev)
  (tagarela--on-turn-end ev)
  (tagarela-tests--assert
   "no cache: mode-line omits the ⚡ fragment"
   (and (string-match-p "↑5 ↓3 gemini" (tagarela--mode-line-session))
        (not (string-match-p "⚡" (tagarela--mode-line-session)))))
  (tagarela--reset-session))

;;; Usage delta — incremental updates during turn and final turn_end

(let ((ev (make-hash-table :test 'equal)))
  (tagarela--reset-session)
  ;; Simulate intermediate usage_delta
  (puthash "event" "usage_delta" ev)
  (puthash "input_tokens" 10 ev)
  (puthash "output_tokens" 5 ev)
  (puthash "total_tokens" 15 ev)
  (tagarela--on-usage-delta ev)
  (tagarela-tests--assert
   "usage_delta accumulates session tokens incrementally"
   (and (= 10 tagarela-session-input-tokens)
        (= 5 tagarela-session-output-tokens)))

  ;; Simulate turn_end with total turn tokens
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "deepseek-chat" ev)
  (puthash "input_tokens" 25 ev)
  (puthash "output_tokens" 12 ev)
  (puthash "total_tokens" 37 ev)
  (tagarela--on-turn-end ev)
  (tagarela-tests--assert
   "turn_end finalizes session tokens correctly"
   (and (= 25 tagarela-session-input-tokens)
        (= 12 tagarela-session-output-tokens))))

;;; Regression: first open — the input buffer does not exist yet when the
;;; mode-line setup runs; even so, the token indicator must be installed.

(let ((input (get-buffer "*llm-bridge-input*")))
  (when input (kill-buffer input))
  (tagarela--setup-input-mode-line)
  (let ((buf (get-buffer "*llm-bridge-input*")))
    (tagarela-tests--assert
     "setup creates the input buffer if missing" buf)
    (tagarela-tests--assert
     "setup installs the indicator even on the first open"
     (with-current-buffer buf
       (cl-member '(:eval (tagarela--mode-line-session))
                  mode-line-misc-info :test #'equal)))
    ;; idempotency: repeating does not duplicate
    (tagarela--setup-input-mode-line)
    (tagarela-tests--assert
     "repeated setup does not duplicate the indicator"
     (with-current-buffer buf
       (let ((n 0))
         (dolist (el mode-line-misc-info)
           (when (equal el '(:eval (tagarela--mode-line-session)))
             (cl-incf n)))
         (= n 1))))))

;;; Thinking — two-blank-lines separator before the response

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq tagarela--thinking-separator-pending nil)
  (tagarela--on-thinking "model reasoning")
  (tagarela-tests--assert
   "thinking marks the pending separator"
   tagarela--thinking-separator-pending)
  (tagarela--on-chunk "response")
  (tagarela-tests--assert
   "first chunk clears the pending separator"
   (not tagarela--thinking-separator-pending))
  (tagarela--on-chunk " final")
  (tagarela-tests--assert
   "two blank lines between thinking and response"
   (equal "model reasoning\n\n\nresponse final"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq tagarela--thinking-separator-pending nil)
  (tagarela--on-chunk "direct response")
  (tagarela-tests--assert
   "without thinking, the response goes straight (no extra blank lines)"
   (equal "direct response"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

;;; Tool → model: two blank lines between the tool output and the model's
;;; next thinking/response

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq tagarela--after-tool-separator-pending nil)
  ;; simulate: tool_call shown and result sent back to the bridge
  (tagarela--show-tool-call
   "call_1" "read"
   (tagarela--json-plist-to-hash (list "path" "/tmp/x.txt")))
  (tagarela--send-tool-result "call_1" "content" "success")
  (tagarela-tests--assert
   "tool result marks the pending tool->model separator"
   tagarela--after-tool-separator-pending)
  (tagarela--on-thinking "post-tool reasoning")
  (tagarela-tests--assert
   "thinking consumes the tool->model separator"
   (not tagarela--after-tool-separator-pending))
  (tagarela--on-chunk "post-tool response")
  (tagarela-tests--assert
   "two blank lines between the tool output and the model thinking"
   (equal "\n📄 read\n  path: /tmp/x.txt\n\n\npost-tool reasoning\n\n\npost-tool response"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq tagarela--after-tool-separator-pending nil)
  (tagarela--show-tool-call
   "call_2" "glob"
   (tagarela--json-plist-to-hash (list "pattern" "*.el")))
  (tagarela--send-tool-result "call_2" "a.el" "success")
  (tagarela--on-chunk "direct post-tool response")
  (tagarela--on-chunk " continues")
  (tagarela-tests--assert
   "without thinking, the tool->response separator appears (and only once)"
   (equal "\n🔎 glob\n  pattern: *.el\n\n\ndirect post-tool response continues"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

(let ((ev (make-hash-table :test 'equal)))
  (setq tagarela--after-tool-separator-pending t)
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "deepseek-chat" ev)
  (puthash "input_tokens" 0 ev)
  (puthash "output_tokens" 0 ev)
  (tagarela--on-turn-end ev)
  (tagarela-tests--assert
   "turn_end resets the tool->model separator"
   (not tagarela--after-tool-separator-pending)))

;;; Slash command /project

(let ((tmp-dir (expand-file-name (make-temp-file "pdj-proj-test" t))))
  (unwind-protect
      (let* ((captured-cwd nil)
             (vnew (lambda (method params)
                     (tagarela-tests--assert
                      "slash command /project sends set_cwd"
                      (equal method "set_cwd"))
                     (setq captured-cwd (cadr (member "cwd" params)))))
             (old (symbol-function 'tagarela--send)))
        (unwind-protect
            (progn
              (fset 'tagarela--send vnew)
              (tagarela-tests--assert
               "slash command /project returns t when handled"
               (tagarela--handle-slash-command (format "/project %s" tmp-dir)))
              (tagarela-tests--assert
               "slash command /project sends correct cwd path"
               (equal (file-truename tmp-dir) (file-truename captured-cwd))))
          (fset 'tagarela--send old)))
    (ignore-errors (delete-directory tmp-dir t))))

;; `/project' argument resolution.  With `tagarela-project-dir' non-nil the
;; argument is a project NAME resolved as BASE/NAME; with it nil the argument
;; is a PATH expanded with `expand-file-name'.
(let* ((base (expand-file-name (make-temp-file "tagarela-projbase" t)))
       (proj (expand-file-name "tupi" base)))
  (unwind-protect
      (progn
        (make-directory proj)
        (let* ((captured-cwd nil)
               (tagarela-project-dir base)
               (old (symbol-function 'tagarela--send)))
          (unwind-protect
              (progn
                (fset 'tagarela--send
                      (lambda (_m params)
                        (setq captured-cwd (cadr (member "cwd" params)))))
                (tagarela-tests--assert
                 "with project-dir: /project NAME is handled"
                 (tagarela--handle-slash-command "/project tupi"))
                (tagarela-tests--assert
                 "with project-dir: NAME resolves to BASE/NAME"
                 (equal (file-truename proj) (file-truename captured-cwd))))
            (fset 'tagarela--send old))))
    (ignore-errors (delete-directory base t))))

;; With `tagarela-project-dir' nil the argument is a path relative to
;; `default-directory' (here bound to a temp dir).
(let ((tmp (expand-file-name (make-temp-file "tagarela-relproj" t))))
  (unwind-protect
      (progn
        (make-directory (expand-file-name "sub" tmp))
        (let* ((captured-cwd nil)
               (tagarela-project-dir nil)
               (default-directory (file-name-as-directory tmp))
               (old (symbol-function 'tagarela--send)))
          (unwind-protect
              (progn
                (fset 'tagarela--send
                      (lambda (_m params)
                        (setq captured-cwd (cadr (member "cwd" params)))))
                (tagarela--handle-slash-command "/project sub")
                (tagarela-tests--assert
                 "with project-dir nil: relative path resolves against default-directory"
                 (equal (file-truename (expand-file-name "sub" tmp))
                        (file-truename captured-cwd))))
            (fset 'tagarela--send old))))
    (ignore-errors (delete-directory tmp t))))

;; `tagarela-project-change-hook' is run with the new project directory.
(let* ((tmp (expand-file-name (make-temp-file "tagarela-hookproj" t)))
       (captured nil)
       (old (symbol-function 'tagarela--send)))
  (unwind-protect
      (let ((tagarela-project-change-hook
             (list (lambda (dir) (setq captured dir)))))
        (unwind-protect
            (progn
              (fset 'tagarela--send (lambda (&rest _) nil))
              (tagarela--handle-slash-command (format "/project %s" tmp))
              (tagarela-tests--assert
               "project-change-hook is run with the new dir"
               (equal (file-truename tmp) (file-truename captured))))
          (fset 'tagarela--send old)))
    (ignore-errors (delete-directory tmp t))))

;;; Hooks — a prompt starting with "#" runs a local script (no LLM)

;; The dispatcher routes a `hook_action' event to `--on-hook-action', which
;; inserts the script's output and clears the client-side turn state (there is
;; no `turn_end' for hooks).  Exercised through the process filter so the
;; `hook_action' case in `--handle-line' is covered too.
(setq tagarela-line-buffer ""
      tagarela-in-turn t)
(tagarela--process-filter
 nil (concat "{\"event\":\"hook_action\",\"name\":\"ls\",\"output\":\"a\\nb\"}\n"))
(tagarela-tests--assert
 "hook_action output is inserted into the conversation"
 (string-match-p "a\nb"
                 (with-current-buffer (get-buffer "*llm-bridge*")
                   (buffer-string))))
(tagarela-tests--assert
 "hook_action clears the in-turn state (no turn_end for hooks)"
 (not tagarela-in-turn))

;; `--on-hook-action' with an `error' field (missing script / bad name / bad
;; exit) shows the message in the error face.
(let ((ev (make-hash-table :test 'equal)))
  (puthash "event" "hook_action" ev)
  (puthash "name" "naoexiste" ev)
  (puthash "error" "hook: not found: naoexiste" ev)
  (tagarela--on-hook-action ev)
  (tagarela-tests--assert
   "hook_action error is shown in the conversation"
   (string-match-p "\\[hook naoexiste\\] error: hook: not found: naoexiste"
                   (with-current-buffer (get-buffer "*llm-bridge*")
                     (buffer-string)))))

;; A prompt whose text starts with "#" goes through the hook path: it echoes the
;; command and sends it as a `prompt' (the bridge decides it is a hook), marking
;; the turn in progress.  A normal prompt is unaffected.
(let ((sent nil)
      (start (with-current-buffer (get-buffer "*llm-bridge*") (point-max))))
  (setq tagarela-in-turn nil tagarela-pending-tools nil)
  (cl-letf (((symbol-function 'tagarela--ensure-ready) (lambda ()))
            ((symbol-function 'tagarela--send)
             (lambda (method &optional params) (push (cons method params) sent))))
    (tagarela--prompt-send "#ls -l"))
  (tagarela-tests--assert
   "hook prompt is sent as a prompt command"
   (equal "prompt" (caar sent)))
  (tagarela-tests--assert
   "hook prompt carries the # text"
   (string-match-p "#ls -l" (format "%S" (cdar sent))))
  (tagarela-tests--assert
   "hook prompt echoes the command in the conversation"
   (string-match-p ">>> #ls -l"
                   (with-current-buffer (get-buffer "*llm-bridge*")
                     (buffer-substring-no-properties start (point-max)))))
  (tagarela-tests--assert
   "hook prompt marks the turn in progress"
   tagarela-in-turn))

;;; Braille spinner & mode-line status

(let ((tagarela-in-turn nil)
      (tagarela--spinner-active nil)
      (tagarela--spinner-timer nil))
  (tagarela-tests--assert
   "mode-line status empty when idle"
   (equal "" (tagarela--mode-line-status)))
  (setq tagarela-in-turn t)
  (tagarela-tests--assert
   "mode-line status shows llm-bridge... when in turn (no spinner)"
   (equal " [llm-bridge…]" (tagarela--mode-line-status)))
  (tagarela--start-spinner)
  (tagarela-tests--assert
   "mode-line status shows braille spinner when active"
   (string-match-p " \\[[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]\\]" (tagarela--mode-line-status)))
  ;; spinner stays active (and keeps spinning) across streaming chunks
  (tagarela--start-spinner)
  (tagarela-tests--assert
   "spinner stays active after a chunk (streaming does not stop it)"
   (and tagarela--spinner-active
        (timerp tagarela--spinner-timer)
        (string-match-p " \\[[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]\\]"
                        (tagarela--mode-line-status))))
  (tagarela--on-chunk "response")
  (tagarela-tests--assert
   "on-chunk keeps the spinner active (still in turn)"
   (and tagarela--spinner-active
        (timerp tagarela--spinner-timer)))
  ;; turn_end stops it
  (let ((ev (make-hash-table :test 'equal)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "deepseek-chat" ev)
    (puthash "input_tokens" 0 ev)
    (puthash "output_tokens" 0 ev)
    (tagarela--on-turn-end ev))
  (tagarela-tests--assert
   "turn_end stops the spinner and clears the turn"
   (and (not tagarela--spinner-active)
        (not (timerp tagarela--spinner-timer))
        (equal "" (tagarela--mode-line-status))))
  ;; error stops it too
  (tagarela--start-spinner)
  (tagarela--on-error "boom")
  (tagarela-tests--assert
   "error stops the spinner"
   (not tagarela--spinner-active))
  ;; cancelled stops it too
  (tagarela--start-spinner)
  (tagarela--on-cancelled)
  (tagarela-tests--assert
   "cancelled stops the spinner"
   (not tagarela--spinner-active)))

;;; The answer segment is accumulated while streaming.  With
;;; `tagarela-render-markdown-live' off it is rendered once, when it
;;; closes (turn_end / thinking / tool call); with it on it is re-rendered
;;; after every chunk, as it streams.

;; With live rendering off, the segment is only tracked (not rendered) until
;; it closes.
(let ((tagarela-render-markdown-live nil)
      (buf (get-buffer "*llm-bridge*")))
  (with-current-buffer buf
    (let ((inhibit-read-only t)) (erase-buffer)))
  (setq tagarela--answer-start nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil)
  (tagarela--on-chunk "# Hi\n")
  (tagarela-tests--assert
   "streaming (live off): the answer segment is tracked but not rendered yet"
   (and tagarela--answer-start
        (null (get-text-property 1 'display buf))))
  (tagarela--render-answer)
  (tagarela-tests--assert
   "render-answer renders the segment and closes it"
   (and (null tagarela--answer-start)
        (equal "" (get-text-property 1 'display buf))))
  (tagarela-tests--assert
   "rendering the answer does not change the buffer text"
   (equal "# Hi\n"
          (with-current-buffer buf
            (buffer-substring-no-properties (point-min) (point-max))))))

;; With live rendering on, every chunk re-renders the segment as it streams
;; (the segment stays open until it closes).
(let ((tagarela-render-markdown-live t)
      (buf (get-buffer "*llm-bridge*")))
  (with-current-buffer buf
    (let ((inhibit-read-only t)) (erase-buffer)))
  (setq tagarela--answer-start nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil)
  (tagarela--on-chunk "# Hi\n")
  (tagarela-tests--assert
   "streaming (live on): the chunk is rendered right away (segment still open)"
   (and tagarela--answer-start
        (equal "" (get-text-property 1 'display buf))))
  ;; a construct split across two chunks only renders once it is complete
  (tagarela--on-chunk "a **bo")
  (tagarela-tests--assert
   "streaming (live on): an incomplete `**' is left raw"
   (with-current-buffer buf
     (null (get-text-property
            (tagarela-tests--md-pos "**") 'display))))
  (tagarela--on-chunk "ld** b\n")
  (tagarela-tests--assert
   "streaming (live on): the bold renders once the closing `**' arrives"
   (with-current-buffer buf
     (and (eq (tagarela-tests--md-face "bold")
              'tagarela-md-bold-face)
          (equal "" (get-text-property
                     (tagarela-tests--md-pos "**") 'display)))))
  (tagarela-tests--assert
   "streaming (live on): the buffer text is unchanged"
   (equal "# Hi\na **bold** b\n"
          (with-current-buffer buf
            (buffer-substring-no-properties (point-min) (point-max))))))

;; turn_end closes (and renders) the pending answer
(let ((buf (get-buffer "*llm-bridge*"))
      (ev (make-hash-table :test 'equal)))
  (with-current-buffer buf
    (let ((inhibit-read-only t)) (erase-buffer)))
  (setq tagarela--answer-start nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela-session-input-tokens 0
        tagarela-session-output-tokens 0)
  (tagarela--on-chunk "## Sub\n")
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "deepseek-chat" ev)
  (puthash "input_tokens" 1 ev)
  (puthash "output_tokens" 1 ev)
  (tagarela--on-turn-end ev)
  (tagarela-tests--assert
   "turn_end renders the pending answer as markdown (and closes the segment)"
   (and (null tagarela--answer-start)
        (equal "" (get-text-property 1 'display buf))
        (eq (get-text-property 4 'face buf) 'tagarela-md-heading-2-face))))

;; thinking keeps the raw markers
(let ((buf (get-buffer "*llm-bridge*")))
  (with-current-buffer buf
    (let ((start (point-max))
          (tagarela--answer-start nil)
          (tagarela--thinking-separator-pending nil)
          (tagarela--after-tool-separator-pending nil)
          (tagarela-show-thinking t))
      (tagarela--on-thinking "# raw **thinking**\n")
      (tagarela-tests--assert
       "thinking is NOT markdown-rendered (markers kept, thinking face)"
       (and (null (get-text-property start 'display))
            (eq (get-text-property start 'face)
                'tagarela-thinking-face)))))
  (tagarela--stop-spinner))

;;; turn_end scrolls a long answer back to its beginning

;; While streaming the window is glued to the end of the buffer; when the
;; turn ends and the answer is taller than the window, the window is scrolled
;; back so the beginning of the answer is on screen.

(let ((win (selected-window))
      (buf (tagarela--get-buffer)))
  (set-window-buffer win buf)
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert ">>> pergunta\n\n")))
  (setq tagarela--answer-start nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela-show-thinking nil)
  (with-current-buffer buf
    (setq tagarela--turn-answer-start (copy-marker (point-max))))
  (let ((answer-beg (marker-position tagarela--turn-answer-start)))
    (tagarela--on-chunk
     (concat (mapconcat (lambda (i) (format "linha %d" i))
                        (number-sequence 1 80) "\n")
             "\n"))
    (let ((ev (make-hash-table :test 'equal)))
      (puthash "event" "turn_end" ev)
      (puthash "stop_reason" "END_TURN" ev)
      (puthash "model" "deepseek-chat" ev)
      (puthash "input_tokens" 1 ev)
      (puthash "output_tokens" 1 ev)
      (tagarela--on-turn-end ev))
    (tagarela-tests--assert
     "turn_end scrolls a long answer back to its beginning"
     (and (> answer-beg (point-min))
          (= (window-start win) answer-beg)
          (= (window-point win) answer-beg))))

  ;; A short answer (fits in the window) leaves the scroll untouched.
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert ">>> pergunta\n\n")
      (goto-char (point-max))))
  (setq tagarela--answer-start nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil)
  (with-current-buffer buf
    (setq tagarela--turn-answer-start (copy-marker (point-max))))
  (tagarela--on-chunk "resposta curta\n")
  (let ((before (window-start win))
        (ev (make-hash-table :test 'equal)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "deepseek-chat" ev)
    (puthash "input_tokens" 1 ev)
    (puthash "output_tokens" 1 ev)
    (tagarela--on-turn-end ev)
    (tagarela-tests--assert
     "turn_end leaves a short answer's scroll untouched"
     (= (window-start win) before))))

(provide 'tagarela-ui-tests)

;;; tagarela-ui-tests.el ends here
