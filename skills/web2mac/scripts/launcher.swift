// web2mac launcher — a native window around a local web tool.
//
// Compiled by make_app.py with `xcrun swiftc`. Everything app-specific travels
// in Info.plist under the single key `W2MConfig` (a JSON string), so the same
// source builds any app and pointing a bundle at another command or port is a
// plist edit, not a recompile.
//
// The app owns the server's whole lifecycle:
//   start   - adopt a server already answering on the port, otherwise spawn the
//             configured command through a login shell and wait until it answers
//   quit    - SIGTERM the server (and its children), SIGKILL after a grace period
//   crash   - a tiny sh watchdog notices the app is gone and kills the server, for
//             the exits that never reach applicationWillTerminate (Force Quit,
//             crash, logout). The server itself needs no cooperation.
//
// A server the app adopted is never killed: quitting must not take down a
// session this app did not start.

import AppKit
import WebKit
import Darwin

// MARK: - Configuration

struct Config {
    let name: String
    let mode: String              // "command" | "url"
    let command: String           // shell string; may contain {port}
    let cwd: String
    let configuredPort: Int       // 0 = pick a free one
    let path: String
    let readyPath: String
    let remoteURL: String
    let env: [String: String]
    let pathPrepend: [String]
    let startupTimeout: Double
    let lang: String
    let width: Double, height: Double, minWidth: Double, minHeight: Double
    let logURL: URL
    let autosave: String

    init() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "W2MConfig") as? String ?? "{}"
        let j = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
            as? [String: Any] ?? [:]
        func num(_ v: Any?, _ d: Double) -> Double { (v as? NSNumber)?.doubleValue ?? d }
        let win = j["window"] as? [String: Any] ?? [:]
        name = j["name"] as? String ?? "App"
        mode = j["mode"] as? String ?? "command"
        command = j["command_shell"] as? String ?? ""
        cwd = j["cwd"] as? String ?? NSHomeDirectory()
        configuredPort = Int(num(j["port"], 0))
        path = j["path"] as? String ?? "/"
        readyPath = j["ready_path"] as? String ?? (j["path"] as? String ?? "/")
        remoteURL = j["url"] as? String ?? ""
        env = j["env"] as? [String: String] ?? [:]
        pathPrepend = j["path_prepend"] as? [String] ?? []
        startupTimeout = num(j["startup_timeout"], 20)
        lang = j["lang"] as? String ?? "en"
        width = num(win["width"], 1280); height = num(win["height"], 820)
        minWidth = num(win["min_width"], 800); minHeight = num(win["min_height"], 520)
        let safe = name.filter { $0.isLetter || $0.isNumber }
        logURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/\(safe.isEmpty ? "web2mac" : safe).log")
        autosave = "W2M-" + (Bundle.main.bundleIdentifier ?? name)
    }
}

let config = Config()

/// Resolved at start: the configured port, or a free one when it is 0.
var activePort = config.configuredPort

func pageURL(_ path: String) -> URL? {
    if config.mode == "url" { return URL(string: config.remoteURL) }
    return URL(string: "http://127.0.0.1:\(activePort)\(path)")
}

// MARK: - Strings

struct L {
    let es = config.lang == "es"
    var starting: String { es ? "Levantando \(config.name)…" : "Starting \(config.name)…" }
    var failTitle: String { es ? "No pude abrir \(config.name)" : "Could not open \(config.name)" }
    var showLog: String { es ? "Ver el log" : "Show log" }
    var quit: String { es ? "Salir" : "Quit" }
    var cancel: String { es ? "Cancelar" : "Cancel" }
    var about: String { es ? "Acerca de \(config.name)" : "About \(config.name)" }
    var hide: String { es ? "Ocultar" : "Hide" }
    var edit: String { es ? "Edición" : "Edit" }
    var undo: String { es ? "Deshacer" : "Undo" }
    var redo: String { es ? "Rehacer" : "Redo" }
    var cut: String { es ? "Cortar" : "Cut" }
    var copy: String { es ? "Copiar" : "Copy" }
    var paste: String { es ? "Pegar" : "Paste" }
    var selectAll: String { es ? "Seleccionar todo" : "Select All" }
    var view: String { es ? "Visualización" : "View" }
    var reload: String { es ? "Recargar" : "Reload" }
    var back: String { es ? "Atrás" : "Back" }
    var forward: String { es ? "Adelante" : "Forward" }
    var zoomIn: String { es ? "Acercar" : "Zoom In" }
    var zoomOut: String { es ? "Alejar" : "Zoom Out" }
    var zoomReset: String { es ? "Tamaño real" : "Actual Size" }
    var openBrowser: String { es ? "Abrir en el browser" : "Open in Browser" }
    var window: String { es ? "Ventana" : "Window" }
    var minimize: String { es ? "Minimizar" : "Minimize" }
    var close: String { es ? "Cerrar" : "Close" }
}
let T = L()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: config.logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: config.logURL)
    }
}

func findFreePort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    guard bound == 0 else { return nil }
    let got = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard got == 0 else { return nil }
    return Int(UInt16(bigEndian: addr.sin_port))
}

