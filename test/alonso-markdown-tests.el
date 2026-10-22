;;; alonso-markdown-tests.el --- Tests for the alonso Markdown rendering and code-block font.  -*- lexical-binding: t; -*-

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

;; Tests for the alonso Markdown rendering and code-block font.
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT: one `ert-deftest' per
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

;;; Clickable links — opening, the at-point lookup and the mouse handler

(ert-deftest alonso-markdown--open-link-opens-the-url-at-point ()
  :tags '(markdown)
  (let (opened)
    (with-temp-buffer
      (insert "docs")
      (put-text-property (point-min) (point-max)
                         'alonso-url "https://example.com")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url) (setq opened url))))
        (alonso-open-link)))
    (should (equal "https://example.com" opened))))

(ert-deftest alonso-markdown--open-link-falls-back-to-char-before-point ()
  :tags '(markdown)
  (let (opened)
    (with-temp-buffer
      (insert "docs")
      (put-text-property (point-min) (point-max)
                         'alonso-url "https://example.com")
      ;; Point sits right *after* the link, where the property is not present.
      (goto-char (point-max))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url) (setq opened url))))
        (alonso-open-link)))
    (should (equal "https://example.com" opened))))

(ert-deftest alonso-markdown--open-link-errors-without-a-link ()
  :tags '(markdown)
  (with-temp-buffer
    (insert "plain text")
    (goto-char (point-min))
    (should-error (alonso-open-link) :type 'user-error)))

(ert-deftest alonso-markdown--open-link-mouse-sets-point-then-opens ()
  :tags '(markdown)
  (let (moved (opened 0))
    (cl-letf (((symbol-function 'mouse-set-point)
               (lambda (_event) (setq moved t)))
              ((symbol-function 'alonso-open-link)
               (lambda () (cl-incf opened))))
      (alonso--open-link-mouse 'some-event))
    (should (and moved (= 1 opened)))))

;;; `alonso--md-line-end' — the line end extended over its newline

(ert-deftest alonso-markdown--md-line-end-extends-over-the-newline ()
  :tags '(markdown)
  (with-temp-buffer
    (insert "abc\ndef")
    (goto-char (point-min))
    (should (= 5 (alonso--md-line-end)))))

(ert-deftest alonso-markdown--md-line-end-stops-at-end-of-buffer ()
  :tags '(markdown)
  (with-temp-buffer
    (insert "abc")
    (goto-char (point-min))
    (should (= 4 (alonso--md-line-end)))))

;;; Block quotes and the hiding-off rendering paths

