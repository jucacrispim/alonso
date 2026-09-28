;;; tagarela-markdown.el --- Markdown rendering for tagarela  -*- lexical-binding: t; -*-

;;; Commentary:

;; Render the model's answer as Markdown in the conversation buffer: the faces,
;; the marker hiding (through the `display' property), the clickable links and
;; the syntax highlighting of fenced code blocks.  Rendering only adds text
;; properties -- the buffer text is never changed, so copying the conversation
;; out is unaffected.
;;
;; This file is self-contained: it never touches the buffer/mode plumbing, it
;; only operates on positions in the current buffer.  The conversation buffer
;; drives it through `tagarela--render-markdown-region'.
;;
;; See tagarela-ui.el.

;;; Code:

(require 'rx)

;;; Markdown faces (used to render the model's answer)

(defface tagarela-md-heading-1-face
  '((t (:inherit font-lock-function-name-face :bold t :height 1.3)))
  "Face for level-1 Markdown headings (`#') in the model's answer."
  :group 'tagarela)

(defface tagarela-md-heading-2-face
  '((t (:inherit font-lock-function-name-face :bold t :height 1.15)))
  "Face for level-2 Markdown headings (`##') in the model's answer."
  :group 'tagarela)

(defface tagarela-md-heading-3-face
  '((t (:inherit font-lock-variable-name-face :bold t)))
  "Face for level-3 Markdown headings (`###') in the model's answer."
  :group 'tagarela)

(defface tagarela-md-heading-4-face
  '((t (:inherit font-lock-keyword-face :bold t)))
  "Face for level 4-6 Markdown headings in the model's answer."
  :group 'tagarela)

(defface tagarela-md-bold-face
  '((t (:inherit bold)))
  "Face for `**bold**' text in the model's answer."
  :group 'tagarela)

(defface tagarela-md-italic-face
  '((t (:inherit italic)))
  "Face for `*italic*' text in the model's answer."
  :group 'tagarela)

(defface tagarela-md-strike-face
  '((t (:inherit shadow :strike-through t)))
  "Face for `~~strikethrough~~' text in the model's answer."
  :group 'tagarela)

(defface tagarela-md-inline-code-face
  '((t (:inherit font-lock-constant-face)))
  "Face for inline code (between backticks) in the model's answer."
  :group 'tagarela)

(defface tagarela-md-code-face
  '((t (:inherit default)))
  "Face for fenced code blocks in the model's answer.
By default it inherits `default', so the code matches the conversation's
font (size and family).  See `tagarela-md-code-font' to use a different
font family for the code (e.g. a monospaced one)."
  :group 'tagarela)

(defface tagarela-md-bullet-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for list bullets/numbers in the model's answer."
  :group 'tagarela)

(defface tagarela-md-quote-face
  '((t (:inherit font-lock-doc-face :italic t)))
  "Face for block quotes (`>') in the model's answer."
  :group 'tagarela)

(defface tagarela-md-link-face
  '((t (:inherit font-lock-string-face :underline t)))
  "Face for links in the model's answer."
  :group 'tagarela)

(defface tagarela-md-rule-face
  '((t (:inherit shadow)))
  "Face for horizontal rules (`---') in the model's answer."
  :group 'tagarela)

(defface tagarela-md-url-face
  '((t (:inherit shadow)))
  "Face for the URL shown right after the text of a Markdown link.
The URL is displayed visibly (e.g. \\\"docs (https://example.com)\\\"), dimmed so
it does not compete with the link text."
  :group 'tagarela)

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

(defcustom tagarela-render-markdown t
  "Whether to render the model's answer as Markdown in the conversation.
Only the answer (the streaming `chunk' events) is rendered; the
chain-of-thought and the tool-call lines are left as plain text."
  :type 'boolean
  :group 'tagarela)

(defcustom tagarela-hide-markdown-markers t
  "Whether to hide the Markdown markers in the rendered answer.
When non-nil the markers (`#', `**', backticks, code fences, list bullets,
...) are hidden through the `display' property, so the answer reads as
formatted text.  When nil the markers stay visible, dimmed in `shadow'.
Has no effect when `tagarela-render-markdown' is nil."
  :type 'boolean
  :group 'tagarela)

(defcustom tagarela-fontify-code-blocks t
  "Whether to syntax-highlight the fenced code blocks in the model's answer.
When non-nil, a fenced code block whose language maps to an available major
mode (see `tagarela--md-lang-mode') is fontified with that mode's
syntax highlighting, composed with the base `tagarela-md-code-face'
(the block font is controlled by `tagarela-md-code-font').  When nil the
block keeps only
the base face (monospaced, no colors).  Has no effect when
`tagarela-render-markdown' is nil."
  :type 'boolean
  :group 'tagarela)

(defun tagarela--apply-md-code-font ()
  "Apply `tagarela-md-code-font' to `tagarela-md-code-face'.
When `tagarela-md-code-font' is nil the code face has no explicit font
family, so it inherits `default' (the conversation font); otherwise it
uses the given family."
  (set-face-attribute 'tagarela-md-code-face nil
                      :family (or tagarela-md-code-font 'unspecified)))

(defun tagarela--set-md-code-font (_symbol value)
  "Store VALUE in `tagarela-md-code-font' and apply it to the code face."
  (set-default 'tagarela-md-code-font value)
  (tagarela--apply-md-code-font))

(defcustom tagarela-md-code-font nil
  "Font family used for the code blocks in the model's answer.
When nil (the default) the code blocks inherit `default', so they use the
same font (family and size) as the rest of the conversation.  When a
string, e.g. \"Monospace\" or \"Inconsolata\", the code blocks use that
font family while keeping the conversation's size.  Affects the fenced
code blocks and their fence lines (see `tagarela-md-code-face')."
  :type '(choice (const :tag "Same as the conversation" nil)
                 (string :tag "Font family"))
  :group 'tagarela
  :set #'tagarela--set-md-code-font)

(defcustom tagarela-render-markdown-live t
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
`tagarela-render-markdown' is nil."
  :type 'boolean
  :group 'tagarela)

(defconst tagarela--md-inline-re
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

(defvar tagarela-link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'tagarela-open-link)
    (define-key map [mouse-1] #'tagarela--open-link-mouse)
    map)
  "Keymap put on rendered Markdown links (RET / mouse-1 open the URL).")

;;;###autoload
(defun tagarela-open-link ()
  "Open in the browser the URL of the Markdown link at point."
  (interactive)
  (let ((url (or (get-text-property (point) 'tagarela-url)
                 (get-text-property (max (point-min) (1- (point)))
                                    'tagarela-url))))
    (if url
        (browse-url url)
      (user-error "No link at point"))))

(defun tagarela--open-link-mouse (event)
  "Open the Markdown link clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (tagarela-open-link))

(defun tagarela--md-line-end ()
  "Return the end of the current line, extended over its newline (if any)."
  (let ((e (line-end-position)))
    (if (< e (point-max)) (1+ e) e)))

(defun tagarela--md-face (start end face)
  "Put FACE on the text between START and END."
  (when (< start end)
    (put-text-property start end 'face face)))

(defun tagarela--md-hide (start end)
  "Hide the marker text between START and END, or dim it in `shadow'.
What happens depends on `tagarela-hide-markdown-markers'."
  (when (< start end)
    (if tagarela-hide-markdown-markers
        (put-text-property start end 'display "")
      (put-text-property start end 'face 'shadow))))

(defun tagarela--md-show-url (start end url)
  "Show URL after the link text, replacing the `](url)' tail between START and END.
The tail is replaced (through the `display' property) by \\\" (url)\\\", so the
buffer reads `text (url)' — the URL stays visible, in
`tagarela-md-url-face'.  With `tagarela-hide-markdown-markers'
nil the raw `](url)' tail is kept instead, dimmed in `shadow'."
  (if tagarela-hide-markdown-markers
      (put-text-property start end 'display
                         (concat " ("
                                 (propertize url 'face 'tagarela-md-url-face)
                                 ")"))
    (tagarela--md-hide start end)))

(defun tagarela--md-inline-region (start end)
  "Render the inline Markdown constructs between START and END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward tagarela--md-inline-re end t)
      (let ((ms (match-beginning 0))
            (me (match-end 0)))
        (cond
         ((match-beginning 1)           ; `inline code`
          (tagarela--md-face ms me 'tagarela-md-inline-code-face)
          (tagarela--md-hide ms (1+ ms))
          (tagarela--md-hide (1- me) me))
         ((match-beginning 2)           ; [text](url)
          (let ((url (match-string-no-properties 3))
                (text-end (match-end 2)))
            (tagarela--md-face ms me 'tagarela-md-link-face)
            (put-text-property ms me 'mouse-face 'highlight)
            (put-text-property ms me 'keymap tagarela-link-keymap)
            (put-text-property ms me 'help-echo url)
            (put-text-property ms me 'tagarela-url url)
            (tagarela--md-hide ms (1+ ms))     ; the `['
            (tagarela--md-show-url text-end me url)))  ; `](url)' -> ` (url)'
         ((match-beginning 4)           ; **bold**
          (tagarela--md-face ms me 'tagarela-md-bold-face)
          (tagarela--md-hide ms (+ ms 2))
          (tagarela--md-hide (- me 2) me))
         ((match-beginning 5)           ; ~~strikethrough~~
          (tagarela--md-face ms me 'tagarela-md-strike-face)
          (tagarela--md-hide ms (+ ms 2))
          (tagarela--md-hide (- me 2) me))
         ((match-beginning 6)           ; *italic*
          (tagarela--md-face ms me 'tagarela-md-italic-face)
          (tagarela--md-hide ms (1+ ms))
          (tagarela--md-hide (1- me) me)))))))

(defun tagarela--md-normal-line (line-start line-end)
  "Render one non-code Markdown line between LINE-START and LINE-END."
  (goto-char line-start)
  (cond
   ;; horizontal rule
   ((looking-at "[ \t]*\\(---\\|___\\|\\*\\*\\*\\)[ \t]*$")
    (tagarela--md-face line-start line-end 'tagarela-md-rule-face)
    (when tagarela-hide-markdown-markers
      (put-text-property line-start line-end
                         'display "────────────────────────")))
   ;; heading
   ((looking-at "[ \t]*\\(#\\{1,6\\}\\)[ \t]+\\(.+\\)$")
    (let ((level (length (match-string 1)))
          (body-start (match-beginning 2)))
      (tagarela--md-face line-start line-end
                               (pcase level
                                 (1 'tagarela-md-heading-1-face)
                                 (2 'tagarela-md-heading-2-face)
                                 (3 'tagarela-md-heading-3-face)
                                 (_ 'tagarela-md-heading-4-face)))
      (tagarela--md-hide line-start body-start)
      (tagarela--md-inline-region body-start line-end)))
   ;; block quote
   ((looking-at "[ \t]*>+ ?")
    (tagarela--md-face line-start line-end 'tagarela-md-quote-face)
    (tagarela--md-hide line-start (match-end 0))
    (tagarela--md-inline-region (match-end 0) line-end))
   ;; unordered list item
   ((looking-at "[ \t]*\\([-*+]\\)[ \t]+")
    (tagarela--md-face (match-beginning 1) (match-end 1)
                             'tagarela-md-bullet-face)
    (when tagarela-hide-markdown-markers
      (put-text-property (match-beginning 1) (match-end 1) 'display "•"))
    (tagarela--md-inline-region (match-end 0) line-end))
   ;; ordered list item
   ((looking-at "[ \t]*\\([0-9]+\\.\\)[ \t]+")
    (tagarela--md-face (match-beginning 1) (match-end 1)
                             'tagarela-md-bullet-face)
    (tagarela--md-inline-region (match-end 0) line-end))
   (t
    (tagarela--md-inline-region line-start line-end))))

(defun tagarela--md-fence-line (line-start line-end)
  "Handle a ``` fence line: hide it as a marker (or dim it as code)."
  (if tagarela-hide-markdown-markers
      (put-text-property line-start (tagarela--md-line-end) 'display "")
    (tagarela--md-face line-start line-end 'tagarela-md-code-face)))

(defvar tagarela--md-lang-mode
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
Used by `tagarela--md-highlight-code'.  A language with no entry here
(or whose mode is unavailable) keeps only the base
`tagarela-md-code-face' (monospaced, no colors).")

(defun tagarela--md-fence-lang ()
  "Return the language of the code fence on the current line, or nil.
E.g. the line \"```python\" yields \"python\"."
  (when (looking-at "[ \t]*```[ \t]*\\([^ \t\n]+\\)")
    (match-string-no-properties 1)))

(defun tagarela--md-highlight-code (start end lang)
  "Fontify the code between START and END in the conversation buffer as LANG.
The region is copied into a temporary buffer, the major mode mapped from
LANG (see `tagarela--md-lang-mode') is turned on and font-locked, and
the resulting faces are copied back, composed with the base
`tagarela-md-code-face' (the syntax face first, so it wins the foreground;
the base face last, so the block keeps the code font).  Only `face' text
properties are added -- the buffer text is never changed.  Does
nothing when `tagarela-fontify-code-blocks' is nil, LANG is unknown or
its mode is unavailable."
  (when (and tagarela-fontify-code-blocks lang (> end start))
    (let ((mode (cdr (assoc (downcase lang) tagarela--md-lang-mode))))
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
                (let ((next (or (next-single-property-change p 'face nil max)
                                max))
                      (fl (get-text-property p 'face)))
                  (when fl
                    (push (list (- p (point-min)) (- next (point-min)) fl)
                          runs))
                  (setq p next)))))
          (with-current-buffer conv
            (dolist (run (nreverse runs))
              ;; The syntax face goes FIRST and the base `tagarela-md-code-face'
              ;; LAST: in a `face' list the first face has the highest priority,
              ;; so the syntax colors win the foreground while the base face
              ;; still supplies font family/background.
              (put-text-property (+ start (nth 0 run)) (+ start (nth 1 run))
                                 'face (list (nth 2 run)
                                             'tagarela-md-code-face)))))))))

(defun tagarela--render-markdown-region (start end)
  "Render the Markdown constructs between START and END (buffer positions).
Only text properties are added (`face', `display' and a clickable `keymap'
on links), so the buffer text stays byte-for-byte identical."
  (when tagarela-render-markdown
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (save-excursion
          (save-restriction
            (narrow-to-region start end)
            (goto-char (point-min))
            (let ((in-code nil)
                  (code-start nil)
                  (code-lang nil))
              (while (< (point) (point-max))
                (let* ((line-start (point))
                       (line-end (line-end-position)))
                  (cond
                   ;; inside a fenced code block: content lines or closing fence
                   (in-code
                    (if (looking-at-p "[ \t]*```")
                        (progn
                          (tagarela--md-highlight-code
                           code-start line-start code-lang)
                          (setq in-code nil code-start nil code-lang nil)
                          (tagarela--md-fence-line line-start line-end))
                      (tagarela--md-face line-start
                                               (tagarela--md-line-end)
                                               'tagarela-md-code-face)))
                   ;; a fence opening a code block
                   ((looking-at-p "[ \t]*```")
                    (setq in-code t
                          code-lang (tagarela--md-fence-lang)
                          code-start (tagarela--md-line-end))
                    (tagarela--md-fence-line line-start line-end))
                   (t
                    (tagarela--md-normal-line line-start line-end)))
                  (goto-char line-start)
                  (forward-line 1)))
              ;; a code block left open at the end of the segment
              (when in-code
                (tagarela--md-highlight-code
                 code-start (point-max) code-lang)))))))))

(provide 'tagarela-markdown)

;;; tagarela-markdown.el ends here
