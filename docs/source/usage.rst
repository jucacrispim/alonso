Usage
=====

Starting the client
-------------------

The prefix key ``C-c a`` holds every command:

.. list-table::
   :header-rows: 1
   :widths: 15 20 65

   * - Key
     - Command
     - Description
   * - ``C-c a l``
     - ``alonso-open``
     - Start the client: split the window in two (left keeps the current
       buffer; right shows the conversation on top and the input buffer
       below, ~20% of the frame).
   * - ``C-c a o``
     - ``alonso-open``
     - Alias for ``alonso-open``.
   * - ``C-c a r``
     - ``alonso-restart``
     - Kill the bridge, clear the buffers, reset the state and reopen.
   * - ``C-c a k``
     - ``alonso-kill``
     - Terminate the bridge and clean up.
   * - ``C-c a c``
     - ``alonso-cancel``
     - Cancel the current in-flight turn.
   * - ``C-c a q``
     - ``alonso-quit``
     - Send ``quit`` to the bridge and stop.
   * - ``C-c a p``
     - ``alonso-set-provider``
     - Set the provider override for the next prompt.
   * - ``C-c a m``
     - ``alonso-set-model``
     - Set the model override for the next prompt (empty = provider default).
   * - ``C-c a t``
     - ``alonso-set-thinking``
     - Toggle thinking on/off/unset per request.
   * - ``C-c a e``
     - ``alonso-set-reasoning-effort``
     - Set the thinking depth (low/medium/high, empty = provider default) per
       request.
   * - ``C-c a i``
     - ``alonso-attach-image-file``
     - Attach an image (by path) to the next prompt.
   * - ``C-c a u``
     - ``alonso-attach-image-url``
     - Attach an image (by URL) to the next prompt.

The conversation and the input buffer
-------------------------------------

The conversation buffer shows the user prompts prefixed with ``>>> `` and the
model's response streaming into it.  Thinking (chain-of-thought) is rendered in
PaleVioletRed4 (``#8b475d``, set in ``pdj-theme.el``) and separated from the
answer by two blank lines.  The model's answer is rendered as Markdown (faces,
hidden markers, clickable links and fenced-code-block highlighting), without
ever changing the buffer text — copying the conversation out is unaffected.

In the input buffer:

* ``C-c C-c`` — ``alonso-send-input`` sends the prompt (``RET`` inserts a
  newline).
* ``C-y`` — ``alonso-yank`` pastes an image from the clipboard when there is
  one, otherwise yanks text as usual.
* ``RET`` / ``C-j`` — insert a newline.

Images are attached inline in the input buffer (the image shows in the buffer)
and sent with the prompt as the bridge's ``images`` array.  There is no separate
"pending images" list: an image is carried as text with the ``alonso-image``
property.

Tool calls
----------

Mutating tool calls show their confirmation question right away, one at a time
— the tool's icon and the ``Run tool: <name>?`` prompt, e.g.
``🖥 Run tool: shell?``, followed by the parameters beneath it.  Once the user
answers, the ``[allowed]`` / ``[denied]`` tag is prepended to the front of that
same line.  The trust-scope decision (per-call question and trust scope) uses
transient menus, with a ``read-char-choice`` fallback when transient is
unavailable.

Hooks
-----

A prompt whose text starts with ``#`` is treated as a local hook: the bridge
runs the script ``.llm-bridge/hooks/<name>.sh`` (project dir first, then
``~/.llm-bridge/hooks/``) instead of calling the LLM, and replies
asynchronously with a single ``hook_action`` event (no ``turn_end``).

The ``/project`` command
------------------------

Typing ``/project <something>`` in the input buffer changes the working
directory the bridge uses.  The meaning of ``<something>`` depends on the
``alonso-project-dir`` defcustom:

* ``nil`` (default) — the argument is a **path** (expanded with
  ``expand-file-name``).
* non-``nil`` — the argument is a **project name** resolved as ``BASE/NAME``.

As a side effect the project's ``.dir-locals.el`` is applied (respecting
``safe-local-variable-values``), ``set_cwd`` is sent to the bridge and
``alonso-project-change-hook`` is run with the directory.

The mode line
-------------

The conversation buffer's mode line (which hides the usual modes and
line/column info) shows::

   [<model>] [↑<in> ↓<out> ⚡<hit>/<miss>] <dial> <pct>% (<used>/<window>) <status>

The last group is the braille spinner while a turn is running, ``alonso…`` for a
turn without a spinner, and empty when idle.  The session token block ``⚡`` only
appears when ``hit + miss > 0``.

The input buffer's mode line shows only its name plus the request overrides for
the next prompt, e.g. `` [thinking=on effort=high]`` (empty when none is set).
