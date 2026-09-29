;;; alonso-ui-tests.el --- Tests for the alonso UI shell: session/usage, separators, spinner, project, hooks and the answer glue.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso UI shell: session/usage, separators, spinner, project, hooks and the answer glue.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'alonso-tests-lib)

;;; Kill hook registered

(alonso-tests--assert
 "kill-emacs-hook registered" (memq 'alonso-kill kill-emacs-hook))

;;; Session — token accumulation, per-turn summary and input mode-line

(let ((ev (make-hash-table :test 'equal)))
  (alonso--reset-session)
  (dolist (turn '((12 8 100 4) (30 15 900 120)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "deepseek-chat" ev)
    (puthash "input_tokens" (nth 0 turn) ev)
    (puthash "output_tokens" (nth 1 turn) ev)
    (puthash "cache_hit_tokens" (nth 2 turn) ev)
    (puthash "cache_miss_tokens" (nth 3 turn) ev)
    (puthash "total_tokens" (+ (nth 0 turn) (nth 1 turn)) ev)
    (alonso--on-turn-end ev))
  (alonso-tests--assert
   "session accumulates sent/received tokens"
   (and (= 42 alonso-session-input-tokens)
        (= 23 alonso-session-output-tokens)))
  (alonso-tests--assert
   "session accumulates prompt-cache hit/miss tokens"
   (and (= 1000 alonso-session-cache-hit-tokens)
        (= 124 alonso-session-cache-miss-tokens)))
  (alonso-tests--assert
   "session model comes from turn_end"
   (equal "deepseek-chat" alonso-session-model))
  (alonso-tests--assert
   "mode-line shows sent/received/cache/model"
   (string-match-p "↑42 ↓23 ⚡1000/124 deepseek-chat"
                   (alonso--mode-line-session)))
  (alonso-tests--assert
   "turn inserts a summary into the conversation"
   (string-match-p "turn: sent 30, received 15, cache 900/120"
                   (with-current-buffer (get-buffer "*llm-bridge*")
                     (buffer-string))))
  (alonso--reset-session)
  (alonso-tests--assert
   "reset clears the session"
   (and (zerop alonso-session-input-tokens)
        (zerop alonso-session-output-tokens)
        (zerop alonso-session-cache-hit-tokens)
        (zerop alonso-session-cache-miss-tokens)
        (null alonso-session-model))))

;; A provider without prompt cache reports 0 hit / 0 miss: the mode-line must
;; omit the ⚡ fragment entirely (nothing to show).
(let ((ev (make-hash-table :test 'equal)))
  (alonso--reset-session)
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "gemini" ev)
  (puthash "input_tokens" 5 ev)
  (puthash "output_tokens" 3 ev)
  (puthash "cache_hit_tokens" 0 ev)
  (puthash "cache_miss_tokens" 0 ev)
  (alonso--on-turn-end ev)
  (alonso-tests--assert
   "no cache: mode-line omits the ⚡ fragment"
   (and (string-match-p "↑5 ↓3 gemini" (alonso--mode-line-session))
        (not (string-match-p "⚡" (alonso--mode-line-session)))))
  (alonso--reset-session))

;;; Usage delta — incremental updates during turn and final turn_end

(let ((ev (make-hash-table :test 'equal)))
  (alonso--reset-session)
  ;; Simulate intermediate usage_delta
  (puthash "event" "usage_delta" ev)
  (puthash "input_tokens" 10 ev)
  (puthash "output_tokens" 5 ev)
  (puthash "total_tokens" 15 ev)
  (alonso--on-usage-delta ev)
  (alonso-tests--assert
   "usage_delta accumulates session tokens incrementally"
   (and (= 10 alonso-session-input-tokens)
        (= 5 alonso-session-output-tokens)))

  ;; Simulate turn_end with total turn tokens
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "deepseek-chat" ev)
  (puthash "input_tokens" 25 ev)
  (puthash "output_tokens" 12 ev)
  (puthash "total_tokens" 37 ev)
  (alonso--on-turn-end ev)
  (alonso-tests--assert
   "turn_end finalizes session tokens correctly"
   (and (= 25 alonso-session-input-tokens)
        (= 12 alonso-session-output-tokens))))

;;; Regression: first open — the input buffer does not exist yet when the
;;; mode-line setup runs; even so, the token indicator must be installed.

(let ((input (get-buffer "*llm-bridge-input*")))
  (when input (kill-buffer input))
  (alonso--setup-input-mode-line)
  (let ((buf (get-buffer "*llm-bridge-input*")))
    (alonso-tests--assert
     "setup creates the input buffer if missing" buf)
    (alonso-tests--assert
     "setup installs the indicator even on the first open"
     (with-current-buffer buf
       (cl-member '(:eval (alonso--mode-line-session))
                  mode-line-misc-info :test #'equal)))
    ;; idempotency: repeating does not duplicate
    (alonso--setup-input-mode-line)
    (alonso-tests--assert
     "repeated setup does not duplicate the indicator"
     (with-current-buffer buf
       (let ((n 0))
         (dolist (el mode-line-misc-info)
           (when (equal el '(:eval (alonso--mode-line-session)))
             (cl-incf n)))
         (= n 1))))))

;;; Thinking — two-blank-lines separator before the response

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq alonso--thinking-separator-pending nil)
  (alonso--on-thinking "model reasoning")
  (alonso-tests--assert
   "thinking marks the pending separator"
   alonso--thinking-separator-pending)
  (alonso--on-chunk "response")
  (alonso-tests--assert
   "first chunk clears the pending separator"
   (not alonso--thinking-separator-pending))
  (alonso--on-chunk " final")
  (alonso-tests--assert
   "two blank lines between thinking and response"
   (equal "model reasoning\n\n\nresponse final"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq alonso--thinking-separator-pending nil)
  (alonso--on-chunk "direct response")
  (alonso-tests--assert
   "without thinking, the response goes straight (no extra blank lines)"
   (equal "direct response"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

;;; Tool → model: two blank lines between the tool output and the model's
;;; next thinking/response

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq alonso--after-tool-separator-pending nil)
  ;; simulate: tool_call shown and result sent back to the bridge
  (alonso--show-tool-call
   "call_1" "read"
   (alonso--json-plist-to-hash (list "path" "/tmp/x.txt")))
  (alonso--send-tool-result "call_1" "content" "success")
  (alonso-tests--assert
   "tool result marks the pending tool->model separator"
   alonso--after-tool-separator-pending)
  (alonso--on-thinking "post-tool reasoning")
  (alonso-tests--assert
   "thinking consumes the tool->model separator"
   (not alonso--after-tool-separator-pending))
  (alonso--on-chunk "post-tool response")
  (alonso-tests--assert
   "two blank lines between the tool output and the model thinking"
   (equal "\n📄 read\n  path: /tmp/x.txt\n\n\npost-tool reasoning\n\n\npost-tool response"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max))))
  (setq alonso--after-tool-separator-pending nil)
  (alonso--show-tool-call
   "call_2" "glob"
   (alonso--json-plist-to-hash (list "pattern" "*.el")))
  (alonso--send-tool-result "call_2" "a.el" "success")
  (alonso--on-chunk "direct post-tool response")
  (alonso--on-chunk " continues")
  (alonso-tests--assert
   "without thinking, the tool->response separator appears (and only once)"
   (equal "\n🔎 glob\n  pattern: *.el\n\n\ndirect post-tool response continues"
          (with-current-buffer buf
            (buffer-substring-no-properties start (point-max))))))

(let ((ev (make-hash-table :test 'equal)))
  (setq alonso--after-tool-separator-pending t)
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "deepseek-chat" ev)
  (puthash "input_tokens" 0 ev)
  (puthash "output_tokens" 0 ev)
  (alonso--on-turn-end ev)
  (alonso-tests--assert
   "turn_end resets the tool->model separator"
   (not alonso--after-tool-separator-pending)))

;;; Slash command /project

(let ((tmp-dir (expand-file-name (make-temp-file "pdj-proj-test" t))))
  (unwind-protect
      (let* ((captured-cwd nil)
             (vnew (lambda (method params)
                     (alonso-tests--assert
                      "slash command /project sends set_cwd"
                      (equal method "set_cwd"))
                     (setq captured-cwd (cadr (member "cwd" params)))))
             (old (symbol-function 'alonso--send)))
        (unwind-protect
            (progn
              (fset 'alonso--send vnew)
              (alonso-tests--assert
               "slash command /project returns t when handled"
               (alonso--handle-slash-command (format "/project %s" tmp-dir)))
              (alonso-tests--assert
               "slash command /project sends correct cwd path"
               (equal (file-truename tmp-dir) (file-truename captured-cwd))))
          (fset 'alonso--send old)))
    (ignore-errors (delete-directory tmp-dir t))))

;; `/project' argument resolution.  With `alonso-project-dir' non-nil the
;; argument is a project NAME resolved as BASE/NAME; with it nil the argument
;; is a PATH expanded with `expand-file-name'.
(let* ((base (expand-file-name (make-temp-file "alonso-projbase" t)))
       (proj (expand-file-name "tupi" base)))
  (unwind-protect
      (progn
        (make-directory proj)
        (let* ((captured-cwd nil)
               (alonso-project-dir base)
               (old (symbol-function 'alonso--send)))
          (unwind-protect
              (progn
                (fset 'alonso--send
                      (lambda (_m params)
                        (setq captured-cwd (cadr (member "cwd" params)))))
                (alonso-tests--assert
                 "with project-dir: /project NAME is handled"
                 (alonso--handle-slash-command "/project tupi"))
                (alonso-tests--assert
                 "with project-dir: NAME resolves to BASE/NAME"
                 (equal (file-truename proj) (file-truename captured-cwd))))
            (fset 'alonso--send old))))
    (ignore-errors (delete-directory base t))))

;; With `alonso-project-dir' nil the argument is a path relative to
;; `default-directory' (here bound to a temp dir).
(let ((tmp (expand-file-name (make-temp-file "alonso-relproj" t))))
  (unwind-protect
      (progn
        (make-directory (expand-file-name "sub" tmp))
        (let* ((captured-cwd nil)
               (alonso-project-dir nil)
               (default-directory (file-name-as-directory tmp))
               (old (symbol-function 'alonso--send)))
          (unwind-protect
              (progn
                (fset 'alonso--send
                      (lambda (_m params)
                        (setq captured-cwd (cadr (member "cwd" params)))))
                (alonso--handle-slash-command "/project sub")
                (alonso-tests--assert
                 "with project-dir nil: relative path resolves against default-directory"
                 (equal (file-truename (expand-file-name "sub" tmp))
                        (file-truename captured-cwd))))
            (fset 'alonso--send old))))
    (ignore-errors (delete-directory tmp t))))

;; `alonso-project-change-hook' is run with the new project directory.
(let* ((tmp (expand-file-name (make-temp-file "alonso-hookproj" t)))
       (captured nil)
       (old (symbol-function 'alonso--send)))
  (unwind-protect
      (let ((alonso-project-change-hook
             (list (lambda (dir) (setq captured dir)))))
        (unwind-protect
            (progn
              (fset 'alonso--send (lambda (&rest _) nil))
              (alonso--handle-slash-command (format "/project %s" tmp))
              (alonso-tests--assert
               "project-change-hook is run with the new dir"
               (equal (file-truename tmp) (file-truename captured))))
          (fset 'alonso--send old)))
    (ignore-errors (delete-directory tmp t))))

;;; Hooks — a prompt starting with "#" runs a local script (no LLM)

;; The dispatcher routes a `hook_action' event to `--on-hook-action', which
;; inserts the script's output and clears the client-side turn state (there is
;; no `turn_end' for hooks).  Exercised through the process filter so the
;; `hook_action' case in `--handle-line' is covered too.
(setq alonso-line-buffer ""
      alonso-in-turn t)
(alonso--process-filter
 nil (concat "{\"event\":\"hook_action\",\"name\":\"ls\",\"output\":\"a\\nb\"}\n"))
(alonso-tests--assert
 "hook_action output is inserted into the conversation"
 (string-match-p "a\nb"
                 (with-current-buffer (get-buffer "*llm-bridge*")
                   (buffer-string))))
(alonso-tests--assert
 "hook_action clears the in-turn state (no turn_end for hooks)"
 (not alonso-in-turn))

;; `--on-hook-action' with an `error' field (missing script / bad name / bad
;; exit) shows the message in the error face.
(let ((ev (make-hash-table :test 'equal)))
  (puthash "event" "hook_action" ev)
  (puthash "name" "naoexiste" ev)
  (puthash "error" "hook: not found: naoexiste" ev)
  (alonso--on-hook-action ev)
  (alonso-tests--assert
   "hook_action error is shown in the conversation"
   (string-match-p "\\[hook naoexiste\\] error: hook: not found: naoexiste"
                   (with-current-buffer (get-buffer "*llm-bridge*")
                     (buffer-string)))))

;; A prompt whose text starts with "#" goes through the hook path: it echoes the
;; command and sends it as a `prompt' (the bridge decides it is a hook), marking
;; the turn in progress.  A normal prompt is unaffected.
(let ((sent nil)
      (start (with-current-buffer (get-buffer "*llm-bridge*") (point-max))))
  (setq alonso-in-turn nil alonso-pending-tools nil)
  (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ()))
            ((symbol-function 'alonso--send)
             (lambda (method &optional params) (push (cons method params) sent))))
    (alonso--prompt-send "#ls -l"))
  (alonso-tests--assert
   "hook prompt is sent as a prompt command"
   (equal "prompt" (caar sent)))
  (alonso-tests--assert
   "hook prompt carries the # text"
   (string-match-p "#ls -l" (format "%S" (cdar sent))))
  (alonso-tests--assert
   "hook prompt echoes the command in the conversation"
   (string-match-p ">>> #ls -l"
                   (with-current-buffer (get-buffer "*llm-bridge*")
                     (buffer-substring-no-properties start (point-max)))))
  (alonso-tests--assert
   "hook prompt marks the turn in progress"
   alonso-in-turn))

;;; Braille spinner & mode-line status

(let ((alonso-in-turn nil)
      (alonso--spinner-active nil)
      (alonso--spinner-timer nil))
  (alonso-tests--assert
   "mode-line status empty when idle"
   (equal "" (alonso--mode-line-status)))
  (setq alonso-in-turn t)
  (alonso-tests--assert
   "mode-line status shows llm-bridge... when in turn (no spinner)"
   (equal " [llm-bridge…]" (alonso--mode-line-status)))
  (alonso--start-spinner)
  (alonso-tests--assert
   "mode-line status shows braille spinner when active"
   (string-match-p " \\[[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]\\]" (alonso--mode-line-status)))
  ;; spinner stays active (and keeps spinning) across streaming chunks
  (alonso--start-spinner)
  (alonso-tests--assert
   "spinner stays active after a chunk (streaming does not stop it)"
   (and alonso--spinner-active
        (timerp alonso--spinner-timer)
        (string-match-p " \\[[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]\\]"
                        (alonso--mode-line-status))))
  (alonso--on-chunk "response")
  (alonso-tests--assert
   "on-chunk keeps the spinner active (still in turn)"
   (and alonso--spinner-active
        (timerp alonso--spinner-timer)))
  ;; turn_end stops it
  (let ((ev (make-hash-table :test 'equal)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "deepseek-chat" ev)
    (puthash "input_tokens" 0 ev)
    (puthash "output_tokens" 0 ev)
    (alonso--on-turn-end ev))
  (alonso-tests--assert
   "turn_end stops the spinner and clears the turn"
   (and (not alonso--spinner-active)
        (not (timerp alonso--spinner-timer))
        (equal "" (alonso--mode-line-status))))
  ;; error stops it too
  (alonso--start-spinner)
  (alonso--on-error "boom")
  (alonso-tests--assert
   "error stops the spinner"
   (not alonso--spinner-active))
  ;; cancelled stops it too
  (alonso--start-spinner)
  (alonso--on-cancelled)
  (alonso-tests--assert
   "cancelled stops the spinner"
   (not alonso--spinner-active)))

;;; The answer segment is accumulated while streaming.  With
;;; `alonso-render-markdown-live' off it is rendered once, when it
;;; closes (turn_end / thinking / tool call); with it on it is re-rendered
;;; after every chunk, as it streams.

;; With live rendering off, the segment is only tracked (not rendered) until
;; it closes.
(let ((alonso-render-markdown-live nil)
      (buf (get-buffer "*llm-bridge*")))
  (with-current-buffer buf
    (let ((inhibit-read-only t)) (erase-buffer)))
  (setq alonso--answer-start nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil)
  (alonso--on-chunk "# Hi\n")
  (alonso-tests--assert
   "streaming (live off): the answer segment is tracked but not rendered yet"
   (and alonso--answer-start
        (null (get-text-property 1 'display buf))))
  (alonso--render-answer)
  (alonso-tests--assert
   "render-answer renders the segment and closes it"
   (and (null alonso--answer-start)
        (equal "" (get-text-property 1 'display buf))))
  (alonso-tests--assert
   "rendering the answer does not change the buffer text"
   (equal "# Hi\n"
          (with-current-buffer buf
            (buffer-substring-no-properties (point-min) (point-max))))))

;; With live rendering on, every chunk re-renders the segment as it streams
;; (the segment stays open until it closes).
(let ((alonso-render-markdown-live t)
      (buf (get-buffer "*llm-bridge*")))
  (with-current-buffer buf
    (let ((inhibit-read-only t)) (erase-buffer)))
  (setq alonso--answer-start nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil)
  (alonso--on-chunk "# Hi\n")
  (alonso-tests--assert
   "streaming (live on): the chunk is rendered right away (segment still open)"
   (and alonso--answer-start
        (equal "" (get-text-property 1 'display buf))))
  ;; a construct split across two chunks only renders once it is complete
  (alonso--on-chunk "a **bo")
  (alonso-tests--assert
   "streaming (live on): an incomplete `**' is left raw"
   (with-current-buffer buf
     (null (get-text-property
            (alonso-tests--md-pos "**") 'display))))
  (alonso--on-chunk "ld** b\n")
  (alonso-tests--assert
   "streaming (live on): the bold renders once the closing `**' arrives"
   (with-current-buffer buf
     (and (eq (alonso-tests--md-face "bold")
              'alonso-md-bold-face)
          (equal "" (get-text-property
                     (alonso-tests--md-pos "**") 'display)))))
  (alonso-tests--assert
   "streaming (live on): the buffer text is unchanged"
   (equal "# Hi\na **bold** b\n"
          (with-current-buffer buf
            (buffer-substring-no-properties (point-min) (point-max))))))

;; turn_end closes (and renders) the pending answer
(let ((buf (get-buffer "*llm-bridge*"))
      (ev (make-hash-table :test 'equal)))
  (with-current-buffer buf
    (let ((inhibit-read-only t)) (erase-buffer)))
  (setq alonso--answer-start nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil
        alonso-session-input-tokens 0
        alonso-session-output-tokens 0)
  (alonso--on-chunk "## Sub\n")
  (puthash "event" "turn_end" ev)
  (puthash "stop_reason" "END_TURN" ev)
  (puthash "model" "deepseek-chat" ev)
  (puthash "input_tokens" 1 ev)
  (puthash "output_tokens" 1 ev)
  (alonso--on-turn-end ev)
  (alonso-tests--assert
   "turn_end renders the pending answer as markdown (and closes the segment)"
   (and (null alonso--answer-start)
        (equal "" (get-text-property 1 'display buf))
        (eq (get-text-property 4 'face buf) 'alonso-md-heading-2-face))))

;; thinking keeps the raw markers
(let ((buf (get-buffer "*llm-bridge*")))
  (with-current-buffer buf
    (let ((start (point-max))
          (alonso--answer-start nil)
          (alonso--thinking-separator-pending nil)
          (alonso--after-tool-separator-pending nil)
          (alonso-show-thinking t))
      (alonso--on-thinking "# raw **thinking**\n")
      (alonso-tests--assert
       "thinking is NOT markdown-rendered (markers kept, thinking face)"
       (and (null (get-text-property start 'display))
            (eq (get-text-property start 'face)
                'alonso-thinking-face)))))
  (alonso--stop-spinner))

;;; turn_end scrolls a long answer back to its beginning

;; While streaming the window is glued to the end of the buffer; when the
;; turn ends and the answer is taller than the window, the window is scrolled
;; back so the beginning of the answer is on screen.

(let ((win (selected-window))
      (buf (alonso--get-buffer)))
  (set-window-buffer win buf)
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert ">>> pergunta\n\n")))
  (setq alonso--answer-start nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil
        alonso-show-thinking nil)
  (with-current-buffer buf
    (setq alonso--turn-answer-start (copy-marker (point-max))))
  (let ((answer-beg (marker-position alonso--turn-answer-start)))
    (alonso--on-chunk
     (concat (mapconcat (lambda (i) (format "linha %d" i))
                        (number-sequence 1 80) "\n")
             "\n"))
    (let ((ev (make-hash-table :test 'equal)))
      (puthash "event" "turn_end" ev)
      (puthash "stop_reason" "END_TURN" ev)
      (puthash "model" "deepseek-chat" ev)
      (puthash "input_tokens" 1 ev)
      (puthash "output_tokens" 1 ev)
      (alonso--on-turn-end ev))
    (alonso-tests--assert
     "turn_end scrolls a long answer back to its beginning"
     (and (> answer-beg (point-min))
          (= (window-start win) answer-beg)
          (= (window-point win) answer-beg))))

  ;; A short answer (shorter than the window) is scrolled back too, so it is
  ;; shown from its start (with blank space below) instead of glued to the
  ;; bottom of the window.
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert ">>> pergunta\n\n")
      (goto-char (point-max))))
  (setq alonso--answer-start nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil)
  (with-current-buffer buf
    (setq alonso--turn-answer-start (copy-marker (point-max))))
  (alonso--on-chunk "resposta curta\n")
  (let ((answer-beg (marker-position alonso--turn-answer-start))
        (ev (make-hash-table :test 'equal)))
    (puthash "event" "turn_end" ev)
    (puthash "stop_reason" "END_TURN" ev)
    (puthash "model" "deepseek-chat" ev)
    (puthash "input_tokens" 1 ev)
    (puthash "output_tokens" 1 ev)
    (alonso--on-turn-end ev)
    (alonso-tests--assert
     "turn_end scrolls a short answer back to its beginning"
     (and (> answer-beg (point-min))
          (= (window-start win) answer-beg)
          (= (window-point win) answer-beg)))))

;; When a turn is split into several answer segments (answer, thinking,
;; answer), turn_end scrolls back to the *last* segment (the final answer),
;; not to the first one.
(let ((win (selected-window))
      (buf (alonso--get-buffer)))
  (set-window-buffer win buf)
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert ">>> pergunta\n\n")))
  (setq alonso--answer-start nil
        alonso--thinking-separator-pending nil
        alonso--after-tool-separator-pending nil
        alonso-show-thinking nil)
  (with-current-buffer buf
    (setq alonso--turn-answer-start (copy-marker (point-max))))
  ;; first answer segment (long enough to be taller than the window)
  (alonso--on-chunk
   (concat (mapconcat (lambda (i) (format "primeira %d" i))
                      (number-sequence 1 40) "\n")
           "\n"))
  ;; the model goes back to thinking, closing the first segment
  (alonso--on-thinking "pensando...\n")
  (alonso--stop-spinner)
  ;; the final answer segment starts here
  (let ((final-beg (with-current-buffer buf (point-max))))
    (alonso--on-chunk
     (concat (mapconcat (lambda (i) (format "final %d" i))
                        (number-sequence 1 80) "\n")
             "\n"))
    (let ((ev (make-hash-table :test 'equal)))
      (puthash "event" "turn_end" ev)
      (puthash "stop_reason" "END_TURN" ev)
      (puthash "model" "deepseek-chat" ev)
      (puthash "input_tokens" 1 ev)
      (puthash "output_tokens" 1 ev)
      (alonso--on-turn-end ev))
    (alonso-tests--assert
     "turn_end scrolls back to the final answer segment, not the first"
     (and (> final-beg (point-min))
          (= (window-start win) final-beg)
          (= (window-point win) final-beg)))))

(provide 'alonso-ui-tests)

;;; alonso-ui-tests.el ends here
