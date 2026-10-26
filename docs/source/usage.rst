Usage
=====

Starting the client
-------------------

The prefix key ``C-c C-a`` holds every command:

.. list-table::
   :header-rows: 1
   :widths: 15 20 65

   * - Key
     - Command
     - Description
   * - ``C-c C-a l``
     - ``alonso-open``
     - Start the client: split the window in two (left keeps the current
       buffer; right shows the conversation on top and the input buffer
       below, ~20% of the frame).
   * - ``C-c C-a o``
     - ``alonso-open``
     - Alias for ``alonso-open``.
   * - ``C-c C-a r``
     - ``alonso-restart``
     - Kill the bridge, clear the buffers, reset the state and reopen.
   * - ``C-c C-a k``
     - ``alonso-kill``
     - Terminate the bridge and clean up.
   * - ``C-c C-a c``
     - ``alonso-cancel``
     - Cancel the current in-flight turn.
   * - ``C-c C-a q``
     - ``alonso-quit``
     - Send ``quit`` to the bridge and stop.
   * - ``C-c C-a p``
     - ``alonso-set-provider``
     - Set the provider override for the next prompt.
   * - ``C-c C-a m``
     - ``alonso-set-model``
     - Set the model override for the next prompt (empty = provider default).
   * - ``C-c C-a t``
     - ``alonso-set-thinking``
     - Toggle thinking on/off/unset per request.
   * - ``C-c C-a w``
     - ``alonso-toggle-show-thinking``
     - Toggle how the thinking is displayed: the text (``alonso-show-thinking``
       t) or the transient placeholder with the braille spinner (nil).
   * - ``C-c C-a e``
     - ``alonso-set-reasoning-effort``
     - Set the thinking depth (low/medium/high, empty = provider default) per
       request.
   * - ``C-c C-a i``
     - ``alonso-attach-image-file``
     - Attach an image (by path) to the next prompt.
   * - ``C-c C-a u``
     - ``alonso-attach-image-url``
     - Attach an image (by URL) to the next prompt.

The conversation and the input buffer
-------------------------------------

The conversation buffer shows the user prompts prefixed with ``>>> `` and the
model's response streaming into it.  Thinking (chain-of-thought) is rendered in
PaleVioletRed4 (``#8b475d``, set in ``pdj-theme.el``) and separated from the
answer by two blank lines.  When ``alonso-show-thinking`` is nil the thinking
text is hidden instead and a transient placeholder is shown — the
``alonso-thinking-placeholder`` string (``thinking…`` by default) with the
braille spinner running just to its left — which disappears as soon as the
answer (or a tool call) starts.  The model's answer is rendered as Markdown
(faces, hidden markers, clickable links and fenced-code-block highlighting),
without ever changing the buffer text — copying the conversation out is
unaffected.

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

The bridge executes every tool call.  Read-only tools (``read``, ``grep``,
``glob``) run without confirmation: the bridge emits a ``tool_call`` event and
alonso just displays it in the conversation.  Mutating tools (``write``,
``search_replace``, ``shell``, ``curl``) need the user's approval: the bridge
emits a ``tool_confirm`` event with the tool's name and parameters, and alonso
asks for a decision (approving sends the ``tool_confirm`` command; denying is a
``cancel``).

``knowledge`` is classified per call: ``show`` and ``search`` are read-only and
run inline, while ``add``/``delete``/``reset`` (and a command alonso cannot
classify) are mutating and ask.  Trust is never granted by *class* to
``knowledge``: a class trust on KB writes would let a note planted by an
injected page skip the human, and the KB is read by every later session.

What a trust scope covers depends on the tool:

``shell``
   *class* is the **program of a single-command line** (``git`` for
   ``git status``), matched exactly — ``sed`` never covers ``sedx``.  A line
   that runs more than one command (``cd /tmp && git status``) has no class:
   its first token would be ``cd``, and trusting that would cover every
   command that merely changes directory first.  The same goes for a line
   whose first token is inert (``cd``, ``export``, ``true``…), for an
   assignment prefix (``FOO=1 cmd``) and for a call the bridge classified as
   ``medium``/``high`` risk — the class of ``git`` is offered on ``git
   status``, not on ``git push --force``.  Such a call can still be trusted
   per call (``s``) or per tool (``a``).

``write`` / ``search_replace``
   *class* is the file's directory, matched by prefix so sub-directories are
   covered too.

``curl``
   *class* is the URL's **host**: scheme, any ``user:password@`` prefix and the
   port are dropped and the host is lowercased, so ``https://user@Example.COM:8443/a``
   is trusted as ``example.com``.  The match is exact — trusting
   ``example.com`` does not trust ``example.com.evil.tld``.  Only the ``url``
   is considered: a host reached through a redirect (``-L``), ``--resolve`` or
   an argument is not covered.

A tool without a class (``knowledge``, a ``shell`` line that runs several
commands, or a ``curl`` call with no usable host) does not offer the *class*
entry: the menu only shows the scopes that can actually record something.

The ``tool_confirm`` event also carries the prompt-injection hardening detail,
which alonso shows before the question:

``segments``
   The commands a ``shell`` one-liner really runs (split on ``;``, ``&&``,
   ``||``, ``|`` and newlines, never inside quotes).  Redirections are not
   separators: ``git describe --tags 2>&1 || true`` is two commands, not
   four.  When there is more than one, they are listed
   one per line, so an approval that runs ``make && sudo make install`` is read
   as two commands instead of one long line.

``risk``
   ``high``, ``medium`` or ``low``.  It is appended to the question and, on
   ``high``, the call has to be confirmed with a **typed** ``yes`` — a single
   keystroke only approves ``low``/``medium`` calls.  A trust never covers
   this: a ``git`` class trust does not turn ``git push --force`` into a
   silent run.

``tainted``
   Non-nil when the arguments reproduce content fetched earlier in the session
   (the shape of "read this page, then run what it says").  It is shown as a
   warning line and never blocks the call by itself.

Mutating tool calls show their confirmation question right away, one at a time
— the tool's icon and the ``Run tool: <name>?`` prompt, e.g.
``🖥 Run tool: shell?``, followed by the parameters beneath it.  Once the user
answers, the ``[allowed]`` / ``[denied]`` tag is prepended to the front of that
same line.  The trust-scope decision (per-call question and trust scope) uses
transient menus, with a ``read-char-choice`` fallback when transient is
unavailable: trust this call (``s``), this class of calls (``c``) or the whole
tool (``a``).  If a *class* trust cannot be recorded for the call, a message
says so and the call is marked ``[allowed]`` (trusted once), never silently
``[trusted]``.

The ``a`` scope trusts the tool whose question was on screen — never the other
tools of the session.  A trust silences the questions it covers, so it is never
invisible: choosing a scope says what it now covers in the echo area, the
conversation mode line names the active grants (``🔓shell``,
``🔓curl=example.com``) and ``M-x alonso-trust-reset`` forgets every grant of
the session (they are also cleared when the bridge is restarted).  The
*specific* scope is not shown in the mode line: it covers a single call, already
tagged ``[trusted]`` in the conversation.

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
