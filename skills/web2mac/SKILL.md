---
name: web2mac
description: Turn a local web dashboard or tool (Streamlit, Vite/Next, Flask/FastAPI, a plain index.html, anything that serves HTTP on localhost) into a real macOS .app with its own Dock icon and window. The app starts the local server, waits until it answers, shows it in a WKWebView, and kills the server when you quit. Use when the user wants to "make this a mac app", "wrap this dashboard in an app", "ponerlo en el Dock", "convertir esta herramienta local en una app de macOS", or stop running a server in a terminal by hand.
---

# web2mac

Wraps a local web tool in a native macOS app. The generated `.app` is a small Swift
`NSApplication` hosting a `WKWebView`. **It owns the server lifecycle**: it adopts a
server that is already up, otherwise spawns the configured command through a login
shell, waits until it answers HTTP, and stops it on quit — including after a Force
Quit or crash, via a watchdog, so no orphan is left holding the port.

Requirements: macOS 13+, Xcode command line tools (`xcrun swiftc`). Nothing else —
no npm, no Electron.

Scripts live next to this file in `scripts/`. Below, `$W2M` is that directory.

## Workflow

### 1. Find out how the tool starts
```sh
python3 $W2M/detect.py <project-dir>      # draft config on stdout, reasoning on stderr
```
It recognises Vite, Next, Astro, other `package.json` scripts, Streamlit, Gradio,
FastAPI, Flask, Django, plain Python HTTP servers and a bare `index.html`. It scans the
directory you pass (not subfolders): if the entry point is in `tools/`, pass that. If it
cannot tell, read the README and the entry point yourself. **Treat the result as a
candidate**, not an answer.

### 2. Write `web2mac.json` next to the project
Keys (all optional except `name`, and `command` / `static_dir` / `url` per mode):

| key | meaning |
|---|---|
| `name` | App and window name |
| `mode` | `command` (default), `static` (folder of HTML), `url` (just wrap a URL, no server) |
| `command` | List (quoted for you, becomes `exec …`) or a shell string. `{port}` is replaced at launch |
| `cwd` | Working dir, relative to the config file |
| `port` | Fixed port, or `0` to pick a free one on every launch (recommended unless the app hardcodes its port) |
| `path` / `ready_path` | Page to load / URL polled until the server answers (default `/`) |
| `env` | Extra environment; values may contain `{port}`. `PORT` and `W2M_PORT` are always set |
| `path_prepend` | Extra PATH entries (e.g. an nvm or venv `bin`) |
| `startup_timeout` | Seconds to wait for the server (default 20; raise for slow starters) |
| `icon` | `{"emoji":"📊"}`, `{"text":"SD"}` or `{"image":"logo.png"}`, plus `top`/`bottom` gradient hex colours; `"raw":true` uses an image as-is. Default: initials on a gradient derived from the name |
| `window` | `width`, `height`, `min_width`, `min_height` |
| `lang` | `en` (default) or `es` for the menus and dialogs |
| `bundle_id` | Default `dev.web2mac.<slug>`. Change it to your own domain |

### 3. Prove the command works *before* building
Run it exactly as the app will, from a login shell, on a spare port, and hit it:
```sh
cd <cwd> && PORT=8799 zsh -l -c 'exec <command with 8799>' &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8799/ ; kill %1
```
Most "the app opens blank" reports are a command that never listened on `{port}`.
If the tool ignores `PORT` and flags and hardcodes a port, put that number in `"port"`
and remove `{port}` from the command.

### 4. Build
```sh
python3 $W2M/make_app.py --config web2mac.json            # -> ~/Applications/<name>.app
python3 $W2M/make_app.py --config web2mac.json --dest ./build
python3 $W2M/make_app.py --name "My Dash" --static ./dist  # no config file needed
python3 $W2M/make_app.py --config web2mac.json --print-config
```
Re-running overwrites in place, so a Dock alias keeps working. Version the config, not
the `.app`.

### 5. Verify the lifecycle, don't assume it
```sh
open ~/Applications/<name>.app; sleep 4; cat ~/Library/Logs/<NameWithoutSpaces>.log
```
The log must show `started server (pid …)` and `page loaded in the window`. Then:
- `osascript -e 'quit app "<name>"'` → the port must be free afterwards.
- `kill -9` the app → the server must be gone within ~2 s.
- A server already running on a fixed port → the log says `adopted`, and quitting leaves it up.

### 6. Dock
Tell the user to drag the `.app` from `~/Applications` to the Dock (`open ~/Applications`).
macOS will not keep a bare script or `.command` file in the Dock, which is why this is a bundle.

## What the app gives the page for free
Native ⌘C/⌘V/⌘X/⌘A/⌘Z (a `WKWebView` has no Edit menu otherwise), ⌘R reload, ⌘[ ⌘],
zoom ⌘+ ⌘− ⌘0, ⇧⌘B open in the browser, **Show log**; downloads go to `~/Downloads` and
reveal in Finder; `<input type=file>` works; `alert()`/`confirm()` are shown natively;
`target=_blank` and external links open in the real browser; window size and position
persist.

If the page keeps its own undo stack, define `window.appUndo(redo)` returning `true` when
it handled the key: AppKit swallows ⌘Z before the page sees it, so the menu item asks the
page first and falls back to the native undo otherwise.

## When something is off
Read `reference/gotchas.md` — the PATH problem, why a script cannot be the executable,
what "adopted" means for stale servers, per-bundle `localStorage`, and testing notes.
The log is `~/Library/Logs/<Name>.log` (spaces removed).
