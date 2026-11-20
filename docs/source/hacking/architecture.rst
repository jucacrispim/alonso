Architecture
============

alonso is split into a few files, all alongside each other in the package root.
``alonso.el`` is the thin entry point: it requires all of them, so
``(require 'alonso)`` gives you everything.

Dependency direction
--------------------

The dependency is strictly one-way::

   leaves (markdown / image / tools)  →  ui  →  client

* **``alonso-client.el``**: the "client".  It owns the JSON protocol
  (serializing the commands sent to the bridge and parsing the events it
  emits), the subprocess lifecycle (spawning, line filtering, handshake) and
  the approval of the mutating tools (the ``tool_confirm`` command), plus the
  trust-scope decision logic.  It implements no tool itself: the bridge
  executes them all and the read-only ones are merely displayed.  It knows
  nothing about buffers/windows: every event it dispatches goes to a rendering
  handler in ``alonso-ui.el``, reached via ``declare-function``, defined by the
  time the event arrives.

* **``alonso-ui.el``**: the "UI shell".  The conversation and input buffers,
  their minor modes and keymaps, the insertion helpers the renderers build on,
  the shared conversation state, the braille spinner, the mode-line fragments,
  the event render handlers, the ``/project`` command, the window layout
  (open/restart/kill) and the ``C-c C-a`` prefix map.  It requires
  ``alonso-client.el`` and reaches the leaf files' functions only at runtime
  (via ``declare-function``); the UI shell does **not** require the leaves.

* The three leaf files build on the shell but are **not** required by it:

  - **``alonso-markdown.el``**: Markdown rendering of the model's answer.
    Self-contained: it only operates on positions in the current buffer, driven
    through ``alonso--render-markdown-region``.
  - **``alonso-image.el``**: pasting/attaching images to a prompt (multimodal).
  - **``alonso-tools.el``**: tool-call display (an MCP tool is shown as
    ``<server>/<tool>``), per-call confirmation and the trust-scope menus.

The conversation pair
---------------------

The conversation and the input buffer are displayed as one atomic window
(``window-make-atom``).  ``delete-window`` and ``quit-window`` close both and
``delete-other-windows`` keeps both.  ``window-atom`` is not a persistent
parameter by default, so ``alonso-ui.el`` registers it as writable: without
that, restoring a saved window state (desktop.el, ``window-state-put``) drops
the group.

``display-buffer`` does not see the atomic group.  It reuses neither the
dedicated windows and it will not split an atomic one, so a buffer that asks
for "another window" (a compilation buffer, ``magit-status``) falls through to
the fallback action and splits the window the user is working in.  The
``display-buffer-alist`` entry in ``alonso-ui.el`` claims those buffers for the
pair's column: the conversation window is reused over the full column height
and the input window is deleted, so the newcomer takes the whole column.  Only
buffers that state no display policy of their own are claimed, and never while
the selected window is one of the two.

Two window states are stashed on a takeover, because the two ways out differ:
``quit-window`` only brings the conversation back into the column's window,
while ``delete-window`` removes that window.  The pair's own state covers the
first case and the whole frame's state the second.  Both are applied only
while the pair is not displayed, so they do not fight ``alonso-open``.

Rendering the answer
--------------------

The answer streams in as ``chunk`` events.  Rendering each fragment as it
arrives breaks mid-construct (the two ``*`` of a ``**bold**``), so the
fragments of a segment are accumulated and rendered in one shot when the
segment ends: before a ``thinking`` block, before a tool call and at the end
of the turn.

While the answer streams, the whole segment is re-rendered on every chunk.  Re
fontifying each code block from scratch every time is quadratic, and the worst
case is C: cc-mode's font-lock is slow on unbalanced braces, which is the
state of a C function while it is still being written.  So the open block is
fontified incrementally into a work buffer (the text that just arrived plus a
little context), and a block already fontified is skipped through the
``alonso-md-code-fontified`` marker on its opening fence.

Naming conventions
------------------

* Public symbols are prefixed ``alonso-``; internal ones ``alonso--``.
* Faces are named ``alonso-*-face``.
* Everything lives in the ``alonso`` customisation group.
