;;; alonso-image-tests.el --- Tests for the alonso image attachments (images array and inline attachment).  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the alonso image attachments (images array and inline attachment).
;;
;; Part of the alonso test suite; `alonso-tests.el' is the runner.
;;
;; Migrated to ERT (phase 2 of ERT-MIGRATION.md): one `ert-deftest' per
;; assertion, all tagged `image'.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'ert)
(require 'alonso-tests-lib)

;;; Images — the `images' array in the prompt and inline attachment
;;;
;;; An image is attached by inserting it inline in the input buffer (a space
;;; carrying the image in its `display' property and the spec in the
;;; `alonso-image' property).  At send time `alonso--buffer-collect'
;;; strips the placeholders from the text and yields the specs, which
;;; `alonso--prompt-params' serializes as the bridge's `images' array.

(defun alonso-image-tests--reset-request ()
  "Reset the per-request overrides so the image tests see a clean prompt."
  (with-current-buffer (get-buffer-create "alonso-chat")
    (setq alonso-request-provider ""
          alonso-request-model ""
          alonso-request-thinking 'unset
          alonso-request-reasoning-effort "")))

(ert-deftest alonso-image--image-json-data-image-carries-data-and-mime ()
  :tags '(image)
  (let ((h (alonso--image-json (list :data "AAAA" :mime "image/png"))))
    (should (and (equal "AAAA" (gethash "data" h))
                 (equal "image/png" (gethash "mime_type" h))
                 (null (gethash "path" h))))))

(ert-deftest alonso-image--image-json-path-image-carries-only-path ()
  :tags '(image)
  (let ((h (alonso--image-json (list :path "/tmp/x.png"))))
    (should (and (equal "/tmp/x.png" (gethash "path" h))
                 (null (gethash "data" h))))))

(ert-deftest alonso-image--image-json-url-image-carries-only-url ()
  :tags '(image)
  (let ((h (alonso--image-json (list :url "https://example.com/x.png"))))
    (should (and (equal "https://example.com/x.png" (gethash "url" h))
                 (null (gethash "path" h))))))

(ert-deftest alonso-image--prompt-params-include-the-images-array ()
  :tags '(image)
  (alonso-image-tests--reset-request)
  (let* ((specs (list (list :data "AAAA" :mime "image/png")
                      (list :path "/tmp/x.png")))
         (json (alonso--json-object
                "method" "prompt" "params"
                (alonso--json-plist-to-hash
                 (alonso--prompt-params "hi" specs)))))
    (should (and (string-match-p "\"images\":\\[" json)
                 (string-match-p "\"AAAA\"" json)
                 (string-match-p "\"path\":\"/tmp/x.png\"" json)
                 (string-match-p "\"mime_type\":\"image/png\"" json)))))

(ert-deftest alonso-image--without-images-the-prompt-has-no-images-field ()
  :tags '(image)
  (alonso-image-tests--reset-request)
  (should (not (string-match-p "images"
                               (alonso--json-object
                                "method" "prompt" "params"
                                (alonso--json-plist-to-hash
                                 (alonso--prompt-params "hi")))))))

;; Collecting text + images from the input buffer: the placeholders vanish
;; from the text and the specs come back in order.

(ert-deftest alonso-image--buffer-collect-strips-the-image-placeholders ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "before ")
          (alonso--insert-image (list :url "https://example.com/a.png"))
          (insert " middle ")
          (alonso--insert-image (list :path "/tmp/alonso-missing-b.png"))
          (insert " after")
          (should (equal "before  middle  after" (car (alonso--buffer-collect)))))
      (kill-buffer buf))))

(ert-deftest alonso-image--buffer-collect-returns-the-specs-in-order ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "before ")
          (alonso--insert-image (list :url "https://example.com/a.png"))
          (insert " middle ")
          (alonso--insert-image (list :path "/tmp/alonso-missing-b.png"))
          (insert " after")
          (let ((images (cdr (alonso--buffer-collect))))
            (should (and (= 2 (length images))
                         (equal "https://example.com/a.png"
                                (plist-get (nth 0 images) :url))
                         (equal "/tmp/alonso-missing-b.png"
                                (plist-get (nth 1 images) :path))))))
      (kill-buffer buf))))