(ert-deftest alonso-markdown--block-quote-face ()
  :tags '(markdown)
  (alonso-tests--with-rendered "> quoted\n"
    (should (eq (alonso-tests--md-face "quoted")
                'alonso-md-quote-face))))

(ert-deftest alonso-markdown--block-quote-marker-hidden ()
  :tags '(markdown)
  (alonso-tests--with-rendered "> quoted\n"
    (should (equal "" (alonso-tests--md-display ">")))))

(ert-deftest alonso-markdown--link-tail-dimmed-when-hiding-off ()
  :tags '(markdown)
  (let ((alonso-hide-markdown-markers nil))
    (alonso-tests--with-rendered "see [docs](https://example.com/x)\n"
      (should (and (null (alonso-tests--md-display "]("))
                   (eq (alonso-tests--md-face "](") 'shadow))))))

(ert-deftest alonso-markdown--fence-dimmed-when-hiding-off ()
  :tags '(markdown)
  (let ((alonso-hide-markdown-markers nil))
    (alonso-tests--with-rendered "```elisp\n(setq x 1)\n```\n"
      (should (eq (alonso-tests--md-face "```")
                  'alonso-md-code-face)))))

;; A code block left open at the end of the segment is still fontified.

(ert-deftest alonso-markdown--unclosed-code-block-fontified ()
  :tags '(markdown)
  (alonso-tests--with-rendered "```elisp\n(setq x 1)\n"
    (should (memq 'font-lock-keyword-face
                  (alonso-tests--md-faces "setq")))))

;;; Live (streaming) code-block fontification
;;;
;;; While the answer streams, the whole segment is re-rendered on every
;;; `chunk'.  To avoid re-fontifying a long (C) code block from scratch on
;;; every chunk, the open block is fontified incrementally into a persistent
;;; work buffer, and an already-fontified block is skipped through the
;;; `alonso-md-code-fontified' marker on its opening fence.  These tests check
;;; the highlighting still comes out right and that the work is not redone.

(defun alonso-markdown-tests--faces-per-char ()
  "Return the buffer's `face' property for each character, in order.
Comparing faces per character (not per run) makes the check independent
of how the runs happen to be split."
  (let ((out nil) (p (point-min)))
    (while (< p (point-max))
      (push (get-text-property p 'face) out)
      (setq p (1+ p)))
    (nreverse out)))

(defun alonso-markdown-tests--render-full (text)
  "Render TEXT in a fresh buffer (non-live); return its per-char faces."
  (with-temp-buffer
    (insert text)
    (alonso--render-markdown-region (point-min) (point-max))
    (alonso-markdown-tests--faces-per-char)))

(defun alonso-markdown-tests--render-streamed (pieces)
  "Render PIECES one by one as if streaming.
Each piece is appended and the segment re-rendered live (as a `chunk'
does); no final non-live render is done, so the open block is left as the
incremental fontification produced it.  Returns the per-char faces."
  (with-temp-buffer
    (dolist (piece pieces)
      (goto-char (point-max))
      (insert piece)
      (alonso--render-markdown-region (point-min) (point-max) t))
    (alonso-markdown-tests--faces-per-char)))

(defconst alonso-markdown-tests--c-pieces
  '("```c\n"
    "int main(void) {\n"
    "  /* um comentario\n"
    "     que ocupa varias linhas */\n"
    "  const char *s = \"uma string\";\n"
    "  if (s) { return 0;\n")
  "C code split into pieces, one per streaming chunk (left unbalanced).")

(defconst alonso-markdown-tests--c-block
  (apply #'concat alonso-markdown-tests--c-pieces)
  "The C code of `alonso-markdown-tests--c-pieces' as a single string.")

(ert-deftest alonso-markdown--live-open-block-syntax-highlighted ()
  :tags '(markdown)
  (with-temp-buffer
    (insert alonso-markdown-tests--c-block)
    (alonso--render-markdown-region (point-min) (point-max) t)
    ;; The still-open block is syntax-highlighted and keeps the base face.
    (should (memq 'font-lock-type-face (alonso-tests--md-faces "int")))
    (should (memq 'font-lock-comment-face
                  (alonso-tests--md-faces "comentario")))
    (should (memq 'alonso-md-code-face (alonso-tests--md-faces "main")))))

(ert-deftest alonso-markdown--live-open-block-keeps-base-face ()
  :tags '(markdown)
  (with-temp-buffer
    (insert alonso-markdown-tests--c-block)
    (alonso--render-markdown-region (point-min) (point-max) t)
    ;; Every code character keeps the base face; the syntax face is composed
    ;; on top where there is one.
    (should (memq 'alonso-md-code-face
                  (alonso-tests--md-faces "\"uma string\"")))))

(ert-deftest alonso-markdown--live-open-block-without-language-keeps-base-face ()
  :tags '(markdown)
  ;; A block that cannot be fontified (here, one with no language) still gets
  ;; the base face while streaming: the live path must fall back to it.
  (with-temp-buffer
    (insert "```\n(setq x 1)\n")
    (alonso--render-markdown-region (point-min) (point-max) t)
    (should (equal '(alonso-md-code-face)
                   (alonso-tests--md-faces "setq")))))

(ert-deftest alonso-markdown--live-open-block-faces-match-full ()
  :tags '(markdown)
  ;; The incremental fontification of the open block must produce exactly the
  ;; same faces as fontifying the whole block in one go.
  (should (equal (alonso-markdown-tests--render-full
                  alonso-markdown-tests--c-block)
                 (alonso-markdown-tests--render-streamed
                  alonso-markdown-tests--c-pieces))))

(ert-deftest alonso-markdown--live-closed-block-faces-match-full ()
  :tags '(markdown)
  ;; A block streamed and then closed (as a whole turn does) must end up with
  ;; exactly the same faces as a one-shot render.
  (let* ((pieces (append alonso-markdown-tests--c-pieces '("  }\n" "}\n" "```\n")))
         (text (apply #'concat pieces)))
    (should (equal (alonso-markdown-tests--render-full text)
                   (with-temp-buffer
                     (dolist (piece pieces)
                       (goto-char (point-max))
                       (insert piece)
                       (alonso--render-markdown-region (point-min) (point-max) t))
                     ;; the turn ends: a final non-live render closes the segment
                     (alonso--render-markdown-region (point-min) (point-max))
                     (alonso-markdown-tests--faces-per-char))))))

(ert-deftest alonso-markdown--live-closed-block-not-refontified-on-rerender ()
  :tags '(markdown)
  (with-temp-buffer
    (insert "```elisp\n(setq x 1)\n```\n")
    (alonso--render-markdown-region (point-min) (point-max) t)
    ;; The block got the "already fontified" marker on its opening fence...
    (should (get-text-property (point-min) 'alonso-md-code-fontified))
    ;; ...so a second live pass must not fontify anything again.
    (let ((calls 0))
      (cl-letf (((symbol-function 'font-lock-ensure)
                 (lambda (&rest _) (cl-incf calls))))
        (alonso--render-markdown-region (point-min) (point-max) t))
      (should (= 0 calls)))))

(ert-deftest alonso-markdown--live-open-block-fontified-incrementally ()
  :tags '(markdown)
  ;; With a block larger than the context window, each chunk must fontify only
  ;; the new text (plus the bounded context), never the whole growing block --
  ;; otherwise the total cost would be quadratic in the block size.
  (with-temp-buffer
    (insert "```c\n")
    (let ((line "  if (x) { do_something (1);\n")
          (sizes nil))
      (cl-letf (((symbol-function 'font-lock-ensure)
                 (lambda (beg end &optional _loudly)
                   (push (- end beg) sizes))))
        (dotimes (_ 40)
          (goto-char (point-max))
          (insert line)
          (alonso--render-markdown-region (point-min) (point-max) t)))
      (should (<= (apply #'max sizes)
                  (+ alonso--md-live-context (length line) 5))))))

(ert-deftest alonso-markdown--live-rendering-does-not-change-text ()
  :tags '(markdown)
  (with-temp-buffer
    (insert (apply #'concat alonso-markdown-tests--c-pieces))
    (alonso--render-markdown-region (point-min) (point-max) t)
    (should (equal (apply #'concat alonso-markdown-tests--c-pieces)
                   (buffer-substring-no-properties (point-min) (point-max))))))

(provide 'alonso-markdown-tests)

;;; alonso-markdown-tests.el ends here
