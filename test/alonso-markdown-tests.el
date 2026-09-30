;;; alonso-markdown-tests.el --- Tests for the alonso Markdown rendering and code-block font.  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso Markdown rendering and code-block font.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT (phase 1 of ERT-MIGRATION.md): one `ert-deftest' per
;; assertion, all tagged `markdown'.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'ert)
(require 'alonso-tests-lib)

;;; Markdown rendering of the model's answer
;;;
;;; Only the model's *answer* (the streaming `chunk' events) is rendered; the
;;; chain-of-thought and the tool-call lines are left as they are.  The
;;; fragments of an answer segment are accumulated and rendered in one shot
;;; when the segment closes (turn_end / thinking / tool call), so a construct
;;; is never rendered half-written (e.g. between the two `*' of a `**bold**').

(ert-deftest alonso-markdown--heading-1-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "# Title\n"
    (should (eq (alonso-tests--md-face "Title")
                'alonso-md-heading-1-face))))

(ert-deftest alonso-markdown--heading-1-marker-hidden ()
  :tags '(markdown)
  (alonso-tests--with-rendered "# Title\n"
    (should (equal "" (alonso-tests--md-display "#")))))

(ert-deftest alonso-markdown--heading-3-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "### Sub\n"
    (should (eq (alonso-tests--md-face "Sub")
                'alonso-md-heading-3-face))))

(ert-deftest alonso-markdown--bold-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "a **bold** b\n"
    (should (eq (alonso-tests--md-face "bold") 'alonso-md-bold-face))))

(ert-deftest alonso-markdown--bold-markers-hidden ()
  :tags '(markdown)
  (alonso-tests--with-rendered "a **bold** b\n"
    (should (equal "" (alonso-tests--md-display "**")))))

(ert-deftest alonso-markdown--italic-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "an *emphatic* word\n"
    (should (eq (alonso-tests--md-face "emphatic")
                'alonso-md-italic-face))))

(ert-deftest alonso-markdown--italic-markers-hidden ()
  :tags '(markdown)
  (alonso-tests--with-rendered "an *emphatic* word\n"
    (should (equal "" (alonso-tests--md-display "*")))))

(ert-deftest alonso-markdown--strikethrough-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "~~gone~~ here\n"
    (should (eq (alonso-tests--md-face "gone")
                'alonso-md-strike-face))))

(ert-deftest alonso-markdown--inline-code-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "use `foo` here\n"
    (should (eq (alonso-tests--md-face "foo")
                'alonso-md-inline-code-face))))

(ert-deftest alonso-markdown--inline-code-backticks-hidden ()
  :tags '(markdown)
  (alonso-tests--with-rendered "use `foo` here\n"
    (should (equal "" (alonso-tests--md-display "`")))))

(ert-deftest alonso-markdown--link-text-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "see [docs](https://example.com/x)\n"
    (should (eq (alonso-tests--md-face "docs") 'alonso-md-link-face))))

(ert-deftest alonso-markdown--link-url-property ()
  :tags '(markdown)
  (alonso-tests--with-rendered "see [docs](https://example.com/x)\n"
    (should (equal "https://example.com/x"
                   (alonso-tests--md-prop "docs" 'alonso-url)))))

(ert-deftest alonso-markdown--link-clickable ()
  :tags '(markdown)
  (alonso-tests--with-rendered "see [docs](https://example.com/x)\n"
    (should (keymapp (alonso-tests--md-prop "docs" 'keymap)))))

(ert-deftest alonso-markdown--link-opening-bracket-hidden ()
  :tags '(markdown)
  (alonso-tests--with-rendered "see [docs](https://example.com/x)\n"
    (should (equal "" (alonso-tests--md-display "[")))))

(ert-deftest alonso-markdown--link-url-shown-after-text ()
  :tags '(markdown)
  (alonso-tests--with-rendered "see [docs](https://example.com/x)\n"
    (should (equal " (https://example.com/x)"
                   (alonso-tests--md-display "](")))))

(ert-deftest alonso-markdown--code-block-base-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
    (should (memq 'alonso-md-code-face
                  (alonso-tests--md-faces "(setq x 1)")))))

(ert-deftest alonso-markdown--code-block-syntax-highlighted ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
    (should (memq 'font-lock-keyword-face
                  (alonso-tests--md-faces "setq")))))

(ert-deftest alonso-markdown--syntax-face-precedes-base-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
    (let ((faces (alonso-tests--md-faces "setq")))
      (should (and (cl-position 'font-lock-keyword-face faces)
                   (cl-position 'alonso-md-code-face faces)
                   (< (cl-position 'font-lock-keyword-face faces)
                      (cl-position 'alonso-md-code-face faces)))))))

(ert-deftest alonso-markdown--code-fences-hidden ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
    (should (equal "" (alonso-tests--md-display "```")))))

(ert-deftest alonso-markdown--python-code-block-highlighted ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```python\nimport os\n```\n"
    (should (memq 'font-lock-keyword-face
                  (alonso-tests--md-faces "import")))))

(ert-deftest alonso-markdown--fontification-can-be-disabled ()
  :tags '(markdown)
  (let ((alonso-fontify-code-blocks nil))
    (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
      (should (equal '(alonso-md-code-face)
                     (alonso-tests--md-faces "setq"))))))

(ert-deftest alonso-markdown--fence-without-language-not-fontified ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```\n(setq x 1)\n```\n"
    (should (equal '(alonso-md-code-face)
                   (alonso-tests--md-faces "setq")))))

;;; Code-block font (alonso-md-code-font)

(ert-deftest alonso-markdown--code-font-default-follows-conversation ()
  :tags '(markdown)
  (alonso--set-md-code-font 'alonso-md-code-font nil)
  (should (and (eq (face-attribute 'alonso-md-code-face :family) 'unspecified)
               (eq (face-attribute 'alonso-md-code-face :inherit) 'default))))

(ert-deftest alonso-markdown--code-font-sets-family ()
  :tags '(markdown)
  (unwind-protect
      (progn
        (alonso--set-md-code-font 'alonso-md-code-font "Monospace")
        (should (equal (face-attribute 'alonso-md-code-face :family) "Monospace")))
    (alonso--set-md-code-font 'alonso-md-code-font nil)))

(ert-deftest alonso-markdown--fontifying-does-not-change-buffer-text ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
    (should (equal "```elisp\n(setq x 1)\n```\n"
                   (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest alonso-markdown--bullet-replaced-by-dot ()
  :tags '(markdown)
  (alonso-tests--with-rendered "- item\n"
    (should (equal "•" (alonso-tests--md-display "-")))))

(ert-deftest alonso-markdown--ordered-list-number-propertized ()
  :tags '(markdown)
  (alonso-tests--with-rendered "1. item\n"
    (should (eq (alonso-tests--md-face "1.")
                'alonso-md-bullet-face))))

(ert-deftest alonso-markdown--horizontal-rule-drawn ()
  :tags '(markdown)
  (alonso-tests--with-rendered "---\n"
    (should (string-prefix-p "─" (or (alonso-tests--md-display "---") "")))))

(ert-deftest alonso-markdown--rendering-never-changes-buffer-text ()
  :tags '(markdown)
  (alonso-tests--with-rendered "plain text\n# h\n- l\n"
    (should (equal "plain text\n# h\n- l\n"
                   (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest alonso-markdown--snake-case-left-alone ()
  :tags '(markdown)
  (alonso-tests--with-rendered "the keep_alive name\n"
    (should (and (null (alonso-tests--md-face "_"))
                 (null (alonso-tests--md-display "_"))))))

(ert-deftest alonso-markdown--rendering-can-be-disabled ()
  :tags '(markdown)
  (let ((alonso-render-markdown nil))
    (alonso-tests--with-rendered "# Title\n"
      (should (and (null (alonso-tests--md-display "#"))
                   (null (alonso-tests--md-face "Title")))))))

(ert-deftest alonso-markdown--hiding-off-keeps-markers-visible ()
  :tags '(markdown)
  (let ((alonso-hide-markdown-markers nil))
    (alonso-tests--with-rendered "a **bold** b\n"
      (should (and (null (alonso-tests--md-display "**"))
                   (eq (alonso-tests--md-face "**") 'shadow))))))

(provide 'alonso-markdown-tests)

;;; alonso-markdown-tests.el ends here
