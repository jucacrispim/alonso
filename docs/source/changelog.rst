Changelog
=========

All notable changes to this project are documented in this file.

The format is based on `Keep a Changelog
<https://keepachangelog.com/en/1.1.0/>`_, and this project adheres to
`Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.

Unreleased
----------

Changed
~~~~~~~

- The client no longer wraps the bridge in a sandbox launcher: the **bridge**
  applies the sandbox to itself (it re-executes itself under ``caged`` and
  runs its tools under a stricter policy).  ``alonso-sandbox-command`` is gone;
  the new ``alonso-sandbox`` (default ``t``) makes the client pass the bridge's
  own flags — ``-sandbox-ro``/``-sandbox-rw``, or ``-disable-sandbox`` when it
  is ``nil``.
- ``alonso-sandbox-ro-paths`` (default ``nil``) and ``alonso-sandbox-rw-paths``
  (default ``("~/mysrc")``) are now passed to the bridge as
  ``-sandbox-ro``/``-sandbox-rw``.  The bridge already grants the system trees,
  ``/dev/urandom``, the KB assets and ``~/.llm-bridge``, so the lists only add
  the projects root and extras.
- ``alonso-sandbox-extra-args`` became ``alonso-sandbox-args``: the bridge's
  sandbox flags, passed verbatim after the paths.
- The client no longer filters the environment: the bridge keeps its own (the
  API key and the rest) and runs the tools without it.  ``CAGED_DISABLE_WARNINGS=1``
  is still set around the spawn, because the bridge forwards it to ``caged``.
- The directories holding the binaries and the log file are no longer added by
  the client: the bridge grants itself the binary directories, creates the log
  file and grants that file only (never its directory).

Removed
~~~~~~~

- ``alonso-sandbox-command``, ``alonso-sandbox-extra-ro-paths``,
  ``alonso-sandbox-extra-rw-paths``, ``alonso-sandbox-env-vars`` and
  ``alonso-sandbox-launcher-env``.

0.4.0 (2026-10-21)
------------------

Added
~~~~~

- ``alonso-sandbox-extra-args``: extra flags emitted to the sandbox launcher
  before the ``--`` (after the ``--ro``/``--rw`` paths).  The default,
  ``--allow-network-sockets`` and ``--allow-connect-port 443``, is what
  ``caged`` 0.2.0 needs for the bridge to reach its provider: without the
  socket family even DNS fails (the resolver opens a netlink socket), and
  without the port rule Landlock blocks the HTTPS connection.
- ``alonso-sandbox-env-vars``: names of environment variables passed through
  as ``--env NAME=VALUE``, only for the ones actually set at launch.  This is
  required because ``caged`` 0.2.0 wipes the child environment by default
  (only ``PATH``, ``HOME``, ``LANG``, ``LANGUAGE`` and ``LC_*`` survive);
  passing them one by one instead of using ``--keep-env`` keeps
  ``SSH_AUTH_SOCK``, ``DISPLAY`` and ``DBUS_*`` out of the sandbox.
- ``alonso-sandbox-launcher-env``: an alist applied with ``setenv`` around the
  spawn (and restored afterwards) so the *launcher* sees it — e.g.
  ``CAGED_DISABLE_WARNINGS=1`` to silence ``caged``'s Landlock ABI warning,
  which would otherwise be reported as a launch failure.

Changed
~~~~~~~

- The sandbox argv is now ``SANDBOX [--ro DIR]... [--rw DIR]...
  [EXTRA-ARGS]... [--env NAME=VALUE]... -- BRIDGE <args>``.

`0.3.0`_ (2026-10-04)
---------------------

Added
~~~~~

- Optional sandbox wrapper for the bridge subprocess.  Set
  ``alonso-sandbox-command`` to a launcher (e.g. ``caged``) and the bridge is
  run as that launcher with a list of read-only (``alonso-sandbox-ro-paths``)
  and read-write (``alonso-sandbox-rw-paths``) paths before the bridge command.
- Extra path lists, ``alonso-sandbox-extra-ro-paths`` and
  ``alonso-sandbox-extra-rw-paths`` (both empty by default), appended to the
  base lists so more paths can be granted from the init file without redefining
  the base ones.
- The directories holding the bridge and the sandbox binaries are added as
  ``--ro`` automatically (so the sandbox can ``exec`` them wherever they are
  installed), and the directory holding ``alonso-logfile`` as ``--rw``
  automatically.
- ``/dev/null`` and ``/dev/urandom`` are in the default read-write list: the Go
  runtime opens ``/dev/null`` for the stdin of the tools the bridge spawns
  (``shell``, ``grep``), and tools that create temporary files or tokens
  (``git`` via ``mkstemp``, TLS) read ``/dev/urandom``.

Fixed
~~~~~

- A failed sandbox launch (e.g. the sandbox denying ``exec``) is now reported
  with the process's stderr and exit status, instead of a bare ``ready``
  timeout.

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

.. _0.3.0: https://github.com/poraodojuca/alonso/compare/v0.2.0...v0.3.0
.. _0.2.0: https://github.com/poraodojuca/alonso/compare/v0.1.0...v0.2.0
.. _0.1.0: https://github.com/poraodojuca/alonso/releases/tag/v0.1.0
