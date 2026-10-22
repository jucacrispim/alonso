Installation
============

Requirements
------------

* Emacs 27.1 or newer.
* `transient <https://github.com/magit/transient>`_ (for the tool-confirmation
  menus).  When it is missing, alonso falls back to ``read-char-choice``.
* A working **llm-bridge** binary on ``PATH`` (see the
  `llm-bridge docs <https://docs.poraodojuca.dev/llm-bridge/>`_).  The command
  can be customised through the ``alonso-command`` defcustom.

Installing the package
----------------------

Clone the repository and put it on the load path, then require it::

   (add-to-list 'load-path "/path/to/alonso")
   (require 'alonso)

``(require 'alonso)`` pulls in the whole package: the client protocol
(``alonso-client.el``), the UI shell (``alonso-ui.el``) and the rendering
pieces (``alonso-markdown.el``, ``alonso-image.el``, ``alonso-tools.el``).

Optional sandbox
----------------

The bridge subprocess can optionally be wrapped in a sandbox launcher, such as
``caged`` (a small Landlock-based process sandbox, see the *alonso-cage*
project).  Set ``alonso-sandbox-command`` to the launcher and the bridge is
started as::

   caged [--ro DIR]... [--rw DIR]... [EXTRA-ARGS]... [--env NAME=VALUE]... -- llm-bridge <bridge-args>

The read-only and read-write directories come from ``alonso-sandbox-ro-paths``
(default ``/usr``, ``/bin``, ``/lib``, ``/etc``) and
``alonso-sandbox-rw-paths`` (default ``~/.cache/llm-bridge``,
``~/.llm-bridge``, ``~/.local/share/llm-bridge``, ``/dev/null``,
``/dev/urandom``).  Two extra lists, ``alonso-sandbox-extra-ro-paths`` and
``alonso-sandbox-extra-rw-paths`` (both empty by default), are appended to
those, so you can grant more paths from your init file without redefining the
base lists.  The
directories holding the
bridge and the sandbox binaries are added as ``--ro`` automatically, so the
sandbox can ``exec`` them wherever they are installed (e.g. a bridge under
``~/.local/bin``).  When ``alonso-logfile`` is set, the directory holding the
log file is added as ``--rw`` automatically, so the bridge can create/write it.
Two ``/dev`` devices are in the default read-write list: ``/dev/null``, because
the bridge lets the Go runtime open it for the stdin of the tools it spawns
(``shell``, ``grep``); and ``/dev/urandom``, because spawned tools that create
temporary files or tokens (e.g. ``git`` via ``mkstemp``, TLS) read random bytes
from it.  Without either one the tool fails with ``permission denied`` or
``unable to get random bytes``.
The sandbox is **off by default**
(``alonso-sandbox-command`` is empty): the bridge is started directly unless
you configure it.

Three settings cover the extra layers of ``caged`` 0.2.0, which governs
network, environment and rlimits on top of the filesystem:

- ``alonso-sandbox-extra-args`` (default ``--allow-network-sockets
  --allow-connect-port 443``) is emitted verbatim after the paths.  Without
  ``--allow-network-sockets`` the bridge cannot even resolve DNS (the resolver
  opens a netlink socket, and ``socket`` fails with EACCES); without the port
  rule Landlock blocks the provider's HTTPS connection.  Add one
  ``--allow-connect-port`` per extra port (a proxy, a local server).  Set it
  to ``nil`` for a launcher that does not understand these flags.
- ``alonso-sandbox-env-vars`` is a list of variable *names* passed through as
  ``--env NAME=VALUE``, only for the ones that are set when the bridge is
  launched.  The default is the set the bridge reads (``DEEPSEEK_API_KEY``,
  ``GOOGLE_*``/``GEMINI_*``, the ``URL``/``MODEL`` overrides,
  ``KNOWLEDGE_BASE``, ``LLM_BRIDGE_KB_*``,
  ``LLM_BRIDGE_ONNXRUNTIME_LIB``, ``LLM_BRIDGE_PATH``, ``NO_COLOR``).
  ``caged`` 0.2.0 wipes the child environment by default (only ``PATH``,
  ``HOME``, ``LANG``, ``LANGUAGE`` and the ``LC_*`` variables survive), so the
  API key and the rest must be named here.  Passing variables one by one,
  instead of ``--keep-env``, keeps the rest of the cleanup: ``SSH_AUTH_SOCK``,
  ``DISPLAY``, ``XAUTHORITY`` and ``DBUS_*`` stay out of the sandbox.
- ``alonso-sandbox-launcher-env`` (an alist, default
  ``(("CAGED_DISABLE_WARNINGS" . "1"))``) sets variables in the *launcher's*
  own environment around the spawn, restoring them afterwards.  It silences
  ``caged``'s ``warning: Landlock ABI 6 does not support some features``,
  which otherwise shows up on stderr and is reported as a launch failure.  It
  cannot go through ``--env``: the launcher reads it before building the
  child's environment.
