;;; alonso-client-tests.el --- Tests for the alonso client: JSON protocol, line buffering and the tools.  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Juca Crispim <juca@poraodojuca.dev>
;;
;; This file is part of alonso.
;;
;; alonso is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; alonso is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with alonso.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for the alonso client: JSON protocol, line buffering and the tools.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT: one `ert-deftest' per
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

;;; Provider override in the annotation / prompt params

(ert-deftest alonso-client--annotation-shows-provider ()
  :tags '(client)
  (let ((buf (get-buffer-create "alonso-chat")))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq alonso-request-provider "google"))
          (should (string-match-p "provider=google"
                                  (alonso--request-annotation))))
      (with-current-buffer buf (setq alonso-request-provider "")))))

(ert-deftest alonso-client--prompt-params-include-the-provider ()
  :tags '(client)
  (let ((buf (get-buffer-create "alonso-chat")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq alonso-request-provider "google"
                  alonso-request-model ""
                  alonso-request-thinking 'unset
                  alonso-request-reasoning-effort ""))
          (let ((params (alonso--prompt-params "hi")))
            (should (equal "google" (cadr (member "provider" params))))))
      (with-current-buffer buf (setq alonso-request-provider "")))))

(ert-deftest alonso-client--mode-line-request-shows-thinking-off ()
  :tags '(client)
  (let ((buf (get-buffer-create "alonso-chat")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq alonso-request-thinking 'off
                  alonso-request-reasoning-effort ""))
          (should (string-match-p "thinking=off"
                                  (alonso--mode-line-request))))
      (with-current-buffer buf (setq alonso-request-thinking 'unset)))))

;;; Transport layer — `alonso--send', the sentinel and event dispatch

