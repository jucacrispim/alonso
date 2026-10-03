# alonso

Emacs client for [llm-bridge](https://github.com/poraodojuca/llm-bridge) — a
long-running Go process that bridges the editor and the LLM over JSON lines
(stdin/stdout).  alonso starts the bridge as a subprocess, reads its events
asynchronously and displays the conversation in a dedicated buffer.  The bridge
executes the tool calls — read-only ones run inline and are just displayed;
mutating ones ask for the user's approval before running.

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

`C-c C-a` is the prefix for every command.  `C-c C-a l` (or `C-c C-a o`) starts the
client: it splits the frame in two, showing the conversation on top and the
input buffer below.  In the input buffer, `C-c C-c` sends the prompt (`RET`
inserts a newline).

A few of the key bindings:

| Key         | Command          | Description                          |
|-------------|------------------|--------------------------------------|
| `C-c C-a l` | `alonso-open`    | Start the client                     |
| `C-c C-a r` | `alonso-restart` | Restart the bridge and reopen        |
| `C-c C-a k` | `alonso-kill`    | Terminate the bridge and clean up    |
| `C-c C-a c` | `alonso-cancel`  | Cancel the current in-flight turn    |
| `C-c C-a q` | `alonso-quit`    | Send `quit` to the bridge and stop   |
| `C-c C-a w` | `alonso-toggle-show-thinking` | Toggle the thinking display (text or spinner placeholder) |

## Documentation

Full documentation is available at **https://docs.poraodojuca.dev/alonso/**.
