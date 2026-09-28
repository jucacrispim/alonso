;;; tagarela-client-tests.el --- Tests for the tagarela client: JSON protocol, line buffering and the tools.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the tagarela client: JSON protocol, line buffering and the tools.
;;
;; Part of the tagarela test suite; `tagarela-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'tagarela-tests-lib)

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

(provide 'tagarela-client-tests)

;;; tagarela-client-tests.el ends here
