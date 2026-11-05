#!/usr/bin/env python3
"""Guess how a local web tool is started and print a draft web2mac.json.

    detect.py [PROJECT_DIR]            # prints a JSON config to stdout

It is a heuristic, not an oracle: it reads package.json, Python entry points and
index.html, and the result is a *candidate*. Always run the proposed command
yourself and curl the port before building the app (SKILL.md, step 3).
"""

import json
import os
import re
import sys


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def node_candidate(root, pkg):
    scripts = pkg.get("scripts", {})
    deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
    script = next((s for s in ("dev", "start", "serve", "preview") if s in scripts), None)
    if not script:
        return None
    runner = "pnpm" if os.path.exists(os.path.join(root, "pnpm-lock.yaml")) else \
             "yarn" if os.path.exists(os.path.join(root, "yarn.lock")) else "npm"
    run = [runner, "run", script] if runner != "yarn" else ["yarn", script]
    # Each framework takes the port its own way; PORT env covers CRA/Express/most.
    if "vite" in deps or "vite" in scripts[script]:
        cmd = run + ["--", "--port", "{port}", "--strictPort", "--host", "127.0.0.1"]
        why = "Vite (port via flags)"
    elif "next" in deps:
        cmd = run + ["--", "-p", "{port}"]
        why = "Next.js"
    elif "astro" in deps:
        cmd = run + ["--", "--port", "{port}"]
        why = "Astro"
    else:
        cmd = run
        why = "Node script; relies on the PORT env var the app sets — verify it listens there"
    return cmd, {"PORT": "{port}", "BROWSER": "none"}, why


def python_candidate(root):
    files = [f for f in os.listdir(root) if f.endswith(".py")]
    reqs = read(os.path.join(root, "requirements.txt")).lower() + \
        read(os.path.join(root, "pyproject.toml")).lower()
    sources = {f: read(os.path.join(root, f)) for f in files[:40]}
    for f, src in sources.items():
        if re.search(r"^\s*(import|from)\s+streamlit", src, re.M):
            return (["streamlit", "run", f, "--server.port", "{port}",
                     "--server.headless", "true", "--browser.gatherUsageStats", "false"],
                    {}, "Streamlit")
    for f, src in sources.items():
        if re.search(r"gradio", src):
            return (["python3", f], {"GRADIO_SERVER_PORT": "{port}",
                                     "GRADIO_SERVER_NAME": "127.0.0.1"}, "Gradio")
    for f, src in sources.items():
        m = re.search(r"^\s*(\w+)\s*=\s*FastAPI\(", src, re.M)
        if m:
            return (["uvicorn", f"{f[:-3]}:{m.group(1)}", "--port", "{port}",
                     "--host", "127.0.0.1"], {}, "FastAPI/uvicorn")
    for f, src in sources.items():
        if re.search(r"^\s*(\w+)\s*=\s*Flask\(", src, re.M):
            return (["flask", "--app", f[:-3], "run", "--port", "{port}",
                     "--host", "127.0.0.1"], {}, "Flask")
    if os.path.exists(os.path.join(root, "manage.py")):
        return (["python3", "manage.py", "runserver", "127.0.0.1:{port}", "--noreload"],
                {}, "Django")
    # A plain script that serves HTTP: look for a port argument or constant.
    for f, src in sources.items():
        if "http.server" in src or "HTTPServer" in src or "socketserver" in src:
            if re.search(r"add_argument\(['\"]--port", src):
                return (["python3", f, "--port", "{port}"], {}, f"{f}: argparse --port")
            if re.search(r"environ.*(PORT)", src):
                return (["python3", f], {"PORT": "{port}"}, f"{f}: reads PORT")
            return (["python3", f], {"PORT": "{port}"},
                    f"{f}: serves HTTP but no port option found — it may hardcode the port; "
                    "set \"port\" to that number and drop {port} instead")
    return None


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")
    name = os.path.basename(root).replace("-", " ").replace("_", " ").title()
    cfg = {"name": name, "cwd": ".", "port": 0}
    notes = []

    pkg_path = os.path.join(root, "package.json")
    found = None
    if os.path.exists(pkg_path):
        try:
            found = node_candidate(root, json.loads(read(pkg_path)))
        except json.JSONDecodeError:
            notes.append("package.json is not valid JSON")
    if not found:
        found = python_candidate(root)

    if found:
        cmd, env, why = found
        cfg["mode"], cfg["command"] = "command", cmd
        if env:
            cfg["env"] = env
        notes.append(why)
    elif os.path.exists(os.path.join(root, "index.html")):
        cfg.update({"mode": "static", "static_dir": "."})
        notes.append("index.html with no server entry point: serve it as static files")
    else:
        notes.append("could not tell how this starts — read the README / package scripts")
        cfg["command"] = ["REPLACE-ME", "--port", "{port}"]

    cfg["icon"] = {"text": "".join(w[0] for w in name.split()[:2]).upper() or "W"}
    print(json.dumps(cfg, indent=2, ensure_ascii=False))
    for n in notes:
        print(f"# detected: {n}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
