alonso
======

**alonso** is an AI coding assistant for Emacs. Ask a question about your
code, get help tracking down a test failure, or ask for an edit without
leaving your editor.

Features
--------

- **Chat in Emacs.** Read replies as they stream while keeping your prompt
  in a separate buffer.
- **Show what you're seeing.** Attach a screenshot, diagram, or other image
  when the selected model supports image inputs.
- **Work with your project.** Ask alonso to search files, suggest edits,
  or run your tests. Review file changes and shell commands before they run.
- **Run tools in a sandbox.** By default, ``caged`` limits what tools can access.
- **Switch models as you work.** Pick a provider and model from Emacs.
  Adjust reasoning settings without restarting the session.
- **Keep an eye on usage.** See how long each turn took and check the
  estimated cost when pricing is available.

After :doc:`installation`, open alonso with ``C-c C-a l`` and try:
“Where should I start reading this project?”

.. toctree::
   :maxdepth: 2

   installation
   usage

.. toctree::
   :maxdepth: 2

   hacking/index

.. toctree::
   :maxdepth: 2

   changelog

Indices and tables
------------------

* :ref:`genindex`
* :ref:`modindex`
* :ref:`search`
