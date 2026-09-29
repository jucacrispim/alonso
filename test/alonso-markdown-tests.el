;;; alonso-markdown-tests.el --- Tests for the alonso Markdown rendering and code-block font.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso Markdown rendering and code-block font.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'alonso-tests-lib)

;;; Markdown rendering of the model's answer
;;;
;;; Only the model's *answer* (the streaming `chunk' events) is rendered; the
;;; chain-of-thought and the tool-call lines are left as they are.  The
;;; fragments of an answer segment are accumulated and rendered in one shot
;;; when the segment closes (turn_end / thinking / tool call), so a construct
;;; is never rendered half-written (e.g. between the two `*' of a `**bold**').

(alonso-tests--with-rendered "# Title\n"
  (alonso-tests--assert
   "markdown: heading gets the level-1 face"
   (eq (alonso-tests--md-face "Title")
       'alonso-md-heading-1-face))
  (alonso-tests--assert
   "markdown: the heading marker is hidden"
   (equal "" (alonso-tests--md-display "#"))))

(alonso-tests--with-rendered "### Sub\n"
  (alonso-tests--assert
   "markdown: level-3 heading face"
   (eq (alonso-tests--md-face "Sub")
       'alonso-md-heading-3-face)))

(alonso-tests--with-rendered "a **bold** b\n"
  (alonso-tests--assert
   "markdown: bold text is propertized"
   (eq (alonso-tests--md-face "bold") 'alonso-md-bold-face))
  (alonso-tests--assert
   "markdown: the ** markers are hidden"
   (equal "" (alonso-tests--md-display "**"))))

(alonso-tests--with-rendered "an *emphatic* word\n"
  (alonso-tests--assert
   "markdown: italic text is propertized"
   (eq (alonso-tests--md-face "emphatic")
       'alonso-md-italic-face))
  (alonso-tests--assert
   "markdown: the * markers are hidden"
   (equal "" (alonso-tests--md-display "*"))))

(alonso-tests--with-rendered "~~gone~~ here\n"
  (alonso-tests--assert
   "markdown: strikethrough text is propertized"
   (eq (alonso-tests--md-face "gone")
       'alonso-md-strike-face)))

(alonso-tests--with-rendered "use `foo` here\n"
  (alonso-tests--assert
   "markdown: inline code is propertized"
   (eq (alonso-tests--md-face "foo")
       'alonso-md-inline-code-face))
  (alonso-tests--assert
   "markdown: the backticks are hidden"
   (equal "" (alonso-tests--md-display "`"))))

(alonso-tests--with-rendered "see [docs](https://example.com/x)\n"
  (alonso-tests--assert
   "markdown: the link text is propertized"
   (eq (alonso-tests--md-face "docs") 'alonso-md-link-face))
  (alonso-tests--assert
   "markdown: the link URL is stored as a text property"
   (equal "https://example.com/x"
          (alonso-tests--md-prop "docs" 'alonso-url)))
  (alonso-tests--assert
   "markdown: the link is clickable"
   (keymapp (alonso-tests--md-prop "docs" 'keymap)))
  (alonso-tests--assert
   "markdown: the [ marker is hidden"
   (equal "" (alonso-tests--md-display "[")))
  (alonso-tests--assert
   "markdown: the URL is shown visibly after the link text"
   (equal " (https://example.com/x)"
          (alonso-tests--md-display "]("))))

(alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
  (alonso-tests--assert
   "markdown: code block content keeps the base code face"
   (memq 'alonso-md-code-face
         (alonso-tests--md-faces "(setq x 1)")))
  (alonso-tests--assert
   "markdown: code block is syntax-highlighted (keyword face on `setq')"
   (memq 'font-lock-keyword-face
         (alonso-tests--md-faces "setq")))
  (alonso-tests--assert
   "markdown: the syntax face precedes the base face (wins the foreground)"
   (let ((faces (alonso-tests--md-faces "setq")))
     (and (cl-position 'font-lock-keyword-face faces)
          (cl-position 'alonso-md-code-face faces)
          (< (cl-position 'font-lock-keyword-face faces)
             (cl-position 'alonso-md-code-face faces)))))
  (alonso-tests--assert
   "markdown: the code fences are hidden"
   (equal "" (alonso-tests--md-display "```"))))

(alonso-tests--with-rendered "```python\nimport os\n```\n"
  (alonso-tests--assert
   "markdown: a python code block is syntax-highlighted"
   (memq 'font-lock-keyword-face
         (alonso-tests--md-faces "import"))))

(let ((alonso-fontify-code-blocks nil))
  (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
    (alonso-tests--assert
     "markdown: fontification can be disabled (base face only)"
     (equal '(alonso-md-code-face)
            (alonso-tests--md-faces "setq")))))

(alonso-tests--with-rendered "```\n(setq x 1)\n```\n"
  (alonso-tests--assert
   "markdown: a fence with no language is not fontified (base face only)"
   (equal '(alonso-md-code-face)
          (alonso-tests--md-faces "setq"))))

;;; Code-block font (alonso-md-code-font)

(alonso-tests--assert
 "markdown: by default the code face follows the conversation font"
 (progn
   (alonso--set-md-code-font 'alonso-md-code-font nil)
   (and (eq (face-attribute 'alonso-md-code-face :family) 'unspecified)
        (eq (face-attribute 'alonso-md-code-face :inherit) 'default))))

(alonso-tests--assert
 "markdown: alonso-md-code-font sets the code face font family"
 (prog1
     (progn
       (alonso--set-md-code-font 'alonso-md-code-font "Monospace")
       (equal (face-attribute 'alonso-md-code-face :family) "Monospace"))
   (alonso--set-md-code-font 'alonso-md-code-font nil)))

(alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
  (alonso-tests--assert
   "markdown: fontifying a code block does not change the buffer text"
   (equal "```elisp\n(setq x 1)\n```\n"
          (buffer-substring-no-properties (point-min) (point-max)))))

(alonso-tests--with-rendered "- item\n"
  (alonso-tests--assert
   "markdown: the bullet is replaced by a dot"
   (equal "•" (alonso-tests--md-display "-"))))

(alonso-tests--with-rendered "1. item\n"
  (alonso-tests--assert
   "markdown: the ordered-list number is propertized"
   (eq (alonso-tests--md-face "1.")
       'alonso-md-bullet-face)))

(alonso-tests--with-rendered "---\n"
  (alonso-tests--assert
   "markdown: a horizontal rule is drawn"
   (string-prefix-p "─" (or (alonso-tests--md-display "---") ""))))

(alonso-tests--with-rendered "plain text\n# h\n- l\n"
  (alonso-tests--assert
   "markdown: rendering never changes the buffer text"
   (equal "plain text\n# h\n- l\n"
          (buffer-substring-no-properties (point-min) (point-max)))))

(alonso-tests--with-rendered "the keep_alive name\n"
  (alonso-tests--assert
   "markdown: snake_case is left alone (no `_' italic)"
   (and (null (alonso-tests--md-face "_"))
        (null (alonso-tests--md-display "_")))))

(let ((alonso-render-markdown nil))
  (alonso-tests--with-rendered "# Title\n"
    (alonso-tests--assert
     "markdown: rendering can be disabled"
     (and (null (alonso-tests--md-display "#"))
          (null (alonso-tests--md-face "Title"))))))

(let ((alonso-hide-markdown-markers nil))
  (alonso-tests--with-rendered "a **bold** b\n"
    (alonso-tests--assert
     "markdown: with hiding off the markers stay visible (dimmed)"
     (and (null (alonso-tests--md-display "**"))
          (eq (alonso-tests--md-face "**") 'shadow)))))

(provide 'alonso-markdown-tests)

;;; alonso-markdown-tests.el ends here
