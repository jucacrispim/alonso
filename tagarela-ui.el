;;; tagarela-ui.el --- llm-bridge UI: buffers, windows and rendering -*- lexical-binding: t; -*-

;;; Commentary:

;; The "UI" half of the Emacs llm-bridge integration.  It owns everything that
;; touches buffers and windows: the conversation and input buffers, their minor
;; modes and keymaps, insertion/rendering of model output (chunks, thinking,
;; tool calls, errors, turn summaries), the Markdown rendering of the model's
;; answer (faces, hidden markers, clickable links), the braille spinner, the mode-line
;; fragments, the window layout (open/restart/kill) and the tool-confirmation
;; UX (individual questions asked through a transient menu, `[allowed]' /
;; `[denied]' tags, the transient trust-scope sub-menu, with a minibuffer
;; char-prompt fallback when transient is unavailable).
;;
;; It requires tagarela-client.el (single one-way dependency) and reaches
;; the client only through its public API: `tagarela--send',
;; `tagarela--prompt-params', `tagarela--ensure-ready', the trust
;; helpers, the tool dispatchers and the shared state variables.
;;
;; See tagarela.el (the entry point) and tagarela-client.el.

;;; Code:

(require 'cl-lib)
(require 'rx)
(require 'seq)
(require 'tagarela-client)

;; `yank-media' (Emacs 29+) is autoloaded; declared so the compiler/loader
;; knows the symbols used by `tagarela-yank' and the input-mode setup.
(declare-function yank-media "yank-media" ())
(declare-function yank-media-handler "yank-media" (types handler))

;;; Conversation/input buffers

(defcustom tagarela-buffer-name "*llm-bridge*"
  "Name of the conversation buffer."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-input-buffer-name "*llm-bridge-input*"
  "Name of the buffer where the user types prompts."
  :type 'string
  :group 'tagarela)

(defcustom tagarela-files-changed-hook nil
  "Hook run when the bridge emits a `files_changed' event.
The hook is called with a single argument: the list of files (strings,
relative paths as the model called them, sorted alphabetically and
deduplicated) that were changed (written) by the model in the turn that just
finished.  Add functions with `add-hook'."
  :type 'hook
  :group 'tagarela)

;;; Faces

(defface tagarela-user-face
  '((t (:inherit font-lock-keyword-face :bold t)))
  "Face for the user's prompts in the conversation buffer."
  :group 'tagarela)

(defface tagarela-hook-face
  '((t (:inherit font-lock-builtin-face :bold t)))
  "Face for local hook commands (a prompt starting with \"#\")."
  :group 'tagarela)

(defface tagarela-tool-face
  '((t (:inherit font-lock-builtin-face)))
  "Face for tool_call lines."
  :group 'tagarela)

(defface tagarela-search-face
  '((t (:foreground "red")))
  "Face for the `search' part of a `search_replace' tool call (diff `-')."
  :group 'tagarela)

(defface tagarela-replace-face
  '((t (:foreground "dark green")))
  "Face for the `replace' part of a `search_replace' tool call (diff `+')."
  :group 'tagarela)

(defface tagarela-error-face
  '((t (:inherit error)))
  "Face for error lines."
  :group 'tagarela)

(defface tagarela-command-face
  '((t (:inherit font-lock-string-face :bold t)))
  "Face for the command/pattern/path highlighted in a tool confirmation."
  :group 'tagarela)

(defface tagarela-separator-face
  '((t (:inherit shadow)))
  "Face for turn separators and metadata lines."
  :group 'tagarela)

(defcustom tagarela-show-thinking t
  "Whether to display the model's chain-of-thought (thinking events)."
  :type 'boolean
  :group 'tagarela)

(defface tagarela-thinking-face
  '((t (:inherit font-lock-comment-face :italic t)))
  "Face used to display the model's chain-of-thought."
  :group 'tagarela)

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

(defvar tagarela--answer-start nil
  "Marker at the start of the answer segment still to be rendered, or nil.
Set on the first `chunk' of a segment by `tagarela--answer-begin' and
cleared by `tagarela--render-answer' once the segment is rendered.")

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
`tagarela-md-code-face' so the block keeps its monospaced font.  Only
`face' text properties are added -- the buffer text is never changed.  Does
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
              (put-text-property (+ start (nth 0 run)) (+ start (nth 1 run))
                                 'face (list 'tagarela-md-code-face
                                             (nth 2 run))))))))))

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

(defun tagarela--answer-begin ()
  "Start a new answer segment if one is not already open."
  (unless tagarela--answer-start
    (setq tagarela--answer-start
          (with-current-buffer (tagarela--get-buffer)
            (copy-marker (point-max))))))

(defun tagarela--render-answer ()
  "Render the Markdown of the current answer segment and close it.
No-op when no segment is open.  Called at every boundary where the model
stops writing (thinking, tool call, end of turn)."
  (when tagarela--answer-start
    (let ((start (marker-position tagarela--answer-start)))
      (set-marker tagarela--answer-start nil)
      (setq tagarela--answer-start nil)
      (when start
        (with-current-buffer (tagarela--get-buffer)
          (let ((end (point-max)))
            (when (< start end)
              (tagarela--render-markdown-region start end))))))))

(defun tagarela--render-answer-live ()
  "Re-render the pending answer segment without closing it.
No-op when `tagarela-render-markdown-live' is nil or no segment is
open.  Called after every `chunk' so the formatting appears while the model
is still writing.  Only complete constructs are rendered, so the answer is
never shown with a half-written marker hidden."
  (when (and tagarela-render-markdown-live
             tagarela--answer-start)
    (let ((start (marker-position tagarela--answer-start)))
      (when start
        (with-current-buffer (tagarela--get-buffer)
          (let ((end (point-max)))
            (when (< start end)
              (tagarela--render-markdown-region start end))))))))

;;; Conversation buffer state used by the render handlers

(defvar tagarela--thinking-separator-pending nil
  "Non-nil when thinking was shown in the current turn and the two blank
lines separating it from the response have not been inserted yet.
Set by `tagarela--on-thinking', consumed by the first `chunk'
and cleared at the start/end of every turn.")

(defvar tagarela--tool-call-pos nil
  "Buffer position of the start of the visible line (title for read-only
tools, `Run tool: ...?' question for mutating ones) of the last tool call
shown.  Used as the scroll anchor while the tool's confirmation question is
being asked (`tagarela--keep-question-visible'), so the beginning of a
possibly large diff stays visible, and as the spot where
`tagarela--record-tool-confirmation' prepends the `[allowed]' /
`[denied]' tag.")

(defvar tagarela--tool-confirm-pos nil
  "Buffer position just after the parameters of the last tool call shown,
kept as the lower scroll anchor while the confirmation is pending.")

;;; Braille spinner animation during thinking

(defvar tagarela--spinner-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames for the braille spinner during thinking.")

(defvar tagarela--spinner-index 0
  "Current frame index of the braille spinner.")

(defvar tagarela--spinner-timer nil
  "Timer running the braille spinner animation.")

(defvar tagarela--spinner-interval 0.1
  "Interval in seconds between spinner frame updates (animation speed).")

(defvar tagarela--spinner-active nil
  "Non-nil while the turn spinner is active (from prompt to turn end).")

(defun tagarela--spinner-tick ()
  "Advance the spinner frame and update the mode-line."
  (setq tagarela--spinner-index
        (mod (1+ tagarela--spinner-index)
             (length tagarela--spinner-frames)))
  (force-mode-line-update t))

(defun tagarela--start-spinner ()
  "Start the braille spinner timer if not already running.
Keeps the animation frame when the timer is already running, so streaming
chunks do not restart the spinner from the beginning."
  (setq tagarela--spinner-active t)
  (unless (timerp tagarela--spinner-timer)
    (setq tagarela--spinner-index 0)
    (setq tagarela--spinner-timer
          (run-with-timer tagarela--spinner-interval
                          tagarela--spinner-interval
                          #'tagarela--spinner-tick))))

(defun tagarela--stop-spinner ()
  "Stop the braille spinner timer and clear the active state."
  (setq tagarela--spinner-active nil)
  (when (timerp tagarela--spinner-timer)
    (cancel-timer tagarela--spinner-timer)
    (setq tagarela--spinner-timer nil))
  (force-mode-line-update t))

(defun tagarela--mode-line-status ()
  "Return the mode-line status fragment for the conversation buffer.
Shows the braille spinner while a turn is in flight (from prompt to
turn_end/error/cancelled), or `[llm-bridge…]' during a turn with no spinner."
  (cond
   (tagarela--spinner-active
    (format " [%s]" (aref tagarela--spinner-frames
                          tagarela--spinner-index)))
   (tagarela-in-turn
    " [llm-bridge…]")
   (t "")))

;;; Event render handlers (dispatched by the client's `--handle-line')

(defun tagarela--on-chunk (text)
  "Handle a `chunk' event with TEXT (streaming fragment)."
  (when tagarela--after-tool-separator-pending
    ;; The tool output finished and the model resumed: separate it with
    ;; two blank lines (three newlines), only on the first transition.
    (setq tagarela--after-tool-separator-pending nil)
    (tagarela--insert "\n\n\n"))
  (when tagarela--thinking-separator-pending
    ;; The thinking finished and the answer started: separate it with two
    ;; blank lines (three newlines), only on the first transition.
    (setq tagarela--thinking-separator-pending nil)
    (tagarela--insert "\n\n\n"))
  (tagarela--answer-begin)
  (tagarela--insert text)
  (tagarela--render-answer-live))

(defun tagarela--on-thinking (text)
  "Handle a `thinking' event with TEXT (chain-of-thought fragment)."
  (tagarela--render-answer)
  (tagarela--start-spinner)
  (when tagarela-show-thinking
    (when tagarela--after-tool-separator-pending
      ;; The tool output finished and the model started thinking: separate
      ;; it with two blank lines, only on the first transition.
      (setq tagarela--after-tool-separator-pending nil)
      (tagarela--insert "\n\n\n"))
    (setq tagarela--thinking-separator-pending t)
    (tagarela--insert-propertized
     text 'face 'tagarela-thinking-face)))

(defun tagarela--on-turn-end (ev)
  "Handle a `turn_end' event EV: finalize turn tokens, accumulate session
usage and show a per-turn summary with the model."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela--turn-finalized t)
  (let ((input (gethash "input_tokens" ev 0))
        (output (gethash "output_tokens" ev 0))
        (cache-hit (gethash "cache_hit_tokens" ev 0))
        (cache-miss (gethash "cache_miss_tokens" ev 0))
        (model (gethash "model" ev)))
    (let ((inc-in (- input tagarela--current-turn-input-tokens))
          (inc-out (- output tagarela--current-turn-output-tokens)))
      (setq tagarela-session-input-tokens
            (+ tagarela-session-input-tokens (max 0 inc-in))
            tagarela-session-output-tokens
            (+ tagarela-session-output-tokens (max 0 inc-out))
            tagarela-session-cache-hit-tokens
            (+ tagarela-session-cache-hit-tokens (max 0 cache-hit))
            tagarela-session-cache-miss-tokens
            (+ tagarela-session-cache-miss-tokens (max 0 cache-miss))
            tagarela--current-turn-input-tokens 0
            tagarela--current-turn-output-tokens 0))
    (when model
      (setq tagarela-session-model model))
    (tagarela--insert-propertized
     (format "\n[stop_reason=%s model=%s | turn: sent %d, received %d, cache %d/%d | session: sent %d, received %d, cache %d/%d]\n"
             (gethash "stop_reason" ev)
             (or model "?")
             input output cache-hit cache-miss
             tagarela-session-input-tokens
             tagarela-session-output-tokens
             tagarela-session-cache-hit-tokens
             tagarela-session-cache-miss-tokens)
     'face 'tagarela-separator-face))
  (force-mode-line-update t))

(defun tagarela--on-usage-delta (ev)
  "Handle a `usage_delta' event EV: update turn and session token usage."
  (unless tagarela--turn-finalized
    (let ((input (gethash "input_tokens" ev 0))
          (output (gethash "output_tokens" ev 0)))
      (let ((inc-in (- input tagarela--current-turn-input-tokens))
            (inc-out (- output tagarela--current-turn-output-tokens)))
        (when (> inc-in 0)
          (setq tagarela-session-input-tokens (+ tagarela-session-input-tokens inc-in)
                tagarela--current-turn-input-tokens input))
        (when (> inc-out 0)
          (setq tagarela-session-output-tokens (+ tagarela-session-output-tokens inc-out)
                tagarela--current-turn-output-tokens output)))
      (force-mode-line-update t))))

(defun tagarela--on-error (msg)
  "Handle an `error' event with MSG."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil)
  (tagarela--cancel-confirm)
  (tagarela--insert-propertized
   (format "\n[error] %s\n" msg)
   'face 'tagarela-error-face))

(defun tagarela--on-files-changed (ev)
  "Handle a `files_changed' event EV.
Runs `tagarela-files-changed-hook' with the list of files changed by
the model in the turn that just finished (the `files' field of EV)."
  (let ((changed (gethash "files" ev)))
    (when changed
      (run-hook-with-args 'tagarela-files-changed-hook changed))))

(defun tagarela--on-cancelled ()
  "Handle a `cancelled' event."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil)
  (tagarela--cancel-confirm)
  (tagarela--insert-propertized
   "\n[cancelled]\n"
   'face 'tagarela-separator-face))

(defun tagarela--on-hook-action (ev)
  "Handle a `hook_action' event EV: show a local hook's result.
A hook (a prompt starting with \"#\") runs a local script instead of calling
the LLM; the bridge replies with a single `hook_action' event and NO
`turn_end', so this handler also finalizes the client-side \"turn\" state
(stopping the spinner, clearing `tagarela-in-turn' and the separator
flags).  There is no token/model accounting here because there is no
`turn_end'.  When EV carries an `error' field (script missing, invalid name
or non-zero exit) the message is shown in the error face; otherwise the
script's combined output is inserted as plain text."
  (tagarela--render-answer)
  (tagarela--stop-spinner)
  (setq tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela--turn-finalized t)
  (tagarela--cancel-confirm)
  (let ((name (gethash "name" ev))
        (output (gethash "output" ev))
        (err (gethash "error" ev)))
    (if err
        (tagarela--insert-propertized
         (format "\n[hook %s] error: %s\n" name err)
         'face 'tagarela-error-face)
      (tagarela--insert-propertized
       (concat "\n" (or output "") "\n"))))
  (force-mode-line-update t))

;;; Tool-call display helpers

(defvar tagarela-tool-icons
  '(("shell"         . "🖥")
    ("grep"          . "🔎")
    ("glob"          . "🔎")
    ("read"          . "📄")
    ("write"         . "✏️")
    ("search_replace" . "🔁")
    ("knowledge"     . "🧠"))
  "Alist of tool name → unicode icon, shown before the tool name in the
confirmation questions (the `Run tool: ...?' prompt and its recorded line).")

(defun tagarela--tool-icon (name)
  "Return the unicode icon for tool NAME (a generic wrench when unknown)."
  (or (cdr (assoc name tagarela-tool-icons)) "🔧"))

(defun tagarela--tool-detail-string (name input)
  "Return the plain-text detail of tool NAME with INPUT, for the minibuffer.
`shell' shows its command, `grep'/`glob' the pattern and the file tools the
path.  Used in the confirmation question prompt."
  (cond
   ((equal name "shell")
    (or (tagarela--hval input "command") ""))
   ((member name '("grep" "glob"))
    (or (tagarela--hval input "pattern") ""))
   ((member name '("read" "write" "search_replace"))
    (or (tagarela--hval input "path") ""))
   (t "")))

(defun tagarela--tool-detail-propertized (name input)
  "Return the tool NAME detail (command/pattern/path) propertized in
`tagarela-command-face' (blue), for the recorded confirmation line."
  (let ((v (tagarela--tool-detail-string name input)))
    (if (string-empty-p v)
        ""
      (propertize v 'face 'tagarela-command-face))))

(defun tagarela--confirm-question (name input)
  "Build the minibuffer confirmation question for tool NAME with INPUT.
Prefixes the tool's unicode icon and, when available, shows the command
(`shell'), pattern (`grep'/`glob') or path (file tools) right after the name,
e.g. \"🖥 Run tool: shell · ps aux? \".  The minibuffer itself cannot render
colors, so the detail is shown as plain text here (the recorded line in the
conversation buffer shows it in blue via
`tagarela--tool-detail-propertized')."
  (let ((detail (tagarela--tool-detail-string name input)))
    (if (string-empty-p detail)
        (format "%s Run tool: %s? " (tagarela--tool-icon name) name)
      (format "%s Run tool: %s · %s? "
              (tagarela--tool-icon name) name detail))))

(defun tagarela--tool-input-pairs (input)
  "Return INPUT (a hash-table) as a sorted list of (key . value) pairs."
  (when (hash-table-p input)
    (let (pairs)
      (maphash (lambda (k v) (push (cons k v) pairs)) input)
      (sort pairs (lambda (a b) (string< (car a) (car b)))))))

(defun tagarela--diff-lines (text prefix)
  "Return TEXT with each line prefixed by PREFIX, preserving a trailing newline."
  (let ((trimmed (string-trim-right text "\n"))
        (nl (and (string-suffix-p "\n" text) "\n")))
    (concat
     (mapconcat (lambda (line) (concat prefix line))
                (split-string trimmed "\n")
                "\n")
     nl)))

(defun tagarela--format-tool-call (name input)
  "Return a propertized string describing tool NAME with its INPUT.
For `search_replace' the search is shown in red prefixed with `-' and the
replace in dark green prefixed with `+', diff style.  Other tools show all
their parameters as `key: value' lines."
  (if (hash-table-p input)
      (cond
       ((equal name "search_replace")
        (let ((path (or (tagarela--hval input "path") ""))
              (search (or (tagarela--hval input "search") ""))
              (replace (or (tagarela--hval input "replace") "")))
          (concat
           (format "  path: %s\n" path)
           (propertize (tagarela--diff-lines search "-")
                       'face 'tagarela-search-face)
           (propertize (concat "\n"
                               (tagarela--diff-lines replace "+"))
                       'face 'tagarela-replace-face))))
       (t
        (let ((pairs (tagarela--tool-input-pairs input)))
          (mapconcat (lambda (pair)
                       (format "  %s: %s" (car pair) (cdr pair)))
                     pairs "\n"))))
    ""))

(defun tagarela--show-tool-call (_id name input)
  "Insert the tool-call line and its parameters for tool NAME with INPUT.

Read-only tools (which run without confirmation) get a title line with the
tool's icon and name, e.g. \"📄 read\".  Mutating tools (which ask for an
individual confirmation) show the confirmation question line right away —
the tool's icon and the `Run tool: <name> · <detail>?' prompt — followed by
the parameters beneath it.  The `[allowed]' / `[denied]' prefix is later
prepended to the front of that same question line by
`tagarela--record-tool-confirmation' once the user answers, so the
question is visible from the start (not only after the answer).  Returns the
buffer position of the visible title/parameters."
  (tagarela--render-answer)
  (let* ((read-only (tagarela--tool-read-only-p name))
         (detail (tagarela--tool-detail-propertized name input))
         (header (if read-only
                     (format "\n%s %s\n" (tagarela--tool-icon name) name)
                   (concat "\n"
                           (tagarela--tool-icon name)
                           " Run tool: " name
                           (if (string-empty-p detail) "" (concat " · " detail))
                           "? \n")))
         (pos (tagarela--insert-propertized header)))
    ;; point at the start of the visible line (title or question), where the
    ;; `[allowed]' / `[denied]' tag is prepended later
    (setq tagarela--tool-call-pos (1+ pos))
    (let ((desc (tagarela--format-tool-call name input)))
      (when (> (length desc) 0)
        (tagarela--insert-propertized desc)))
    (setq tagarela--tool-confirm-pos (point-max))
    (1+ pos)))

;;; Images — pasting/attaching images to a prompt (multimodal)

;; An image is attached by inserting it *inline* in the input buffer: the
;; buffer shows the image itself and, right beneath the text, carries the spec
;; (a plist) in the `tagarela-image' text property.  At send time
;; `tagarela--buffer-collect' strips those placeholders out of the text and
;; hands the specs to `tagarela--prompt-send', so the pasted image is a
;; WYSIWYG attachment — no separate "pending images" list to manage.

(defcustom tagarela-image-max-width 400
  "Maximum width, in pixels, an inline image is displayed at.
Bigger images are scaled down for DISPLAY only; the full-resolution image is
what gets sent to the model.  nil displays images at their full size."
  :type '(choice (const :tag "Full size" nil) integer)
  :group 'tagarela)

(defcustom tagarela-image-mime-priority
  '("image/png" "image/webp" "image/gif" "image/jpeg"
    "image/bmp" "image/tiff" "image/svg+xml")
  "Clipboard image MIME types, most preferred first.
When the clipboard offers several renderable image types, `tagarela-yank'
inserts the first one present in this list — no prompt.  Types not listed
rank after every listed type."
  :type '(repeat string)
  :group 'tagarela)

(defun tagarela--image-bytes (data)
  "Return DATA (a clipboard selection string) as a unibyte string of bytes."
  (if (multibyte-string-p data)
      (encode-coding-string data 'binary)
    data))

(defun tagarela--image-symbol (mime)
  "Return the `create-image' type symbol for MIME (e.g. `png'), or nil."
  (when (and (stringp mime) (string-match-p "/" mime))
    (intern (cadr (split-string mime "/")))))

(defun tagarela--image-create (spec)
  "Create an Emacs image object for the image SPEC, or nil if not displayable.
SPEC is a plist (`:data'/`:mime', `:path' or `:url'); a URL has no local bytes
and is never displayed.  The image is scaled to `tagarela-image-max-width'."
  (ignore-errors
    (let ((data (plist-get spec :data))
          (path (plist-get spec :path))
          (props (when tagarela-image-max-width
                   (list :max-width tagarela-image-max-width))))
      (cond
       (data
        (apply #'create-image (base64-decode-string data)
               (tagarela--image-symbol (plist-get spec :mime)) t props))
       (path
        (apply #'create-image (expand-file-name path) nil t props))
       (t nil)))))

(defun tagarela--image-string (spec)
  "Return a string carrying the inline image of SPEC.
The string is a single space holding the image in its `display' property and
SPEC itself in the `tagarela-image' property (so it can be collected at send
time).  When the image cannot be displayed (a URL, or a format this Emacs
cannot render) a textual placeholder — still carrying the `tagarela-image'
property — is returned instead.  The placeholder is `rear-nonsticky' so text
typed right after it does not inherit the attachment properties."
  ;; `rear-nonsticky' matters: text typed right after the placeholder is
  ;; inserted with `insert-and-inherit', which would otherwise copy the
  ;; `tagarela-image' (and `display') properties onto it — making typed text
  ;; look like another image and get dropped from the prompt at send time.
  (let ((img (tagarela--image-create spec)))
    (if img
        (propertize " " 'display img 'tagarela-image spec 'rear-nonsticky t)
      (propertize (format "[imagem: %s]"
                          (or (plist-get spec :path)
                              (plist-get spec :url)
                              (plist-get spec :mime)
                              "?"))
                  'face 'tagarela-separator-face
                  'tagarela-image spec
                  'rear-nonsticky t))))

(defun tagarela--insert-image (spec)
  "Insert SPEC as an inline image at point in the current buffer."
  (insert (tagarela--image-string spec)))

(defun tagarela--yank-media-image (type data)
  "`yank-media' handler: insert clipboard image DATA (of MIME TYPE) inline.
Registered for the input buffer by `tagarela-input-mode'.  Returns non-nil so
`yank-media' knows it handled the selection."
  (tagarela--insert-image
   (list :mime (symbol-name type)
         :data (base64-encode-string (tagarela--image-bytes data) t)))
  t)

(defun tagarela--image-mime-rank (mime)
  "Return the preference rank of the MIME type string MIME (lower is better).
Unknown types rank after every type in `tagarela-image-mime-priority'."
  (or (cl-position mime tagarela-image-mime-priority :test #'string=)
      (length tagarela-image-mime-priority)))

(defun tagarela--clipboard-image ()
  "Return the best image on the clipboard as (MIME . DATA), or nil.
Like `yank-media', only considers image types this Emacs can actually render
\(so the clipboard's `image/x-win-bitmap' and the like are skipped).  Among
them it picks the highest-priority one per `tagarela-image-mime-priority'
WITHOUT prompting.  MIME is a string (e.g. \"image/png\"); DATA is the raw
selection bytes."
  (when-let* ((targets (gui-get-selection 'CLIPBOARD 'TARGETS))
              (types (and (vectorp targets) (append targets nil)))
              (images (seq-filter
                       (lambda (type)
                         (let ((parts (split-string (symbol-name type) "/")))
                           (and (equal (car parts) "image")
                                (cadr parts)
                                (image-type-available-p (intern (cadr parts)))
                                (gui-get-selection 'CLIPBOARD type))))
                       types))
              (best (car (sort images
                               (lambda (a b)
                                 (< (tagarela--image-mime-rank (symbol-name a))
                                    (tagarela--image-mime-rank (symbol-name b))))))))
    (let ((data (gui-get-selection 'CLIPBOARD best)))
      (when (stringp data)
        (cons (symbol-name best) (tagarela--image-bytes data))))))

;;;###autoload
(defun tagarela-yank ()
  "Yank from the clipboard: an image when there is one, else text.
When the clipboard holds an image this Emacs can render, the best one (per
`tagarela-image-mime-priority') is inserted inline without prompting;
otherwise this falls back to the normal text `yank'."
  (interactive)
  (if-let ((image (ignore-errors (tagarela--clipboard-image))))
      (tagarela--yank-media-image (intern (car image)) (cdr image))
    (call-interactively #'yank)))

;;;###autoload
(defun tagarela-attach-image-file (file)
  "Attach the image FILE to the next prompt (sent to the bridge by path)."
  (interactive "fImage file: ")
  (let ((file (expand-file-name file)))
    (unless (file-readable-p file)
      (user-error "Cannot read image file: %s" file))
    (with-current-buffer (tagarela--request-buffer)
      (tagarela--insert-image (list :path file)))
    (message "Image attached: %s" file)))

;;;###autoload
(defun tagarela-attach-image-url (url)
  "Attach the image at URL to the next prompt (passed through to the provider)."
  (interactive "sImage URL: ")
  (with-current-buffer (tagarela--request-buffer)
    (tagarela--insert-image (list :url url)))
  (message "Image URL attached: %s" url))

(defun tagarela--buffer-collect-segments ()
  "Collect the current (input) buffer as an ordered list of segments.
Each segment is a cons (KIND . VALUE): KIND is either `text' (VALUE the text
run, with the image placeholders removed) or `image' (VALUE an image spec
plist).  Segments appear in buffer order, so an image pasted above a caption
comes before it and one pasted below comes after — this is what the echo in
`tagarela--prompt-send' uses to reproduce the order the user typed."
  (let ((pt (point-min))
        (segments '()))
    (while (< pt (point-max))
      (let* ((next (or (next-single-property-change pt 'tagarela-image nil (point-max))
                       (point-max)))
             (spec (get-text-property pt 'tagarela-image)))
        (push (if spec
                  (cons 'image spec)
                (cons 'text (buffer-substring-no-properties pt next)))
              segments)
        (setq pt next)))
    (nreverse segments)))

(defun tagarela--buffer-collect ()
  "Collect the text and the images of the current (input) buffer.
Returns (TEXT . IMAGES): TEXT is the buffer text with the image placeholders
removed, IMAGES the list of image specs (plists) in order of appearance."
  (let ((texts '())
        (images '()))
    (dolist (seg (tagarela--buffer-collect-segments))
      (if (eq (car seg) 'image)
          (push (cdr seg) images)
        (push (cdr seg) texts)))
    (cons (apply #'concat (nreverse texts))
          (nreverse images))))

;;; Step 5 — Conversation buffer and input buffer

(defvar tagarela-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a q") #'tagarela-quit)
    (define-key map (kbd "C-c a k") #'tagarela-kill)
    map)
  "Keymap for `tagarela-mode'.")

(define-minor-mode tagarela-mode
  "Minor mode for the llm-bridge conversation buffer."
  :lighter " LB")

(defun tagarela--get-buffer ()
  "Return the conversation buffer, creating it if needed."
  (let ((buf (get-buffer-create tagarela-buffer-name)))
    (with-current-buffer buf
      (unless buffer-read-only
        (setq buffer-read-only t))
      (unless tagarela-mode
        (tagarela-mode 1))
      (unless (cl-member '(:eval (tagarela--mode-line-status))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (tagarela--mode-line-status))))))
      ;; Hide the position (line/column/%) — the buffer is a chat log whose
      ;; size changes at every chunk, so the position counter would flicker
      ;; frantically during streaming and make the mode-line (and the
      ;; spinner) look unstable.
      (setq-local mode-line-position nil))
    buf))

(defun tagarela--insert-propertized (text &rest props)
  "Insert TEXT at the end of the conversation buffer with PROPS (plist).
The displayed window follows along when it was already showing the end.
Return the buffer position where TEXT was inserted (start of TEXT)."
  (let ((buf (tagarela--get-buffer)))
    (with-current-buffer buf
      (let* ((win (get-buffer-window buf t))
             (at-bottom (or (null win)
                            (>= (window-point win) (1- (point-max)))))
             (inhibit-read-only t)
             (start (point-max)))
        (goto-char (point-max))
        (insert (if props (apply #'propertize text props) text))
        (goto-char (point-max))
        (when (and win at-bottom)
          (set-window-point win (point-max)))
        start))))

(defun tagarela--insert (text)
  "Insert TEXT at the end of the conversation buffer."
  (tagarela--insert-propertized text))

(defun tagarela--insert-propertized-at (pos text &rest props)
  "Insert TEXT at buffer position POS (or at the end if POS is nil) with PROPS.
Return the buffer position where TEXT was inserted (start of TEXT)."
  (let ((buf (tagarela--get-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (target (or pos (point-max))))
        (goto-char target)
        (insert (if props (apply #'propertize text props) text))
        target))))

(defun tagarela--prompt-send (text &optional images segments)
  "Core routine: echo TEXT in the conversation and send it as a prompt.
IMAGES, when non-nil, is a list of image specs collected from the input
buffer (see `tagarela--buffer-collect'); they are echoed inline and attached
to the prompt as the `images' array.  SEGMENTS, when non-nil, is the ordered
list of (KIND . VALUE) segments from `tagarela--buffer-collect-segments' and
is used to echo the images interleaved with the text the way the user typed
them (an image above a caption stays above it, and vice versa).  A message
whose trimmed text starts with \"#\" is sent as a local hook instead (images
are then ignored, as a hook is not an LLM call).  Rejects a new prompt while
a turn is in progress."
  (tagarela--ensure-ready)
  (when (or tagarela-in-turn tagarela-pending-tools)
    (error "There is a turn in progress; wait for it to finish"))
  (if (string-prefix-p "#" (string-trim-left text))
      (tagarela--hook-send text)
    (let ((text (if (and images (string-empty-p (string-trim text)))
                    "(imagem)" text)))
      (tagarela--render-answer)
      (setq tagarela-in-turn t
            tagarela--thinking-separator-pending nil
            tagarela--after-tool-separator-pending nil
            tagarela--current-turn-input-tokens 0
            tagarela--current-turn-output-tokens 0
            tagarela--turn-finalized nil)
      (tagarela--start-spinner)
      (tagarela--insert-propertized
       "\n──────────────────────────────\n"
       'face 'tagarela-separator-face)
      (tagarela--insert-propertized
       (concat ">>> " (tagarela--prompt-echo-body text images segments) "\n")
       'face 'tagarela-user-face)
      (tagarela--insert "\n")
      (tagarela--send "prompt" (tagarela--prompt-params text images)))))

(defun tagarela--prompt-echo-body (text images segments)
  "Return the echoing body (after the \">>> \") for a prompt.
TEXT is the raw prompt text and IMAGES its image specs.  SEGMENTS, when
non-nil, is the ordered list of (KIND . VALUE) segments typed in the input
buffer; the images are placed where the user put them and each text block is
trimmed for display.  When SEGMENTS is nil the images are appended after the
text (used by direct callers such as the slash-command prompt echo).  A
`[🖼 N]' badge and the per-request annotation trail the first line."
  (let ((suffix (concat (if images (format "  [🖼 %d]" (length images)) "")
                        (tagarela--request-annotation)))
        (chunks
         (if segments
             (delq nil
                   (mapcar (lambda (seg)
                             (let ((chunk (if (eq (car seg) 'image)
                                              (tagarela--image-string (cdr seg))
                                            (string-trim (cdr seg)))))
                               (unless (string-empty-p chunk) chunk)))
                           segments))
           (list (string-trim text)))))
    (when (null chunks)
      (setq chunks (list (if images "(imagem)" (string-trim text)))))
    (concat (car chunks) suffix
            (mapconcat (lambda (c) (concat "\n" c)) (cdr chunks) ""))))

(defun tagarela--hook-send (text)
  "Echo TEXT (a local hook command) and send it to the bridge as a prompt.
TEXT must start with \"#\" (the caller, `tagarela--prompt-send', has
already checked it and applied the shared turn-in-progress guard).  The
bridge runs the local script instead of calling the LLM and replies
asynchronously with a single `hook_action' event and no `turn_end'; the
client-side turn state is still marked in progress here and closed by
`tagarela--on-hook-action'."
  (tagarela--render-answer)
  (setq tagarela-in-turn t
        tagarela--thinking-separator-pending nil
        tagarela--after-tool-separator-pending nil
        tagarela--current-turn-input-tokens 0
        tagarela--current-turn-output-tokens 0
        tagarela--turn-finalized nil)
  (tagarela--start-spinner)
  (tagarela--insert-propertized
   "\n──────────────────────────────\n"
   'face 'tagarela-separator-face)
  (tagarela--insert-propertized
   (format ">>> %s\n\n" text)
   'face 'tagarela-hook-face)
  (tagarela--send "prompt" (tagarela--prompt-params text)))

(defcustom tagarela-project-dir nil
  "Base directory under which the `/project' command resolves its argument.

When non-nil (e.g. \"~/mysrc/\") the `/project' argument is taken as a
project NAME and resolved to BASE/NAME, so `/project tupi' means
`~/mysrc/tupi/'.  When nil (the default) the argument is taken as a PATH and
expanded with `expand-file-name' — an absolute path, a `~' path or a path
relative to `default-directory' all work."
  :type '(choice (const :tag "Argument is a path" nil)
                 (directory :tag "Base directory for project names"))
  :group 'tagarela)

(defcustom tagarela-project-change-hook nil
  "Hook run after the `/project' command switches the working directory.
The hook is called with a single argument: the new project directory.  Use
it to react to a project change (e.g. reload project-specific commands or
keybindings); the package itself knows nothing about projects."
  :type 'hook
  :group 'tagarela)

(defun tagarela--apply-project-dir-locals (dir)
  "Set `default-directory' of the current buffer to DIR and load its
.dir-locals.el, respecting `safe-local-variable-values'.

Uses `hack-dir-local-variables-non-file-buffer' so that only variables
present in `safe-local-variable-values' are applied silently; unsafe ones
prompt the user.  The `hack-local-variables-hook' runs afterwards, so any
hook it triggers (e.g. project keybindings) fires as usual."
  (setq default-directory (file-name-as-directory dir))
  (when (file-exists-p (expand-file-name ".dir-locals.el" dir))
    (hack-dir-local-variables-non-file-buffer)))

(defun tagarela--handle-slash-command (text)
  "Check if TEXT is a slash command (e.g. /project <name>), execute it and return non-nil if handled.

The `/project' argument is resolved against `tagarela-project-dir': when that
variable is non-nil the argument is a project NAME (resolved as BASE/NAME),
otherwise it is a PATH expanded with `expand-file-name'.  After switching the
new directory is passed to `tagarela-project-change-hook'."
  (cond
   ((string-match "^/project[[:space:]]+\\(.+\\)$" text)
    (let* ((arg (string-trim (match-string 1 text)))
           (base (and tagarela-project-dir
                      (file-name-as-directory
                       (expand-file-name tagarela-project-dir))))
           (dir (expand-file-name arg base)))
      (if (not (file-directory-p dir))
          (error "Project directory does not exist: %s" dir)
        (tagarela--apply-project-dir-locals dir)
        (with-current-buffer (tagarela--request-buffer)
          (tagarela--apply-project-dir-locals dir))
        (with-current-buffer (tagarela--get-buffer)
          (tagarela--apply-project-dir-locals dir))
        (tagarela--send "set_cwd" (list "cwd" dir))
        (run-hook-with-args 'tagarela-project-change-hook dir)
        (dolist (buf (list (get-buffer "*GNU Emacs*") (get-buffer "*scratch*")))
          (when buf
            (with-current-buffer buf
              (tagarela--apply-project-dir-locals dir))))
        (tagarela--insert-propertized
         (format "\n[project set to %s]\n" dir)
         'face 'tagarela-separator-face)
        (message "Project set to %s" dir))
      t))
   (t nil)))

(defun tagarela-send-input ()
  "Send the current input buffer contents to the bridge and clear it.
Images pasted/attached in the buffer are collected as attachments (see
`tagarela--buffer-collect') and sent with the prompt; a slash command never
carries images."
  (interactive)
  (let* ((segments (tagarela--buffer-collect-segments))
         (collected (tagarela--buffer-collect))
         (text (car collected))
         (images (cdr collected))
         (has-text (string-match-p "[^[:space:]]" text)))
    (when (or has-text images)
      (unless (and has-text (tagarela--handle-slash-command text))
        (tagarela--prompt-send text images segments))
      (erase-buffer))))

(define-minor-mode tagarela-input-mode
  "Minor mode for typing input destined to the llm-bridge.
C-c C-c sends the whole buffer; RET inserts a newline.  C-y yanks an image
from the clipboard when there is one (see `tagarela-yank')."
  :lighter " LBIn"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'tagarela-send-input)
            (define-key map (kbd "C-y") #'tagarela-yank)
            (define-key map (kbd "RET") #'newline)
            (define-key map (kbd "C-j") #'newline)
            map)
  (when tagarela-input-mode
    ;; Let `yank-media' (and `tagarela-yank', via it) insert clipboard
    ;; images inline in this buffer.
    (yank-media-handler "image/.*" #'tagarela--yank-media-image)))

(defun tagarela--mode-line-session ()
  "Return the mode-line fragment with the session token usage and model.
Shows tokens sent (↑, input), tokens received (↓, output), the prompt-cache
hit/miss totals (⚡, shown only when the provider reports any) and the model
of the current session, e.g. \" [↑12 ↓8 ⚡900/124 deepseek-chat]\"."
  (let* ((hit tagarela-session-cache-hit-tokens)
         (miss tagarela-session-cache-miss-tokens)
         (cache (if (> (+ hit miss) 0) (format "⚡%d/%d " hit miss) ""))
         (s (format " [↑%d ↓%d %s%s]"
                    tagarela-session-input-tokens
                    tagarela-session-output-tokens
                    cache
                    (or tagarela-session-model "?"))))
    (propertize s 'help-echo
                "↑ tokens sent · ↓ tokens received · ⚡ prompt-cache hit/miss · session model")))

(defun tagarela--mode-line-request ()
  "Return the mode-line fragment describing the per-request overrides.
Shows the model, thinking and effort overrides set for the next prompt,
e.g. \" [model=deepseek-reasoner thinking=on effort=high]\".  Empty when no
override is set."
  (let ((ann (tagarela--request-annotation)))
    (if (string-empty-p ann)
        ""
      (propertize ann 'help-echo "Per-request overrides (C-c a m / t / e)"))))

(defun tagarela--setup-input-mode-line ()
  "Install the session and request indicators in the input buffer's
mode-line (idempotent).  Creates the input buffer if it does not exist yet
(on a fresh open)."
  (let ((buf (or (get-buffer tagarela-input-buffer-name)
                 (get-buffer-create tagarela-input-buffer-name))))
    (with-current-buffer buf
      (unless (cl-member '(:eval (tagarela--mode-line-session))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (tagarela--mode-line-session))))))
      (unless (cl-member '(:eval (tagarela--mode-line-request))
                         mode-line-misc-info :test #'equal)
        (setq-local mode-line-misc-info
                    (append mode-line-misc-info
                            (list '(:eval (tagarela--mode-line-request)))))))))

;;;###autoload
(defun tagarela-open ()
  "Start the bridge and set up the llm-bridge window layout.
Divides the selected window in two: the left side keeps the buffer that
was already open and the right side shows the llm-bridge (conversation
on top, input buffer below, ~20% of the frame height)."
  (interactive)
  (tagarela--ensure-ready)
  (tagarela--setup-input-mode-line)
  (let ((conv (tagarela--get-buffer))
        (in (get-buffer-create tagarela-input-buffer-name)))
    (if (get-buffer-window conv)
        ;; Already open: focus the conversation and ensure the input below it.
        (progn
          (select-window (get-buffer-window conv))
          (unless (get-buffer-window tagarela-input-buffer-name)
            (split-window-below)
            (other-window 1)
            (switch-to-buffer in)
            (tagarela-input-mode 1)))
      ;; Split the current window in two: left = already-open buffer,
      ;; right = conversation (top) + input (bottom).
      (split-window-right)
      (other-window 1)                    ; right window
      (switch-to-buffer conv)
      (split-window-below)
      (other-window 1)                    ; bottom window of the right side
      (switch-to-buffer in)
      (tagarela-input-mode 1))
    ;; Adjust the bottom window (input) to ~20% of the total frame height
    (let* ((input-window (get-buffer-window tagarela-input-buffer-name))
           (frame-height (window-total-height (frame-root-window)))
           (target-height (max 1 (round (* frame-height 0.2))))
           (delta (- target-height (window-total-height input-window))))
      (when input-window
        (window-resize input-window delta nil t)))))

;;; Step 9 — Batch confirmation, trust scope and UX

(defun tagarela--cancel-confirm ()
  "Cancel any pending batch tool confirmation."
  (when (timerp tagarela--confirm-timer)
    (cancel-timer tagarela--confirm-timer)
    (setq tagarela--confirm-timer nil))
  (setq tagarela--confirm-queue nil)
  (setq tagarela--confirm-context nil)
  (setq tagarela--trust-context nil)
  (setq tagarela--menu-answered nil))

(defun tagarela--schedule-confirm ()
  "Schedule the batch tool confirmation 0.5s after the last tool_call."
  (when (timerp tagarela--confirm-timer)
    (cancel-timer tagarela--confirm-timer))
  (setq tagarela--confirm-timer
        (run-with-timer 0.5 nil #'tagarela--confirm-pending)))

(defun tagarela--keep-question-visible (pos)
  "Scroll the llm-bridge conversation window so that buffer position POS
stays visible, a few lines below the top of the window.

POS is normally the start of the tool-confirmation line just inserted, or
the start of the tool-call parameters while the confirmation question is
being asked (see `tagarela--confirm-pending').  After scrolling, that
line sits near the top — not centered — so the question and the beginning of
a large diff remain on screen together even when the diff is much taller
than the window."
  (let ((win (get-buffer-window tagarela-buffer-name t)))
    (when (and win pos (window-live-p win))
      (let ((sel (selected-window)))
        (unwind-protect
            (progn
              (select-window win)
              (goto-char (max (point-min) (min pos (point-max))))
              ;; a few lines of context above the line, the rest of the
              ;; (possibly large) diff fills the window below — never
              ;; centered mid-diff
              (recenter 3))
          (select-window sel))))))

(defun tagarela--record-tool-confirmation (_name _input allowed &optional trust)
  "Record the tool-confirmation decision for a mutating tool call in the
conversation buffer.  ALLOWED non-nil when the user permitted it.  The
confirmation question line (the `Run tool: <name> · <detail>?' prompt) was
already inserted by `tagarela--show-tool-call'; this function merely
prepends the visible `[allowed]' / `[denied]' tag (in the tool / error face)
to the front of that same line (at `tagarela--tool-call-pos'), so the
question is visible from the start and only the outcome is added after the
answer.  When TRUST is non-nil the tag is `[trusted]' instead (same face as
`[allowed]').  Keeps the line on screen (at least 2 lines from the top) via
`tagarela--keep-question-visible'.  Returns the buffer position of the
recorded line."
  (let* ((status-face (if allowed
                          'tagarela-tool-face
                        'tagarela-error-face))
         (prefix (propertize (cond (trust "[trusted] ")
                                   (allowed "[allowed] ")
                                   (t "[denied] "))
                             'face status-face)))
    (if tagarela--tool-call-pos
        (progn
          (tagarela--insert-propertized-at
           tagarela--tool-call-pos prefix)
          (tagarela--keep-question-visible tagarela--tool-call-pos)
          tagarela--tool-call-pos)
      ;; No preceding visible question line (only happens if the confirmation
      ;; is recorded without `tagarela--show-tool-call' having run);
      ;; fall back to appending the tag at the end of the buffer.
      (tagarela--insert-propertized-at nil prefix))))

(defun tagarela--ask-user-trust (prompt)
  "Ask the user PROMPT and return `run', `deny' or `trust'.
Reads a single char: y/Y runs the tool once, n/N denies it, ! opens the
trust-scope menu (run every time from then on)."
  (let ((ch (read-char-choice (concat prompt "(y)es / (n)o / (!)trust ")
                              '(?y ?Y ?n ?N ?!))))
    (pcase ch
      ((or ?y ?Y) 'run)
      ((or ?n ?N) 'deny)
      (_ 'trust))))

(defun tagarela--trust-pause (name input id rest denied)
  "Pause batch confirmation for tool NAME/INPUT/ID to pick a trust scope.
Saves the remaining REST of the queue and the DENIED flag in
`tagarela--trust-context' and opens the trust menu."
  (setq tagarela--trust-context
        (list :name name :input input :id id :rest rest :denied denied))
  (setq tagarela--menu-answered nil)
  (tagarela--trust-menu))

(defun tagarela--trust-finish (scope)
  "Record the trust chosen in SCOPE for the paused tool call and resume.
Reads the paused context, records the trust, marks the current tool as
`[trusted]' (or `[allowed]' when the scope could not record a trust, e.g. a
`class' on a tool without a class key), dispatches it guarded, and continues
confirming the rest of the batch."
  (let* ((ctx tagarela--trust-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (id (plist-get ctx :id))
         (rest (plist-get ctx :rest))
         (denied (plist-get ctx :denied)))
    (setq tagarela--trust-context nil)
    ;; Nothing paused (e.g. the turn was cancelled while the sub-menu was
    ;; open): do not dispatch a nil tool call.
    (when name
      (tagarela--trust-record scope name input)
      (if (tagarela--trusted-p name input)
          (tagarela--record-tool-confirmation name input t "trusted")
        (tagarela--record-tool-confirmation name input t))
      (tagarela--dispatch-tool-guarded name input id)
      (tagarela--confirm-next rest denied))))

(defun tagarela--trust-description (kind)
  "Return a menu description for the paused trust context of KIND.
KIND is one of the symbols `specific', `class' or `all'.  Reads the paused
tool call from `tagarela--trust-context' so the menu shows exactly
what is being approved: the concrete command/pattern/path for `specific',
the class key (e.g. the first `shell' command token or the file's
directory) for `class' and the tool name for `all' — so, for example, a
`sed' class is shown as \"This class of calls: sed\" instead of an
ambiguous label."
  (let ((name (plist-get tagarela--trust-context :name))
        (input (plist-get tagarela--trust-context :input)))
    (pcase kind
      ('all
       (if name
           (format "This whole tool: %s" name)
         "This whole tool"))
      ('class
       (if (and name input)
           (let ((key (tagarela--trust-class-key name input)))
             (if key
                 (format "This class of calls: %s" key)
               "This class of calls"))
         "This class of calls"))
      ('specific
       (let ((detail (if (and name input)
                         (tagarela--tool-detail-string name input)
                       "")))
         (if (string-empty-p detail)
             "This specific call"
           (format "This specific call: %s" detail))))
      (_ ""))))

(defun tagarela--trust-cancel ()
  "Abort a paused trust choice: deny the tool and abort the batch.
Called when the trust sub-menu is closed without picking a scope (e.g.
`C-g'): the paused tool call in `tagarela--trust-context' is recorded
`[denied]' and the remaining batch is auto-denied, ending in a `cancel' so
the turn does not hang."
  (let* ((ctx tagarela--trust-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (rest (plist-get ctx :rest)))
    (setq tagarela--trust-context nil)
    (when name
      (tagarela--record-tool-confirmation name input nil))
    (tagarela--confirm-next rest t)))

(defun tagarela--menu-exit-hook ()
  "Deny the pending tool call when a confirmation menu closes unanswered.
Runs on `transient-exit-hook'.  The batch confirmation is asked through a
transient menu whose suffixes record the answer (via
`tagarela--menu-answered') and consume the pending context; when the
user closes the menu WITHOUT picking an option (e.g. `C-g'), no suffix runs
and, without this, neither a `tool_result' nor a `cancel' would ever be sent
— the turn would hang waiting forever.  Detect that by the still-pending
context plus the unanswered flag and treat it as a deny: the current tool is
recorded `[denied]' and the batch is aborted with a `cancel'.  The answer is
applied from a 0s timer so the transient has fully exited before the batch
continues (a deny never reopens a menu, so this cannot recurse into a new
transient from inside the exit hook)."
  (unless tagarela--menu-answered
    (cond
     (tagarela--confirm-context
      (run-with-timer 0 nil #'tagarela--confirm-answer 'deny))
     (tagarela--trust-context
      (run-with-timer 0 nil #'tagarela--trust-cancel)))))

;;; Confirmation and trust menus (transient).  Transient is loaded first
;;; (top-level) so the guard below always sees `transient-define-prefix'
;;; defined — otherwise the chicken-and-egg (checking fboundp BEFORE requiring)
;;; would skip the menu definitions at startup and `--confirm-menu' /
;;; `--trust-menu' would end up void.  The guard remains for batch test
;;; environments (-Q) without transient; there `--ask-user-trust'
;;; (`read-char-choice') is the fallback question.

(require 'transient nil t)
(when (fboundp 'transient-define-prefix)
  ;; Run once / deny suffixes.  The batch is continued from a 0s timer so the
  ;; current menu is fully closed before the next tool's question is asked (it
  ;; may open another menu).  The trust choice is a sub-menu (`--trust-menu').
  (transient-define-suffix tagarela--confirm-run ()
    "Run the pending tool call once."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--confirm-answer 'run))
  (transient-define-suffix tagarela--confirm-deny ()
    "Deny the pending tool call (cancels the rest of the batch)."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--confirm-answer 'deny))
  (transient-define-suffix tagarela--confirm-trust ()
    "Open the trust-scope sub-menu for the pending tool call.
Routed through `tagarela--confirm-answer' (rather than binding the
menu key straight to `tagarela--trust-menu') so that
`tagarela--trust-pause' runs first and saves the paused tool call in
`tagarela--trust-context'; without it the trust sub-menu would read an
empty context and dispatch a nil tool call, leaving the turn hanging."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--confirm-answer 'trust))
  (transient-define-prefix tagarela--trust-menu ()
    "Choose how broadly to trust the pending tool call."
    [["Trust"
      ("s" (lambda () (tagarela--trust-description 'specific))
       tagarela--trust-finish-specific)
      ("c" (lambda () (tagarela--trust-description 'class))
       tagarela--trust-finish-class)
      ("a" (lambda () (tagarela--trust-description 'all))
       tagarela--trust-finish-all)]])
  (transient-define-suffix tagarela--trust-finish-specific ()
    "Trust only this exact call."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--trust-finish 'specific))
  (transient-define-suffix tagarela--trust-finish-class ()
    "Trust this whole class of calls (shell command token / path directory)."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--trust-finish 'class))
  (transient-define-suffix tagarela--trust-finish-all ()
    "Trust every call of this tool."
    (interactive)
    (setq tagarela--menu-answered t)
    (run-with-timer 0 nil #'tagarela--trust-finish 'all))
  ;; The confirmation menu.  The question for the tool being confirmed (icon +
  ;; command/pattern/path) is shown as a dynamic `:info' line at the top of the
  ;; menu, rebuilt each time the menu opens from
  ;; `tagarela--confirm-context'.  (`(:info FUN)' with a function
  ;; description is used instead of a group description because the latter is
  ;; only supported by newer transients; `:info' works with the bundled Emacs
  ;; one too.)  `t' opens the trust sub-menu.
  (transient-define-prefix tagarela--confirm-menu ()
    "Run the pending tool call?"
    [["Confirm"
      (:info (lambda () (tagarela--confirm-menu-question)))
      ("r" "Run once" tagarela--confirm-run)
      ("d" "Deny" tagarela--confirm-deny)
      ("t" "Trust…" tagarela--confirm-trust)]])
  ;; A confirmation (or trust) menu closed without an answer — `C-g', or any
  ;; other exit that runs no suffix — must not leave the turn hanging: the
  ;; exit hook treats it as a deny and aborts the batch.
  (add-hook 'transient-exit-hook #'tagarela--menu-exit-hook))

(defun tagarela--confirm-menu-question ()
  "Return the question shown at the top of the confirmation menu.
Reads the pending tool call from `tagarela--confirm-context' so the
menu displays exactly what is about to run (icon + command/pattern/path)."
  (let ((name (plist-get tagarela--confirm-context :name))
        (input (plist-get tagarela--confirm-context :input)))
    (tagarela--confirm-question name input)))

(defun tagarela--confirm-pending (&optional queue)
  "Confirm and execute each tool queued for confirmation, one question per
tool call.  When the model responds with several tool calls the user is
asked once for each of them (rather than a single batch question covering
all), and each tool call is shown one at a time: the next one is only
displayed (and asked) after the previous one has been answered, so the
questions never pile up on screen together.  Before each question the
conversation window is scrolled so the top of the tool call (and the
beginning of a possibly large diff) is visible.  Each confirmation is
recorded in the conversation buffer and kept near the top after the user
answers, so the question and the start of the diff do not disappear.

When one tool call is denied, every tool call left in the batch is denied
automatically (without asking) and the turn is cancelled: the bridge stops
waiting for / running the pending tools, so the conversation falls back to
waiting for the user's next prompt.

The questions are asked through the transient `tagarela--confirm-menu'
(or, without transient, the `tagarela--ask-user-trust' char prompt).
Because the menu is asynchronous, the batch is driven by
`tagarela--confirm-next' / `tagarela--confirm-answer' rather than
by a single blocking loop."
  (setq tagarela--confirm-timer nil)
  (let ((queue (or queue
                   (prog1 tagarela--confirm-queue
                     (setq tagarela--confirm-queue nil)))))
    (tagarela--confirm-next queue nil)))

(defun tagarela--confirm-next (queue denied)
  "Show and process the first tool call in QUEUE, then continue the batch.
DENIED non-nil means an earlier tool of this batch was denied, so every
remaining tool is denied right away (no question).  Each tool is displayed
one at a time.  The first tool that must be asked is saved in
`tagarela--confirm-context' and its question opened; the batch is
resumed by `tagarela--confirm-answer'.  When the queue is exhausted,
a denial cancels the turn."
  (if (null queue)
      (when denied
        (tagarela-cancel))
    (let* ((tc (car queue))
           (rest (cdr queue))
           (id (plist-get tc :id))
           (name (plist-get tc :name))
           (input (plist-get tc :input)))
      ;; Show this tool call now (one at a time), so only the tool being
      ;; confirmed appears on screen — not every tool of the batch.
      (tagarela--show-tool-call id name input)
      (cond
       ;; A previous tool was denied: refuse this one too, no question.  No
       ;; tool_result is sent — the batch is aborted with a `cancel' at the end.
       (denied
        (tagarela--record-tool-confirmation name input nil)
        (tagarela--confirm-next rest t))
       ;; Already trusted: run directly, no question.
       ((tagarela--trusted-p name input)
        (tagarela--record-tool-confirmation name input t "trusted")
        (tagarela--dispatch-tool-guarded name input id)
        (tagarela--confirm-next rest nil))
       ;; Otherwise ask the user, saving the batch state for the answer.
       (t
        ;; Bring the top of the tool call into view before asking: with a large
        ;; diff the insertion left the window scrolled to the end, so without
        ;; this the user would not see the line being confirmed.
        (tagarela--keep-question-visible tagarela--tool-call-pos)
        (setq tagarela--confirm-context
              (list :name name :input input :id id :rest rest :denied denied))
        (tagarela--confirm-ask name input))))))

(defun tagarela--confirm-ask (name input)
  "Ask the user whether to run tool NAME with INPUT.
Opens the transient `tagarela--confirm-menu' when transient is
available; otherwise falls back to `tagarela--ask-user-trust' and
applies the answer synchronously via `tagarela--confirm-answer'.
This is the single seam the batch tests stub to answer without a menu.
Closing the question without answering is treated as a deny: the menu path
is handled by `tagarela--menu-exit-hook' and the char-prompt fallback
by the `quit' handler here, so the turn never hangs."
  (if (fboundp 'tagarela--confirm-menu)
      (progn
        (setq tagarela--menu-answered nil)
        (tagarela--confirm-menu))
    (condition-case nil
        (tagarela--confirm-answer
         (tagarela--ask-user-trust
          (tagarela--confirm-question name input)))
      (quit (tagarela--confirm-answer 'deny)))))

(defun tagarela--confirm-answer (answer)
  "Apply ANSWER (`run', `deny' or `trust') to the pending confirmation.
Reads the pending tool call and the remaining batch from
`tagarela--confirm-context' and continues via
`tagarela--confirm-next'.  Called by the confirmation menu suffixes
(via `tagarela--confirm-run'/`--confirm-deny') and by the fallback
path in `tagarela--confirm-ask'."
  (let* ((ctx tagarela--confirm-context)
         (name (plist-get ctx :name))
         (input (plist-get ctx :input))
         (id (plist-get ctx :id))
         (rest (plist-get ctx :rest))
         (denied (plist-get ctx :denied)))
    ;; Consume the pending context: it has been read above and a stale
    ;; `--confirm-context' could otherwise be reused by a later menu rebuild.
    (setq tagarela--confirm-context nil)
    (pcase answer
      ('deny
       ;; Record the `[denied]' tag, but do NOT send a tool_result — the turn
       ;; is aborted with a `cancel' (once, at the end of the batch), so a
       ;; redundant tool_result would only race the cancel and make the bridge
       ;; error with \"tool_result without pending tool call\".
       (tagarela--record-tool-confirmation name input nil)
       (tagarela--confirm-next rest t))
      ('trust
       ;; Pause to pick a scope; `--trust-finish' runs this tool (as
       ;; `[trusted]') and continues the rest of the batch.
       (tagarela--trust-pause name input id rest denied))
      (_ ;; run once
       (tagarela--record-tool-confirmation name input t)
       (tagarela--dispatch-tool-guarded name input id)
       (tagarela--confirm-next rest denied)))))

;;; Step 4 — User commands (basic interaction)

;;;###autoload
(defun tagarela-prompt (text)
  "Send TEXT as a prompt to the bridge."
  (interactive "sPrompt: ")
  (tagarela--prompt-send text))

;;;###autoload
(defun tagarela-cancel ()
  "Cancel the current in-flight turn and stop any running tool command."
  (interactive)
  ;; Stop any asynchronous tool command (shell/grep) still running: otherwise
  ;; it would keep running after the turn is cancelled and send a late
  ;; tool_result the bridge no longer expects.
  (dolist (p tagarela--tool-procs)
    (when (process-live-p p)
      (delete-process p)))
  (setq tagarela--tool-procs nil)
  (when (and tagarela-process (process-live-p tagarela-process))
    (tagarela--send "cancel")))

;;;###autoload
(defun tagarela-set-cwd (dir)
  "Set the bridge working directory to DIR."
  (interactive "DWorking dir: ")
  (tagarela--send "set_cwd" (list "cwd" (expand-file-name dir))))

;;;###autoload
(defun tagarela-set-provider (provider)
  "Set the provider override for the next prompt (empty = default).
The override is sent as the `provider' field of the next `prompt'."
  (interactive
   (list (completing-read
          "Provider for the next prompt (empty = default): "
          '("deepseek" "google") nil t)))
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-provider provider))
  (force-mode-line-update t)
  (message "Provider for the next prompt: %s"
           (if (string-empty-p provider) "(default)" provider)))

;;;###autoload
(defun tagarela-set-model (model)
  "Set the model override for the next prompt (empty = provider default).
The override is sent as the `model' field of the next `prompt' and stays
active for the following prompts until changed (mirrors the bridge)."
  (interactive "sModel for the next prompt (empty = provider default): ")
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-model model))
  (force-mode-line-update t)
  (message "Model for the next prompt: %s"
           (if (string-empty-p model) "(provider default)" model)))

;;;###autoload
(defun tagarela-set-thinking (thinking)
  "Set the thinking override for the next prompt: on, off or unset.
`on' forces thinking (deepseek-reasoner), `off' forces it off
(deepseek-chat) and `unset' restores the provider's configured mode."
  (interactive
   (list (intern (completing-read
                  "Thinking for the next prompt (unset/on/off): "
                  '("unset" "on" "off") nil t))))
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-thinking thinking))
  (force-mode-line-update t)
  (message "Thinking for the next prompt: %s"
           (pcase thinking
             ('t "on")
             ('off "off")
             (_ "unset (provider default)"))))

;;;###autoload
(defun tagarela-set-reasoning-effort (effort)
  "Set the thinking depth (reasoning_effort) for the next prompt.
One of \"low\", \"medium\" or \"high\"; empty = provider default."
  (interactive
   (list (completing-read
          "Reasoning effort for the next prompt (empty = default): "
          '("low" "medium" "high") nil t)))
  (with-current-buffer (tagarela--request-buffer)
    (setq-local tagarela-request-reasoning-effort effort))
  (force-mode-line-update t)
  (message "Reasoning effort for the next prompt: %s"
           (if (string-empty-p effort) "(provider default)" effort)))

(defun tagarela-set-knowledge-bases (bases)
  "Set the bridge knowledge BASES (list of hash tables)."
  (tagarela--send "set_knowledge_bases" (list "bases" bases)))

;;;###autoload
(defun tagarela-quit ()
  "Send `quit' to the bridge, ending the process."
  (interactive)
  (when (and tagarela-process (process-live-p tagarela-process))
    (tagarela--send "quit")))

;;; Step 10 — Shutdown and robustness

;;;###autoload
(defun tagarela-kill ()
  "Terminate the bridge, kill any running tool processes and clean state."
  (interactive)
  (tagarela--cancel-confirm)
  (when (and tagarela-process (process-live-p tagarela-process))
    (tagarela--send "quit")
    (sleep-for 0.1)
    ;; the sentinel may have already cleared the process; only delete if alive
    (when (and tagarela-process (process-live-p tagarela-process))
      (delete-process tagarela-process)))
  (dolist (p tagarela--tool-procs)
    (when (process-live-p p)
      (delete-process p)))
  (setq tagarela--tool-procs nil)
  (setq tagarela-process nil
        tagarela-ready nil
        tagarela-in-turn nil
        tagarela-pending-tools nil
        tagarela-line-buffer ""
        tagarela--after-tool-separator-pending nil)
  ;; Detach the pending-answer marker: the buffers may be erased next
  ;; (`--restart'), and a stale marker would then re-render from position 1.
  (when (markerp tagarela--answer-start)
    (set-marker tagarela--answer-start nil))
  (setq tagarela--answer-start nil)
  (tagarela--reset-session))

(add-hook 'kill-emacs-hook #'tagarela-kill)

;;; Step 11 — Prefix keymap and interactive commands

;;;###autoload
(defun tagarela-restart ()
  "Restart the bridge: kill it, clear the buffers and reset the state.
Then reopen the llm-bridge window layout."
  (interactive)
  (tagarela-kill)
  (dolist (b (list (get-buffer tagarela-buffer-name)
                   (get-buffer tagarela-input-buffer-name)))
    (when b
      (with-current-buffer b
        (let ((inhibit-read-only t))
          (erase-buffer)))))
  (tagarela-open))

(defvar tagarela-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "l") #'tagarela-open)
    (define-key map (kbd "o") #'tagarela-open)
    (define-key map (kbd "r") #'tagarela-restart)
    (define-key map (kbd "k") #'tagarela-kill)
    (define-key map (kbd "c") #'tagarela-cancel)
    (define-key map (kbd "q") #'tagarela-quit)
    (define-key map (kbd "p") #'tagarela-set-provider)
    (define-key map (kbd "m") #'tagarela-set-model)
    (define-key map (kbd "t") #'tagarela-set-thinking)
    (define-key map (kbd "e") #'tagarela-set-reasoning-effort)
    (define-key map (kbd "i") #'tagarela-attach-image-file)
    (define-key map (kbd "u") #'tagarela-attach-image-url)
    map)
  "Keymap for the `C-c a' prefix of the llm-bridge commands.")

;;;###autoload
(global-set-key (kbd "C-c a") tagarela-prefix-map)

(provide 'tagarela-ui)

;;; tagarela-ui.el ends here
