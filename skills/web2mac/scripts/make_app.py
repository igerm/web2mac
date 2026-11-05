#!/usr/bin/env python3
"""Build a macOS .app that wraps a local web tool in a native window.

    make_app.py --config web2mac.json [--dest DIR] [--port N]
    make_app.py --name "My Dash" --command "python3 app.py --port {port}" --cwd .
    make_app.py --name "My Site" --static ./dist
    make_app.py --name "Docs" --url https://example.com

The app starts the server, waits until it answers, shows it in a WKWebView and
stops it on quit. See SKILL.md for the config keys. The bundle is a build
artifact: version the config, not the .app.

Needs Xcode command line tools (`xcrun swiftc`, `sips`, `iconutil`, `codesign`).
"""

import argparse
import colorsys
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER_SRC = os.path.join(HERE, "launcher.swift")
ICON_SRC = os.path.join(HERE, "render_icon.swift")

DEFAULTS = {
    "mode": "command",
    "port": 8765,
    "path": "/",
    "startup_timeout": 20,
    "lang": "en",
    "window": {"width": 1280, "height": 820, "min_width": 800, "min_height": 520},
}


def die(msg):
    sys.exit(f"make_app: {msg}")


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "app"


# ------------------------------------------------------------------ config ---

def load_config(args):
    cfg = {}
    base = os.getcwd()
    if args.config:
        path = os.path.abspath(args.config)
        with open(path) as f:
            cfg = json.load(f)
        base = os.path.dirname(path)
    # Flags override the file.
    for key in ("name", "bundle_id", "cwd", "lang", "path"):
        if getattr(args, key, None) is not None:
            cfg[key] = getattr(args, key)
    if args.command:
        cfg["command"] = args.command
    if args.static:
        cfg["mode"], cfg["static_dir"] = "static", args.static
    if args.url:
        cfg["mode"], cfg["url"] = "url", args.url
    if args.port is not None:
        cfg["port"] = args.port

    merged = {**DEFAULTS, **cfg}
    merged["window"] = {**DEFAULTS["window"], **cfg.get("window", {})}
    if not merged.get("name"):
        die("a name is required (--name or \"name\" in the config)")

    def resolve(p):
        return os.path.abspath(os.path.join(base, os.path.expanduser(p)))

    mode = merged["mode"]
    if mode not in ("command", "static", "url"):
        die(f"unknown mode {mode!r} (command | static | url)")

    if mode == "url":
        if not merged.get("url"):
            die('mode "url" needs "url"')
        merged["cwd"] = base
        merged["command_shell"] = ""
    elif mode == "static":
        folder = resolve(merged.get("static_dir", "."))
        if not os.path.isdir(folder):
            die(f"static_dir not found: {folder}")
        merged["cwd"] = folder
        merged["command_shell"] = (
            "exec /usr/bin/python3 -m http.server {port} --bind 127.0.0.1")
    else:
        command = merged.get("command")
        if not command:
            die('mode "command" needs "command"')
        merged["cwd"] = resolve(merged.get("cwd", "."))
        if not os.path.isdir(merged["cwd"]):
            die(f"cwd not found: {merged['cwd']}")
        if isinstance(command, list):
            # `exec` so the shell becomes the server: the pid the app tracks (and
            # kills) is the server's own, not a wrapper's.
            # Quoting {port} is harmless: the launcher substitutes it inside.
            merged["command_shell"] = "exec " + " ".join(shlex.quote(p) for p in command)
        else:
            merged["command_shell"] = command  # a shell string, used verbatim

    merged["bundle_id"] = merged.get("bundle_id") or f"dev.web2mac.{slug(merged['name'])}"
    return merged


def default_icon(name):
    """Initials on a gradient whose hue comes from the name, so apps differ."""
    words = [w for w in re.split(r"[\s_-]+", name) if w]
    initials = "".join(w[0] for w in words[:2]).upper() or name[:1].upper()
    hue = int(hashlib.md5(name.encode()).hexdigest()[:4], 16) / 0xFFFF

    def hexcol(s, v):
        r, g, b = colorsys.hsv_to_rgb(hue, s, v)
        return "#%02X%02X%02X" % (round(r * 255), round(g * 255), round(b * 255))

    return {"text": initials, "top": hexcol(0.55, 0.78), "bottom": hexcol(0.75, 0.42)}


# --------------------------------------------------------------------- build ---

def compile_swift(src, out):
    if not os.path.isfile(src):
        die(f"missing {src}")
    p = subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "5",
                        "-o", out, src], capture_output=True, text=True)
    if p.returncode != 0:
        die("swiftc failed (is Xcode / the command line tools installed?):\n"
            + (p.stderr or p.stdout))


