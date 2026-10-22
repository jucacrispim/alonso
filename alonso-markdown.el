;;; alonso-markdown.el --- Markdown rendering for alonso  -*- lexical-binding: t; -*-

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

;; Render the model's answer as Markdown in the conversation buffer: the faces,
;; the marker hiding (through the `display' property), the clickable links and
;; the syntax highlighting of fenced code blocks.  Rendering only adds text
;; properties -- the buffer text is never changed, so copying the conversation
;; out is unaffected.
;;
;; This file is self-contained: it never touches the buffer/mode plumbing, it
;; only operates on positions in the current buffer.  The conversation buffer
;; drives it through `alonso--render-markdown-region'.
;;
;; See alonso-ui.el.

;;; Code:

(require 'rx)

;;; Markdown faces (used to render the model's answer)

(defface alonso-md-heading-1-face
  '((t (:inherit font-lock-function-name-face :bold t :height 1.3)))
  "Face for level-1 Markdown headings (`#') in the model's answer."
  :group 'alonso)

(defface alonso-md-heading-2-face
  '((t (:inherit font-lock-function-name-face :bold t :height 1.15)))
  "Face for level-2 Markdown headings (`##') in the model's answer."
  :group 'alonso)

(defface alonso-md-heading-3-face
  '((t (:inherit font-lock-variable-name-face :bold t)))
  "Face for level-3 Markdown headings (`###') in the model's answer."
  :group 'alonso)

(defface alonso-md-heading-4-face
  '((t (:inherit font-lock-keyword-face :bold t)))
  "Face for level 4-6 Markdown headings in the model's answer."
  :group 'alonso)

(defface alonso-md-bold-face
  '((t (:inherit bold)))
  "Face for `**bold**' text in the model's answer."
  :group 'alonso)

(defface alonso-md-italic-face
  '((t (:inherit italic)))
  "Face for `*italic*' text in the model's answer."
  :group 'alonso)

(defface alonso-md-strike-face
  '((t (:inherit shadow :strike-through t)))
  "Face for `~~strikethrough~~' text in the model's answer."
  :group 'alonso)

(defface alonso-md-inline-code-face
  '((t (:inherit font-lock-constant-face)))
  "Face for inline code (between backticks) in the model's answer."
  :group 'alonso)

(defface alonso-md-code-face
  '((t (:inherit default)))
  "Face for fenced code blocks in the model's answer.
By default it inherits `default', so the code matches the conversation's
font (size and family).  See `alonso-md-code-font' to use a different
font family for the code (e.g. a monospaced one)."
  :group 'alonso)

(defface alonso-md-bullet-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for list bullets/numbers in the model's answer."
  :group 'alonso)

(defface alonso-md-quote-face
  '((t (:inherit font-lock-doc-face :italic t)))
  "Face for block quotes (`>') in the model's answer."
  :group 'alonso)

(defface alonso-md-link-face
  '((t (:inherit font-lock-string-face :underline t)))
  "Face for links in the model's answer."
  :group 'alonso)

(defface alonso-md-rule-face
  '((t (:inherit shadow)))
  "Face for horizontal rules (`---') in the model's answer."
  :group 'alonso)

(defface alonso-md-url-face
  '((t (:inherit shadow)))
  "Face for the URL shown right after the text of a Markdown link.
The URL is displayed visibly (e.g. \\\"docs (https://example.com)\\\"),
dimmed so it does not compete with the link text."
  :group 'alonso)

;;; Markdown rendering of the model's answer
;;
;; The answer streams in as `chunk' events.  Rendering every fragment as it
;; arrives would break mid-construct (e.g. between the two `*' of a
;; `**bold**'), so the fragments of an answer segment are accumulated and
;; rendered in one shot when the segment ends: right before the model starts
;; a `thinking' block, before a tool call is shown, and at the end of the
;; turn (`turn_end', `error', `cancelled').  Only the model's *answer* is
;; rendered -- the chain-of-thought and the tool lines are left as they are.
;;
;; Rendering only adds text properties (faces, hidden markers through the
;; `display' property and a clickable keymap on links): the buffer text is
;; never changed, so copying the conversation out is unaffected.

(defcustom alonso-render-markdown t
  "Whether to render the model's answer as Markdown in the conversation.
Only the answer (the streaming `chunk' events) is rendered; the
chain-of-thought and the tool-call lines are left as plain text."
  :type 'boolean
  :group 'alonso)

(defcustom alonso-hide-markdown-markers t
  "Whether to hide the Markdown markers in the rendered answer.
When non-nil the markers (`#', `**', backticks, code fences, list bullets,
...) are hidden through the `display' property, so the answer reads as
formatted text.  When nil the markers stay visible, dimmed in `shadow'.
Has no effect when `alonso-render-markdown' is nil."
  :type 'boolean
  :group 'alonso)

(defcustom alonso-fontify-code-blocks t
  "Whether to syntax-highlight the fenced code blocks in the model's answer.
When non-nil, a fenced code block whose language maps to an available major
mode (see `alonso--md-lang-mode') is fontified with that mode's
syntax highlighting, composed with the base `alonso-md-code-face'
\(the block font is controlled by `alonso-md-code-font').  When nil the
block keeps only
the base face (monospaced, no colors).  Has no effect when
`alonso-render-markdown' is nil."
  :type 'boolean
  :group 'alonso)

(defun alonso--apply-md-code-font ()
  "Apply `alonso-md-code-font' to `alonso-md-code-face'.
When `alonso-md-code-font' is nil the code face has no explicit font
family, so it inherits `default' (the conversation font); otherwise it
uses the given family."
  (set-face-attribute 'alonso-md-code-face nil
                      :family (or alonso-md-code-font 'unspecified)))

(defun alonso--set-md-code-font (_symbol value)
  "Store VALUE in `alonso-md-code-font' and apply it to the code face."
  (set-default 'alonso-md-code-font value)
  (alonso--apply-md-code-font))

(defcustom alonso-md-code-font nil
  "Font family used for the code blocks in the model's answer.
When nil (the default) the code blocks inherit `default', so they use the
same font (family and size) as the rest of the conversation.  When a
string, e.g. \"Monospace\" or \"Inconsolata\", the code blocks use that
font family while keeping the conversation's size.  Affects the fenced
code blocks and their fence lines (see `alonso-md-code-face')."
  :type '(choice (const :tag "Same as the conversation" nil)
                 (string :tag "Font family"))
  :group 'alonso
  :set #'alonso--set-md-code-font)

(defcustom alonso-render-markdown-live t
  "Whether to render the answer as it streams, instead of only at the end.
When non-nil the answer segment accumulated so far is re-rendered after
every streaming `chunk', so the formatting appears while the model is
still writing.  A Markdown construct is only rendered once both of its
markers have arrived (e.g. `**bold**' stays raw until the closing `**'
shows up), because the renderer only matches complete constructs -- so the
answer is never shown with a half-written marker hidden.  Rendering
re-scans the whole segment on every chunk, so a very long answer costs
more (quadratic in the segment length); set this to nil to render each
segment once, when it ends.  Has no effect when
`alonso-render-markdown' is nil."
  :type 'boolean
  :group 'alonso)

(defconst alonso--md-inline-re
  (rx (or (and (group "`" (minimal-match (one-or-more (not (any "`\n")))) "`"))
          (and "[" (group (minimal-match (one-or-more (not (any "]\n"))))) "]("
               (group (minimal-match (one-or-more (not (any ")\n"))))) ")")
          (and (group "**" (minimal-match (one-or-more (not (any "*\n")))) "**"))
          (and (group "~~" (minimal-match (one-or-more (not (any "~\n")))) "~~"))
          (and (group "*" (minimal-match (one-or-more (not (any "*\n")))) "*"))))
  "Regexp matching the inline Markdown constructs the renderer supports.
The groups, in order: 1 inline code, 2 link text, 3 link URL, 4 bold,
5 strikethrough, 6 italic.  A single `_' is deliberately not matched so
snake_case identifiers in plain text are left alone.")

(defvar alonso-link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'alonso-open-link)
    (define-key map [mouse-1] #'alonso--open-link-mouse)
    map)
  "Keymap put on rendered Markdown links (RET / mouse-1 open the URL).")

;;;###autoload
(defun alonso-open-link ()
  "Open in the browser the URL of the Markdown link at point."
  (interactive)
  (let ((url (or (get-text-property (point) 'alonso-url)
                 (get-text-property (max (point-min) (1- (point)))
                                    'alonso-url))))
    (if url
        (browse-url url)
      (user-error "No link at point"))))

(defun alonso--open-link-mouse (event)
  "Open the Markdown link clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (alonso-open-link))

(defun alonso--md-line-end ()
  "Return the end of the current line, extended over its newline (if any)."
  (let ((e (line-end-position)))
    (if (< e (point-max)) (1+ e) e)))

(defun alonso--md-face (start end face)
  "Put FACE on the text between START and END."
  (when (< start end)
    (put-text-property start end 'face face)))

(defun alonso--md-hide (start end)
  "Hide the marker text between START and END, or dim it in `shadow'.
What happens depends on `alonso-hide-markdown-markers'."
  (when (< start end)
    (if alonso-hide-markdown-markers
        (put-text-property start end 'display "")
      (put-text-property start end 'face 'shadow))))

(defun alonso--md-show-url (start end url)
  "Show URL after the link text, replacing the `](url)' tail between START and END.
The tail is replaced (through the `display' property) by \\\" (url)\\\", so the
buffer reads `text (url)' — the URL stays visible, in
`alonso-md-url-face'.  With `alonso-hide-markdown-markers'
nil the raw `](url)' tail is kept instead, dimmed in `shadow'."
  (if alonso-hide-markdown-markers
      (put-text-property start end 'display
                         (concat " ("
                                 (propertize url 'face 'alonso-md-url-face)
                                 ")"))
    (alonso--md-hide start end)))

(defun alonso--md-inline-region (start end)
  "Render the inline Markdown constructs between START and END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward alonso--md-inline-re end t)
      (let ((ms (match-beginning 0))
            (me (match-end 0)))
        (cond
         ((match-beginning 1)           ; `inline code`
          (alonso--md-face ms me 'alonso-md-inline-code-face)
          (alonso--md-hide ms (1+ ms))
          (alonso--md-hide (1- me) me))
         ((match-beginning 2)           ; [text](url)
          (let ((url (match-string-no-properties 3))
                (text-end (match-end 2)))
            (alonso--md-face ms me 'alonso-md-link-face)
            (put-text-property ms me 'mouse-face 'highlight)
            (put-text-property ms me 'keymap alonso-link-keymap)
            (put-text-property ms me 'help-echo url)
            (put-text-property ms me 'alonso-url url)
            (alonso--md-hide ms (1+ ms))     ; the `['
            (alonso--md-show-url text-end me url)))  ; `](url)' -> ` (url)'
         ((match-beginning 4)           ; **bold**
          (alonso--md-face ms me 'alonso-md-bold-face)
          (alonso--md-hide ms (+ ms 2))
          (alonso--md-hide (- me 2) me))
         ((match-beginning 5)           ; ~~strikethrough~~
          (alonso--md-face ms me 'alonso-md-strike-face)
          (alonso--md-hide ms (+ ms 2))
          (alonso--md-hide (- me 2) me))
         ((match-beginning 6)           ; *italic*
          (alonso--md-face ms me 'alonso-md-italic-face)
          (alonso--md-hide ms (1+ ms))
          (alonso--md-hide (1- me) me)))))))

(defun alonso--md-normal-line (line-start line-end)
  "Render one non-code Markdown line between LINE-START and LINE-END."
  (goto-char line-start)
  (cond
   ;; horizontal rule
   ((looking-at "[ \t]*\\(---\\|___\\|\\*\\*\\*\\)[ \t]*$")
    (alonso--md-face line-start line-end 'alonso-md-rule-face)
    (when alonso-hide-markdown-markers
      (put-text-property line-start line-end
                         'display "────────────────────────")))
   ;; heading
   ((looking-at "[ \t]*\\(#\\{1,6\\}\\)[ \t]+\\(.+\\)$")
    (let ((level (length (match-string 1)))
          (body-start (match-beginning 2)))
      (alonso--md-face line-start line-end
                               (pcase level
                                 (1 'alonso-md-heading-1-face)
                                 (2 'alonso-md-heading-2-face)
                                 (3 'alonso-md-heading-3-face)
                                 (_ 'alonso-md-heading-4-face)))
      (alonso--md-hide line-start body-start)
      (alonso--md-inline-region body-start line-end)))
   ;; block quote
   ((looking-at "[ \t]*>+ ?")
    (alonso--md-face line-start line-end 'alonso-md-quote-face)
    (alonso--md-hide line-start (match-end 0))
    (alonso--md-inline-region (match-end 0) line-end))
   ;; unordered list item
   ((looking-at "[ \t]*\\([-*+]\\)[ \t]+")
    (alonso--md-face (match-beginning 1) (match-end 1)
                             'alonso-md-bullet-face)
    (when alonso-hide-markdown-markers
      (put-text-property (match-beginning 1) (match-end 1) 'display "•"))
    (alonso--md-inline-region (match-end 0) line-end))
   ;; ordered list item
   ((looking-at "[ \t]*\\([0-9]+\\.\\)[ \t]+")
    (alonso--md-face (match-beginning 1) (match-end 1)
                             'alonso-md-bullet-face)
    (alonso--md-inline-region (match-end 0) line-end))
   (t
    (alonso--md-inline-region line-start line-end))))

(defun alonso--md-fence-line (line-start line-end)
  "Handle a ``` fence line: hide it as a marker (or dim it as code).
LINE-START and LINE-END delimit the fence line in the current buffer."
  (if alonso-hide-markdown-markers
      (put-text-property line-start (alonso--md-line-end) 'display "")
    (alonso--md-face line-start line-end 'alonso-md-code-face)))

(defvar alonso--md-lang-mode
  '(("elisp" . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode)
    ("lisp" . emacs-lisp-mode)
    ("python" . python-mode)
    ("py" . python-mode)
    ("go" . go-mode)
    ("golang" . go-mode)
    ("javascript" . js-mode)
    ("js" . js-mode)
    ("jsx" . js-mode)
    ("json" . js-json-mode)
    ("sh" . sh-mode)
    ("bash" . sh-mode)
    ("shell" . sh-mode)
    ("zsh" . sh-mode)
    ("yaml" . yaml-mode)
    ("yml" . yaml-mode)
    ("c" . c-mode)
    ("c++" . c++-mode)
    ("cpp" . c++-mode)
    ("rust" . rust-mode)
    ("html" . html-mode)
    ("css" . css-mode)
    ("sql" . sql-mode)
    ("make" . makefile-gmake-mode)
    ("makefile" . makefile-gmake-mode)
    ("diff" . diff-mode)
    ("org" . org-mode)
    ("dockerfile" . dockerfile-mode))
  "Alist mapping a code-fence language to the major mode used to fontify it.
Used by `alonso--md-highlight-code'.  A language with no entry here
\(or whose mode is unavailable) keeps only the base
`alonso-md-code-face' (monospaced, no colors).")

(defun alonso--md-fence-lang ()
  "Return the language of the code fence on the current line, or nil.
E.g. the line \"```python\" yields \"python\"."
  (when (looking-at "[ \t]*```[ \t]*\\([^ \t\n]+\\)")
    (match-string-no-properties 1)))

(defun alonso--md-highlight-code (start end lang)
  "Fontify the code between START and END in the conversation buffer as LANG.
The region is copied into a temporary buffer, the major mode mapped from
LANG (see `alonso--md-lang-mode') is turned on and font-locked, and
the resulting faces are copied back, composed with the base
`alonso-md-code-face' (the syntax face first, so it wins the foreground;
the base face last, so the block keeps the code font).  Only `face' text
properties are added -- the buffer text is never changed.  Does
nothing when `alonso-fontify-code-blocks' is nil, LANG is unknown or
its mode is unavailable."
  (when (and alonso-fontify-code-blocks lang (> end start))
    (let ((mode (cdr (assoc (downcase lang) alonso--md-lang-mode))))
      (when (and mode (fboundp mode))
        (let ((conv (current-buffer))
              (code (buffer-substring-no-properties start end))
              (runs nil))
          (with-temp-buffer
            (insert code)
            (delay-mode-hooks (funcall mode))
            (unless font-lock-mode (font-lock-mode 1))
            (font-lock-ensure (point-min) (point-max))
            (let ((p (point-min))
                  (max (point-max)))
              (while (< p max)
                (let ((next (next-single-property-change p 'face nil max))
                      (fl (get-text-property p 'face)))
                  (when fl
                    (push (list (- p (point-min)) (- next (point-min)) fl)
                          runs))
                  (setq p next)))))
          (with-current-buffer conv
            (dolist (run (nreverse runs))
              ;; The syntax face goes FIRST and the base `alonso-md-code-face'
              ;; LAST: in a `face' list the first face has the highest priority,
              ;; so the syntax colors win the foreground while the base face
              ;; still supplies font family/background.
              (put-text-property (+ start (nth 0 run)) (+ start (nth 1 run))
                                 'face (list (nth 2 run)
                                             'alonso-md-code-face)))))))))

;;; Incremental fontification of the streaming code blocks
;;
;; While the answer streams (live rendering) the whole segment is re-rendered
;; on every `chunk'.  Re-fontifying each code block from scratch every time is
;; quadratic -- and the worst offender is C: cc-mode's font-lock is very slow
;; on unbalanced braces, exactly the state of a C function while it is still
;; being written.  To keep the syntax highlighting live without the stalls,
;; the *open* block is fontified incrementally into a persistent work buffer
;; (only the text that just arrived is fontified, plus a little context), and
;; a block that is already fontified is skipped through the
;; `alonso-md-code-fontified' marker on its opening fence.

(defconst alonso--md-live-context 200
  "Characters of context re-fontified before the newly arrived code.
When a block is fontified incrementally, the last few hundred characters are
re-scanned together with the new text, so a construct that spans the chunk
boundary (a multi-line comment or string) is fontified correctly.  Small
enough that the per-chunk cost stays constant.")

(defvar-local alonso--md-live-cache nil
  "Work buffer used to fontify the *open* code block while streaming.
A plist (:buffer B :start N :copied M :mode MODE :lang LANG): B is a
temporary buffer holding a copy of the block's code copied so far, START the
conversation buffer position where the block's code begins, COPIED how many
characters of it were already copied into B, MODE the major mode in use and
LANG the fence language.  nil when no block is being fontified incrementally.
Killed by `alonso--md-live-cache-reset'.")

(defun alonso--md-live-cache-reset ()
  "Discard the incremental code-block work buffer, if any."
  (when alonso--md-live-cache
    (let ((buf (plist-get alonso--md-live-cache :buffer)))
      (when (buffer-live-p buf) (kill-buffer buf)))
    (setq alonso--md-live-cache nil)))

(defun alonso--md-code-block-fontify (start end lang)
  "Fontify the whole code block between START and END as LANG.
Applies the base `alonso-md-code-face' over the block, then the language
syntax highlighting on top (see `alonso--md-highlight-code')."
  (alonso--md-face start end 'alonso-md-code-face)
  (alonso--md-highlight-code start end lang))

(defun alonso--md-code-block-flush-runs (runs start)
  "Apply the collected font-lock RUNS to the current (conversation) buffer.
RUNS is a list of (BEG END FACE) triples with BEG/END relative to the block
start; START is the conversation position where the block's code begins.
Each run's syntax face is composed with the base `alonso-md-code-face'
\(the syntax face first, so it wins the foreground; the base face last, so
the block keeps the code font), exactly as `alonso--md-highlight-code'."
  (dolist (run (nreverse runs))
    (put-text-property (+ start (nth 0 run)) (+ start (nth 1 run))
                       'face (list (nth 2 run) 'alonso-md-code-face))))

(defun alonso--md-code-block-fontify-live (start end lang)
  "Fontify the open code block between START and END incrementally, as LANG.
Keeps a persistent work buffer (see `alonso--md-live-cache') and fontifies
only the text that arrived since the previous call, so a long block is not
re-fontified from scratch on every streaming `chunk'.  Falls back to the
plain base face when the block cannot be fontified (no language, unknown
mode, fontification disabled)."
  (let ((mode (and alonso-fontify-code-blocks lang
                  (cdr (assoc (downcase lang) alonso--md-lang-mode)))))
    (if (and mode (fboundp mode))
        (progn
          (unless (and alonso--md-live-cache
                       (eq (plist-get alonso--md-live-cache :start) start)
                       (equal (plist-get alonso--md-live-cache :lang) lang))
            (alonso--md-live-cache-reset)
            (setq alonso--md-live-cache
                  (list :buffer (generate-new-buffer " *alonso-md-code*")
                        :start start :copied 0 :mode mode :lang lang))
            (with-current-buffer (plist-get alonso--md-live-cache :buffer)
              (delay-mode-hooks (funcall mode))
              (unless font-lock-mode (font-lock-mode 1)))
            (add-hook 'kill-buffer-hook #'alonso--md-live-cache-reset nil t))
          (let* ((copied (plist-get alonso--md-live-cache :copied))
                 (conv-upto (+ start copied)))
            (when (< conv-upto end)
              (alonso--md-face conv-upto end 'alonso-md-code-face)
              (let ((buf (plist-get alonso--md-live-cache :buffer))
                    (chunk (buffer-substring-no-properties conv-upto end))
                    (runs nil)
                    (temp-size nil))
                (with-current-buffer buf
                  (goto-char (point-max))
                  (let* ((temp-upto (point))
                         (lo (max (point-min)
                                  (- temp-upto alonso--md-live-context))))
                    (insert chunk)
                    (font-lock-ensure lo (point-max))
                    (let ((p lo) (max (point-max)))
                      (while (< p max)
                        (let ((next (next-single-property-change p 'face nil max))
                              (fl (get-text-property p 'face)))
                          (when fl
                            (push (list (- p (point-min)) (- next (point-min)) fl)
                                  runs))
                          (setq p next))))
                    (setq temp-size (- (point-max) (point-min)))))
                ;; Record the progress in the conversation buffer (the one
                ;; that holds the cache), not in the work buffer.
                (setq alonso--md-live-cache
                      (plist-put alonso--md-live-cache :copied temp-size))
                (alonso--md-code-block-flush-runs runs start)))))
      (alonso--md-face start end 'alonso-md-code-face))))

(defun alonso--md-code-block-finish (start end lang fence)
  "Fontify the closed code block between START and END as LANG, once.
FENCE is the position of the block's opening fence line, where the
`alonso-md-code-fontified' marker is kept: when the block was already
fontified (during live streaming) it is left untouched."
  (unless (get-text-property fence 'alonso-md-code-fontified)
    (alonso--md-code-block-fontify start end lang)
    (put-text-property fence (1+ fence) 'alonso-md-code-fontified t)))

(defun alonso--md-code-block-finish-live (start end lang fence)
  "Finish the code block closed by the fence at FENCE, while streaming.
The block was fontified incrementally as it streamed (see
`alonso--md-code-block-fontify-live'); here we only flush the content that
arrived since the last live render -- usually nothing, since the closing
fence is all that was just added -- and record the `alonso-md-code-fontified'
marker, instead of re-fontifying the whole block from scratch."
  (alonso--md-code-block-fontify-live start end lang)
  (put-text-property fence (1+ fence) 'alonso-md-code-fontified t)
  (alonso--md-live-cache-reset))

(defun alonso--render-markdown-region (start end &optional live)
  "Render the Markdown constructs between START and END (buffer positions).
Only text properties are added (`face', `display' and a clickable `keymap'
on links), so the buffer text stays byte-for-byte identical.
When LIVE is non-nil the segment is re-rendered while it still streams (see
`alonso-render-markdown-live'): a code block that is already fontified is
skipped, and a still-open block is fontified incrementally, so a long C
block does not stall Emacs by being re-fontified from scratch on every
`chunk'."
  (when alonso-render-markdown
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (save-excursion
          (save-restriction
            (narrow-to-region start end)
            (goto-char (point-min))
            (let ((in-code nil)
                  (code-start nil)
                  (code-lang nil)
                  (code-fence nil)
                  (code-done nil))
              (while (< (point) (point-max))
                (let* ((line-start (point))
                       (line-end (line-end-position)))
                  (cond
                   ;; inside a fenced code block: content lines or closing fence
                   (in-code
                    (if (looking-at-p "[ \t]*```")
                        (progn
                          ;; Fontify the block once, at its closing fence; a
                          ;; block already fontified (while streaming) is left
                          ;; alone.  While streaming, only flush what arrived
                          ;; since the last render instead of re-fontifying the
                          ;; whole block.
                          (unless code-done
                            (if live
                                (alonso--md-code-block-finish-live
                                 code-start line-start code-lang code-fence)
                              (alonso--md-code-block-finish
                               code-start line-start code-lang code-fence)))
                          (setq in-code nil code-start nil code-lang nil
                                code-fence nil code-done nil)
                          (alonso--md-live-cache-reset)
                          (alonso--md-fence-line line-start line-end))
                      ;; A content line gets the base face here only in the
                      ;; non-live path; while streaming (live) the incremental
                      ;; helper is the one that applies the faces.
                      (unless (or live code-done)
                        (alonso--md-face line-start
                                         (alonso--md-line-end)
                                         'alonso-md-code-face))))
                   ;; a fence opening a code block
                   ((looking-at-p "[ \t]*```")
                    (setq in-code t
                          code-lang (alonso--md-fence-lang)
                          code-start (alonso--md-line-end)
                          code-fence line-start
                          code-done (get-text-property
                                     line-start 'alonso-md-code-fontified))
                    (alonso--md-fence-line line-start line-end))
                   (t
                    (alonso--md-normal-line line-start line-end)))
                  (goto-char line-start)
                  (forward-line 1)))
              ;; a code block left open at the end of the segment
              (when in-code
                (if live
                    (alonso--md-code-block-fontify-live
                     code-start (point-max) code-lang)
                  (unless code-done
                    (alonso--md-code-block-fontify
                     code-start (point-max) code-lang)))))))))))

(provide 'alonso-markdown)

;;; alonso-markdown.el ends here