(defun alonso-client-tests--hash (&rest kv)
  "Build a hash table from KV (alternating key/value pairs)."
  (let ((h (make-hash-table :test 'equal)))
    (cl-loop for (k v) on kv by #'cddr do (puthash k v h))
    h))

(defun alonso-client-tests--event-json (&rest kv)
  "Serialize KV (alternating key/value pairs) into a JSON event string."
  (json-serialize (apply #'alonso-client-tests--hash kv)))

(defun alonso-client-tests--capture-process (fn)
  "Call FN with `make-process' stubbed.
Return (PROC . ARGS): PROC is the fake process object `make-process'
returned and ARGS the arguments it received."
  (let (captured fake)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq captured args)
                 (setq fake (make-pipe-process :name "alonso-fake-proc"
                                               :noquery t)))))
      (funcall fn))
    (cons fake captured)))

;; `alonso--send' serializes the method (and its params) onto the process,
;; followed by a newline.

(ert-deftest alonso-client--send-serializes-method-and-newline ()
  :tags '(client)
  (let (sent)
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_proc s) (setq sent s))))
      (alonso--send "quit" nil))
    (should (and (equal "quit" (alonso-tests--json-get (string-trim sent) "method"))
                 (string-suffix-p "\n" sent)))))

(ert-deftest alonso-client--send-includes-the-params ()
  :tags '(client)
  (let (sent)
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_proc s) (setq sent s))))
      (alonso--send "set_cwd" (list "cwd" "/tmp")))
    (let ((h (json-parse-string (string-trim sent) :object-type 'hash-table)))
      (should (equal "/tmp" (gethash "cwd" (gethash "params" h)))))))

;; The sentinel clears the process state when the bridge exits, but leaves a
;; still-running process alone.

(ert-deftest alonso-client--sentinel-on-exit-clears-state ()
  :tags '(client)
  (let ((alonso-process 'fake) (alonso-ready t) (alonso-in-turn t)
        (alonso-pending-tools '((:id "c1")))
        (alonso--after-tool-separator-pending t)
        reset)
    (cl-letf (((symbol-function 'process-status) (lambda (_p) 'exit))
              ((symbol-function 'alonso--reset-session) (lambda () (setq reset t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (alonso--process-sentinel 'fake "finished"))
    (should (and (null alonso-process) (null alonso-ready)
                 (null alonso-in-turn) (null alonso-pending-tools)
                 (null alonso--after-tool-separator-pending) reset))))

(ert-deftest alonso-client--sentinel-ignores-a-running-process ()
  :tags '(client)
  (let ((alonso-process 'fake) (alonso-ready t))
    (cl-letf (((symbol-function 'process-status) (lambda (_p) 'run))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (alonso--process-sentinel 'fake "running"))
    (should (and (eq 'fake alonso-process) alonso-ready))))

;; `alonso--handle-line' dispatches each event to its UI handler.

(ert-deftest alonso-client--handle-line-dispatches-thinking ()
  :tags '(client)
  (let (got)
    (cl-letf (((symbol-function 'alonso--on-thinking) (lambda (txt) (setq got txt))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "thinking" "text" "t")))
    (should (equal "t" got))))

(ert-deftest alonso-client--handle-line-dispatches-tool-call ()
  :tags '(client)
  (let (got)
    (cl-letf (((symbol-function 'alonso--on-tool-call) (lambda (ev) (setq got ev))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "tool_call" "id" "c1")))
    (should (hash-table-p got))))

(ert-deftest alonso-client--handle-line-dispatches-turn-end ()
  :tags '(client)
  (let (got)
    (cl-letf (((symbol-function 'alonso--on-turn-end) (lambda (ev) (setq got ev))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "turn_end")))
    (should (hash-table-p got))))

(ert-deftest alonso-client--handle-line-dispatches-files-changed ()
  :tags '(client)
  (let (got)
    (cl-letf (((symbol-function 'alonso--on-files-changed) (lambda (ev) (setq got ev))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "files_changed")))
    (should (hash-table-p got))))

(ert-deftest alonso-client--handle-line-dispatches-usage-delta ()
  :tags '(client)
  (let (got)
    (cl-letf (((symbol-function 'alonso--on-usage-delta) (lambda (ev) (setq got ev))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "usage_delta")))
    (should (hash-table-p got))))

(ert-deftest alonso-client--handle-line-dispatches-hook-action ()
  :tags '(client)
  (let (got)
    (cl-letf (((symbol-function 'alonso--on-hook-action) (lambda (ev) (setq got ev))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "hook_action")))
    (should (hash-table-p got))))

(ert-deftest alonso-client--handle-line-dispatches-error ()
  :tags '(client)
  (let (msg)
    (cl-letf (((symbol-function 'alonso--on-error) (lambda (m) (setq msg m))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "error" "message" "boom")))
    (should (equal "boom" msg))))

(ert-deftest alonso-client--handle-line-dispatches-cancelled ()
  :tags '(client)
  (let (called)
    (cl-letf (((symbol-function 'alonso--on-cancelled) (lambda () (setq called t))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "cancelled")))
    (should called)))

(ert-deftest alonso-client--handle-line-unknown-event-warns ()
  :tags '(client)
  (let (warned)
    (cl-letf (((symbol-function 'message) (lambda (&rest _) (setq warned t))))
      (alonso--handle-line (alonso-client-tests--event-json "event" "weird")))
    (should warned)))

;;; Tool-calling loop — `alonso--on-tool-call'

(ert-deftest alonso-client--tool-call-knowledge-is-shown-but-not-pending ()
  :tags '(client)
  (let ((alonso-pending-tools nil) (alonso-confirm-tools t) shown)
    (cl-letf (((symbol-function 'alonso--show-tool-call)
               (lambda (_id name _input) (setq shown name))))
      (alonso--on-tool-call (alonso-client-tests--hash "id" "c1" "name" "knowledge"
                                                       "input" (make-hash-table))))
    (should (and (equal "knowledge" shown) (null alonso-pending-tools)))))

(ert-deftest alonso-client--tool-call-read-only-runs-immediately ()
  :tags '(client)
  (let ((alonso-pending-tools nil) (alonso-confirm-tools t) dispatched)
    (cl-letf (((symbol-function 'alonso--show-tool-call) (lambda (&rest _) nil))
              ((symbol-function 'alonso--dispatch-tool)
               (lambda (name _input id) (setq dispatched (list name id)))))
      (alonso--on-tool-call (alonso-client-tests--hash "id" "c1" "name" "read"
                                                       "input" (make-hash-table))))
    (should (and (equal '("read" "c1") dispatched)
                 (= 1 (length alonso-pending-tools))))))

(ert-deftest alonso-client--tool-call-read-only-error-reported-as-tool-result ()
  :tags '(client)
  (let ((alonso-pending-tools nil) (alonso-confirm-tools t) reported)
    (cl-letf (((symbol-function 'alonso--show-tool-call) (lambda (&rest _) nil))
              ((symbol-function 'alonso--dispatch-tool) (lambda (&rest _) (error "boom")))
              ((symbol-function 'alonso--send-tool-result)
               (lambda (id result status) (setq reported (list id result status)))))
      (alonso--on-tool-call (alonso-client-tests--hash "id" "c1" "name" "read"
                                                       "input" (make-hash-table))))
    (should (equal '("c1" "boom" "error") reported))))

(ert-deftest alonso-client--tool-call-with-confirm-disabled-runs-immediately ()
  :tags '(client)
  (let ((alonso-pending-tools nil) (alonso-confirm-tools nil) dispatched)
    (cl-letf (((symbol-function 'alonso--show-tool-call) (lambda (&rest _) nil))
              ((symbol-function 'alonso--dispatch-tool)
               (lambda (name _input _id) (setq dispatched name))))
      (alonso--on-tool-call (alonso-client-tests--hash "id" "c1" "name" "write"
                                                       "input" (make-hash-table))))
    (should (equal "write" dispatched))))

(ert-deftest alonso-client--tool-call-mutating-is-queued-for-confirmation ()
  :tags '(client)
  (let ((alonso-pending-tools nil) (alonso-confirm-tools t)
        (alonso--confirm-queue nil) scheduled)
    (cl-letf (((symbol-function 'alonso--schedule-confirm)
               (lambda () (setq scheduled t))))
      (alonso--on-tool-call (alonso-client-tests--hash "id" "c1" "name" "write"
                                                       "input" (make-hash-table))))
    (should (and scheduled (= 1 (length alonso--confirm-queue))))))

;;; `alonso--send-tool-result' and `alonso--dispatch-tool'

(ert-deftest alonso-client--send-tool-result-sends-and-clears-pending ()
  :tags '(client)
  (let ((alonso-process 'fake) sent
        (alonso-pending-tools (list (list :id "c1" :name "x" :input nil)))
        (alonso--after-tool-separator-pending nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'alonso--send)
               (lambda (method params) (setq sent (cons method params)))))
      (alonso--send-tool-result "c1" "out" "success"))
    (should (and (equal "tool_result" (car sent))
                 (member "c1" (cdr sent))
                 (null alonso-pending-tools)
                 alonso--after-tool-separator-pending))))

(ert-deftest alonso-client--send-tool-result-without-process-skips-the-send ()
  :tags '(client)
  (let ((alonso-process nil) (alonso-pending-tools nil) sent)
    (cl-letf (((symbol-function 'alonso--send) (lambda (&rest _) (setq sent t))))
      (alonso--send-tool-result "c1" "out" "success"))
    (should (null sent))))

(ert-deftest alonso-client--dispatch-tool-shell-is-async ()
  :tags '(client)
  (let (called)
    (cl-letf (((symbol-function 'alonso--tool-shell-async)
               (lambda (_input _id) (setq called "shell"))))
      (alonso--dispatch-tool "shell" (make-hash-table) "c1"))
    (should (equal "shell" called))))

(ert-deftest alonso-client--dispatch-tool-grep-is-async ()
  :tags '(client)
  (let (called)
    (cl-letf (((symbol-function 'alonso--tool-grep-async)
               (lambda (_input _id) (setq called "grep"))))
      (alonso--dispatch-tool "grep" (make-hash-table) "c1"))
    (should (equal "grep" called))))

(ert-deftest alonso-client--dispatch-tool-default-runs-synchronously ()
  :tags '(client)
  (let (exec reported)
    (cl-letf (((symbol-function 'alonso--execute-tool)
               (lambda (name _input) (setq exec name) "res"))
              ((symbol-function 'alonso--send-tool-result)
               (lambda (id result status) (setq reported (list id result status)))))
      (alonso--dispatch-tool "read" (make-hash-table) "c1"))
    (should (and (equal "read" exec)
                 (equal '("c1" "res" "success") reported)))))

;;; Tool subprocess output filter and cancellation

(ert-deftest alonso-client--tool-proc-filter-accumulates-output ()
  :tags '(client)
  (let ((proc (make-pipe-process :name "alonso-filter-proc" :noquery t)))
    (unwind-protect
        (progn
          (alonso--tool-proc-filter proc "a")
          (alonso--tool-proc-filter proc "b")
          (should (equal "ab" (process-get proc :output))))
      (delete-process proc))))

(ert-deftest alonso-client--kill-tool-procs-kills-live-and-clears ()
  :tags '(client)
  (let* ((proc (make-pipe-process :name "alonso-kill-proc" :noquery t))
         (alonso--tool-procs (list proc)))
    (unwind-protect
        (progn
          (alonso--kill-tool-procs)
          (should (and (process-get proc :cancelled)
                       (null alonso--tool-procs)
                       (not (process-live-p proc)))))
      (ignore-errors (delete-process proc)))))

;;; `alonso--tool-read' — errors and line slices

(ert-deftest alonso-client--tool-read-errors-without-path ()
  :tags '(client)
  (should-error (alonso--tool-read (make-hash-table)) :type 'error))

(ert-deftest alonso-client--tool-read-slice-with-offset-and-limit ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write (alonso--json-plist-to-hash
                         (list "path" f "content" "a\nb\nc\nd\n")))
    (should (equal "b\nc"
                   (alonso--tool-read
                    (alonso--json-plist-to-hash
                     (list "path" f "offset" 1 "limit" 2)))))))

(ert-deftest alonso-client--tool-read-slice-with-offset-only ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write (alonso--json-plist-to-hash
                         (list "path" f "content" "a\nb\nc\nd\n")))
    (should (equal "c\nd\n"
                   (alonso--tool-read
                    (alonso--json-plist-to-hash (list "path" f "offset" 2)))))))

(ert-deftest alonso-client--tool-read-non-number-offset-defaults-to-zero ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write (alonso--json-plist-to-hash
                         (list "path" f "content" "a\nb\nc\nd\n")))
    (should (equal "a"
                   (alonso--tool-read
                    (alonso--json-plist-to-hash
                     (list "path" f "offset" "nope" "limit" 1)))))))

(ert-deftest alonso-client--tool-read-non-number-limit-runs-to-end ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write (alonso--json-plist-to-hash
                         (list "path" f "content" "a\nb\nc\nd\n")))
    (should (equal "b\nc\nd\n"
                   (alonso--tool-read
                    (alonso--json-plist-to-hash
                     (list "path" f "offset" 1 "limit" "nope")))))))

;;; `alonso--tool-write', `alonso--tool-glob' and `alonso--tool-search-replace'

(ert-deftest alonso-client--tool-write-errors-without-content ()
  :tags '(client)
  (should-error (alonso--tool-write
                 (alonso--json-plist-to-hash (list "path" "/tmp/alonso-x")))
                :type 'error))

(ert-deftest alonso-client--tool-glob-errors-without-pattern ()
  :tags '(client)
  (should-error (alonso--tool-glob (make-hash-table)) :type 'error))

(ert-deftest alonso-client--search-replace-errors-with-missing-args ()
  :tags '(client)
  (should-error (alonso--tool-search-replace
                 (alonso--json-plist-to-hash (list "path" "/tmp/alonso-x")))
                :type 'error))

(ert-deftest alonso-client--search-replace-errors-when-not-found ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write (alonso--json-plist-to-hash
                         (list "path" f "content" "hello\n")))
    (should-error (alonso--tool-search-replace
                   (alonso--json-plist-to-hash
                    (list "path" f "search" "zzz" "replace" "y")))
                  :type 'error)))

;;; `alonso--execute-tool' dispatches to each synchronous tool

(ert-deftest alonso-client--execute-tool-read ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write (alonso--json-plist-to-hash (list "path" f "content" "hi")))
    (should (equal "hi" (alonso--execute-tool
                         "read" (alonso--json-plist-to-hash (list "path" f)))))))

(ert-deftest alonso-client--execute-tool-write ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (should (equal "ok"
                   (alonso--execute-tool
                    "write" (alonso--json-plist-to-hash
                             (list "path" f "content" "x")))))))

(ert-deftest alonso-client--execute-tool-glob ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (should (string-match-p
             (regexp-quote f)
             (alonso--execute-tool
              "glob" (alonso--json-plist-to-hash
                      (list "pattern" (concat (file-name-directory f) "*.txt"))))))))

(ert-deftest alonso-client--execute-tool-search-replace ()
  :tags '(client)
  (alonso-client-tests--with-temp-file f
    (alonso--tool-write (alonso--json-plist-to-hash
                         (list "path" f "content" "a b c")))
    (should (equal "ok"
                   (alonso--execute-tool
                    "search_replace"
                    (alonso--json-plist-to-hash
                     (list "path" f "search" "b" "replace" "X")))))))

(ert-deftest alonso-client--execute-tool-unknown-errors ()
  :tags '(client)
  (should-error (alonso--execute-tool "bogus" (make-hash-table)) :type 'error))

;;; `alonso--tool-shell-async' — missing command, command and sentinel

(ert-deftest alonso-client--tool-shell-async-errors-without-command ()
  :tags '(client)
  (should-error (alonso--tool-shell-async (make-hash-table) "c1") :type 'error))

(ert-deftest alonso-client--tool-shell-async-runs-bash-with-the-command ()
  :tags '(client)
  (let ((alonso--tool-procs nil))
    (let* ((res (alonso-client-tests--capture-process
                 (lambda () (alonso--tool-shell-async
                             (alonso-client-tests--hash "command" "echo hi") "c1"))))
           (proc (car res)) (args (cdr res)))
      (unwind-protect
          (should (equal '("bash" "-c" "echo hi") (plist-get args :command)))
        (delete-process proc)))))

(ert-deftest alonso-client--tool-shell-async-sentinel-sends-output ()
  :tags '(client)
  (let ((alonso--tool-procs nil) reported)
    (let* ((res (alonso-client-tests--capture-process
                 (lambda () (alonso--tool-shell-async
                             (alonso-client-tests--hash "command" "echo hi") "c1"))))
           (proc (car res)) (args (cdr res))
           (sentinel (plist-get args :sentinel)))
      (unwind-protect
          (progn
            (process-put proc :output "hi\n")
            (cl-letf (((symbol-function 'process-status) (lambda (_p) 'exit))
                      ((symbol-function 'process-exit-status) (lambda (_p) 0))
                      ((symbol-function 'alonso--send-tool-result)
                       (lambda (id result status) (setq reported (list id result status)))))
              (funcall sentinel proc "finished"))
            (should (equal '("c1" "hi\n" "success") reported)))
        (delete-process proc)))))

(ert-deftest alonso-client--tool-shell-async-sentinel-reports-nonzero-status ()
  :tags '(client)
  (let ((alonso--tool-procs nil) reported)
    (let* ((res (alonso-client-tests--capture-process
                 (lambda () (alonso--tool-shell-async
                             (alonso-client-tests--hash "command" "false") "c1"))))
           (proc (car res)) (args (cdr res))
           (sentinel (plist-get args :sentinel)))
      (unwind-protect
          (progn
            (process-put proc :output "oops")
            (cl-letf (((symbol-function 'process-status) (lambda (_p) 'exit))
                      ((symbol-function 'process-exit-status) (lambda (_p) 3))
                      ((symbol-function 'alonso--send-tool-result)
                       (lambda (_id result _status) (setq reported result))))
              (funcall sentinel proc "finished"))
            (should (equal "oops\n[exited with status 3]" reported)))
        (delete-process proc)))))

(ert-deftest alonso-client--tool-shell-async-sentinel-skips-when-cancelled ()
  :tags '(client)
  (let ((alonso--tool-procs nil) reported)
    (let* ((res (alonso-client-tests--capture-process
                 (lambda () (alonso--tool-shell-async
                             (alonso-client-tests--hash "command" "echo hi") "c1"))))
           (proc (car res)) (args (cdr res))
           (sentinel (plist-get args :sentinel)))
      (unwind-protect
          (progn
            (process-put proc :cancelled t)
            (cl-letf (((symbol-function 'process-status) (lambda (_p) 'exit))
                      ((symbol-function 'alonso--send-tool-result)
                       (lambda (&rest _) (setq reported t))))
              (funcall sentinel proc "finished"))
            (should (null reported)))
        (delete-process proc)))))

;;; `alonso--tool-grep-async' — missing pattern and the exit-status mapping

(ert-deftest alonso-client--tool-grep-async-errors-without-pattern ()
  :tags '(client)
  (should-error (alonso--tool-grep-async (make-hash-table) "c1") :type 'error))

(ert-deftest alonso-client--tool-grep-async-sentinel-status-1-is-success ()
  :tags '(client)
  (let ((alonso--tool-procs nil) reported)
    (let* ((res (alonso-client-tests--capture-process
                 (lambda () (alonso--tool-grep-async
                             (alonso-client-tests--hash "pattern" "x") "c1"))))
           (proc (car res)) (args (cdr res))
           (sentinel (plist-get args :sentinel)))
      (unwind-protect
          (progn
            (process-put proc :output "match\n")
            (cl-letf (((symbol-function 'process-status) (lambda (_p) 'exit))
                      ((symbol-function 'process-exit-status) (lambda (_p) 1))
                      ((symbol-function 'alonso--send-tool-result)
                       (lambda (id result status) (setq reported (list id result status)))))
              (funcall sentinel proc "finished"))
            (should (equal '("c1" "match\n" "success") reported)))
        (delete-process proc)))))

(ert-deftest alonso-client--tool-grep-async-sentinel-status-2-is-error ()
  :tags '(client)
  (let ((alonso--tool-procs nil) reported)
    (let* ((res (alonso-client-tests--capture-process
                 (lambda () (alonso--tool-grep-async
                             (alonso-client-tests--hash "pattern" "x") "c1"))))
           (proc (car res)) (args (cdr res))
           (sentinel (plist-get args :sentinel)))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-status) (lambda (_p) 'exit))
                      ((symbol-function 'process-exit-status) (lambda (_p) 2))
                      ((symbol-function 'alonso--send-tool-result)
                       (lambda (id result status) (setq reported (list id result status)))))
              (funcall sentinel proc "finished"))
            (should (equal '("c1" "" "error") reported)))
        (delete-process proc)))))

;;; `alonso--resolve-command' and the provider startup flag

(ert-deftest alonso-client--resolve-command-expands-a-path ()
  :tags '(client)
  (should (equal (expand-file-name "/usr/bin/llm-bridge")
                 (alonso--resolve-command "/usr/bin/llm-bridge"))))

(ert-deftest alonso-client--resolve-command-keeps-a-bare-name ()
  :tags '(client)
  (should (equal "llm-bridge" (alonso--resolve-command "llm-bridge"))))

(ert-deftest alonso-client--start-args-with-provider ()
  :tags '(client)
  (let ((alonso-provider "google")
        (alonso-model "")
        (alonso-thinking 'unset)
        (alonso-reasoning-effort "")
        (alonso-logfile "")
        (alonso-prune nil)
        (alonso-aggressive-prune nil))
    (should (equal '("-provider" "google") (alonso--start-args)))))

;;; `alonso--start-process' — reuse, spawn and the runtime-lib env override

(ert-deftest alonso-client--start-process-returns-a-live-process ()
  :tags '(client)
  (let ((alonso-process 'existing))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t)))
      (should (eq 'existing (alonso--start-process))))))

(ert-deftest alonso-client--start-process-spawns-and-clears-line-buffer ()
  :tags '(client)
  (let ((old (getenv "LLM_BRIDGE_ONNXRUNTIME_LIB"))
        (alonso-process nil) (alonso-line-buffer "leftover")
        (alonso-onnxruntime-lib "")
        (alonso-command "llm-bridge") (alonso-provider "") (alonso-model "")
        (alonso-thinking 'unset) (alonso-reasoning-effort "")
        (alonso-logfile "") (alonso-prune nil) (alonso-aggressive-prune nil)
        captured)
    (unwind-protect
        (progn
          (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" nil)
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest args) (setq captured args) 'proc)))
            (should (eq 'proc (alonso--start-process))))
          (should (and (equal "" alonso-line-buffer)
                       (equal "llm-bridge" (plist-get captured :name)))))
      (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" old))))

(ert-deftest alonso-client--start-process-sets-and-restores-the-runtime-lib ()
  :tags '(client)
  (let ((old (getenv "LLM_BRIDGE_ONNXRUNTIME_LIB"))
        (alonso-process nil) (alonso-line-buffer "")
        (alonso-onnxruntime-lib "/new/lib.so")
        (alonso-command "llm-bridge") (alonso-provider "") (alonso-model "")
        (alonso-thinking 'unset) (alonso-reasoning-effort "")
        (alonso-logfile "") (alonso-prune nil) (alonso-aggressive-prune nil)
        seen)
    (unwind-protect
        (progn
          (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" "/old/lib.so")
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest _) (setq seen (getenv "LLM_BRIDGE_ONNXRUNTIME_LIB")) 'proc)))
            (alonso--start-process))
          (should (and (equal "/new/lib.so" seen)
                       (equal "/old/lib.so" (getenv "LLM_BRIDGE_ONNXRUNTIME_LIB")))))
      (setenv "LLM_BRIDGE_ONNXRUNTIME_LIB" old))))

;;; `alonso--ensure-ready' — ready, handshake and timeout

(ert-deftest alonso-client--ensure-ready-returns-when-already-ready ()
  :tags '(client)
  (let ((alonso-ready t))
    (should (null (alonso--ensure-ready)))))

(ert-deftest alonso-client--ensure-ready-loops-until-ready ()
  :tags '(client)
  (let ((alonso-ready nil) (alonso-process 'fake))
    (cl-letf (((symbol-function 'alonso--start-process) (lambda () 'fake))
              ((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'accept-process-output)
               (lambda (&rest _) (setq alonso-ready t))))
      (should (null (alonso--ensure-ready))))))

(ert-deftest alonso-client--ensure-ready-errors-when-the-process-dies ()
  :tags '(client)
  (let ((alonso-ready nil) (alonso-process 'fake))
    (cl-letf (((symbol-function 'alonso--start-process) (lambda () 'fake))
              ((symbol-function 'process-live-p) (lambda (_p) nil)))
      (should-error (alonso--ensure-ready) :type 'error))))

;;; `alonso--dispatch-tool-guarded' reports execution errors

(ert-deftest alonso-client--dispatch-tool-guarded-reports-errors ()
  :tags '(client)
  (let (reported)
    (cl-letf (((symbol-function 'alonso--dispatch-tool) (lambda (&rest _) (error "nope")))
              ((symbol-function 'alonso--send-tool-result)
               (lambda (id result status) (setq reported (list id result status)))))
      (alonso--dispatch-tool-guarded "read" (make-hash-table) "c1"))
    (should (equal '("c1" "nope" "error") reported))))

;;; `alonso--trust-record' — recording replaces a previous entry

(ert-deftest alonso-client--trust-record-specific-replaces-a-previous-entry ()
  :tags '(client)
  (let* ((in (alonso-client-tests--hash "command" "ls"))
         (alonso--trust-specific (list (cons "shell" in))))
    (alonso--trust-record 'specific "shell" in)
    (should (= 1 (length alonso--trust-specific)))))

(ert-deftest alonso-client--trust-record-class-replaces-a-previous-entry ()
  :tags '(client)
  (let* ((in (alonso-client-tests--hash "path" "/tmp/alonso/sub/x.el"))
         (alonso--trust-class (list (cons "write" "/tmp/alonso/"))))
    (alonso--trust-record 'class "write" in)
    (should (= 1 (length alonso--trust-class)))))

(provide 'alonso-client-tests)

;;; alonso-client-tests.el ends here
