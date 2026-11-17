;;; alonso.el --- Emacs client for llm-bridge (entry point)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Juca Crispim <juca@poraodojuca.dev>

;; Author: Juca Crispim <juca@poraodojuca.dev>
;; Version: 0.5.0
;; Package-Requires: ((emacs "27.1") (transient "0.4.0"))
;; Keywords: tools, convenience
;; URL: https://github.com/poraodojuca/alonso

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

;; Emacs client for llm-bridge, a long-running Go process that bridges an
;; editor and an LLM over JSON lines (stdin/stdout).  This package
;; starts the bridge as a subprocess, reads its events asynchronously and
;; displays the conversation in a dedicated buffer.  The bridge executes the
;; tool calls: read-only ones run inline and are just displayed; mutating ones
;; ask for the user's approval before running.
;;
;; The bridge protocol is documented in
;; ~/mysrc/llm-bridge/docs/source/.
;;
;; This file is the thin entry point: it requires all of the others, so
;; `(require 'alonso)' gives you everything.  The commands live under the
;; `C-c C-a' prefix.
;;
;; The manual covers the commands (docs/source/usage.rst) and the file layout
;; and design (docs/source/hacking/architecture.rst).
;;
;;; Code:

(require 'cl-lib)

;; The files live alongside this one in the package root; make sure that
;; directory is loadable.
(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (when dir
    (add-to-list 'load-path dir)))

(require 'alonso-client)
(require 'alonso-ui)
(require 'alonso-markdown)
(require 'alonso-image)
(require 'alonso-tools)

(provide 'alonso)

;;; alonso.el ends here
