;;; tagarela-image-tests.el --- Tests for the tagarela image attachments (images array and inline attachment).  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the tagarela image attachments (images array and inline attachment).
;;
;; Part of the tagarela test suite; `tagarela-tests.el' is the runner.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir (add-to-list 'load-path dir)))
(require 'cl-lib)
(require 'tagarela-tests-lib)

;;; Images — the `images' array in the prompt and inline attachment
;;;
;;; An image is attached by inserting it inline in the input buffer (a space
;;; carrying the image in its `display' property and the spec in the
;;; `tagarela-image' property).  At send time `tagarela--buffer-collect'
;;; strips the placeholders from the text and yields the specs, which
;;; `tagarela--prompt-params' serializes as the bridge's `images' array.

;; Reset the per-request overrides so the image tests see a clean prompt.
(with-current-buffer (get-buffer-create "*llm-bridge-input*")
  (setq tagarela-request-provider ""
        tagarela-request-model ""
        tagarela-request-thinking 'unset
        tagarela-request-reasoning-effort ""))

(tagarela-tests--assert
 "image-json: a data image carries data + mime_type"
 (let ((h (tagarela--image-json (list :data "AAAA" :mime "image/png"))))
   (and (equal "AAAA" (gethash "data" h))
        (equal "image/png" (gethash "mime_type" h))
        (null (gethash "path" h)))))

(tagarela-tests--assert
 "image-json: a path image carries only path"
 (let ((h (tagarela--image-json (list :path "/tmp/x.png"))))
   (and (equal "/tmp/x.png" (gethash "path" h))
        (null (gethash "data" h)))))

(tagarela-tests--assert
 "image-json: a url image carries only url"
 (let ((h (tagarela--image-json (list :url "https://example.com/x.png"))))
   (and (equal "https://example.com/x.png" (gethash "url" h))
        (null (gethash "path" h)))))

(tagarela-tests--assert
 "prompt params include the images array"
 (let* ((specs (list (list :data "AAAA" :mime "image/png")
                     (list :path "/tmp/x.png")))
        (json (tagarela--json-object
               "method" "prompt" "params"
               (tagarela--json-plist-to-hash
                (tagarela--prompt-params "hi" specs)))))
   (and (string-match-p "\"images\":\\[" json)
        (string-match-p "\"AAAA\"" json)
        (string-match-p "\"path\":\"/tmp/x.png\"" json)
        (string-match-p "\"mime_type\":\"image/png\"" json))))

(tagarela-tests--assert
 "without images the prompt has no images field"
 (not (string-match-p "images"
                      (tagarela--json-object
                       "method" "prompt" "params"
                       (tagarela--json-plist-to-hash
                        (tagarela--prompt-params "hi"))))))

;; Collecting text + images from the input buffer: the placeholders vanish
;; from the text and the specs come back in order.
(let ((buf (get-buffer-create "*tagarela-img-test*")))
  (unwind-protect
      (with-current-buffer buf
        (erase-buffer)
        (insert "before ")
        (tagarela--insert-image (list :url "https://example.com/a.png"))
        (insert " middle ")
        (tagarela--insert-image (list :path "/tmp/tagarela-missing-b.png"))
        (insert " after")
        (let* ((collected (tagarela--buffer-collect))
               (text (car collected))
               (images (cdr collected)))
          (tagarela-tests--assert
           "buffer-collect strips the image placeholders from the text"
           (equal "before  middle  after" text))
          (tagarela-tests--assert
           "buffer-collect returns the image specs in order"
           (and (= 2 (length images))
                (equal "https://example.com/a.png"
                       (plist-get (nth 0 images) :url))
                (equal "/tmp/tagarela-missing-b.png"
                       (plist-get (nth 1 images) :path))))))
    (kill-buffer buf)))

;; Text typed *right after* an inline image must be collected as text, not
;; swallowed as another image.  Interactive typing goes through
;; `self-insert-command', which uses `insert-and-inherit' and would copy the
;; placeholder's properties onto the new characters unless it is
;; `rear-nonsticky' (regression: an image pasted with a caption below arrived
;; at the model as image-only).
(let ((buf (get-buffer-create "*tagarela-img-inherit-test*")))
  (unwind-protect
      (with-current-buffer buf
        (erase-buffer)
        (tagarela--insert-image (list :url "https://example.com/a.png"))
        (insert-and-inherit "caption after the image")
        (let* ((collected (tagarela--buffer-collect))
               (text (car collected))
               (images (cdr collected)))
          (tagarela-tests--assert
           "text typed after an inline image is collected as text"
           (equal "caption after the image" text))
          (tagarela-tests--assert
           "text typed after an inline image is not collected as an image"
           (= 1 (length images)))))
    (kill-buffer buf)))

;; The yank-media handler stores the clipboard bytes base64-encoded with the
;; declared mime type, and returns non-nil so `yank-media' knows it handled it.
(let ((buf (get-buffer-create "*tagarela-img-handler*"))
      (bytes (unibyte-string 137 80 78 71 13 10 26 10)))
  (unwind-protect
      (with-current-buffer buf
        (erase-buffer)
        (let ((ret (tagarela--yank-media-image
                    'image/png (string-make-unibyte bytes))))
          (let ((spec (get-text-property (point-min) 'tagarela-image)))
            (tagarela-tests--assert
             "yank-media handler inserts a base64 data spec and returns t"
             (and ret spec
                  (equal "image/png" (plist-get spec :mime))
                  (equal bytes
                         (base64-decode-string (plist-get spec :data))))))))
    (kill-buffer buf)))

;; `tagarela-yank' (C-y in the input buffer) auto-detects the clipboard image
;; (no `yank-media' prompt) and only falls back to the normal text yank when
;; there is no renderable image.
(let ((text 0) (inserted nil))
  (cl-letf (((symbol-function 'tagarela--clipboard-image)
             (lambda () (cons "image/png" (unibyte-string 1 2 3))))
            ((symbol-function 'tagarela--yank-media-image)
             (lambda (type data) (setq inserted (list type data))))
            ((symbol-function 'yank) (lambda (&optional _) (cl-incf text)))
            ((symbol-function 'call-interactively)
             (lambda (fn &rest _) (funcall fn))))
    (tagarela-yank))
  (tagarela-tests--assert
   "yank auto-detects the clipboard image (no prompt, no text yank)"
   (and (equal '(image/png) (list (car inserted)))
        (equal (unibyte-string 1 2 3) (cadr inserted))
        (= 0 text))))

(let ((text 0))
  (cl-letf (((symbol-function 'tagarela--clipboard-image) (lambda () nil))
            ((symbol-function 'yank) (lambda (&optional _) (cl-incf text)))
            ((symbol-function 'call-interactively)
             (lambda (fn &rest _) (funcall fn))))
    (tagarela-yank))
  (tagarela-tests--assert
   "yank falls back to text when there is no clipboard image"
   (= 1 text)))

;; The best renderable image type is chosen by priority, without prompting.
(tagarela-tests--assert
 "mime priority: png outranks bmp"
 (< (tagarela--image-mime-rank "image/png")
    (tagarela--image-mime-rank "image/bmp")))
(tagarela-tests--assert
 "mime priority: listed types outrank unknown ones"
 (and (< (tagarela--image-mime-rank "image/jpeg")
         (tagarela--image-mime-rank "image/x-win-bitmap"))
      (< (tagarela--image-mime-rank "image/webp")
         (tagarela--image-mime-rank "image/unknown"))))

;; `tagarela--clipboard-image' skips non-renderable image types and picks the
;; highest-priority renderable one (here: png over bmp), reading its bytes.
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
    (let ((chosen (tagarela--clipboard-image)))
      (tagarela-tests--assert
       "clipboard-image picks the highest-priority renderable type (png over bmp)"
       (and (equal "image/png" (car chosen))
            (equal png-bytes (cdr chosen)))))))

;; With no renderable image on the clipboard, it returns nil (no prompt).
(cl-letf (((symbol-function 'gui-get-selection)
           (lambda (&rest _) (vector 'TARGETS 'text/plain 'image/x-win-bitmap)))
          ((symbol-function 'image-type-available-p) (lambda (_t) nil)))
  (tagarela-tests--assert
   "clipboard-image returns nil when nothing is renderable"
   (null (tagarela--clipboard-image))))

;; The explicit parameter commands insert into the input buffer.
(let ((input (get-buffer-create "*llm-bridge-input*")))
  (unwind-protect
      (progn
        (with-current-buffer input (erase-buffer))
        (tagarela-attach-image-url "https://example.com/pic.png")
        (tagarela-tests--assert
         "attach-image-url inserts a url image spec in the input buffer"
         (with-current-buffer input
           (equal "https://example.com/pic.png"
                  (plist-get (car (cdr (tagarela--buffer-collect))) :url)))))
    (with-current-buffer input (erase-buffer))))

;; Sending collects the images as the `images' array and clears the buffer.
(let ((input (get-buffer-create "*llm-bridge-input*"))
      (sent nil))
  (unwind-protect
      (progn
        (with-current-buffer input
          (erase-buffer)
          (insert "look at this ")
          (tagarela--insert-image (list :url "https://example.com/a.png")))
        (cl-letf (((symbol-function 'tagarela--send)
                   (lambda (method params) (push (cons method params) sent)))
                  ((symbol-function 'tagarela--ensure-ready) (lambda ()))
                  (tagarela-in-turn nil)
                  (tagarela-pending-tools nil))
          (with-current-buffer input (tagarela-send-input)))
        (let ((params (cdar sent)))
          (tagarela-tests--assert
           "send-input sends a prompt carrying the images array"
           (and (equal "prompt" (caar sent))
                (equal "look at this " (cadr (member "text" params)))
                (vectorp (cadr (member "images" params)))))
          (tagarela-tests--assert
           "send-input clears the input buffer (the image is gone)"
           (with-current-buffer input (string-empty-p (buffer-string))))))
    (tagarela--stop-spinner)
    (with-current-buffer input (erase-buffer))))

;; Sending only an image (no text) sends the minimal fallback text.
(let ((input (get-buffer-create "*llm-bridge-input*"))
      (sent nil))
  (unwind-protect
      (progn
        (with-current-buffer input
          (erase-buffer)
          (tagarela--insert-image (list :url "https://example.com/a.png")))
        (cl-letf (((symbol-function 'tagarela--send)
                   (lambda (method params) (push (cons method params) sent)))
                  ((symbol-function 'tagarela--ensure-ready) (lambda ()))
                  (tagarela-in-turn nil)
                  (tagarela-pending-tools nil))
          (with-current-buffer input (tagarela-send-input)))
        (tagarela-tests--assert
         "an image-only prompt gets the fallback text \"(imagem)\""
         (equal "(imagem)" (cadr (member "text" (cdar sent))))))
    (tagarela--stop-spinner)
    (with-current-buffer input (erase-buffer))))

;; Collect order: the segments preserve how the user typed image/text, so the
;; conversation echo can reproduce it (regression: an image pasted above a
;; caption was echoed below it, behind an empty ">>>" line).
(let ((buf (get-buffer-create "*tagarela-img-test*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (erase-buffer)
          (tagarela--insert-image (list :url "https://example.com/a.png"))
          (insert "\ncaption"))
        (let* ((segs (with-current-buffer buf (tagarela--buffer-collect-segments)))
               (kinds (mapcar #'car segs)))
          (tagarela-tests--assert
           "buffer-collect-segments keeps the image-before-text order"
           (equal '(image text) kinds)))
        (with-current-buffer buf
          (erase-buffer)
          (insert "caption")
          (tagarela--insert-image (list :url "https://example.com/a.png")))
        (let* ((segs (with-current-buffer buf (tagarela--buffer-collect-segments)))
               (kinds (mapcar #'car segs)))
          (tagarela-tests--assert
           "buffer-collect-segments keeps the text-before-image order"
           (equal '(text image) kinds)))
        (tagarela-tests--assert
         "buffer-collect still derives (TEXT . IMAGES) from the segments"
         (with-current-buffer buf
           (let ((c (tagarela--buffer-collect)))
             (and (equal "caption" (car c))
                  (= 1 (length (cdr c))))))))
    (kill-buffer buf)))

;; The echo body puts the image where the user typed it and keeps the badge on
;; the first line, so no ">>> " line is left blank.
(let ((spec (list :url "https://example.com/a.png")))
  (let ((body (tagarela--prompt-echo-body
               "\ncaption" (list spec)
               (list (cons 'image spec) (cons 'text "\ncaption")))))
    (tagarela-tests--assert
     "echo body (image above text) starts with the image, not a blank line"
     (and (string-prefix-p "[imagem" body)
          (string-match-p "\ncaption" body)
          (not (string-prefix-p "\n" body)))))
  (let ((body (tagarela--prompt-echo-body
               "caption" (list spec)
               (list (cons 'text "caption") (cons 'image spec)))))
    (tagarela-tests--assert
     "echo body (text above image) starts with the text"
     (and (string-prefix-p "caption" body)
          (string-match-p "\n\\[imagem" body)))))

;; Sending image + text echoes the image before the caption (regression).
(let ((input (get-buffer-create "*llm-bridge-input*"))
      (conv (get-buffer-create "*llm-bridge*")))
  (unwind-protect
      (progn
        (with-current-buffer conv (setq buffer-read-only nil) (erase-buffer))
        (with-current-buffer input
          (erase-buffer)
          (tagarela--insert-image (list :url "https://example.com/a.png"))
          (insert "\ncaption"))
        (cl-letf (((symbol-function 'tagarela--ensure-ready) (lambda ()))
                  ((symbol-function 'tagarela--send) (lambda (&rest _) nil))
                  ((symbol-function 'tagarela--start-spinner) (lambda () nil))
                  ((symbol-function 'tagarela--stop-spinner) (lambda () nil))
                  (tagarela-in-turn nil)
                  (tagarela-pending-tools nil))
          (with-current-buffer input (tagarela-send-input)))
        (let ((out (with-current-buffer conv (buffer-string))))
          (tagarela-tests--assert
           "echo of image+text does not leave a blank >>> line"
           (not (string-match-p ">>>[ \t]*\n" out)))
          (tagarela-tests--assert
           "echo of image+text places the image before the caption"
           (string-match-p ">>> \\[imagem[^\n]*\ncaption" out))))
    (with-current-buffer input (erase-buffer))
    (with-current-buffer conv (setq buffer-read-only nil) (erase-buffer))))

(provide 'tagarela-image-tests)

;;; tagarela-image-tests.el ends here
