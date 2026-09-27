;;; tagarela-tests.el --- Tests for tagarela  -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -l ~/mysrc/tagarela/test/tagarela-tests.el
;;
;; Exits with status 0 if all tests pass, 1 otherwise.

;;; Code:

(require 'cl-lib)

(load-file (expand-file-name "../tagarela.el"
                             (file-name-directory load-file-name)))

;; Declare the functions from tagarela.el (loaded at runtime) so the
;; byte-compiler knows them.
(declare-function tagarela--json-object "tagarela")
(declare-function tagarela--json-plist-to-hash "tagarela")
(declare-function tagarela--process-filter "tagarela")
(declare-function tagarela--tool-read "tagarela")
(declare-function tagarela--tool-write "tagarela")
(declare-function tagarela--tool-search-replace "tagarela")
(declare-function tagarela--tool-glob "tagarela")
(declare-function tagarela--tool-read-only-p "tagarela")
(declare-function tagarela--reset-session "tagarela")
(declare-function tagarela--record-tool-confirmation "tagarela")
(declare-function tagarela--keep-question-visible "tagarela")
(declare-function tagarela--show-tool-call "tagarela")
(declare-function tagarela--on-turn-end "tagarela")
(declare-function tagarela--on-hook-action "tagarela")
(declare-function tagarela--on-chunk "tagarela")
(declare-function tagarela--on-thinking "tagarela")
(declare-function tagarela--prompt-send "tagarela")
(declare-function tagarela--hook-send "tagarela")
(declare-function tagarela--mode-line-status "tagarela")
(declare-function tagarela--spinner-tick "tagarela")
(declare-function tagarela--start-spinner "tagarela")
(declare-function tagarela--stop-spinner "tagarela")
(declare-function tagarela--mode-line-session "tagarela")
(declare-function tagarela--setup-input-mode-line "tagarela")
(declare-function tagarela--prompt-params "tagarela")
(declare-function tagarela--request-annotation "tagarela")
(declare-function tagarela--mode-line-request "tagarela")
(declare-function tagarela--start-args "tagarela")
(declare-function tagarela--confirm-question "tagarela")
(declare-function tagarela--tool-icon "tagarela")
(declare-function tagarela--confirm-pending "tagarela")
(declare-function tagarela--confirm-next "tagarela")
(declare-function tagarela--confirm-ask "tagarela")
(declare-function tagarela--confirm-answer "tagarela")
(declare-function tagarela--confirm-trust "tagarela")
(declare-function tagarela--menu-exit-hook "tagarela")
(declare-function tagarela--trust-cancel "tagarela")
(declare-function tagarela--confirm-menu "tagarela")
(declare-function tagarela--confirm-menu-question "tagarela")
(declare-function tagarela--confirm-run "tagarela")
(declare-function tagarela--confirm-deny "tagarela")
(declare-function tagarela--dispatch-tool "tagarela")
(declare-function tagarela--dispatch-tool-guarded "tagarela")
(declare-function tagarela--send-tool-result "tagarela")
(declare-function tagarela--insert-propertized "tagarela")
(declare-function tagarela--ask-user-trust "tagarela")
(declare-function tagarela--trust-class-key "tagarela")
(declare-function tagarela--class-prefix-p "tagarela")
(declare-function tagarela--trusted-p "tagarela")
(declare-function tagarela--trust-record "tagarela")
(declare-function tagarela--trust-pause "tagarela")
(declare-function tagarela--trust-finish "tagarela")
(declare-function tagarela--render-markdown-region "tagarela")
(declare-function tagarela--render-answer "tagarela")
(declare-function tagarela--answer-begin "tagarela")
(defvar tagarela-model)
(defvar tagarela-thinking)
(defvar tagarela-reasoning-effort)
(defvar tagarela-logfile)
(defvar tagarela-aggressive-prune)
(defvar tagarela-prune)
(defvar tagarela-request-model)
(defvar tagarela-request-thinking)
(defvar tagarela-request-reasoning-effort)
(defvar tagarela-ready)
(defvar tagarela--thinking-separator-pending)
(defvar tagarela--after-tool-separator-pending)
(defvar tagarela-line-buffer)
(defvar tagarela-session-input-tokens)
(defvar tagarela-session-output-tokens)
(defvar tagarela-session-cache-hit-tokens)
(defvar tagarela-session-cache-miss-tokens)
(defvar tagarela-session-model)
(defvar tagarela--tool-call-pos)
(defvar tagarela--tool-confirm-pos)
(defvar tagarela--confirm-queue)
(defvar tagarela--confirm-timer)
(defvar tagarela--confirm-context)
(defvar tagarela--trust-specific)
(defvar tagarela--trust-class)
(defvar tagarela--trust-all)
(defvar tagarela--trust-context)
(defvar tagarela--tool-procs)
(defvar tagarela--answer-start)
(defvar tagarela-render-markdown)
(defvar tagarela-hide-markdown-markers)

(defvar tagarela-tests--pass 0)
(defvar tagarela-tests--fail 0)

(defun tagarela-tests--assert (label condition)
  "Report the result of CONDITION under LABEL."
  (if condition
      (progn (setq tagarela-tests--pass (1+ tagarela-tests--pass))
             (princ (format "PASS: %s\n" label)))
    (setq tagarela-tests--fail (1+ tagarela-tests--fail))
    (princ (format "FAIL: %s\n" label))))

;;; JSON serialization

(defun tagarela-tests--json-get (json key)
  "Parse JSON (string) and return the value of KEY."
  (gethash key (json-parse-string json :object-type 'hash-table)))

(defun tagarela-tests--obj (&rest args)
  "Build a JSON object string from ARGS (helper)."
  (apply #'tagarela--json-object args))

(tagarela-tests--assert
 "serializes set_cwd"
 (equal "set_cwd"
        (tagarela-tests--json-get
         (tagarela-tests--obj "method" "set_cwd" "params"
                                    (tagarela--json-plist-to-hash '("cwd" "/tmp")))
         "method")))

(tagarela-tests--assert
 "set_cwd params correct"
 (let ((h (json-parse-string
           (tagarela-tests--obj
            "method" "set_cwd" "params"
            (tagarela--json-plist-to-hash '("cwd" "/tmp")))
           :object-type 'hash-table)))
   (equal "/tmp" (gethash "cwd" (gethash "params" h)))))

(tagarela-tests--assert
 "serializes prompt"
 (equal "prompt"
        (tagarela-tests--json-get
         (tagarela-tests--obj "method" "prompt" "params"
                                    (tagarela--json-plist-to-hash '("text" "hi")))
         "method")))

(tagarela-tests--assert
 "serializes quit (no params)"
 (equal "quit"
        (tagarela-tests--json-get
         (tagarela-tests--obj "method" "quit")
         "method")))

(tagarela-tests--assert
 "serializes tool_result"
 (let ((s (tagarela-tests--obj
           "method" "tool_result" "params"
           (tagarela--json-plist-to-hash
            '("id" "call_1" "result" "ok" "status" "success")))))
   (and (equal "tool_result" (tagarela-tests--json-get s "method"))
        (string-match-p "call_1" s))))

;;; Line buffer (packet fragmentation)

(setq tagarela-ready nil tagarela-line-buffer "")
(tagarela--process-filter nil "{\"even")
(tagarela--process-filter nil "t\":\"ready\"}\n{")
(tagarela--process-filter nil "\"event\":\"chunk\",\"text\":\"hi\"}")

(tagarela-tests--assert
 "ready set with fragmented packets" tagarela-ready)

(tagarela-tests--assert
 "partial line stays in the buffer"
 (equal "{\"event\":\"chunk\",\"text\":\"hi\"}" tagarela-line-buffer))

(tagarela--process-filter nil "\n")

(tagarela-tests--assert
 "line buffer empties at the end"
 (equal "" tagarela-line-buffer))

(tagarela-tests--assert
 "chunk was inserted into the conversation buffer"
 (string-match-p "hi"
                 (with-current-buffer (get-buffer "*llm-bridge*")
                   (buffer-string))))

;;; Tools (file ops)

(let ((dir (make-temp-file "pdj-lb-test" t))
      (f (make-temp-file "pdj-lb-test" nil ".txt")))
  (unwind-protect
      (progn
        ;; write
        (tagarela-tests--assert
         "tool write returns ok"
         (equal "ok"
                (tagarela--tool-write
                 (tagarela--json-plist-to-hash
                  (list "path" f "content" "have a nice day\nsecond line\n")))))
        ;; read
        (tagarela-tests--assert
         "tool read returns the content"
         (equal "have a nice day\nsecond line\n"
                (tagarela--tool-read
                 (tagarela--json-plist-to-hash (list "path" f)))))
        ;; search_replace: only the first occurrence
        (tagarela--tool-search-replace
         (tagarela--json-plist-to-hash
          (list "path" f "search" "a" "replace" "X")))
        (tagarela-tests--assert
         "search_replace changes only the first occurrence"
         (equal "hXve a nice day\nsecond line\n"
                (tagarela--tool-read
                 (tagarela--json-plist-to-hash (list "path" f)))))
        ;; glob
        (tagarela-tests--assert
         "tool glob finds the file"
         (string-match-p (regexp-quote f)
                         (tagarela--tool-glob
                          (tagarela--json-plist-to-hash
                           (list "pattern" (concat (file-name-directory f) "*.txt")))))))
    (ignore-errors (delete-directory dir t))
    (ignore-errors (delete-file f))))

;;; Read-only tools

(tagarela-tests--assert
 "read is read-only" (tagarela--tool-read-only-p "read"))
(tagarela-tests--assert
 "grep is read-only" (tagarela--tool-read-only-p "grep"))
(tagarela-tests--assert
 "glob is read-only" (tagarela--tool-read-only-p "glob"))
(tagarela-tests--assert
 "write is NOT read-only" (not (tagarela--tool-read-only-p "write")))
(tagarela-tests--assert
 "shell is NOT read-only" (not (tagarela--tool-read-only-p "shell")))

;;; grep tool — treats the pattern as a POSIX extended regex (like `grep -E').
;;; Regression: the tool used to pass `-F' (fixed strings), so a regex the
;;; model sent (e.g. "def setup.*:") never matched and it fell back to the
;;; `shell' tool.  The pattern is now an ERE; the model escapes literal
;;; metacharacters.  `-I' skips binary files and `-n' yields file:line:text.
;;; This test stubs `make-process' to capture the exact command the tool
;;; builds and runs.

(let ((captured nil)
      (tagarela--tool-procs nil))
  (cl-letf (((symbol-function 'make-process)
             (lambda (&rest args)
               (setq captured (plist-get args :command))
               ;; return a fake process object so the tool's bookkeeping works
               (make-symbol "fake-grep-proc"))))
    (tagarela--tool-grep-async
     (tagarela--json-plist-to-hash
      (list "pattern" "def setup.*:" "path" "/tmp"))
     "call_grep"))
  (tagarela-tests--assert
   "grep command uses -rnE so the pattern is an ERE (like grep -E)"
   (and captured
        (member "-rnEI" captured)
        (not (member "-rnF" captured)))))

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

;;; Startup flags — model, thinking, reasoning_effort and logfile (--start-args)

(tagarela-tests--assert
 "start-args empty by default"
 (let ((tagarela-model "")
       (tagarela-thinking 'unset)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "")
       (tagarela-prune nil)
       (tagarela-aggressive-prune nil))
   (equal '() (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with -model"
 (let ((tagarela-model "deepseek-reasoner")
       (tagarela-thinking 'unset)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "")
       (tagarela-prune nil)
       (tagarela-aggressive-prune nil))
   (equal '("-model" "deepseek-reasoner")
          (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with -thinking=false"
 (let ((tagarela-model "")
       (tagarela-thinking 'off)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "")
       (tagarela-prune nil)
       (tagarela-aggressive-prune nil))
   (equal '("-thinking=false") (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with -thinking (explicitly on)"
 (let ((tagarela-model "")
       (tagarela-thinking 't)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "")
       (tagarela-prune nil)
       (tagarela-aggressive-prune nil))
   (equal '("-thinking") (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with -reasoning-effort"
 (let ((tagarela-model "")
       (tagarela-thinking 'unset)
       (tagarela-reasoning-effort "high")
       (tagarela-logfile "")
       (tagarela-prune nil)
       (tagarela-aggressive-prune nil))
   (equal '("-reasoning-effort" "high")
          (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with -logfile"
 (let ((tagarela-model "")
       (tagarela-thinking 'unset)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "/tmp/llm-bridge.log")
       (tagarela-prune nil)
       (tagarela-aggressive-prune nil))
   (equal '("-logfile" "/tmp/llm-bridge.log")
          (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with -prune"
 (let ((tagarela-model "")
       (tagarela-thinking 'unset)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "")
       (tagarela-prune t)
       (tagarela-aggressive-prune nil))
   (equal '("-prune") (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with -aggressive-prune"
 (let ((tagarela-model "")
       (tagarela-thinking 'unset)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "")
       (tagarela-prune nil)
       (tagarela-aggressive-prune t))
   (equal '("-aggressive-prune") (tagarela--start-args))))

(tagarela-tests--assert
 "start-args with all flags"
 (let ((tagarela-model "deepseek-reasoner")
       (tagarela-thinking 'off)
       (tagarela-reasoning-effort "high")
       (tagarela-logfile "/tmp/llm-bridge.log")
       (tagarela-prune t)
       (tagarela-aggressive-prune nil))
   (equal '("-model" "deepseek-reasoner"
            "-thinking=false"
            "-reasoning-effort" "high"
            "-logfile" "/tmp/llm-bridge.log"
            "-prune")
          (tagarela--start-args))))

(tagarela-tests--assert
 "prune and aggressive-prune mutual exclusivity via customize-set-variable"
 (let ((tagarela-prune nil)
       (tagarela-aggressive-prune nil))
   (customize-set-variable 'tagarela-prune t)
   (let ((res1 (and tagarela-prune (not tagarela-aggressive-prune))))
     (customize-set-variable 'tagarela-aggressive-prune t)
     (let ((res2 (and tagarela-aggressive-prune (not tagarela-prune))))
       (and res1 res2)))))

(tagarela-tests--assert
 "start-args with aggressive-prune off omits the flag"
 (let ((tagarela-model "")
       (tagarela-thinking 'unset)
       (tagarela-reasoning-effort "")
       (tagarela-logfile "")
       (tagarela-aggressive-prune nil))
   (not (member "-aggressive-prune" (tagarela--start-args)))))

;;; Per-request overrides — model, thinking and reasoning_effort

(defun tagarela-tests--with-req (model thinking effort fn)
  "Run FN with the per-request overrides set to MODEL/THINKING/EFFORT
(buffer-local to the input buffer)."
  (let ((buf (get-buffer-create "*llm-bridge-input*")))
    (with-current-buffer buf
      (setq tagarela-request-model model)
      (setq tagarela-request-thinking thinking)
      (setq tagarela-request-reasoning-effort effort))
    (funcall fn)))

(defun tagarela-tests--prompt-json (&rest _)
  "Build the JSON of a `prompt' from the current request overrides + text \"hi\"."
  (tagarela--json-object
   "method" "prompt" "params"
   (tagarela--json-plist-to-hash
    (tagarela--prompt-params "hi"))))

(tagarela-tests--assert
 "without overrides, prompt sends only the text"
 (tagarela-tests--with-req
  "" 'unset ""
  (lambda ()
    (let ((json (tagarela-tests--prompt-json)))
      (and (string-match-p "\"text\":\"hi\"" json)
           (not (string-match-p "model" json))
           (not (string-match-p "thinking" json))
           (not (string-match-p "reasoning_effort" json)))))))

(tagarela-tests--assert
 "model override enters the prompt"
 (tagarela-tests--with-req
  "deepseek-reasoner" 'unset ""
  (lambda ()
    (let ((json (tagarela-tests--prompt-json)))
      (and (string-match-p "\"model\":\"deepseek-reasoner\"" json)
           (not (string-match-p "thinking" json))
           (not (string-match-p "reasoning_effort" json)))))))

(tagarela-tests--assert
 "thinking=on enters as true in the prompt"
 (tagarela-tests--with-req
  "" 't ""
  (lambda ()
    (let ((json (tagarela-tests--prompt-json)))
      (and (string-match-p "\"thinking\":true" json)
           (not (string-match-p "model" json))
           (not (string-match-p "reasoning_effort" json)))))))

(tagarela-tests--assert
 "thinking=off enters as false in the prompt"
 (tagarela-tests--with-req
  "" 'off ""
  (lambda ()
    (string-match-p "\"thinking\":false"
                    (tagarela-tests--prompt-json)))))

(tagarela-tests--assert
 "reasoning_effort enters the prompt"
 (tagarela-tests--with-req
  "" 'unset "high"
  (lambda ()
    (let ((json (tagarela-tests--prompt-json)))
      (and (string-match-p "\"reasoning_effort\":\"high\"" json)
           (not (string-match-p "model" json))
           (not (string-match-p "thinking" json)))))))

(tagarela-tests--assert
 "all overrides enter together in the prompt"
 (tagarela-tests--with-req
  "deepseek-reasoner" 't "low"
  (lambda ()
    (let ((json (tagarela-tests--prompt-json)))
      (and (string-match-p "\"model\":\"deepseek-reasoner\"" json)
           (string-match-p "\"thinking\":true" json)
           (string-match-p "\"reasoning_effort\":\"low\"" json))))))

(tagarela-tests--assert
 "annotation empty without overrides"
 (tagarela-tests--with-req
  "" 'unset ""
  (lambda () (equal "" (tagarela--request-annotation)))))

(tagarela-tests--assert
 "annotation shows model/thinking/effort"
 (tagarela-tests--with-req
  "deepseek-reasoner" 't "high"
  (lambda ()
    (string-match-p "model=deepseek-reasoner thinking=on effort=high"
                    (tagarela--request-annotation)))))

(tagarela-tests--assert
 "annotation shows thinking=off"
 (tagarela-tests--with-req
  "" 'off ""
  (lambda ()
    (string-match-p "thinking=off"
                    (tagarela--request-annotation)))))

(tagarela-tests--assert
 "mode-line-request empty without overrides"
 (tagarela-tests--with-req
  "" 'unset ""
  (lambda () (equal "" (tagarela--mode-line-request)))))

(tagarela-tests--assert
 "mode-line-request shows the overrides"
 (tagarela-tests--with-req
  "deepseek-reasoner" 't "high"
  (lambda ()
    (string-match-p "model=deepseek-reasoner thinking=on effort=high"
                    (tagarela--mode-line-request)))))

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

;;; Tool confirmation UI — unicode icons and command/pattern/path in blue

(tagarela-tests--assert
 "shell gets a terminal icon"
 (equal "🖥" (tagarela--tool-icon "shell")))
(tagarela-tests--assert
 "grep gets a magnifying glass"
 (equal "🔎" (tagarela--tool-icon "grep")))
(tagarela-tests--assert
 "glob gets a magnifying glass"
 (equal "🔎" (tagarela--tool-icon "glob")))
(tagarela-tests--assert
 "unknown tool falls back to a wrench"
 (equal "🔧" (tagarela--tool-icon "something_else")))

(let ((shell-in (tagarela--json-plist-to-hash (list "command" "ps aux")))
      (pat-in (tagarela--json-plist-to-hash (list "pattern" "TODO")))
      (path-in (tagarela--json-plist-to-hash (list "path" "/tmp/x.el"))))
  (tagarela-tests--assert
   "confirm question for shell shows the command"
   (string-match-p (regexp-quote "🖥 Run tool: shell · ps aux? ")
                   (tagarela--confirm-question "shell" shell-in)))
  (tagarela-tests--assert
   "confirm question for grep shows the pattern"
   (string-match-p (regexp-quote "🔎 Run tool: grep · TODO? ")
                   (tagarela--confirm-question "grep" pat-in)))
  (tagarela-tests--assert
   "confirm question for write shows the path"
   (string-match-p (regexp-quote "✏️ Run tool: write · /tmp/x.el? ")
                   (tagarela--confirm-question "write" path-in)))
  (tagarela-tests--assert
   "confirm question without detail omits the separator"
   (equal "🔧 Run tool: foo? "
          (tagarela--confirm-question "foo" (make-hash-table)))))

;;; Tool confirmation — the question line is shown from the start (before the
;;; parameters/diff) and the `[allowed]' / `[denied]' tag is prepended to the
;;; front of that same line after the user answers

(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max)))
       (ret (tagarela--insert-propertized "test-text\n")))
  (tagarela-tests--assert
   "insert-propertized returns the start position of the text"
   (and (= start ret)
        (string-match-p "test-text"
                        (with-current-buffer buf (buffer-string))))))

;; A search_replace with a large diff: the question line appears *before* the
;; parameters (at the top) and the `[allowed]' tag is prepended to it.
(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max)))
       (sr-input (tagarela--json-plist-to-hash
                  (list "path" "/tmp/x.txt"
                        "search" "aaaa\nbbbb\ncccc\n"
                        "replace" "XXXX\nYYYY\nZZZZ\n")))
       (pos (progn
              (tagarela--show-tool-call "call_1" "search_replace" sr-input)
              (tagarela--record-tool-confirmation "search_replace" sr-input t))))
  (tagarela-tests--assert
   "allowed confirmation is recorded in the buffer (icon + path in blue)"
   (string-match-p
    (regexp-quote "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? ")
    (with-current-buffer buf (buffer-string))))
  (let ((text (with-current-buffer buf
                (buffer-substring-no-properties start (point-max)))))
    (tagarela-tests--assert
     "question is shown before the parameters (top of the tool call)"
     (let ((qpos (string-match
                  (regexp-quote "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? ")
                  text))
           (dpos (string-match (regexp-quote "path: /tmp/x.txt") text)))
       (and qpos dpos (< qpos dpos)))))
  (tagarela-tests--assert
   "question points to the visible confirmation line"
   (equal "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? "
          (with-current-buffer buf
            (buffer-substring-no-properties
             pos (+ pos (length "[allowed] 🔁 Run tool: search_replace · /tmp/x.txt? "))))))
  (tagarela-tests--assert
   "command fragment is propertized in blue"
   (get-text-property
    (+ pos (length "[allowed] 🔁 Run tool: search_replace · ")) 'face buf))
  (tagarela-tests--assert
   "keep-question-visible does not break without a visible window (batch)"
   (progn (tagarela--keep-question-visible pos) t)))

;; No preceding tool call: the confirmation falls back to the end of the buffer.
(let* ((buf (get-buffer "*llm-bridge*"))
       (start (with-current-buffer buf (point-max)))
       (tagarela--tool-call-pos nil)
       (shell-input (tagarela--json-plist-to-hash (list "command" "ps aux")))
       (pos (tagarela--record-tool-confirmation "shell" shell-input nil)))
  (tagarela-tests--assert
   "denied fallback is appended to the buffer"
   (string-match-p "\\[denied\\] "
                   (with-current-buffer buf
                     (buffer-substring-no-properties start (point-max)))))
  (tagarela-tests--assert
   "confirmation recorded at the captured start point (end fallback)"
   (>= pos start))
  (tagarela-tests--assert
   "keep-question-visible does not break without a visible window (batch)"
   (progn (tagarela--keep-question-visible pos) t)))

;;; Batch confirmation — one denied tool refuses the rest without asking and
;;; cancels the turn (the conversation stops waiting for the user's input)

;; A helper that runs `tagarela--confirm-pending' over a queue of N
;; mutating tools with `tagarela--confirm-ask' stubbed to answer
;; synchronously (ANSWERS, one per question asked, in order; 'run / 'deny),
;; `tagarela--send' stubbed to record the method names, and
;; `tagarela--dispatch-tool' stubbed to avoid side effects (no file
;; writes / shell spawns).  Returns a list: the number of questions asked, the
;; recorded send commands and the conversation text inserted during the run.
;; Stubbing `--confirm-ask' (rather than `--ask-user-trust') bypasses the
;; transient menu: the stub applies the answer via `--confirm-answer' exactly
;; like a menu suffix would (via its 0s timer), but synchronously.
(cl-labels
    ((run-batch (queue answers)
       (let ((sent '())
             (asked 0)
             (start (with-current-buffer (get-buffer "*llm-bridge*")
                      (point-max))))
         (cl-letf (((symbol-function 'tagarela--send)
                    (lambda (method &optional _params) (push method sent)))
                   ((symbol-function 'tagarela--confirm-ask)
                    (lambda (&rest _)
                      (tagarela--confirm-answer
                       (prog1 (pop answers) (cl-incf asked)))))
                   ((symbol-function 'tagarela--dispatch-tool)
                    (lambda (_name _input _id)))
                   ;; A denial cancels the turn via `tagarela-cancel',
                   ;; which only sends `cancel' when the bridge process is
                   ;; alive (it does nothing otherwise).  Bind a fake live
                   ;; process so the batch behaves like the real client, where
                   ;; the bridge is running.
                   (tagarela-process (make-symbol "fake-bridge-proc"))
                   ((symbol-function 'process-live-p) (lambda (_p) t))
                   (tagarela--tool-procs nil)
                   (tagarela--trust-specific nil)
                   (tagarela--trust-class nil)
                   (tagarela--trust-all nil))
           (setq tagarela--confirm-queue queue)
           (setq tagarela--confirm-timer nil)
           ;; Anchor every `[denied]'/'[allowed]' recorded by the run to the end
           ;; of the *llm-bridge* buffer (the captured range) so the test can
           ;; count them below.
           (setq tagarela--tool-call-pos
                 (with-current-buffer (get-buffer "*llm-bridge*") (point-max)))
           (tagarela--confirm-pending))
         (list asked (nreverse sent)
               (with-current-buffer (get-buffer "*llm-bridge*")
                 (buffer-substring-no-properties start (point-max)))))))
  ;; 1) Deny the first of three tools: no further questions, every remaining
  ;; tool is auto-denied and the turn is cancelled.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (res (run-batch queue '(deny))))
    (tagarela-tests--assert
     "denying the first tool asks only once (no questions for the rest)"
     (= 1 (car res)))
    (tagarela-tests--assert
     "a denied tool sends cancel to stop the turn"
     (member "cancel" (cadr res)))
    (let ((text (nth 2 res))
          (n 0))
      (let ((from 0))
        (while (string-match "\\[denied\\] " text from)
          (setq from (match-end 0))
          (cl-incf n)))
      (tagarela-tests--assert
       "every tool of the batch shows a [denied] tag, nothing allowed"
       (and (= 3 n)
            (not (string-match-p "\\[allowed\\] " text))))))
  ;; 2) Deny the second of three tools: the first is allowed, the second is
  ;; asked and denied, the third is auto-denied (no question) and the turn is
  ;; cancelled.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (res (run-batch queue '(run deny))))
    (tagarela-tests--assert
     "denying the second tool asks only twice (third auto-denied)"
     (= 2 (car res)))
    (tagarela-tests--assert
     "denying the second tool also cancels the turn"
     (member "cancel" (cadr res))))
  ;; 3) All tools allowed: no cancel, every question asked.
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))))
         (res (run-batch queue '(run run))))
    (tagarela-tests--assert
     "when all tools are allowed, each is asked"
     (= 2 (car res)))
    (tagarela-tests--assert
     "when all tools are allowed, the turn is NOT cancelled"
     (not (member "cancel" (cadr res))))))

;;; One-at-a-time display — each mutating tool call is shown (via
;;; `--show-tool-call') interleaved with its own confirmation question, not all
;;; at once before any question.  So with N tools, the event sequence alternates
;;; show/ask (show/ask ... show) — the questions never pile up on screen.

(cl-labels
    ((run-seq (queue answers)
       (let ((events '())
             (sent '()))
         (cl-letf (((symbol-function 'tagarela--send)
                    (lambda (method &optional _) (push method sent)))
                   ((symbol-function 'tagarela--confirm-ask)
                    (lambda (&rest _)
                      (push 'ask events)
                      (tagarela--confirm-answer (pop answers))))
                   ((symbol-function 'tagarela--show-tool-call)
                    (lambda (&rest _) (push 'show events) nil))
                   ((symbol-function 'tagarela--record-tool-confirmation)
                    (lambda (_n _i _a &optional _t) nil))
                   ((symbol-function 'tagarela--dispatch-tool)
                    (lambda (_n _i _id) nil))
                   (tagarela--trust-specific nil)
                   (tagarela--trust-class nil)
                   (tagarela--trust-all nil))
           (setq tagarela--confirm-queue queue)
           (setq tagarela--confirm-timer nil)
           (tagarela--confirm-pending))
         (nreverse events))))
  ;; Two tools, both allowed: show, ask, show, ask (each tool is displayed
  ;; only right before its own question).
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (events (run-seq queue '(run run))))
    (tagarela-tests--assert
     "two allowed tools: show/ask interleaved (not both shown up front)"
     (equal '(show ask show ask) events)))
  ;; Three tools, first denied: show, ask, show, show (the rest are shown and
  ;; auto-denied one after the other, no further questions).
  (let* ((queue (list (list :id "a" :name "write"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/a" "content" "x")))
                      (list :id "b" :name "search_replace"
                            :input (tagarela--json-plist-to-hash
                                    (list "path" "/tmp/b" "search" "s" "replace" "r")))
                      (list :id "c" :name "shell"
                            :input (tagarela--json-plist-to-hash
                                    (list "command" "echo hi")))))
         (events (run-seq queue '(deny))))
    (tagarela-tests--assert
     "denied first tool: shown+asked first, the rest shown (auto-denied) after"
     (equal '(show ask show show) events))))

;;; Confirmation menu — the question is asked through the transient
;;; `tagarela--confirm-menu' when transient is available, and through the
;;; `read-char-choice' prompt (`tagarela--ask-user-trust') otherwise.
;;; `tagarela--confirm-ask' is the seam that chooses (and that the batch
;;; helpers above stub to answer synchronously).

;; The question shown at the top of the menu is rebuilt from the pending
;; confirmation context (icon + command/pattern/path).
(let ((tagarela--confirm-context
       (list :name "shell"
             :input (tagarela--json-plist-to-hash (list "command" "ps aux")))))
  (tagarela-tests--assert
   "the confirmation menu question shows the tool detail"
   (equal "🖥 Run tool: shell · ps aux? "
          (tagarela--confirm-menu-question))))

;; With the menu available, `--confirm-ask' opens it and does NOT fall back to
;; the minibuffer prompt.
(let ((opened nil))
  (cl-letf (((symbol-function 'tagarela--confirm-menu)
             (lambda () (setq opened t)))
            ((symbol-function 'tagarela--ask-user-trust)
             (lambda (_) (error "should not fall back to the char prompt"))))
    (tagarela--confirm-ask "shell" (make-hash-table)))
  (tagarela-tests--assert
   "confirm-ask opens the transient menu when it is available" opened))

;; Without the menu (transient absent), `--confirm-ask' reads a char and
;; forwards the answer to `--confirm-answer' (the fallback path).
(let ((answer nil))
  (cl-letf (((symbol-function 'tagarela--confirm-menu) nil)
            ((symbol-function 'tagarela--ask-user-trust)
             (lambda (_) 'run))
            ((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (setq answer a))))
    (tagarela--confirm-ask "shell" (make-hash-table)))
  (tagarela-tests--assert
   "confirm-ask falls back to the char prompt and forwards the answer"
   (eq answer 'run)))

;; When transient is available at runtime (not in `emacs -Q --batch'), the
;; confirmation menu and its run/deny/trust suffixes are defined.
(when (fboundp 'transient-define-prefix)
  (tagarela-tests--assert
   "the transient confirmation menu and its suffixes are defined"
   (and (fboundp 'tagarela--confirm-menu)
        (fboundp 'tagarela--confirm-run)
        (fboundp 'tagarela--confirm-deny)
        (fboundp 'tagarela--confirm-trust)
        (fboundp 'tagarela--trust-menu)))
  ;; Wiring of the menu keys.  `t'/`!' must open the Trust sub-menu THROUGH
  ;; `tagarela--confirm-trust' (which routes to
  ;; `tagarela--confirm-answer' -> `--trust-pause'), NOT by binding the
  ;; key straight to `tagarela--trust-menu': the direct binding skipped
  ;; `--trust-pause', so the sub-menu read an empty `--trust-context' and
  ;; dispatched a nil tool call, leaving the turn hanging (regression).
  (setq tagarela--confirm-context
        (list :name "shell" :input (make-hash-table :test 'equal)))
  (tagarela--confirm-menu)
  (let ((key->cmd '()))
    (when (boundp 'transient--suffixes)
      (dolist (s transient--suffixes)
        (push (cons (oref s key) (oref s command)) key->cmd)))
    (tagarela-tests--assert
     "the menu's t key routes the trust choice through --confirm-trust"
     (and (eq 'tagarela--confirm-trust (cdr (assoc "t" key->cmd)))
          (eq 'tagarela--confirm-run (cdr (assoc "r" key->cmd)))
          (eq 'tagarela--confirm-deny (cdr (assoc "d" key->cmd)))))
    (transient--pre-exit)))

;; Regression: the Trust choice (`t' in the menu, `!' in the char-prompt
;; fallback) goes through `tagarela--confirm-answer' with `trust', which
;; calls `--trust-pause' — that is what saves the paused tool call in
;; `tagarela--trust-context'.  The sub-menu then reads a fully populated
;; context (previously it was nil, so the tool was dispatched with nil
;; name/input/id and nothing ran).
(let ((opened 0))
  (setq tagarela--trust-context nil
        tagarela--confirm-context
        (list :name "shell" :id "7"
              :input (tagarela--json-plist-to-hash
                      (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--trust-menu)
             (lambda () (cl-incf opened))))
    (tagarela--confirm-answer 'trust))
  (tagarela-tests--assert
   "confirm-answer 'trust pauses and saves the tool in the trust context"
   (and (= 1 opened)
        (equal "shell" (plist-get tagarela--trust-context :name))
        (equal "7" (plist-get tagarela--trust-context :id))))
  (tagarela-tests--assert
   "confirm-answer consumes the pending confirmation context"
   (null tagarela--confirm-context)))

;; Regression: answering the trust sub-menu dispatches the REAL paused tool
;; (not a nil one), reading name/input/id from `--trust-context'.
(let ((dispatched nil)
      (recorded nil))
  (setq tagarela--trust-context
        (list :name "shell" :id "7"
              :input (tagarela--json-plist-to-hash
                      (list "command" "echo hi"))
              :rest '() :denied nil)
        tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (cl-letf (((symbol-function 'tagarela--dispatch-tool)
             (lambda (name input id) (setq dispatched (list name input id))))
            ((symbol-function 'tagarela--record-tool-confirmation)
             (lambda (&rest args) (push args recorded))))
    (tagarela--trust-finish 'specific))
  (tagarela-tests--assert
   "trust-finish dispatches the paused tool (not a nil one)"
   (and (equal "shell" (car dispatched))
        (equal "7" (nth 2 dispatched))))
  (tagarela-tests--assert
   "trust-finish clears the trust context after resuming"
   (null tagarela--trust-context)))

;;; Closing a menu unanswered (C-g) must not hang the turn
;;
;; The confirmation and trust menus are answered by their suffixes, which set
;; `tagarela--menu-answered' and consume the pending context.  If the
;; menu is merely closed (C-g, or any exit that runs no suffix) nothing is
;; sent to the bridge, so the turn would wait forever.  `--menu-exit-hook'
;; detects the still-pending, unanswered context and applies a deny.

;; confirm closed unanswered -> deny, via `--confirm-answer'
(let ((answered '()))
  (setq tagarela--menu-answered nil
        tagarela--trust-context nil
        tagarela--confirm-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (push a answered)))
            ((symbol-function 'tagarela--trust-cancel)
             (lambda () (push 'trust-cancel answered))))
    (tagarela--menu-exit-hook)
    (sit-for 0.05))
  (tagarela-tests--assert
   "menu closed unanswered denies the pending confirmation"
   (equal '(deny) answered)))

;; answered menu -> the exit hook does nothing
(let ((answered '()))
  (setq tagarela--menu-answered t
        tagarela--trust-context nil
        tagarela--confirm-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (push a answered)))
            ((symbol-function 'tagarela--trust-cancel)
             (lambda () (push 'trust-cancel answered))))
    (tagarela--menu-exit-hook)
    (sit-for 0.05))
  (tagarela-tests--assert
   "an answered menu is not treated as an abort"
   (null answered)))

;; trust sub-menu closed unanswered -> --trust-cancel
(let ((called nil))
  (setq tagarela--menu-answered nil
        tagarela--confirm-context nil
        tagarela--trust-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '() :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-answer)
             (lambda (_a) nil))
            ((symbol-function 'tagarela--trust-cancel)
             (lambda () (setq called t))))
    (tagarela--menu-exit-hook)
    (sit-for 0.05))
  (tagarela-tests--assert
   "trust sub-menu closed unanswered cancels the paused choice"
   called))

;; --trust-cancel denies the paused tool and aborts the batch (rest, denied=t)
(let ((recorded '())
      (next-args nil))
  (setq tagarela--trust-context
        (list :name "shell" :id "1"
              :input (tagarela--json-plist-to-hash (list "command" "echo hi"))
              :rest '(:name "write") :denied nil))
  (cl-letf (((symbol-function 'tagarela--confirm-next)
             (lambda (q d) (setq next-args (list q d))))
            ((symbol-function 'tagarela--record-tool-confirmation)
             (lambda (&rest a) (push a recorded))))
    (tagarela--trust-cancel))
  (tagarela-tests--assert
   "trust-cancel records the paused tool as denied"
   (and (= 1 (length recorded))
        (equal "shell" (car (car recorded)))
        (null (nth 2 (car recorded)))))
  (tagarela-tests--assert
   "trust-cancel continues the batch with the deny cascade"
   (and (null tagarela--trust-context)
        (equal '((:name "write") t) next-args))))

;; --trust-finish is a no-op (no nil-tool dispatch) without a paused context
(let ((dispatched nil))
  (setq tagarela--trust-context nil)
  (cl-letf (((symbol-function 'tagarela--dispatch-tool)
             (lambda (&rest _a) (setq dispatched t))))
    (tagarela--trust-finish 'specific))
  (tagarela-tests--assert
   "trust-finish does nothing when no tool is paused"
   (null dispatched)))

;; char-prompt fallback aborted with C-g -> deny
(let ((ans '()))
  (setq tagarela--confirm-context
        (list :name "shell" :input (make-hash-table :test 'equal)))
  (cl-letf (((symbol-function 'tagarela--confirm-menu) nil)
            ((symbol-function 'tagarela--ask-user-trust)
             (lambda (_p) (signal 'quit nil)))
            ((symbol-function 'tagarela--confirm-answer)
             (lambda (a) (push a ans))))
    (tagarela--confirm-ask "shell" (make-hash-table :test 'equal)))
  (tagarela-tests--assert
   "aborting the char-prompt fallback denies the confirmation"
   (equal '(deny) ans)))

;;; Trust scope — class keys, prefix matching, recording and reset

(tagarela-tests--assert
 "shell class key is the first command token"
 (equal "sed"
        (tagarela--trust-class-key
         "shell" (tagarela--json-plist-to-hash (list "command" "sed -i s/a/b/ f")))))
(tagarela-tests--assert
 "shell class key is nil without a command"
 (null (tagarela--trust-class-key "shell" (make-hash-table))))
(tagarela-tests--assert
 "write class key is the path directory"
 (equal "/tmp/sub/"
        (tagarela--trust-class-key
         "write" (tagarela--json-plist-to-hash (list "path" "/tmp/sub/x.txt" "content" "x")))))
(tagarela-tests--assert
 "search_replace class key is the path directory"
 (equal "/etc/conf/"
        (tagarela--trust-class-key
         "search_replace" (tagarela--json-plist-to-hash (list "path" "/etc/conf/y.txt")))))
(tagarela-tests--assert
 "unknown tools have no class key"
 (null (tagarela--trust-class-key
        "read" (tagarela--json-plist-to-hash (list "path" "/tmp/z.txt")))))

(tagarela-tests--assert
 "shell class matches exactly (not by prefix)"
 (and (tagarela--class-prefix-p "shell" "sed" "sed")
      (not (tagarela--class-prefix-p "shell" "sed" "sedx"))))
(tagarela-tests--assert
 "path class trusts sub-directories"
 (and (tagarela--class-prefix-p "write" "/tmp/" "/tmp/sub/")
      (not (tagarela--class-prefix-p "write" "/tmp/sub/" "/tmp/"))))

(let ((input (tagarela--json-plist-to-hash (list "command" "ls -la /tmp"))))
  (setq tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (tagarela--trust-record 'specific "shell" input)
  (tagarela-tests--assert
   "specific trust matches the exact same input"
   (tagarela--trusted-p "shell" input))
  (tagarela-tests--assert
   "specific trust does not cover a different input"
   (not (tagarela--trusted-p
         "shell"
         (tagarela--json-plist-to-hash (list "command" "ls -la /other"))))))

(let ((input (tagarela--json-plist-to-hash (list "command" "sed s/a/b/ f"))))
  (setq tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (tagarela--trust-record 'class "shell" input)
  (tagarela-tests--assert
   "class trust covers other commands starting with the same token"
   (tagarela--trusted-p
    "shell" (tagarela--json-plist-to-hash (list "command" "sed s/c/d/ g"))))
  (tagarela-tests--assert
   "class trust does not cover a different command token"
   (not (tagarela--trusted-p
         "shell" (tagarela--json-plist-to-hash (list "command" "awk ..."))))))

(let ((in (tagarela--json-plist-to-hash (list "path" "/tmp/x"))))
  (setq tagarela--trust-specific nil
        tagarela--trust-class nil
        tagarela--trust-all nil)
  (tagarela-tests--assert
   "class trust is not recorded without a class key"
   (and (null (tagarela--trust-record 'class "read" in))
        (null tagarela--trust-class))))

(let ((input (tagarela--json-plist-to-hash (list "command" "echo hi"))))
  (setq tagarela--trust-all nil)
  (tagarela--trust-record 'all "shell" input)
  (tagarela-tests--assert
   "all-tool trust makes every call trusted"
   (tagarela--trusted-p
    "shell" (tagarela--json-plist-to-hash (list "command" "anything"))))
  (setq tagarela--trust-all nil))

(let ((in (tagarela--json-plist-to-hash (list "command" "sed x"))))
  (setq tagarela--trust-specific (list (cons "shell" in))
        tagarela--trust-class (list (cons "shell" "sed"))
        tagarela--trust-all t
        tagarela--trust-context (list :name "shell"))
  (tagarela--reset-session)
  (tagarela-tests--assert
   "reset-session clears the trust state"
   (and (null tagarela--trust-specific)
        (null tagarela--trust-class)
        (null tagarela--trust-all)
        (null tagarela--trust-context))))

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

;;; Markdown rendering of the model's answer
;;;
;;; Only the model's *answer* (the streaming `chunk' events) is rendered; the
;;; chain-of-thought and the tool-call lines are left as they are.  The
;;; fragments of an answer segment are accumulated and rendered in one shot
;;; when the segment closes (turn_end / thinking / tool call), so a construct
;;; is never rendered half-written (e.g. between the two `*' of a `**bold**').

(defmacro tagarela-tests--with-rendered (text &rest body)
  "Eval BODY in a temp buffer containing TEXT rendered as Markdown."
  (declare (indent 1) (debug t))
  `(let ((pdj-lb-md-buf (generate-new-buffer " *pdj-lb-md-test*")))
     (unwind-protect
         (with-current-buffer pdj-lb-md-buf
           (insert ,text)
           (tagarela--render-markdown-region (point-min) (point-max))
           ,@body)
       (kill-buffer pdj-lb-md-buf))))

(defun tagarela-tests--md-pos (text)
  "Return the position of the first occurrence of TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward text nil t)
      (match-beginning 0))))

(defun tagarela-tests--md-face (text)
  "Return the `face' property of the first occurrence of TEXT in the buffer."
  (get-text-property (tagarela-tests--md-pos text) 'face))

(defun tagarela-tests--md-display (text)
  "Return the `display' property of the first occurrence of TEXT."
  (get-text-property (tagarela-tests--md-pos text) 'display))

(defun tagarela-tests--md-prop (text prop)
  "Return PROP of the first occurrence of TEXT in the buffer."
  (get-text-property (tagarela-tests--md-pos text) prop))

(defun tagarela-tests--md-faces (text)
  "Return the `face' of the first occurrence of TEXT, always as a list.
A single face is wrapped in a one-element list so tests can use `memq'."
  (let ((f (tagarela-tests--md-face text)))
    (cond ((null f) nil)
          ((listp f) f)
          (t (list f)))))

(tagarela-tests--with-rendered "# Title\n"
  (tagarela-tests--assert
   "markdown: heading gets the level-1 face"
   (eq (tagarela-tests--md-face "Title")
       'tagarela-md-heading-1-face))
  (tagarela-tests--assert
   "markdown: the heading marker is hidden"
   (equal "" (tagarela-tests--md-display "#"))))

(tagarela-tests--with-rendered "### Sub\n"
  (tagarela-tests--assert
   "markdown: level-3 heading face"
   (eq (tagarela-tests--md-face "Sub")
       'tagarela-md-heading-3-face)))

(tagarela-tests--with-rendered "a **bold** b\n"
  (tagarela-tests--assert
   "markdown: bold text is propertized"
   (eq (tagarela-tests--md-face "bold") 'tagarela-md-bold-face))
  (tagarela-tests--assert
   "markdown: the ** markers are hidden"
   (equal "" (tagarela-tests--md-display "**"))))

(tagarela-tests--with-rendered "an *emphatic* word\n"
  (tagarela-tests--assert
   "markdown: italic text is propertized"
   (eq (tagarela-tests--md-face "emphatic")
       'tagarela-md-italic-face))
  (tagarela-tests--assert
   "markdown: the * markers are hidden"
   (equal "" (tagarela-tests--md-display "*"))))

(tagarela-tests--with-rendered "~~gone~~ here\n"
  (tagarela-tests--assert
   "markdown: strikethrough text is propertized"
   (eq (tagarela-tests--md-face "gone")
       'tagarela-md-strike-face)))

(tagarela-tests--with-rendered "use `foo` here\n"
  (tagarela-tests--assert
   "markdown: inline code is propertized"
   (eq (tagarela-tests--md-face "foo")
       'tagarela-md-inline-code-face))
  (tagarela-tests--assert
   "markdown: the backticks are hidden"
   (equal "" (tagarela-tests--md-display "`"))))

(tagarela-tests--with-rendered "see [docs](https://example.com/x)\n"
  (tagarela-tests--assert
   "markdown: the link text is propertized"
   (eq (tagarela-tests--md-face "docs") 'tagarela-md-link-face))
  (tagarela-tests--assert
   "markdown: the link URL is stored as a text property"
   (equal "https://example.com/x"
          (tagarela-tests--md-prop "docs" 'tagarela-url)))
  (tagarela-tests--assert
   "markdown: the link is clickable"
   (keymapp (tagarela-tests--md-prop "docs" 'keymap)))
  (tagarela-tests--assert
   "markdown: the [ marker is hidden"
   (equal "" (tagarela-tests--md-display "[")))
  (tagarela-tests--assert
   "markdown: the URL is shown visibly after the link text"
   (equal " (https://example.com/x)"
          (tagarela-tests--md-display "]("))))

(tagarela-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
  (tagarela-tests--assert
   "markdown: code block content keeps the base code face"
   (memq 'tagarela-md-code-face
         (tagarela-tests--md-faces "(setq x 1)")))
  (tagarela-tests--assert
   "markdown: code block is syntax-highlighted (keyword face on `setq')"
   (memq 'font-lock-keyword-face
         (tagarela-tests--md-faces "setq")))
  (tagarela-tests--assert
   "markdown: the code fences are hidden"
   (equal "" (tagarela-tests--md-display "```"))))

(tagarela-tests--with-rendered "```python\nimport os\n```\n"
  (tagarela-tests--assert
   "markdown: a python code block is syntax-highlighted"
   (memq 'font-lock-keyword-face
         (tagarela-tests--md-faces "import"))))

(let ((tagarela-fontify-code-blocks nil))
  (tagarela-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
    (tagarela-tests--assert
     "markdown: fontification can be disabled (base face only)"
     (equal '(tagarela-md-code-face)
            (tagarela-tests--md-faces "setq")))))

(tagarela-tests--with-rendered "```\n(setq x 1)\n```\n"
  (tagarela-tests--assert
   "markdown: a fence with no language is not fontified (base face only)"
   (equal '(tagarela-md-code-face)
          (tagarela-tests--md-faces "setq"))))

(tagarela-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
  (tagarela-tests--assert
   "markdown: fontifying a code block does not change the buffer text"
   (equal "```elisp\n(setq x 1)\n```\n"
          (buffer-substring-no-properties (point-min) (point-max)))))

(tagarela-tests--with-rendered "- item\n"
  (tagarela-tests--assert
   "markdown: the bullet is replaced by a dot"
   (equal "•" (tagarela-tests--md-display "-"))))

(tagarela-tests--with-rendered "1. item\n"
  (tagarela-tests--assert
   "markdown: the ordered-list number is propertized"
   (eq (tagarela-tests--md-face "1.")
       'tagarela-md-bullet-face)))

(tagarela-tests--with-rendered "---\n"
  (tagarela-tests--assert
   "markdown: a horizontal rule is drawn"
   (string-prefix-p "─" (or (tagarela-tests--md-display "---") ""))))

(tagarela-tests--with-rendered "plain text\n# h\n- l\n"
  (tagarela-tests--assert
   "markdown: rendering never changes the buffer text"
   (equal "plain text\n# h\n- l\n"
          (buffer-substring-no-properties (point-min) (point-max)))))

(tagarela-tests--with-rendered "the keep_alive name\n"
  (tagarela-tests--assert
   "markdown: snake_case is left alone (no `_' italic)"
   (and (null (tagarela-tests--md-face "_"))
        (null (tagarela-tests--md-display "_")))))

(let ((tagarela-render-markdown nil))
  (tagarela-tests--with-rendered "# Title\n"
    (tagarela-tests--assert
     "markdown: rendering can be disabled"
     (and (null (tagarela-tests--md-display "#"))
          (null (tagarela-tests--md-face "Title"))))))

(let ((tagarela-hide-markdown-markers nil))
  (tagarela-tests--with-rendered "a **bold** b\n"
    (tagarela-tests--assert
     "markdown: with hiding off the markers stay visible (dimmed)"
     (and (null (tagarela-tests--md-display "**"))
          (eq (tagarela-tests--md-face "**") 'shadow)))))

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

;;; Summary

(princ (format "\n%d passed, %d failed\n"
               tagarela-tests--pass tagarela-tests--fail))
(when noninteractive
  (kill-emacs (if (zerop tagarela-tests--fail) 0 1)))

;;; tagarela-tests.el ends here
