# alonso

Emacs client for [llm-bridge](https://github.com/poraodojuca/llm-bridge) — a
long-running Go process that bridges the editor and the LLM over JSON lines
(stdin/stdout).  alonso starts the bridge as a subprocess, reads its events
asynchronously, displays the conversation in a dedicated buffer and executes
the tools locally.

## Requirements

* Emacs 27.1 or newer.
* [transient](https://github.com/magit/transient) (for the tool-confirmation
  menus).  When it is missing, alonso falls back to `read-char-choice`.
* A working **llm-bridge** binary on `PATH`.  The command can be customised
  through the `alonso-command` defcustom.

## Installation

Clone the repository and put it on the load path, then require it:

```elisp
(add-to-list 'load-path "/path/to/alonso")
(require 'alonso)
```

## Usage

`C-c a` is the prefix for every command.  `C-c a l` (or `C-c a o`) starts the
client: it splits the frame in two, showing the conversation on top and the
input buffer below.  In the input buffer, `C-c C-c` sends the prompt (`RET`
inserts a newline).

A few of the key bindings:

| Key       | Command          | Description                          |
|-----------|------------------|--------------------------------------|
| `C-c a l` | `alonso-open`    | Start the client                     |
| `C-c a r` | `alonso-restart` | Restart the bridge and reopen        |
| `C-c a k` | `alonso-kill`    | Terminate the bridge and clean up    |
| `C-c a c` | `alonso-cancel`  | Cancel the current in-flight turn    |
| `C-c a q` | `alonso-quit`    | Send `quit` to the bridge and stop   |

## Documentation

Full documentation is available at **https://docs.poraodojuca.dev/alonso/**.
