# alonso

Emacs client for [llm-bridge](https://github.com/poraodojuca/llm-bridge), a
long-running Go process that bridges the editor and the LLM over JSON lines
(stdin/stdout).  alonso starts the bridge as a subprocess, reads its events
asynchronously and displays the conversation in a dedicated buffer.  The bridge
executes the tool calls: read-only ones run inline and are just displayed, and
mutating ones ask for your approval before running.

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

## Sandbox

The client does not wrap the bridge.  The bridge runs the tools itself, and
every tool it spawns is a [`caged`](https://docs.poraodojuca.dev/caged) child (a
small Landlock + seccomp sandbox) with its own policy: no environment, no IPC, a
private `/tmp` and `/dev/shm`, and a network namespace where only loopback is
up.

The client only says where the projects live:

```elisp
(setq alonso-sandbox-rw-paths '("~/mysrc"))
```

`alonso-sandbox` (default `t`) turns the sandbox on or off: `nil` passes
`-disable-sandbox` and the tools run unconfined.

The [installation chapter](https://docs.poraodojuca.dev/alonso/installation.html#sandbox)
covers the rest: `alonso-sandbox-ro-paths`, `alonso-sandbox-args`, the paths
the bridge already grants, and the flags it passes on to
[`caged`](https://docs.poraodojuca.dev/caged).

## Documentation

Full documentation is available at **https://docs.poraodojuca.dev/alonso/**.
