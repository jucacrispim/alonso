;;; tagarela-image.el --- Image attachments for tagarela  -*- lexical-binding: t; -*-

;;; Commentary:

;; Attach images to a prompt (multimodal): pasting from the clipboard
;; (`tagarela-yank', bound to `C-y' in the input buffer), attaching a file or a
;; URL, and collecting the attached images at send time.  An image is carried
;; inline in the input buffer as text with the `tagarela-image' property, so
;; there is no separate "pending images" list.
;;
;; Builds on tagarela-ui.el (input buffer, faces) and tagarela-client.el
;; (per-request buffers, the `images' JSON).
;;
;; See tagarela-ui.el.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tagarela-client)
(require 'tagarela-ui)

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

(provide 'tagarela-image)

;;; tagarela-image.el ends here
