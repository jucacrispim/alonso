;;; alonso-client-tests.el --- Tests for the alonso client: JSON protocol, line buffering and the tools.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso client: JSON protocol, line buffering and the tools.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'alonso-tests-lib)

;;; JSON serialization

(defun alonso-tests--json-get (json key)
  "Parse JSON (string) and return the value of KEY."
  (gethash key (json-parse-string json :object-type 'hash-table)))

(defun alonso-tests--obj (&rest args)
  "Build a JSON object string from ARGS (helper)."
  (apply #'alonso--json-object args))

(alonso-tests--assert
 "serializes set_cwd"
 (equal "set_cwd"
        (alonso-tests--json-get
         (alonso-tests--obj "method" "set_cwd" "params"
                                    (alonso--json-plist-to-hash '("cwd" "/tmp")))
         "method")))

(alonso-tests--assert
 "set_cwd params correct"
 (let ((h (json-parse-string
           (alonso-tests--obj
            "method" "set_cwd" "params"
            (alonso--json-plist-to-hash '("cwd" "/tmp")))
           :object-type 'hash-table)))
   (equal "/tmp" (gethash "cwd" (gethash "params" h)))))

(alonso-tests--assert
 "serializes prompt"
 (equal "prompt"
        (alonso-tests--json-get
         (alonso-tests--obj "method" "prompt" "params"
                                    (alonso--json-plist-to-hash '("text" "hi")))
         "method")))

(alonso-tests--assert
 "serializes quit (no params)"
 (equal "quit"
        (alonso-tests--json-get
         (alonso-tests--obj "method" "quit")
         "method")))

(alonso-tests--assert
 "serializes tool_result"
 (let ((s (alonso-tests--obj
           "method" "tool_result" "params"
           (alonso--json-plist-to-hash
            '("id" "call_1" "result" "ok" "status" "success")))))
   (and (equal "tool_result" (alonso-tests--json-get s "method"))
        (string-match-p "call_1" s))))

;;; Line buffer (packet fragmentation)

(setq alonso-ready nil alonso-line-buffer "")
(alonso--process-filter nil "{\"even")
(alonso--process-filter nil "t\":\"ready\"}\n{")
(alonso--process-filter nil "\"event\":\"chunk\",\"text\":\"hi\"}")

(alonso-tests--assert
 "ready set with fragmented packets" alonso-ready)

(alonso-tests--assert
 "partial line stays in the buffer"
 (equal "{\"event\":\"chunk\",\"text\":\"hi\"}" alonso-line-buffer))

(alonso--process-filter nil "\n")

(alonso-tests--assert
 "line buffer empties at the end"
 (equal "" alonso-line-buffer))

(alonso-tests--assert
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
        (alonso-tests--assert
         "tool write returns ok"
         (equal "ok"
                (alonso--tool-write
                 (alonso--json-plist-to-hash
                  (list "path" f "content" "have a nice day\nsecond line\n")))))
        ;; read
        (alonso-tests--assert
         "tool read returns the content"
         (equal "have a nice day\nsecond line\n"
                (alonso--tool-read
                 (alonso--json-plist-to-hash (list "path" f)))))
        ;; search_replace: only the first occurrence
        (alonso--tool-search-replace
         (alonso--json-plist-to-hash
          (list "path" f "search" "a" "replace" "X")))
        (alonso-tests--assert
         "search_replace changes only the first occurrence"
         (equal "hXve a nice day\nsecond line\n"
                (alonso--tool-read
                 (alonso--json-plist-to-hash (list "path" f)))))
        ;; glob
        (alonso-tests--assert
         "tool glob finds the file"
         (string-match-p (regexp-quote f)
                         (alonso--tool-glob
                          (alonso--json-plist-to-hash
                           (list "pattern" (concat (file-name-directory f) "*.txt")))))))
    (ignore-errors (delete-directory dir t))
    (ignore-errors (delete-file f))))

;;; Read-only tools

(alonso-tests--assert
 "read is read-only" (alonso--tool-read-only-p "read"))
(alonso-tests--assert
 "grep is read-only" (alonso--tool-read-only-p "grep"))
(alonso-tests--assert
 "glob is read-only" (alonso--tool-read-only-p "glob"))
(alonso-tests--assert
 "write is NOT read-only" (not (alonso--tool-read-only-p "write")))
(alonso-tests--assert
 "shell is NOT read-only" (not (alonso--tool-read-only-p "shell")))

;;; grep tool — treats the pattern as a POSIX extended regex (like `grep -E').
;;; Regression: the tool used to pass `-F' (fixed strings), so a regex the
;;; model sent (e.g. "def setup.*:") never matched and it fell back to the
;;; `shell' tool.  The pattern is now an ERE; the model escapes literal
;;; metacharacters.  `-I' skips binary files and `-n' yields file:line:text.
;;; This test stubs `make-process' to capture the exact command the tool
;;; builds and runs.

(let ((captured nil)
      (alonso--tool-procs nil))
  (cl-letf (((symbol-function 'make-process)
             (lambda (&rest args)
               (setq captured (plist-get args :command))
               ;; return a fake process object so the tool's bookkeeping works
               (make-symbol "fake-grep-proc"))))
    (alonso--tool-grep-async
     (alonso--json-plist-to-hash
      (list "pattern" "def setup.*:" "path" "/tmp"))
     "call_grep"))
  (alonso-tests--assert
   "grep command uses -rnE so the pattern is an ERE (like grep -E)"
   (and captured
        (member "-rnEI" captured)
        (not (member "-rnF" captured)))))

;;; Startup flags — model, thinking, reasoning_effort and logfile (--start-args)

(alonso-tests--assert
 "start-args empty by default"
 (let ((alonso-model "")
       (alonso-thinking 'unset)
       (alonso-reasoning-effort "")
       (alonso-logfile "")
       (alonso-prune nil)
       (alonso-aggressive-prune nil))
   (equal '() (alonso--start-args))))

(alonso-tests--assert
 "start-args with -model"
 (let ((alonso-model "deepseek-reasoner")
       (alonso-thinking 'unset)
       (alonso-reasoning-effort "")
       (alonso-logfile "")
       (alonso-prune nil)
       (alonso-aggressive-prune nil))
   (equal '("-model" "deepseek-reasoner")
          (alonso--start-args))))

(alonso-tests--assert
 "start-args with -thinking=false"
 (let ((alonso-model "")
       (alonso-thinking 'off)
       (alonso-reasoning-effort "")
       (alonso-logfile "")
       (alonso-prune nil)
       (alonso-aggressive-prune nil))
   (equal '("-thinking=false") (alonso--start-args))))

(alonso-tests--assert
 "start-args with -thinking (explicitly on)"
 (let ((alonso-model "")
       (alonso-thinking 't)
       (alonso-reasoning-effort "")
       (alonso-logfile "")
       (alonso-prune nil)
       (alonso-aggressive-prune nil))
   (equal '("-thinking") (alonso--start-args))))

(alonso-tests--assert
 "start-args with -reasoning-effort"
 (let ((alonso-model "")
       (alonso-thinking 'unset)
       (alonso-reasoning-effort "high")
       (alonso-logfile "")
       (alonso-prune nil)
       (alonso-aggressive-prune nil))
   (equal '("-reasoning-effort" "high")
          (alonso--start-args))))

(alonso-tests--assert
 "start-args with -logfile"
 (let ((alonso-model "")
       (alonso-thinking 'unset)
       (alonso-reasoning-effort "")
       (alonso-logfile "/tmp/llm-bridge.log")
       (alonso-prune nil)
       (alonso-aggressive-prune nil))
   (equal '("-logfile" "/tmp/llm-bridge.log")
          (alonso--start-args))))

(alonso-tests--assert
 "start-args with -prune"
 (let ((alonso-model "")
       (alonso-thinking 'unset)
       (alonso-reasoning-effort "")
       (alonso-logfile "")
       (alonso-prune t)
       (alonso-aggressive-prune nil))
   (equal '("-prune") (alonso--start-args))))

(alonso-tests--assert
 "start-args with -aggressive-prune"
 (let ((alonso-model "")
       (alonso-thinking 'unset)
       (alonso-reasoning-effort "")
       (alonso-logfile "")
       (alonso-prune nil)
       (alonso-aggressive-prune t))
   (equal '("-aggressive-prune") (alonso--start-args))))

(alonso-tests--assert
 "start-args with all flags"
 (let ((alonso-model "deepseek-reasoner")
       (alonso-thinking 'off)
       (alonso-reasoning-effort "high")
       (alonso-logfile "/tmp/llm-bridge.log")
       (alonso-prune t)
       (alonso-aggressive-prune nil))
   (equal '("-model" "deepseek-reasoner"
            "-thinking=false"
            "-reasoning-effort" "high"
            "-logfile" "/tmp/llm-bridge.log"
            "-prune")
          (alonso--start-args))))

(alonso-tests--assert
 "prune and aggressive-prune mutual exclusivity via customize-set-variable"
 (let ((alonso-prune nil)
       (alonso-aggressive-prune nil))
   (customize-set-variable 'alonso-prune t)
   (let ((res1 (and alonso-prune (not alonso-aggressive-prune))))
     (customize-set-variable 'alonso-aggressive-prune t)
     (let ((res2 (and alonso-aggressive-prune (not alonso-prune))))
       (and res1 res2)))))

(alonso-tests--assert
 "start-args with aggressive-prune off omits the flag"
 (let ((alonso-model "")
       (alonso-thinking 'unset)
       (alonso-reasoning-effort "")
       (alonso-logfile "")
       (alonso-aggressive-prune nil))
   (not (member "-aggressive-prune" (alonso--start-args)))))

;;; Per-request overrides — model, thinking and reasoning_effort

(defun alonso-tests--with-req (model thinking effort fn)
  "Run FN with the per-request overrides set to MODEL/THINKING/EFFORT
(buffer-local to the input buffer)."
  (let ((buf (get-buffer-create "*llm-bridge-input*")))
    (with-current-buffer buf
      (setq alonso-request-model model)
      (setq alonso-request-thinking thinking)
      (setq alonso-request-reasoning-effort effort))
    (funcall fn)))

(defun alonso-tests--prompt-json (&rest _)
  "Build the JSON of a `prompt' from the current request overrides + text \"hi\"."
  (alonso--json-object
   "method" "prompt" "params"
   (alonso--json-plist-to-hash
    (alonso--prompt-params "hi"))))

(alonso-tests--assert
 "without overrides, prompt sends only the text"
 (alonso-tests--with-req
  "" 'unset ""
  (lambda ()
    (let ((json (alonso-tests--prompt-json)))
      (and (string-match-p "\"text\":\"hi\"" json)
           (not (string-match-p "model" json))
           (not (string-match-p "thinking" json))
           (not (string-match-p "reasoning_effort" json)))))))

(alonso-tests--assert
 "model override enters the prompt"
 (alonso-tests--with-req
  "deepseek-reasoner" 'unset ""
  (lambda ()
    (let ((json (alonso-tests--prompt-json)))
      (and (string-match-p "\"model\":\"deepseek-reasoner\"" json)
           (not (string-match-p "thinking" json))
           (not (string-match-p "reasoning_effort" json)))))))

(alonso-tests--assert
 "thinking=on enters as true in the prompt"
 (alonso-tests--with-req
  "" 't ""
  (lambda ()
    (let ((json (alonso-tests--prompt-json)))
      (and (string-match-p "\"thinking\":true" json)
           (not (string-match-p "model" json))
           (not (string-match-p "reasoning_effort" json)))))))

(alonso-tests--assert
 "thinking=off enters as false in the prompt"
 (alonso-tests--with-req
  "" 'off ""
  (lambda ()
    (string-match-p "\"thinking\":false"
                    (alonso-tests--prompt-json)))))

(alonso-tests--assert
 "reasoning_effort enters the prompt"
 (alonso-tests--with-req
  "" 'unset "high"
  (lambda ()
    (let ((json (alonso-tests--prompt-json)))
      (and (string-match-p "\"reasoning_effort\":\"high\"" json)
           (not (string-match-p "model" json))
           (not (string-match-p "thinking" json)))))))

(alonso-tests--assert
 "all overrides enter together in the prompt"
 (alonso-tests--with-req
  "deepseek-reasoner" 't "low"
  (lambda ()
    (let ((json (alonso-tests--prompt-json)))
      (and (string-match-p "\"model\":\"deepseek-reasoner\"" json)
           (string-match-p "\"thinking\":true" json)
           (string-match-p "\"reasoning_effort\":\"low\"" json))))))

(alonso-tests--assert
 "annotation empty without overrides"
 (alonso-tests--with-req
  "" 'unset ""
  (lambda () (equal "" (alonso--request-annotation)))))

(alonso-tests--assert
 "annotation shows model/thinking/effort"
 (alonso-tests--with-req
  "deepseek-reasoner" 't "high"
  (lambda ()
    (string-match-p "model=deepseek-reasoner thinking=on effort=high"
                    (alonso--request-annotation)))))

(alonso-tests--assert
 "annotation shows thinking=off"
 (alonso-tests--with-req
  "" 'off ""
  (lambda ()
    (string-match-p "thinking=off"
                    (alonso--request-annotation)))))

(alonso-tests--assert
 "mode-line-request empty without overrides"
 (alonso-tests--with-req
  "" 'unset ""
  (lambda () (equal "" (alonso--mode-line-request)))))

(alonso-tests--assert
 "mode-line-request shows the overrides"
 (alonso-tests--with-req
  "deepseek-reasoner" 't "high"
  (lambda ()
    (string-match-p "model=deepseek-reasoner thinking=on effort=high"
                    (alonso--mode-line-request)))))

(provide 'alonso-client-tests)

;;; alonso-client-tests.el ends here