// MARK: - The local server

final class LocalServer {
    private var process: Process?
    private var watchdog: Process?
    /// True when the server was already up: we attached, so we must not stop it.
    private(set) var adopted = false

    /// Any HTTP answer counts. Dev servers routinely 404 or redirect on `/`;
    /// requiring a 200 would report a healthy server as dead.
    func isAlive(timeout: TimeInterval = 1.5) -> Bool {
        guard let url = pageURL(config.readyPath) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = response is HTTPURLResponse
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return ok
    }

    /// Blocking; call off the main thread. Returns an error message, or nil.
    func start() -> String? {
        if config.mode == "url" { return nil }

        if config.configuredPort != 0, isAlive() {
            adopted = true
            log("adopted a server already answering on \(activePort)")
            return nil
        }
        if activePort == 0 {
            guard let free = findFreePort() else { return "No free port available." }
            activePort = free
        }
        guard !config.command.isEmpty else { return "The bundle has no command to run." }
        guard FileManager.default.fileExists(atPath: config.cwd) else {
            return "Working directory not found:\n\(config.cwd)\nRebuild the app with make_app.py."
        }

        let port = String(activePort)
        let command = config.command.replacingOccurrences(of: "{port}", with: port)

        var environment = ProcessInfo.processInfo.environment
        // A GUI app is launched by launchd with PATH=/usr/bin:/bin:/usr/sbin:/sbin,
        // so pyenv, nvm and Homebrew are invisible. The login shell below restores
        // the user's PATH; these extras cover the common cases it does not.
        let extra = config.pathPrepend + ["/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["PORT"] = port
        environment["W2M_PORT"] = port
        environment["PYTHONUNBUFFERED"] = "1"
        environment["APP_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        for (key, value) in config.env {
            environment[key] = value.replacingOccurrences(of: "{port}", with: port)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", command]
        task.currentDirectoryURL = URL(fileURLWithPath: config.cwd)
        task.environment = environment
        if let handle = try? FileHandle(forWritingTo: config.logURL) {
            handle.seekToEndOfFile()
            task.standardOutput = handle
            task.standardError = handle
        }
        log("run: \(command)  (cwd \(config.cwd))")
        do { try task.run() } catch {
            return "Could not launch the server: \(error.localizedDescription)"
        }
        process = task
        log("started server (pid \(task.processIdentifier)) on port \(port)")
        startWatchdog(serverPID: task.processIdentifier)

        let deadline = Date().addingTimeInterval(config.startupTimeout)
        while Date() < deadline {
            if isAlive(timeout: 0.6) { return nil }
            if !task.isRunning {
                process = nil
                let code = task.terminationStatus
                let hint = code == 127
                    ? "Command not found: check the command and that its runtime is on the login shell's PATH (add \"path_prepend\" to the config).\n"
                    : "If port \(port) is taken by another process, close it and retry.\n"
                return "The server exited with code \(code) before answering.\n" + hint
                     + "The log has its output."
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        stop()
        return "The server did not answer within \(Int(config.startupTimeout)) seconds."
    }

    /// Survives the app. Quitting normally runs stop(); Force Quit, a crash or a
    /// logout do not run applicationWillTerminate, and without this the orphan
    /// keeps the port — the next launch would adopt it and quitting would stop
    /// replacing the server at all.
    private func startWatchdog(serverPID: Int32) {
        let script = """
        while kill -0 "$1" 2>/dev/null; do
          kill -0 "$2" 2>/dev/null || exit 0
          sleep 1
        done
        pkill -TERM -P "$2" 2>/dev/null
        kill -TERM "$2" 2>/dev/null
        sleep 2
        pkill -KILL -P "$2" 2>/dev/null
        kill -KILL "$2" 2>/dev/null
        """
        let dog = Process()
        dog.executableURL = URL(fileURLWithPath: "/bin/sh")
        dog.arguments = ["-c", script, "sh",
                         String(ProcessInfo.processInfo.processIdentifier),
                         String(serverPID)]
        dog.standardOutput = FileHandle.nullDevice
        dog.standardError = FileHandle.nullDevice
        do { try dog.run(); watchdog = dog } catch { log("watchdog failed: \(error)") }
    }

    func stop() {
        guard !adopted, let task = process, task.isRunning else { return }
        let pid = task.processIdentifier
        log("stopping server (pid \(pid))")
        // Children first (node workers, reloaders), then the process itself.
        runQuiet("/usr/bin/pkill", ["-TERM", "-P", String(pid)])
        task.terminate()
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if task.isRunning {
            runQuiet("/usr/bin/pkill", ["-KILL", "-P", String(pid)])
            kill(pid, SIGKILL)
        }
        process = nil
        watchdog?.terminate()
    }

    private func runQuiet(_ executable: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private let server = LocalServer()
    private var window: NSWindow!
    private var webView: WKWebView!
    private var splash: NSView!
    private var spinner: NSProgressIndicator!
    private var downloadTargets: [ObjectIdentifier: URL] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let failure = self.server.start()
            DispatchQueue.main.async {
                if let failure { self.fail(failure) } else { self.loadPage() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true  // closing the window is how you stop the server
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = config.name
        window.minSize = NSSize(width: config.minWidth, height: config.minHeight)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(config.autosave)  // size/position across launches

        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = true

        splash = makeSplash()
        splash.autoresizingMask = [.width, .height]

        let container = NSView(frame: window.contentLayoutRect)
        container.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        splash.frame = container.bounds
        container.addSubview(webView)
        container.addSubview(splash)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSplash() -> NSView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: T.starting)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(spinner)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -14),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
        ])
        return view
    }

    private func loadPage() {
        guard let url = pageURL(config.path) else {
            fail("Invalid URL."); return
        }
        webView.load(URLRequest(url: url))
    }

    private func fail(_ message: String) {
        spinner.stopAnimation(nil)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = T.failTitle
        alert.informativeText = message
        alert.addButton(withTitle: T.showLog)
        alert.addButton(withTitle: T.quit)
        log("failed: \(message.replacingOccurrences(of: "\n", with: " "))")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(config.logURL)
        }
        NSApp.terminate(nil)
    }

    // MARK: Web view

    private func isLocal(_ url: URL) -> Bool {
        if config.mode == "url" { return url.host == URL(string: config.remoteURL)?.host }
        return url.host == "127.0.0.1" || url.host == "localhost"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard splash.superview != nil else { return }
        spinner.stopAnimation(nil)
        webView.isHidden = false
        splash.removeFromSuperview()
        log("page loaded in the window")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("The window could not load the page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        fail("The window could not load the page: \(error.localizedDescription)")
    }

    /// Anything that is not the app itself belongs in the real browser.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download); return
        }
        if let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme ?? ""), !isLocal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    // target=_blank / window.open: send it to the browser instead of a window
    // that would never be created.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isLocal(url) { webView.load(navigationAction.request) }
            else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = dir.appendingPathComponent(suggestedFilename)
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            target = dir.appendingPathComponent(name)
            n += 1
        }
        downloadTargets[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) {
            log("downloaded \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        log("download failed: \(error.localizedDescription)")
    }

    // MARK: JS dialogs and file pickers
    //
    // A WKWebView that ignores these callbacks makes alert()/confirm() and
    // <input type=file> vanish silently.

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: T.cancel)
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    // MARK: Menu actions

    @objc private func reload(_ sender: Any?) { webView.reloadFromOrigin() }
    @objc private func goBack(_ sender: Any?) { webView.goBack() }
    @objc private func goForward(_ sender: Any?) { webView.goForward() }
    @objc private func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc private func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.4) }
    @objc private func zoomReset(_ sender: Any?) { webView.pageZoom = 1 }
    @objc private func openInBrowser(_ sender: Any?) {
        if let url = pageURL(config.path) { NSWorkspace.shared.open(url) }
    }
    @objc private func showLog(_ sender: Any?) { NSWorkspace.shared.open(config.logURL) }

    // ⌘Z is a menu key equivalent, and AppKit consumes those before the key ever
    // reaches the page. So the item asks the page first: if it defines
    // `window.appUndo(redo)` and returns true, the page handled it; otherwise the
    // native undo runs (which is what ⌘Z means inside a text field). Pages that
    // define no appUndo get plain native behaviour.
    @objc private func undoAction(_ sender: Any?) { route(redo: false, from: sender) }
    @objc private func redoAction(_ sender: Any?) { route(redo: true, from: sender) }

    private func route(redo: Bool, from sender: Any?) {
        let native = NSSelectorFromString(redo ? "redo:" : "undo:")
        guard let webView else {
            NSApp.sendAction(native, to: nil, from: sender); return
        }
        webView.evaluateJavaScript("!!(window.appUndo && window.appUndo(\(redo)))") { got, _ in
            if (got as? Bool) != true { NSApp.sendAction(native, to: nil, from: sender) }
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: T.about,
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T.hide, action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T.quit, action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Without this menu, ⌘C/V/X/A do nothing inside a WKWebView.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: T.edit)
        editMenu.addItem(withTitle: T.undo, action: #selector(undoAction(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: T.redo, action: #selector(redoAction(_:)),
                                    keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: T.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: T.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: T.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: T.selectAll, action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: T.view)
        viewMenu.addItem(withTitle: T.reload, action: #selector(reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(withTitle: T.back, action: #selector(goBack(_:)), keyEquivalent: "[")
        viewMenu.addItem(withTitle: T.forward, action: #selector(goForward(_:)), keyEquivalent: "]")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: T.zoomIn, action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: T.zoomOut, action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: T.zoomReset, action: #selector(zoomReset(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let browser = viewMenu.addItem(withTitle: T.openBrowser,
                                       action: #selector(openInBrowser(_:)), keyEquivalent: "b")
        browser.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: T.showLog, action: #selector(showLog(_:)), keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: T.window)
        windowMenu.addItem(withTitle: T.minimize,
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: T.close, action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

// Top-level code, not `@main`: swiftc compiling a single file treats it as a
// script, and `@main` is illegal there.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
