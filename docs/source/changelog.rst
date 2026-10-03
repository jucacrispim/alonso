Changelog
=========

All notable changes to this project are documented in this file.

The format is based on `Keep a Changelog
<https://keepachangelog.com/en/1.1.0/>`_, and this project adheres to
`Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.

`0.2.0`_ (2026-10-03)
---------------------

Changed
~~~~~~~

- Tool calls are now executed by the **bridge**, not by the client.  alonso no
  longer implements any tool itself; it only displays them and, when needed,
  asks for the user's approval.

  - Read-only tools (``read``, ``grep``, ``glob``, ``knowledge``) arrive as a
    ``tool_call`` event and are displayed inline without confirmation.
  - Mutating tools (``write``, ``search_replace``, ``shell``) arrive as a
    ``tool_confirm`` event: alonso asks for a decision (approving sends the
    ``tool_confirm`` command; denying is a ``cancel``).

- Documentation (README, ``index.rst``, ``architecture.rst``, ``usage.rst``)
  updated to reflect that the bridge — and not the client — executes the tool
  calls.

Fixed
~~~~~

- Missing blank line after a read-only tool call: the resumed model output was
  rendered glued to the tool display.  ``alonso--on-tool-call`` now marks the
  pending separator so the following thinking/answer is separated by two blank
  lines, matching the mutating-tool flow.

`0.1.0`_ (2026-10-01)
---------------------

Added
~~~~~

- Initial release: an Emacs client for **llm-bridge**, spawning the bridge as a
  subprocess, reading its JSON-lines events asynchronously and displaying the
  conversation in a dedicated buffer (conversation + input buffers, window
  layout, and the ``C-c C-a`` command prefix).
- Streaming responses with Markdown rendering (faces, hidden markers,
  clickable links and fenced-code-block highlighting) that never changes the
  buffer text.
- Thinking (chain-of-thought) rendering, with a toggle between the thinking
  text and a transient braille-spinner placeholder, plus per-request overrides
  for provider, model, thinking and reasoning effort.
- Multimodal prompts: attach images by path or URL, or paste them from the
  clipboard, sent as the bridge's ``images`` array.
- Tool-call display and the confirmation/trust UX (transient menus with a
  ``read-char-choice`` fallback).
- The ``/project`` command to change the bridge's working directory, and local
  hooks (prompts starting with ``#``).
- A conversation/input mode line showing the model, token usage and status.

.. _0.2.0: https://github.com/poraodojuca/alonso/compare/v0.1.0...v0.2.0
.. _0.1.0: https://github.com/poraodojuca/alonso/releases/tag/v0.1.0
