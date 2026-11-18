Installation
============

Requirements
------------

* Emacs 27.1 or newer.
* `transient <https://github.com/magit/transient>`_ (for the tool-confirmation
  menus).  When it is missing, alonso falls back to ``read-char-choice``.

Installing the package
----------------------

Install `llm-bridge <https://docs.poraodojuca.dev/llm-bridge/>`_ and make sure
its binary is on your ``PATH``. To use a different command, set
``alonso-command``.

Clone the repository and put it on the load path, then require it::

   (add-to-list 'load-path "/path/to/alonso")
   (require 'alonso)

``(require 'alonso)`` pulls in the whole package: the client protocol
(``alonso-client.el``), the UI shell (``alonso-ui.el``) and the rendering
pieces (``alonso-markdown.el``, ``alonso-image.el``, ``alonso-tools.el``).

Sandbox
-------

The client does not wrap the bridge.  The bridge runs the tools itself, and
every tool it spawns is a ``caged`` child (a small Landlock + seccomp sandbox,
see the `caged documentation <https://docs.poraodojuca.dev/caged>`_) with its
own policy: no environment, no IPC, a private ``/tmp`` and ``/dev/shm``, and a
network namespace where only loopback is up.

``alonso-sandbox`` (default ``t``) controls it: ``nil`` passes
``-disable-sandbox`` and the tools run unconfined.  Either way ``caged`` has
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
  (``~/.cache/llm-bridge``, read-only) and ``~/.llm-bridge`` (read-write, and
  created at startup).

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
