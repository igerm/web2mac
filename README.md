# web2mac

Turn a local web dashboard or tool — Streamlit, Vite, Flask, FastAPI, a plain `index.html`,
anything that serves HTTP on localhost — into a real macOS app with its own Dock icon and
window.

The app **manages the server for you**: it starts it, waits until it answers, shows it in a
native window, and stops it when you quit. Force-quit or crash and a watchdog still cleans
up, so nothing is left holding your port.

No Electron, no npm. The generated app is a ~100 KB Swift binary hosting a `WKWebView`.

## Install as a Claude Code skill

```sh
git clone https://github.com/<you>/web2mac.git
cp -R web2mac/skills/web2mac ~/.claude/skills/
```

Then ask Claude: *"turn this dashboard into a Mac app"*. The skill detects how the tool
starts, writes a config, proves the command works, builds the app and verifies the
lifecycle.

## Use it without Claude

```sh
# a folder of static files
python3 skills/web2mac/scripts/make_app.py --name "My Site" --static ./dist

# anything with a server ({port} is substituted at launch)
python3 skills/web2mac/scripts/make_app.py --name "Sales" \
  --command "streamlit run app.py --server.port {port} --server.headless true" \
  --cwd ~/code/sales --port 0

# or from a config file
python3 skills/web2mac/scripts/detect.py ~/code/sales > web2mac.json   # draft, review it
python3 skills/web2mac/scripts/make_app.py --config web2mac.json
```

The app lands in `~/Applications`; drag it to the Dock. See
[`skills/web2mac/SKILL.md`](skills/web2mac/SKILL.md) for every config key and
[`examples/`](examples) for ready-made configs.

## How the lifecycle works

| Moment | What happens |
|---|---|
| Launch | A server already answering on the fixed port is **adopted** (and never killed). Otherwise the command runs through `zsh -l -c`, with `PORT`/`{port}` set. `port: 0` picks a free port each time |
| Starting | Splash screen; polls until any HTTP answer, up to `startup_timeout`. If the process dies first you get a dialog with its exit code and a button for the log |
| Quit / last window closed | SIGTERM to the server and its children, SIGKILL after 3 s |
| Force Quit, crash, logout | A tiny `sh` watchdog sees the app is gone and kills the server |

Log: `~/Library/Logs/<Name>.log`.

## Extras the window gives you

Working ⌘C/⌘V/⌘X/⌘A/⌘Z, reload, back/forward, zoom, open in browser; file downloads to
`~/Downloads`; file pickers; native `alert`/`confirm`; external links open in your browser;
window size and position are remembered. Pages can implement `window.appUndo(redo)` to take
over ⌘Z.

## Requirements and limits

- macOS 13+ and the Xcode command line tools (`xcode-select --install`).
- The target machine needs the runtime your command uses; nothing is bundled.
- The bundle is ad-hoc signed: fine on the Mac that built it. Distributing it to others
  requires Developer ID signing and notarization, which this does not do.
- Only loopback is loaded in-app; other hosts open in the default browser.

More in [`skills/web2mac/reference/gotchas.md`](skills/web2mac/reference/gotchas.md).

## License

MIT
