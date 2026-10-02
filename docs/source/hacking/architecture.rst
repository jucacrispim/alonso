Architecture
============

alonso is split into a few files, all alongside each other in the package root.
``alonso.el`` is the thin entry point: it requires all of them, so
``(require 'alonso)`` gives you everything.

Dependency direction
--------------------

The dependency is strictly one-way::

   leaves (markdown / image / tools)  →  ui  →  client

* **``alonso-client.el``** — the "client": the JSON protocol (serializing the
  commands sent to the bridge and parsing the events it emits), the subprocess
  lifecycle (spawning, line filtering, handshake) and the implementation of the
  tools (``read``, ``write``, ``glob``, ``search_replace``, ``shell``,
  ``grep``) plus the trust-scope decision logic.  It knows nothing about
  buffers/windows; every event it dispatches is handed to a rendering handler
  living in ``alonso-ui.el``, reached via ``declare-function`` (only called at
  runtime, never at load time).

* **``alonso-ui.el``** — the "UI shell": the conversation and input buffers,
  their minor modes and keymaps, the insertion helpers the renderers build on,
  the shared conversation state, the braille spinner, the mode-line fragments,
  the event render handlers, the ``/project`` command, the window layout
  (open/restart/kill) and the ``C-c C-a`` prefix map.  It requires
  ``alonso-client.el`` and reaches the leaf files' functions only at runtime
  (via ``declare-function``); the UI shell does **not** require the leaves.

* The three leaf files build on the shell but are **not** required by it:

  - **``alonso-markdown.el``** — Markdown rendering of the model's answer.
    Self-contained: it only operates on positions in the current buffer, driven
    through ``alonso--render-markdown-region``.
  - **``alonso-image.el``** — pasting/attaching images to a prompt (multimodal).
  - **``alonso-tools.el``** — tool-call display, per-call confirmation and the
    trust-scope menus.

Naming conventions
------------------

* Public symbols are prefixed ``alonso-``; internal ones ``alonso--``.
* Faces are named ``alonso-*-face``.
* Everything lives in the ``alonso`` customisation group.
