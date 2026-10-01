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
