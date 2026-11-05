# Gotchas

Each of these cost real time the first time. They are why the launcher looks the way it does.

## The executable must be a real app, not a script
macOS launches a bundle's executable as a foreground app and waits for it to register
with the window server. A shell script never does, so the Dock icon **bounces until
macOS declares the app "not responding"** even though the server behind it is healthy.
That is why web2mac compiles a Swift `NSApplication` instead of shipping a launcher script.

## A GUI app does not see your PATH
launchd starts apps with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. pyenv shims, nvm, Homebrew
and virtualenvs are invisible, and a bare `python3` resolves to `/usr/bin/python3`, which
may lack your packages. The failure is nasty because the window opens and the UI loads;
only the part that shells out breaks. web2mac runs the command through `zsh -l -c`
(which reads `~/.zprofile`) and prepends `/opt/homebrew/bin` and `/usr/local/bin`.
Limits: tools installed from `~/.zshrc` only (nvm is the usual one) are not loaded by a
non-interactive login shell — put their `bin` directory in `"path_prepend"`.
Exit code 127 in the log means command-not-found.

## "Adopted" servers and stale processes
If something already answers on a fixed port, the app adopts it and **never kills it** on
quit — closing a window must not take down a server you started in a terminal. The flip
side: a leftover server from days ago is adopted too, so after changing server code you
can be looking at the old process. Check its age:
`ps -o lstart=,command= -p $(lsof -ti tcp:<port>)`. Using `"port": 0` avoids all of this:
every launch gets a fresh server on a free port.
(`ps` can also lie about the port in a command line — probe it with `curl`.)

## Force Quit and crashes skip the clean shutdown
`applicationWillTerminate` does not run on Force Quit, a crash or a logout. The launcher
therefore starts a small `sh` watchdog that polls the app's pid and kills the server (and
its children) once the app is gone. The server needs no special support.

## `exec` matters
A list-form `command` becomes `exec <cmd>` so the login shell *becomes* the server and the
tracked pid is the server's. A shell-string command (with `&&`, pipes, `cd`) is run
verbatim: the pid is then the shell, and the launcher also signals its children
(`pkill -P`), which covers `npm run dev` spawning node.

## `localStorage`, cookies and sign-ins are per bundle id
The web view's store belongs to the bundle identifier, so the first launch starts empty
and a second bundle on another port (different bundle id) does not share state with the
first. Anything saved in `localStorage` in your browser is not in the app.

## Dialogs, files, downloads
A `WKWebView` that ignores the UI-delegate callbacks silently swallows `alert()`,
`confirm()` and `<input type=file>`; downloads need a `WKDownload` delegate or nothing
happens. All four are handled. `window.open` / `target=_blank` open in the default browser.

## ⌘Z never reaches the page
Menu key equivalents are consumed by AppKit before the web view sees the key. If your
tool has its own undo stack, expose `window.appUndo(redo)`; the Undo menu item calls it and
falls back to the native undo when it returns false (e.g. while typing in a field).

## Testing from a headless browser
`document.hidden` is true in background/hidden panes, so pollers guarded by it never run,
and `scroll` events are not dispatched until a render happens. A page that "doesn't
auto-refresh" under test may be fine in the app.

## Port and bind address
Bind to `127.0.0.1`, not `0.0.0.0`: the app only talks to loopback, and a dashboard with
edit endpoints should not be reachable from the network. ATS is configured to allow local
networking only (wide open only in `url` mode).

## Sharing the app
The bundle is ad-hoc signed, which is enough to run on the Mac that built it. Giving it to
someone else means a Developer ID signature and notarization; unsigned downloads are
blocked by Gatekeeper. Not covered here. The app also depends on the target machine having
the runtime (Python, Node…) the command needs — nothing is bundled.
