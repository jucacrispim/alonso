;;; tagarela-markdown-tests.el --- Tests for the tagarela Markdown rendering and code-block font.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the tagarela Markdown rendering and code-block font.
;;
;; Part of the tagarela test suite; `tagarela-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'tagarela-tests-lib)

;;; Markdown rendering of the model's answer
;;;
;;; Only the model's *answer* (the streaming `chunk' events) is rendered; the
;;; chain-of-thought and the tool-call lines are left as they are.  The
;;; fragments of an answer segment are accumulated and rendered in one shot
;;; when the segment closes (turn_end / thinking / tool call), so a construct
;;; is never rendered half-written (e.g. between the two `*' of a `**bold**').

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
   "markdown: the syntax face precedes the base face (wins the foreground)"
   (let ((faces (tagarela-tests--md-faces "setq")))
     (and (cl-position 'font-lock-keyword-face faces)
          (cl-position 'tagarela-md-code-face faces)
          (< (cl-position 'font-lock-keyword-face faces)
             (cl-position 'tagarela-md-code-face faces)))))
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

;;; Code-block font (tagarela-md-code-font)

(tagarela-tests--assert
 "markdown: by default the code face follows the conversation font"
 (progn
   (tagarela--set-md-code-font 'tagarela-md-code-font nil)
   (and (eq (face-attribute 'tagarela-md-code-face :family) 'unspecified)
        (eq (face-attribute 'tagarela-md-code-face :inherit) 'default))))

(tagarela-tests--assert
 "markdown: tagarela-md-code-font sets the code face font family"
 (prog1
     (progn
       (tagarela--set-md-code-font 'tagarela-md-code-font "Monospace")
       (equal (face-attribute 'tagarela-md-code-face :family) "Monospace"))
   (tagarela--set-md-code-font 'tagarela-md-code-font nil)))

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

(provide 'tagarela-markdown-tests)

;;; tagarela-markdown-tests.el ends here