def build_icns(icon, base, dest):
    icon = {**default_icon("App"), **icon}
    with tempfile.TemporaryDirectory() as tmp:
        tool = os.path.join(tmp, "render_icon")
        compile_swift(ICON_SRC, tool)
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        master = os.path.join(iconset, "icon_512x512@2x.png")
        cmd = [tool, "--out", master, "--top", icon["top"], "--bottom", icon["bottom"]]
        if icon.get("image"):
            image = os.path.abspath(os.path.join(base, os.path.expanduser(icon["image"])))
            if not os.path.isfile(image):
                die(f"icon image not found: {image}")
            cmd += ["--image", image]
            if icon.get("raw"):
                cmd += ["--raw"]
        elif icon.get("emoji"):
            cmd += ["--emoji", icon["emoji"]]
        else:
            cmd += ["--text", icon.get("text", "?")]
        if icon.get("fg"):
            cmd += ["--fg", icon["fg"]]
        subprocess.run(cmd, check=True)
        for name, px in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                         ("icon_32x32", 32), ("icon_32x32@2x", 64),
                         ("icon_128x128", 128), ("icon_128x128@2x", 256),
                         ("icon_256x256", 256), ("icon_256x256@2x", 512),
                         ("icon_512x512", 512)]:
            subprocess.run(["/usr/bin/sips", "-z", str(px), str(px), master,
                            "--out", os.path.join(iconset, name + ".png")],
                           check=True, capture_output=True)
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", iconset, "-o", dest],
                       check=True, capture_output=True)


def build(cfg, base, dest_dir):
    name = cfg["name"]
    app = os.path.join(dest_dir, name + ".app")
    contents = os.path.join(app, "Contents")
    macos = os.path.join(contents, "MacOS")
    res = os.path.join(contents, "Resources")
    if os.path.isdir(app):
        shutil.rmtree(app)
    os.makedirs(macos)
    os.makedirs(res)

    exe = slug(name)
    compile_swift(LAUNCHER_SRC, os.path.join(macos, exe))

    info = {
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleIdentifier": cfg["bundle_id"],
        "CFBundleExecutable": exe,
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": cfg.get("version", "1.0"),
        "CFBundleVersion": "1",
        "CFBundleInfoDictionaryVersion": "6.0",
        "NSPrincipalClass": "NSApplication",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": False,
        "NSHighResolutionCapable": True,
        # Loopback is exempt from ATS; a remote http page needs the wide switch.
        "NSAppTransportSecurity": (
            {"NSAllowsArbitraryLoads": True} if cfg["mode"] == "url"
            else {"NSAllowsLocalNetworking": True}),
        # One key holds everything the launcher needs, so a bundle can be
        # repointed by editing the plist instead of recompiling.
        "W2MConfig": json.dumps({k: cfg.get(k) for k in (
            "name", "mode", "command_shell", "cwd", "port", "path", "ready_path",
            "url", "env", "path_prepend", "startup_timeout", "lang", "window")
            if cfg.get(k) is not None}),
    }
    with open(os.path.join(contents, "Info.plist"), "wb") as f:
        plistlib.dump(info, f)

    icon = cfg.get("icon") or default_icon(name)
    build_icns(icon, base, os.path.join(res, "AppIcon.icns"))

    # Ad-hoc signature: unsigned bundles get re-prompted by Gatekeeper and can lose
    # their icon after an edit. Best effort. (Sharing the app with other people
    # needs a Developer ID signature and notarization — out of scope here.)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", app],
                   capture_output=True)
    subprocess.run(["/usr/bin/touch", app], capture_output=True)
    return app


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", help="path to a web2mac.json")
    ap.add_argument("--dest", default="~/Applications",
                    help="where to write the bundle (default ~/Applications)")
    ap.add_argument("--name")
    ap.add_argument("--bundle-id", dest="bundle_id")
    ap.add_argument("--command", help="shell command that serves the tool; use {port}")
    ap.add_argument("--cwd")
    ap.add_argument("--static", metavar="DIR", help="serve a folder of static files")
    ap.add_argument("--url", help="just wrap a URL (no server to manage)")
    ap.add_argument("--port", type=int,
                    help="fixed port; 0 picks a free one on every launch")
    ap.add_argument("--path")
    ap.add_argument("--lang", choices=["en", "es"])
    ap.add_argument("--print-config", action="store_true",
                    help="show the resolved config and exit")
    args = ap.parse_args()

    cfg = load_config(args)
    base = os.path.dirname(os.path.abspath(args.config)) if args.config else os.getcwd()
    if args.print_config:
        print(json.dumps(cfg, indent=2, ensure_ascii=False))
        return 0

    dest = os.path.expanduser(args.dest)
    os.makedirs(dest, exist_ok=True)
    app = build(cfg, base, dest)
    safe = "".join(c for c in cfg["name"] if c.isalnum()) or "web2mac"
    print(f"built : {app}")
    print(f"mode  : {cfg['mode']}   port: {cfg['port']}")
    if cfg["mode"] != "url":
        print(f"run   : {cfg['command_shell']}   (cwd {cfg['cwd']})")
    print(f"log   : ~/Library/Logs/{safe}.log")
    print(f"open  : open {shlex.quote(app)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