;; Text typed *right after* an inline image must be collected as text, not
;; swallowed as another image.  Interactive typing goes through
;; `self-insert-command', which uses `insert-and-inherit' and would copy the
;; placeholder's properties onto the new characters unless it is
;; `rear-nonsticky' (regression: an image pasted with a caption below arrived
;; at the model as image-only).

(ert-deftest alonso-image--text-after-inline-image-collected-as-text ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-inherit-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (alonso--insert-image (list :url "https://example.com/a.png"))
          (insert-and-inherit "caption after the image")
          (should (equal "caption after the image"
                         (car (alonso--buffer-collect)))))
      (kill-buffer buf))))

(ert-deftest alonso-image--text-after-inline-image-not-collected-as-image ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-inherit-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (alonso--insert-image (list :url "https://example.com/a.png"))
          (insert-and-inherit "caption after the image")
          (should (= 1 (length (cdr (alonso--buffer-collect))))))
      (kill-buffer buf))))

;; The yank-media handler stores the clipboard bytes base64-encoded with the
;; declared mime type, and returns non-nil so `yank-media' knows it handled it.

(ert-deftest alonso-image--yank-media-handler-inserts-base64-spec ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-handler*"))
        (bytes (unibyte-string 137 80 78 71 13 10 26 10)))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (let ((ret (alonso--yank-media-image
                      'image/png (string-make-unibyte bytes))))
            (let ((spec (get-text-property (point-min) 'alonso-image)))
              (should (and ret spec
                           (equal "image/png" (plist-get spec :mime))
                           (equal bytes
                                  (base64-decode-string (plist-get spec :data))))))))
      (kill-buffer buf))))

;; `alonso-yank' (C-y in the input buffer) auto-detects the clipboard image
;; (no `yank-media' prompt) and only falls back to the normal text yank when
;; there is no renderable image.

(ert-deftest alonso-image--yank-auto-detects-clipboard-image ()
  :tags '(image)
  (let ((text 0) (inserted nil))
    (cl-letf (((symbol-function 'alonso--clipboard-image)
               (lambda () (cons "image/png" (unibyte-string 1 2 3))))
              ((symbol-function 'alonso--yank-media-image)
               (lambda (type data) (setq inserted (list type data))))
              ((symbol-function 'yank) (lambda (&optional _) (cl-incf text)))
              ((symbol-function 'call-interactively)
               (lambda (fn &rest _) (funcall fn))))
      (alonso-yank))
    (should (and (equal '(image/png) (list (car inserted)))
                 (equal (unibyte-string 1 2 3) (cadr inserted))
                 (= 0 text)))))

(ert-deftest alonso-image--yank-falls-back-to-text-without-clipboard-image ()
  :tags '(image)
  (let ((text 0))
    (cl-letf (((symbol-function 'alonso--clipboard-image) (lambda () nil))
              ((symbol-function 'yank) (lambda (&optional _) (cl-incf text)))
              ((symbol-function 'call-interactively)
               (lambda (fn &rest _) (funcall fn))))
      (alonso-yank))
    (should (= 1 text))))

;; The best renderable image type is chosen by priority, without prompting.

(ert-deftest alonso-image--mime-rank-png-outranks-bmp ()
  :tags '(image)
  (should (< (alonso--image-mime-rank "image/png")
             (alonso--image-mime-rank "image/bmp"))))

(ert-deftest alonso-image--mime-rank-listed-types-outrank-unknown ()
  :tags '(image)
  (should (and (< (alonso--image-mime-rank "image/jpeg")
                  (alonso--image-mime-rank "image/x-win-bitmap"))
               (< (alonso--image-mime-rank "image/webp")
                  (alonso--image-mime-rank "image/unknown")))))

;; `alonso--clipboard-image' skips non-renderable image types and picks the
;; highest-priority renderable one (here: png over bmp), reading its bytes.

(ert-deftest alonso-image--clipboard-image-picks-highest-priority ()
  :tags '(image)
  (let* ((targets (vector 'TARGETS 'image/bmp 'image/png 'image/png8
                          'text/plain 'image/jpeg))
         (png-bytes (unibyte-string 137 80 78 71)))
    (cl-letf (((symbol-function 'gui-get-selection)
               (lambda (_sel type &optional _)
                 (pcase type
                   ('TARGETS targets)
                   ('image/png png-bytes)
                   (_ nil))))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (memq type '(png jpeg)))))
      (let ((chosen (alonso--clipboard-image)))
        (should (and (equal "image/png" (car chosen))
                     (equal png-bytes (cdr chosen))))))))

;; With no renderable image on the clipboard, it returns nil (no prompt).

(ert-deftest alonso-image--clipboard-image-nil-when-nothing-renderable ()
  :tags '(image)
  (cl-letf (((symbol-function 'gui-get-selection)
             (lambda (&rest _) (vector 'TARGETS 'text/plain 'image/x-win-bitmap)))
            ((symbol-function 'image-type-available-p) (lambda (_t) nil)))
    (should (null (alonso--clipboard-image)))))

;; The explicit parameter commands insert into the input buffer.

(ert-deftest alonso-image--attach-image-url-inserts-spec-in-input-buffer ()
  :tags '(image)
  (let ((input (get-buffer-create "alonso-chat")))
    (unwind-protect
        (progn
          (with-current-buffer input (erase-buffer))
          (alonso-attach-image-url "https://example.com/pic.png")
          (should (with-current-buffer input
                    (equal "https://example.com/pic.png"
                           (plist-get (car (cdr (alonso--buffer-collect))) :url)))))
      (with-current-buffer input (erase-buffer)))))

;; Sending collects the images as the `images' array and clears the buffer.

(ert-deftest alonso-image--send-input-sends-prompt-carrying-images-array ()
  :tags '(image)
  (let ((input (get-buffer-create "alonso-chat"))
        (sent nil))
    (unwind-protect
        (progn
          (with-current-buffer input
            (erase-buffer)
            (insert "look at this ")
            (alonso--insert-image (list :url "https://example.com/a.png")))
          (cl-letf (((symbol-function 'alonso--send)
                     (lambda (method params) (push (cons method params) sent)))
                    ((symbol-function 'alonso--ensure-ready) (lambda ()))
                    (alonso-in-turn nil)
                    (alonso-pending-tools nil))
            (with-current-buffer input (alonso-send-input)))
          (let ((params (cdar sent)))
            (should (and (equal "prompt" (caar sent))
                         (equal "look at this " (cadr (member "text" params)))
                         (vectorp (cadr (member "images" params)))))))
      (alonso--stop-spinner)
      (with-current-buffer input (erase-buffer)))))

(ert-deftest alonso-image--send-input-clears-the-input-buffer ()
  :tags '(image)
  (let ((input (get-buffer-create "alonso-chat"))
        (sent nil))
    (unwind-protect
        (progn
          (with-current-buffer input
            (erase-buffer)
            (insert "look at this ")
            (alonso--insert-image (list :url "https://example.com/a.png")))
          (cl-letf (((symbol-function 'alonso--send)
                     (lambda (method params) (push (cons method params) sent)))
                    ((symbol-function 'alonso--ensure-ready) (lambda ()))
                    (alonso-in-turn nil)
                    (alonso-pending-tools nil))
            (with-current-buffer input (alonso-send-input)))
          (should (with-current-buffer input (string-empty-p (buffer-string)))))
      (alonso--stop-spinner)
      (with-current-buffer input (erase-buffer)))))

;; Sending only an image (no text) sends the minimal fallback text.

(ert-deftest alonso-image--image-only-prompt-gets-fallback-text ()
  :tags '(image)
  (let ((input (get-buffer-create "alonso-chat"))
        (sent nil))
    (unwind-protect
        (progn
          (with-current-buffer input
            (erase-buffer)
            (alonso--insert-image (list :url "https://example.com/a.png")))
          (cl-letf (((symbol-function 'alonso--send)
                     (lambda (method params) (push (cons method params) sent)))
                    ((symbol-function 'alonso--ensure-ready) (lambda ()))
                    (alonso-in-turn nil)
                    (alonso-pending-tools nil))
            (with-current-buffer input (alonso-send-input)))
          (should (equal "(imagem)" (cadr (member "text" (cdar sent))))))
      (alonso--stop-spinner)
      (with-current-buffer input (erase-buffer)))))

;; Collect order: the segments preserve how the user typed image/text, so the
;; conversation echo can reproduce it (regression: an image pasted above a
;; caption was echoed below it, behind an empty ">>>" line).

(ert-deftest alonso-image--collect-segments-keeps-image-before-text-order ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (erase-buffer)
            (alonso--insert-image (list :url "https://example.com/a.png"))
            (insert "\ncaption"))
          (should (equal '(image text)
                         (mapcar #'car (with-current-buffer buf
                                         (alonso--buffer-collect-segments))))))
      (kill-buffer buf))))

(ert-deftest alonso-image--collect-segments-keeps-text-before-image-order ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (erase-buffer)
            (insert "caption")
            (alonso--insert-image (list :url "https://example.com/a.png")))
          (should (equal '(text image)
                         (mapcar #'car (with-current-buffer buf
                                         (alonso--buffer-collect-segments))))))
      (kill-buffer buf))))

(ert-deftest alonso-image--buffer-collect-derives-text-images-from-segments ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (erase-buffer)
            (insert "caption")
            (alonso--insert-image (list :url "https://example.com/a.png")))
          (should (with-current-buffer buf
                    (let ((c (alonso--buffer-collect)))
                      (and (equal "caption" (car c))
                           (= 1 (length (cdr c))))))))
      (kill-buffer buf))))

;; The echo body puts the image where the user typed it and keeps the badge on
;; the first line, so no ">>> " line is left blank.

(ert-deftest alonso-image--echo-body-image-above-text-starts-with-image ()
  :tags '(image)
  (let* ((spec (list :url "https://example.com/a.png"))
         (body (alonso--prompt-echo-body
                "\ncaption" (list spec)
                (list (cons 'image spec) (cons 'text "\ncaption")))))
    (should (and (string-prefix-p "[imagem" body)
                 (string-match-p "\ncaption" body)
                 (not (string-prefix-p "\n" body))))))

(ert-deftest alonso-image--echo-body-text-above-image-starts-with-text ()
  :tags '(image)
  (let* ((spec (list :url "https://example.com/a.png"))
         (body (alonso--prompt-echo-body
                "caption" (list spec)
                (list (cons 'text "caption") (cons 'image spec)))))
    (should (and (string-prefix-p "caption" body)
                 (string-match-p "\n\\[imagem" body)))))

;; Sending image + text echoes the image before the caption (regression).

(ert-deftest alonso-image--echo-of-image-text-no-blank-badge-line ()
  :tags '(image)
  (let ((input (get-buffer-create "alonso-chat"))
        (conv (get-buffer-create "alonso")))
    (unwind-protect
        (progn
          (with-current-buffer conv (setq buffer-read-only nil) (erase-buffer))
          (with-current-buffer input
            (erase-buffer)
            (alonso--insert-image (list :url "https://example.com/a.png"))
            (insert "\ncaption"))
          (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ()))
                    ((symbol-function 'alonso--send) (lambda (&rest _) nil))
                    ((symbol-function 'alonso--start-spinner) (lambda () nil))
                    ((symbol-function 'alonso--stop-spinner) (lambda () nil))
                    (alonso-in-turn nil)
                    (alonso-pending-tools nil))
            (with-current-buffer input (alonso-send-input)))
          (should (not (string-match-p ">>>[ \t]*\n"
                                       (with-current-buffer conv (buffer-string))))))
      (with-current-buffer input (erase-buffer))
      (with-current-buffer conv (setq buffer-read-only nil) (erase-buffer)))))

(ert-deftest alonso-image--echo-of-image-text-places-image-before-caption ()
  :tags '(image)
  (let ((input (get-buffer-create "alonso-chat"))
        (conv (get-buffer-create "alonso")))
    (unwind-protect
        (progn
          (with-current-buffer conv (setq buffer-read-only nil) (erase-buffer))
          (with-current-buffer input
            (erase-buffer)
            (alonso--insert-image (list :url "https://example.com/a.png"))
            (insert "\ncaption"))
          (cl-letf (((symbol-function 'alonso--ensure-ready) (lambda ()))
                    ((symbol-function 'alonso--send) (lambda (&rest _) nil))
                    ((symbol-function 'alonso--start-spinner) (lambda () nil))
                    ((symbol-function 'alonso--stop-spinner) (lambda () nil))
                    (alonso-in-turn nil)
                    (alonso-pending-tools nil))
            (with-current-buffer input (alonso-send-input)))
          (should (string-match-p ">>> \\[imagem[^\n]*\ncaption"
                                  (with-current-buffer conv (buffer-string)))))
      (with-current-buffer input (erase-buffer))
      (with-current-buffer conv (setq buffer-read-only nil) (erase-buffer)))))

;; Regression: the RET that opens the line below an inline image must not drop
;; the attachment.  `electric-indent-mode' (on by default globally) reindents
;; the previous line on RET and trims its trailing horizontal whitespace, which
;; used to delete a space-carried placeholder: the image silently vanished and
;; the prompt arrived with no attachment.  Two guards are tested here: the
;; carrier is a non-whitespace zero-width space (so no whitespace cleanup can
;; hit it), and `alonso-input-mode' disables electric indentation locally.

(ert-deftest alonso-image--ret-after-inline-image-keeps-attachment ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-ret-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (alonso-input-mode 1)
          ;; Force electric indentation ON in this very buffer, so it is the
          ;; carrier itself — not the buffer-local switch — under test.
          (setq-local electric-indent-mode t)
          (cl-letf (((symbol-function 'alonso--image-create)
                     (lambda (_spec) 'dummy)))
            (alonso--insert-image (list :url "https://example.com/a.png")))
          (call-interactively #'newline)
          (insert "caption")
          (should (= 1 (length (cdr (alonso--buffer-collect))))))
      (kill-buffer buf))))

(ert-deftest alonso-image--ret-after-inline-image-keeps-caption-as-text ()
  :tags '(image)
  (let ((buf (get-buffer-create "*alonso-img-ret-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (alonso-input-mode 1)
          (setq-local electric-indent-mode t)
          (cl-letf (((symbol-function 'alonso--image-create)
                     (lambda (_spec) 'dummy)))
            (alonso--insert-image (list :url "https://example.com/a.png")))
          (call-interactively #'newline)
          (insert "caption")
          (should (equal "\ncaption" (car (alonso--buffer-collect)))))
      (kill-buffer buf))))

;; `alonso-input-mode' turns electric indentation off buffer-locally, so a
;; trailing placeholder (or any trailing whitespace) is never trimmed by RET
;; even when `electric-indent-mode' is on globally.

(ert-deftest alonso-image--input-mode-disables-electric-indent-locally ()
  :tags '(image)
  (let ((saved electric-indent-mode)
        (buf (get-buffer-create "*alonso-img-eim-test*")))
    (unwind-protect
        (progn
          (electric-indent-mode 1)
          (with-current-buffer buf
            (alonso-input-mode 1)
            (should (null (buffer-local-value 'electric-indent-mode buf)))))
      (electric-indent-mode (if saved 1 0))
      (kill-buffer buf))))

;;; Encoding, placeholders and file attachments

(ert-deftest alonso-image--image-bytes-encodes-multibyte-as-unibyte ()
  :tags '(image)
  (let ((bytes (alonso--image-bytes "é")))
    (should (and (stringp bytes)
                 (not (multibyte-string-p bytes))))))

(ert-deftest alonso-image--image-bytes-passes-unibyte-through ()
  :tags '(image)
  (let ((bytes (unibyte-string 1 2 3)))
    (should (eq bytes (alonso--image-bytes bytes)))))

;; A spec that cannot be displayed falls back to a textual placeholder; with
;; neither `:path' nor `:url' the placeholder names the `:mime' type.

(ert-deftest alonso-image--placeholder-falls-back-to-mime ()
  :tags '(image)
  (let ((s (alonso--image-string (list :mime "image/xyz"))))
    (should (string-match-p "image/xyz" s))))

(ert-deftest alonso-image--image-json-includes-the-detail-hint ()
  :tags '(image)
  (let ((h (alonso--image-json (list :data "AAAA" :mime "image/png"
                                     :detail "high"))))
    (should (equal "high" (gethash "detail" h)))))

;; With several renderable image types on the clipboard, the comparator runs
;; and the highest-priority one (png over jpeg) wins.

(ert-deftest alonso-image--clipboard-image-picks-best-among-several ()
  :tags '(image)
  (let* ((targets (vector 'image/jpeg 'image/png))
         (bytes (unibyte-string 1 2 3)))
    (cl-letf (((symbol-function 'gui-get-selection)
               (lambda (_sel type &optional _)
                 (pcase type
                   ('TARGETS targets)
                   ((or 'image/jpeg 'image/png) bytes)
                   (_ nil))))
              ((symbol-function 'image-type-available-p)
               (lambda (type) (memq type '(png jpeg)))))
      (let ((chosen (alonso--clipboard-image)))
        (should (and (equal "image/png" (car chosen))
                     (equal bytes (cdr chosen))))))))

(ert-deftest alonso-image--attach-image-file-errors-when-unreadable ()
  :tags '(image)
  (should-error (alonso-attach-image-file "/nonexistent/alonso/nope.png")
                :type 'user-error))

(ert-deftest alonso-image--attach-image-file-inserts-spec-in-input-buffer ()
  :tags '(image)
  (let ((file (make-temp-file "alonso-img" nil ".png"))
        (input (get-buffer-create "alonso-chat")))
    (unwind-protect
        (progn
          (with-current-buffer input (erase-buffer))
          (alonso-attach-image-file file)
          (with-current-buffer input
            (should (equal (expand-file-name file)
                           (plist-get (car (cdr (alonso--buffer-collect)))
                                      :path)))))
      (delete-file file)
      (with-current-buffer input (erase-buffer)))))

(provide 'alonso-image-tests)

;;; alonso-image-tests.el ends here
