Changelog
=========

All notable changes to this project are documented in this file.

The format is based on `Keep a Changelog
<https://keepachangelog.com/en/1.1.0/>`_, and this project adheres to
`Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.

0.5.0 (2026-10-26)
------------------

Added
~~~~~

- Support for the bridge's ``curl`` tool: it is a mutating tool (it leaves the
  machine), so it asks for confirmation, and its display shows the URL with the
  **host highlighted** plus the request ``args``, one per line, only when there
  are any.
- The confirmation detail the bridge sends with a ``tool_confirm`` (the
  prompt-injection hardening) is now consumed and shown: ``segments`` (a
  ``shell`` one-liner is listed command per command), ``risk`` (appended to the
  question) and ``tainted`` (a warning line when the arguments repeat fetched
  content).  All of it is advisory and never blocks the call by itself.
- A ``high`` risk call has to be confirmed with a **typed** ``yes``: a single
  keystroke only approves ``low``/``medium`` calls.  Type ``!`` to reach the
  trust-scope menu instead.
- ``curl`` has a trust class: the URL's **host** (scheme, ``user:password@``
  and port dropped, lowercased), so a host can be trusted once for every URL on
  it.  The match is exact — ``example.com`` never covers
  ``example.com.evil.tld``.
- The trust scope entry that cannot record anything is no longer offered: the
  *class* entry disappears for ``knowledge`` and for a ``curl`` call with no
  usable host, and if a class trust still ends up unrecorded a message says the
  call was trusted once (``[allowed]``) instead of silently doing nothing.

Changed
~~~~~~~

- ``knowledge`` is classified per call, like the bridge does: ``show`` and
  ``search`` are read-only (displayed only), while ``add``/``delete``/``reset``
  — and any command that cannot be classified — are mutating and ask for
  confirmation.  Previously the whole tool counted as read-only, so a KB write
  was shown as if it needed no approval.
- ``knowledge`` deliberately has **no** trust class: trusting a whole class of
  KB writes would let a note planted by an injected page skip the human (and the
  KB is read by every later session).
- The confirmation questions now follow the order the model asked the tool calls
  in.  The bridge emits every ``tool_confirm`` of a turn at once and the client
  queued them newest-first, so a batch used to be reviewed in reverse.
- The ``segments`` of a ``shell`` one-liner no longer count a redirection as a
  command: with the bridge's fixed splitter, ``git describe --tags 2>&1 || true``
  is two commands instead of four, so the "runs N commands" header and the
  segment limit count real commands.
- The risk of a tool call is now hard to miss.  The warning line is upper case
  (``⚠ HIGH RISK — destructive, remote or privileged``) in its own bold faces —
  ``medium`` used to be plain text with no face at all — the taint warning reads
  ``⚠ TAINTED``, and the same tag (``[HIGH RISK]``/``[MEDIUM RISK]``) is
  appended both to the question and to the ``Run tool:`` line in the
  conversation, the one that later carries the ``[allowed]``/``[denied]``
  outcome.
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

Fixed
~~~~~

- The trust menu's ``all`` scope (``a``) trusted **every** tool for the rest of
  the session, although its own entry says "this whole tool": picking it while
  confirming one tool vouched for tools the user never looked at (a KB write,
  say).  It now records only the tool whose menu it was picked from.
- The ``specific`` scope (``s``) never matched in real use, so the call it was
  supposed to trust asked again on the next confirmation.  It stored the parsed
  payload and compared with ``equal``, and ``equal`` on hash tables is true only
  for the very same object — every ``tool_confirm`` arrives parsed afresh.  The
  payload is now canonicalized (keys sorted, recursing into nested tables and
  lists) before being recorded and compared.
- A trust grant is no longer invisible.  It silences the questions it covers,
  so it is now said out loud: picking a scope reports what it covers in the echo
  area, the conversation mode line names the active grants (``🔓shell``,
  ``🔓curl=example.com``) and the new ``M-x alonso-trust-reset`` forgets every
  grant of the session.
- The trust **class** of ``shell`` was the first token of the line, so
  ``cd ~/proj && git status; …`` offered "This class of calls: **cd**" — and a
  ``cd`` class covers every command that merely changes directory first
  (``cd /tmp && rm -rf x`` included).  The class is now the program of a
  **single-command** line (``git`` for ``git status``), and a line that runs
  several commands, starts with an inert token (``cd``, ``export``, ``true``…)
  or carries an assignment prefix (``FOO=1 cmd``) has no class at all: the menu
  offers no ``c`` for it.
- A ``high`` risk call is no longer approved by a trust.  The confirmation
  queue checked the trusts before the risk, so a ``git`` class trust turned
  ``git push --force`` into a silent run — the typed ``yes`` was skipped
  entirely.  A trusted call that the bridge classifies as ``high`` still asks
  for the typed answer, and picking a trust scope while confirming one no
  longer marks this call ``[trusted]`` before that answer.

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
