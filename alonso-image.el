;;; alonso-image.el --- Image attachments for alonso  -*- lexical-binding: t; -*-

;;; Commentary:

;; Attach images to a prompt (multimodal): pasting from the clipboard
;; (`alonso-yank', bound to `C-y' in the input buffer), attaching a file or a
;; URL, and collecting the attached images at send time.  An image is carried
;; inline in the input buffer as text with the `alonso-image' property, so
;; there is no separate "pending images" list.
;;
;; Builds on alonso-ui.el (input buffer, faces) and alonso-client.el
;; (per-request buffers, the `images' JSON).
;;
;; See alonso-ui.el.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'alonso-client)
(require 'alonso-ui)

;;; Images — pasting/attaching images to a prompt (multimodal)

;; An image is attached by inserting it *inline* in the input buffer: the
;; buffer shows the image itself and, right beneath the text, carries the spec
;; (a plist) in the `alonso-image' text property.  At send time
;; `alonso--buffer-collect' strips those placeholders out of the text and
;; hands the specs to `alonso--prompt-send', so the pasted image is a
;; WYSIWYG attachment — no separate "pending images" list to manage.

(defcustom alonso-image-max-width 400
  "Maximum width, in pixels, an inline image is displayed at.
Bigger images are scaled down for DISPLAY only; the full-resolution image is
what gets sent to the model.  nil displays images at their full size."
  :type '(choice (const :tag "Full size" nil) integer)
  :group 'alonso)

(defcustom alonso-image-mime-priority
  '("image/png" "image/webp" "image/gif" "image/jpeg"
    "image/bmp" "image/tiff" "image/svg+xml")
  "Clipboard image MIME types, most preferred first.
When the clipboard offers several renderable image types, `alonso-yank'
inserts the first one present in this list — no prompt.  Types not listed
rank after every listed type."
  :type '(repeat string)
  :group 'alonso)

(defun alonso--image-bytes (data)
  "Return DATA (a clipboard selection string) as a unibyte string of bytes."
  (if (multibyte-string-p data)
      (encode-coding-string data 'binary)
    data))

(defun alonso--image-symbol (mime)
  "Return the `create-image' type symbol for MIME (e.g. `png'), or nil."
  (when (and (stringp mime) (string-match-p "/" mime))
    (intern (cadr (split-string mime "/")))))

(defun alonso--image-create (spec)
  "Create an Emacs image object for the image SPEC, or nil if not displayable.
SPEC is a plist (`:data'/`:mime', `:path' or `:url'); a URL has no local bytes
and is never displayed.  The image is scaled to `alonso-image-max-width'."
  (ignore-errors
    (let ((data (plist-get spec :data))
          (path (plist-get spec :path))
          (props (when alonso-image-max-width
                   (list :max-width alonso-image-max-width))))
      (cond
       (data
        (apply #'create-image (base64-decode-string data)
               (alonso--image-symbol (plist-get spec :mime)) t props))
       (path
        (apply #'create-image (expand-file-name path) nil t props))
       (t nil)))))

(defun alonso--image-string (spec)
  "Return a string carrying the inline image of SPEC.
The string is a single space holding the image in its `display' property and
SPEC itself in the `alonso-image' property (so it can be collected at send
time).  When the image cannot be displayed (a URL, or a format this Emacs
cannot render) a textual placeholder — still carrying the `alonso-image'
property — is returned instead.  The placeholder is `rear-nonsticky' so text
typed right after it does not inherit the attachment properties."
  ;; `rear-nonsticky' matters: text typed right after the placeholder is
  ;; inserted with `insert-and-inherit', which would otherwise copy the
  ;; `alonso-image' (and `display') properties onto it — making typed text
  ;; look like another image and get dropped from the prompt at send time.
  (let ((img (alonso--image-create spec)))
    (if img
        (propertize " " 'display img 'alonso-image spec 'rear-nonsticky t)
      (propertize (format "[imagem: %s]"
                          (or (plist-get spec :path)
                              (plist-get spec :url)
                              (plist-get spec :mime)
                              "?"))
                  'face 'alonso-separator-face
                  'alonso-image spec
                  'rear-nonsticky t))))

(defun alonso--insert-image (spec)
  "Insert SPEC as an inline image at point in the current buffer."
  (insert (alonso--image-string spec)))

(defun alonso--yank-media-image (type data)
  "`yank-media' handler: insert clipboard image DATA (of MIME TYPE) inline.
Registered for the input buffer by `alonso-input-mode'.  Returns non-nil so
`yank-media' knows it handled the selection."
  (alonso--insert-image
   (list :mime (symbol-name type)
         :data (base64-encode-string (alonso--image-bytes data) t)))
  t)

(defun alonso--image-mime-rank (mime)
  "Return the preference rank of the MIME type string MIME (lower is better).
Unknown types rank after every type in `alonso-image-mime-priority'."
  (or (cl-position mime alonso-image-mime-priority :test #'string=)
      (length alonso-image-mime-priority)))

(defun alonso--clipboard-image ()
  "Return the best image on the clipboard as (MIME . DATA), or nil.
Like `yank-media', only considers image types this Emacs can actually render
\(so the clipboard's `image/x-win-bitmap' and the like are skipped).  Among
them it picks the highest-priority one per `alonso-image-mime-priority'
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
                                 (< (alonso--image-mime-rank (symbol-name a))
                                    (alonso--image-mime-rank (symbol-name b))))))))
    (let ((data (gui-get-selection 'CLIPBOARD best)))
      (when (stringp data)
        (cons (symbol-name best) (alonso--image-bytes data))))))

;;;###autoload
(defun alonso-yank ()
  "Yank from the clipboard: an image when there is one, else text.
When the clipboard holds an image this Emacs can render, the best one (per
`alonso-image-mime-priority') is inserted inline without prompting;
otherwise this falls back to the normal text `yank'."
  (interactive)
  (if-let ((image (ignore-errors (alonso--clipboard-image))))
      (alonso--yank-media-image (intern (car image)) (cdr image))
    (call-interactively #'yank)))

;;;###autoload
(defun alonso-attach-image-file (file)
  "Attach the image FILE to the next prompt (sent to the bridge by path)."
  (interactive "fImage file: ")
  (let ((file (expand-file-name file)))
    (unless (file-readable-p file)
      (user-error "Cannot read image file: %s" file))
    (with-current-buffer (alonso--request-buffer)
      (alonso--insert-image (list :path file)))
    (message "Image attached: %s" file)))

;;;###autoload
(defun alonso-attach-image-url (url)
  "Attach the image at URL to the next prompt (passed through to the provider)."
  (interactive "sImage URL: ")
  (with-current-buffer (alonso--request-buffer)
    (alonso--insert-image (list :url url)))
  (message "Image URL attached: %s" url))

(defun alonso--buffer-collect-segments ()
  "Collect the current (input) buffer as an ordered list of segments.
Each segment is a cons (KIND . VALUE): KIND is either `text' (VALUE the text
run, with the image placeholders removed) or `image' (VALUE an image spec
plist).  Segments appear in buffer order, so an image pasted above a caption
comes before it and one pasted below comes after — this is what the echo in
`alonso--prompt-send' uses to reproduce the order the user typed."
  (let ((pt (point-min))
        (segments '()))
    (while (< pt (point-max))
      (let* ((next (or (next-single-property-change pt 'alonso-image nil (point-max))
                       (point-max)))
             (spec (get-text-property pt 'alonso-image)))
        (push (if spec
                  (cons 'image spec)
                (cons 'text (buffer-substring-no-properties pt next)))
              segments)
        (setq pt next)))
    (nreverse segments)))

(defun alonso--buffer-collect ()
  "Collect the text and the images of the current (input) buffer.
Returns (TEXT . IMAGES): TEXT is the buffer text with the image placeholders
removed, IMAGES the list of image specs (plists) in order of appearance."
  (let ((texts '())
        (images '()))
    (dolist (seg (alonso--buffer-collect-segments))
      (if (eq (car seg) 'image)
          (push (cdr seg) images)
        (push (cdr seg) texts)))
    (cons (apply #'concat (nreverse texts))
          (nreverse images))))

(provide 'alonso-image)

;;; alonso-image.el ends here
