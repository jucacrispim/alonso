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

Sandbox
-------

The bridge sandboxes **itself**; the client does not wrap it.  By default the
bridge re-executes itself under ``caged`` (a small Landlock + seccomp sandbox,
see the `caged documentation <https://docs.poraodojuca.dev/caged>`_) at
startup, and runs the external processes it spawns (the ``shell``/``grep``
tools and the hooks) under a stricter policy with no environment, no IPC and no
network.

``alonso-sandbox`` (default ``t``) controls it: ``nil`` passes
``-disable-sandbox`` and the bridge runs unconfined.  Either way ``caged`` has
to be installed and found on ``exec-path``, or its path passed through
``alonso-sandbox-args``.

Two lists tell the bridge where the files are:

- ``alonso-sandbox-rw-paths`` (default ``("~/mysrc")``), one ``-sandbox-rw``
  per directory: what the bridge and its tools may read and write.  The bridge
  grants no project directory on its own (its sandbox is frozen at startup
  while the project changes at runtime), so the projects root belongs here.
  Anything outside these paths is denied to the tools by the kernel
  (``EACCES``), which shows up as the tool failing, not as a sandbox error.
- ``alonso-sandbox-ro-paths`` (default ``nil``), one ``-sandbox-ro`` per
  directory: extra read-only paths such as ``~/.gitconfig``.  The bridge
  already grants the system trees (``/usr``, ``/lib``, ``/lib64``, ``/bin``,
  ``/etc``), ``/dev/urandom``, the knowledge-base assets
  (``~/.cache/llm-bridge``) and the global context and hooks
  (``~/.llm-bridge``).

``alonso-sandbox-args`` (default ``nil``) is passed verbatim to the bridge
after the paths, for sandbox flags that have no dedicated setting, e.g.
``("-caged-bin" "/opt/caged/bin/caged")``.

Every path has to exist when the bridge starts: its sandbox opens each one
while building the policy, and a missing path makes it fail at startup.

The environment is not filtered by the client any more: the bridge keeps its
own environment (the API key, the provider URL, the KB settings) and runs the
tools without it.  The only variable the client sets around the spawn is
``CAGED_DISABLE_WARNINGS=1``, which the bridge forwards to ``caged`` to keep
the ``warning: Landlock ABI N does not support some features`` line off stderr
(the client treats any stderr line as a launch failure).
