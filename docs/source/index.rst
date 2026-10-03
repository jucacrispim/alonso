alonso
======

**alonso** is an Emacs client for **llm-bridge**, a long-running Go process that
bridges the editor and an LLM over JSON lines (stdin/stdout).  The package
starts the bridge as a subprocess, reads its events asynchronously and displays
the conversation in a dedicated buffer.  The bridge executes the tool calls —
read-only ones run inline and are just displayed; mutating ones ask for the
user's approval before running.

Any provider/request-format difference (streaming, authentication, thinking
mode, reasoning effort, images) is handled by the bridge; alonso talks to it
once, in a single protocol, and renders the result in Emacs.

.. toctree::
   :maxdepth: 2

   installation
   usage

.. toctree::
   :maxdepth: 2

   hacking/index

Indices and tables
------------------

* :ref:`genindex`
* :ref:`modindex`
* :ref:`search`
