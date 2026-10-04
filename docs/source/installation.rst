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

   caged [--ro DIR]... [--rw DIR]... -- llm-bridge <bridge-args>

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
