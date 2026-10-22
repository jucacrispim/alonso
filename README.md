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

## Sandbox

Optionally, the bridge subprocess can be wrapped in a sandbox launcher such as
[`caged`](https://github.com/poraodojuca/alonso-cage) (a small Landlock-based
process sandbox).  Set `alonso-sandbox-command` to the launcher and it will be
run as:

```
caged [--ro DIR]... [--rw DIR]... [EXTRA-ARGS]... [--env NAME=VALUE]... -- llm-bridge <bridge-args>
```

The read-only and read-write directories come from `alonso-sandbox-ro-paths`
(default: `/usr`, `/bin`, `/lib`, `/etc`) and `alonso-sandbox-rw-paths`
(default: `~/.cache/llm-bridge`, `~/.llm-bridge`,
`~/.local/share/llm-bridge`, `/dev/null`, `/dev/urandom`).  Two extra lists,
`alonso-sandbox-extra-ro-paths` and `alonso-sandbox-extra-rw-paths` (both empty
by default), are appended to those, so you can grant more paths from your init
file without redefining the base lists.  The directories holding the bridge and the
sandbox binaries are added as `--ro` automatically, so the sandbox can `exec`
them wherever they are installed (e.g. a bridge under `~/.local/bin`).  When
`alonso-logfile` is set, the directory holding the log file is added as `--rw`
automatically (the bridge cannot otherwise create/write the log).  Two `/dev`
devices are in the read-write list: `/dev/null`, because the bridge lets the Go
runtime open it for the stdin of the tools it spawns (`shell`, `grep`); and
`/dev/urandom`, because spawned tools that create temporary files or tokens
(e.g. `git` via `mkstemp`, TLS) read random bytes from it — without either one
the tool fails with `permission denied` or `unable to get random bytes`.  The sandbox
is **off by default** (`alonso-sandbox-command` is empty), so the bridge is
started directly unless you configure it.

Three more settings cover the extra layers of `caged` 0.2.0 (which governs
network, environment and rlimits on top of the filesystem):

`alonso-sandbox-extra-args` (default `--allow-network-sockets
--allow-connect-port 443`) is emitted verbatim after the paths.  Without the
socket family the bridge cannot even do DNS (the resolver opens a netlink
socket), and without the port rule Landlock blocks the provider's HTTPS
connection.  Add a `--allow-connect-port` for each extra port (a proxy, a
local server); for another launcher set the list to `nil`.

`alonso-sandbox-env-vars` is a list of variable *names* passed as
`--env NAME=VALUE`, only for the ones actually set when the bridge is
launched.  Its default is the set the bridge reads (`DEEPSEEK_API_KEY`,
`GOOGLE_*`/`GEMINI_*`, the `*_URL`/`*_MODEL` overrides, `KNOWLEDGE_BASE`,
`LLM_BRIDGE_KB_*`, `LLM_BRIDGE_ONNXRUNTIME_LIB`, `LLM_BRIDGE_PATH`,
`NO_COLOR`).  This is needed because `caged` 0.2.0 wipes the child
environment by default; passing the variables one by one (rather than
`--keep-env`) keeps `SSH_AUTH_SOCK`, `DISPLAY`, `DBUS_*` and friends out.

`alonso-sandbox-launcher-env` (default `CAGED_DISABLE_WARNINGS=1`) sets
variables in the *launcher's* environment around the spawn.  It silences
`caged`'s "Landlock ABI 6 does not support some features" warning, which
otherwise arrives on stderr and is reported as a launch failure.

## Documentation

Full documentation is available at **https://docs.poraodojuca.dev/alonso/**.
