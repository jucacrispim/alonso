;;; alonso-client-tests.el --- Tests for the alonso client: JSON protocol, line buffering and the tools.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso client: JSON protocol, line buffering and the tools.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT (phase 4 of ERT-MIGRATION.md): one `ert-deftest' per
;; assertion, all tagged `client'.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'ert)
(require 'alonso-tests-lib)

;;; Helpers

(defun alonso-tests--json-get (json key)
  "Parse JSON (string) and return the value of KEY."
  (gethash key (json-parse-string json :object-type 'hash-table)))

(defun alonso-tests--obj (&rest args)
  "Build a JSON object string from ARGS (helper)."
  (apply #'alonso--json-object args))

(defmacro alonso-client-tests--with-temp-file (var &rest body)
  "Bind VAR to a fresh temp .txt file, run BODY, then delete the file."
  (declare (indent 1))
  `(let ((,var (make-temp-file "pdj-lb-test" nil ".txt")))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(defun alonso-client-tests--feed-fragmented-packets ()
  "Feed the ready + partial chunk packets, fragmented across filter calls."
  (setq alonso-ready nil alonso-line-buffer "")
  (alonso--process-filter nil "{\"even")
  (alonso--process-filter nil "t\":\"ready\"}\n{")
  (alonso--process-filter nil "\"event\":\"chunk\",\"text\":\"hi\"}"))

;;; JSON serialization

(ert-deftest alonso-client--json-serializes-set-cwd ()
  :tags '(client)
  (should (equal "set_cwd"
                 (alonso-tests--json-get
                  (alonso-tests--obj "method" "set_cwd" "params"
                                     (alonso--json-plist-to-hash '("cwd" "/tmp")))
                  "method"))))

(ert-deftest alonso-client--json-set-cwd-params-correct ()
  :tags '(client)
  (let ((h (json-parse-string
            (alonso-tests--obj
             "method" "set_cwd" "params"
             (alonso--json-plist-to-hash '("cwd" "/tmp")))
            :object-type 'hash-table)))
    (should (equal "/tmp" (gethash "cwd" (gethash "params" h))))))

(ert-deftest alonso-client--json-serializes-prompt ()
  :tags '(client)
  (should (equal "prompt"
                 (alonso-tests--json-get
                  (alonso-tests--obj "method" "prompt" "params"
                                     (alonso--json-plist-to-hash '("text" "hi")))
                  "method"))))

(ert-deftest alonso-client--json-serializes-quit-without-params ()
  :tags '(client)
  (should (equal "quit"
                 (alonso-tests--json-get
                  (alonso-tests--obj "method" "quit")
                  "method"))))

(ert-deftest alonso-client--json-serializes-tool-result ()
  :tags '(client)
  (let ((s (alonso-tests--obj
            "method" "tool_result" "params"
            (alonso--json-plist-to-hash
             '("id" "call_1" "result" "ok" "status" "success")))))
    (should (and (equal "tool_result" (alonso-tests--json-get s "method"))
                 (string-match-p "call_1" s)))))

;;; Line buffer (packet fragmentation)

(ert-deftest alonso-client--ready-set-with-fragmented-packets ()
  :tags '(client)
  (alonso-client-tests--feed-fragmented-packets)
  (should alonso-ready))

(ert-deftest alonso-client--partial-line-stays-in-buffer ()
  :tags '(client)
  (alonso-client-tests--feed-fragmented-packets)
  (should (equal "{\"event\":\"chunk\",\"text\":\"hi\"}" alonso-line-buffer)))

(ert-deftest alonso-client--line-buffer-empties-at-the-end ()
  :tags '(client)
  (alonso-client-tests--feed-fragmented-packets)
  (alonso--process-filter nil "\n")
  (should (equal "" alonso-line-buffer)))

(ert-deftest alonso-client--chunk-inserted-into-conversation-buffer ()
  :tags '(client)
  (alonso-client-tests--feed-fragmented-packets)
  (alonso--process-filter nil "\n")
  (should (string-match-p "hi"
                          (with-current-buffer (get-buffer "alonso")
                            (buffer-string)))))

;;; Tools (file ops)

(ert-deftest alonso-client--tool-write-returns-ok ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (should (equal "ok"
                   (alonso--tool-write
                    (alonso--json-plist-to-hash
                     (list "path" f "content" "have a nice day\nsecond line\n")))))))

(ert-deftest alonso-client--tool-read-returns-content ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write
     (alonso--json-plist-to-hash
      (list "path" f "content" "have a nice day\nsecond line\n")))
    (should (equal "have a nice day\nsecond line\n"
                   (alonso--tool-read
                    (alonso--json-plist-to-hash (list "path" f)))))))

(ert-deftest alonso-client--search-replace-first-occurrence-only ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write
     (alonso--json-plist-to-hash
      (list "path" f "content" "have a nice day\nsecond line\n")))
    (alonso--tool-search-replace
     (alonso--json-plist-to-hash
      (list "path" f "search" "a" "replace" "X")))
    (should (equal "hXve a nice day\nsecond line\n"
                   (alonso--tool-read
                    (alonso--json-plist-to-hash (list "path" f)))))))

(ert-deftest alonso-client--tool-glob-finds-file ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (should (string-match-p (regexp-quote f)
                            (alonso--tool-glob
                             (alonso--json-plist-to-hash
                              (list "pattern" (concat (file-name-directory f) "*.txt"))))))))

;;; Read-only tools

(ert-deftest alonso-client--read-is-read-only ()
  :tags '(client)
  (should (alonso--tool-read-only-p "read")))

(ert-deftest alonso-client--grep-is-read-only ()
  :tags '(client)
  (should (alonso--tool-read-only-p "grep")))

(ert-deftest alonso-client--glob-is-read-only ()
  :tags '(client)
  (should (alonso--tool-read-only-p "glob")))

(ert-deftest alonso-client--write-is-not-read-only ()
  :tags '(client)
  (should (not (alonso--tool-read-only-p "write"))))

(ert-deftest alonso-client--shell-is-not-read-only ()
  :tags '(client)
  (should (not (alonso--tool-read-only-p "shell"))))

;;; grep tool — treats the pattern as a POSIX extended regex (like `grep -E').
;;; Regression: the tool used to pass `-F' (fixed strings), so a regex the
;;; model sent (e.g. "def setup.*:") never matched and it fell back to the
;;; `shell' tool.  The pattern is now an ERE; the model escapes literal
;;; metacharacters.  `-I' skips binary files and `-n' yields file:line:text.
;;; This test stubs `make-process' to capture the exact command the tool
;;; builds and runs.

(ert-deftest alonso-client--grep-command-uses-ere ()
  :tags '(client)
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
    (should (and captured
                 (member "-rnEI" captured)
                 (not (member "-rnF" captured))))))

;;; Startup flags — model, thinking, reasoning_effort and logfile (--start-args)

(ert-deftest alonso-client--start-args-empty-by-default ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-prune nil)
        (alonso-aggressive-prune nil))
    (should (equal '() (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-model ()
  :tags '(client)
  (let ((alonso-model "deepseek-reasoner")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-prune nil)
        (alonso-aggressive-prune nil))
    (should (equal '("-model" "deepseek-reasoner")
                   (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-thinking-false ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 'off)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-prune nil)
        (alonso-aggressive-prune nil))
    (should (equal '("-thinking=false") (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-thinking-on ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 't)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-prune nil)
        (alonso-aggressive-prune nil))
    (should (equal '("-thinking") (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-reasoning-effort ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "high")
        (alonso-logfile "")
        (alonso-prune nil)
        (alonso-aggressive-prune nil))
    (should (equal '("-reasoning-effort" "high")
                   (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-logfile ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "")
        (alonso-logfile "/tmp/llm-bridge.log")
        (alonso-prune nil)
        (alonso-aggressive-prune nil))
    (should (equal '("-logfile" "/tmp/llm-bridge.log")
                   (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-prune ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-prune t)
        (alonso-aggressive-prune nil))
    (should (equal '("-prune") (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-aggressive-prune ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-prune nil)
        (alonso-aggressive-prune t))
    (should (equal '("-aggressive-prune") (alonso--start-args)))))

(ert-deftest alonso-client--start-args-with-all-flags ()
  :tags '(client)
  (let ((alonso-model "deepseek-reasoner")
        (alonso-thinking 'off)
        (alonso-reasoning-effort "high")
        (alonso-logfile "/tmp/llm-bridge.log")
        (alonso-prune t)
        (alonso-aggressive-prune nil))
    (should (equal '("-model" "deepseek-reasoner"
                     "-thinking=false"
                     "-reasoning-effort" "high"
                     "-logfile" "/tmp/llm-bridge.log"
                     "-prune")
                   (alonso--start-args)))))

(ert-deftest alonso-client--prune-and-aggressive-prune-mutual-exclusivity ()
  :tags '(client)
  (let ((alonso-prune nil)
        (alonso-aggressive-prune nil))
    (customize-set-variable 'alonso-prune t)
    (let ((res1 (and alonso-prune (not alonso-aggressive-prune))))
      (customize-set-variable 'alonso-aggressive-prune t)
      (let ((res2 (and alonso-aggressive-prune (not alonso-prune))))
        (should (and res1 res2))))))

(ert-deftest alonso-client--start-args-with-aggressive-prune-off-omits-flag ()
  :tags '(client)
  (let ((alonso-model "")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-aggressive-prune nil))
    (should (not (member "-aggressive-prune" (alonso--start-args))))))

;;; Per-request overrides — model, thinking and reasoning_effort

(defun alonso-tests--with-req (model thinking effort fn)
  "Run FN with the per-request overrides set to MODEL/THINKING/EFFORT
(buffer-local to the input buffer)."
  (let ((buf (get-buffer-create "alonso-chat")))
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

(ert-deftest alonso-client--prompt-without-overrides-sends-only-text ()
  :tags '(client)
  (alonso-tests--with-req
   "" 'unset ""
   (lambda ()
     (let ((json (alonso-tests--prompt-json)))
       (should (and (string-match-p "\"text\":\"hi\"" json)
                    (not (string-match-p "model" json))
                    (not (string-match-p "thinking" json))
                    (not (string-match-p "reasoning_effort" json))))))))

(ert-deftest alonso-client--model-override-enters-prompt ()
  :tags '(client)
  (alonso-tests--with-req
   "deepseek-reasoner" 'unset ""
   (lambda ()
     (let ((json (alonso-tests--prompt-json)))
       (should (and (string-match-p "\"model\":\"deepseek-reasoner\"" json)
                    (not (string-match-p "thinking" json))
                    (not (string-match-p "reasoning_effort" json))))))))

(ert-deftest alonso-client--thinking-on-enters-as-true ()
  :tags '(client)
  (alonso-tests--with-req
   "" 't ""
   (lambda ()
     (let ((json (alonso-tests--prompt-json)))
       (should (and (string-match-p "\"thinking\":true" json)
                    (not (string-match-p "model" json))
                    (not (string-match-p "reasoning_effort" json))))))))

(ert-deftest alonso-client--thinking-off-enters-as-false ()
  :tags '(client)
  (alonso-tests--with-req
   "" 'off ""
   (lambda ()
     (should (string-match-p "\"thinking\":false"
                             (alonso-tests--prompt-json))))))

(ert-deftest alonso-client--reasoning-effort-enters-prompt ()
  :tags '(client)
  (alonso-tests--with-req
   "" 'unset "high"
   (lambda ()
     (let ((json (alonso-tests--prompt-json)))
       (should (and (string-match-p "\"reasoning_effort\":\"high\"" json)
                    (not (string-match-p "model" json))
                    (not (string-match-p "thinking" json))))))))

(ert-deftest alonso-client--all-overrides-enter-together ()
  :tags '(client)
  (alonso-tests--with-req
   "deepseek-reasoner" 't "low"
   (lambda ()
     (let ((json (alonso-tests--prompt-json)))
       (should (and (string-match-p "\"model\":\"deepseek-reasoner\"" json)
                    (string-match-p "\"thinking\":true" json)
                    (string-match-p "\"reasoning_effort\":\"low\"" json)))))))

(ert-deftest alonso-client--annotation-empty-without-overrides ()
  :tags '(client)
  (alonso-tests--with-req
   "" 'unset ""
   (lambda () (should (equal "" (alonso--request-annotation))))))

(ert-deftest alonso-client--annotation-shows-model-thinking-effort ()
  :tags '(client)
  (alonso-tests--with-req
   "deepseek-reasoner" 't "high"
   (lambda ()
     (should (string-match-p "model=deepseek-reasoner thinking=on effort=high"
                             (alonso--request-annotation))))))

(ert-deftest alonso-client--annotation-shows-thinking-off ()
  :tags '(client)
  (alonso-tests--with-req
   "" 'off ""
   (lambda ()
     (should (string-match-p "thinking=off"
                             (alonso--request-annotation))))))

(ert-deftest alonso-client--mode-line-request-empty-without-overrides ()
  :tags '(client)
  (alonso-tests--with-req
   "" 'unset ""
   (lambda () (should (equal "" (alonso--mode-line-request))))))

(ert-deftest alonso-client--mode-line-request-shows-only-thinking-effort ()
  :tags '(client)
  (alonso-tests--with-req
   "deepseek-reasoner" 't "high"
   (lambda ()
     (let ((s (alonso--mode-line-request)))
       (should (and (string-match-p "thinking=on effort=high" s)
                    (not (string-match-p "model=" s))
                    (not (string-match-p "provider=" s))))))))

(provide 'alonso-client-tests)

;;; alonso-client-tests.el ends here
