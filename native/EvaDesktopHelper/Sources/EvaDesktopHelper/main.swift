import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        Thread.detachNewThread { runStdinLoop() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "cursorarrow.click.2",
                accessibilityDescription: "Eva Desktop"
            )
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        let status = Desktop.status()
        menu.removeAllItems()
        menu.addItem(withTitle: "Eva Desktop", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Extension IPC: Connected", action: nil, keyEquivalent: "")
        menu.addItem(
            withTitle: "Accessibility: \(status.permissions.accessibility ? "Granted" : "Missing")",
            action: nil, keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Screen Recording: \(status.permissions.screen_recording ? "Granted" : "Missing")",
            action: nil, keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Automation: \(status.automation.paused ? "Paused" : "Enabled")",
            action: nil, keyEquivalent: ""
        )
        menu.addItem(.separator())
        if status.automation.enabled {
            addAction("Pause Automation", action: #selector(pauseAutomation), to: menu)
        } else {
            addAction("Enable Automation for 10 Minutes", action: #selector(enableAutomation), to: menu)
        }
        if !status.permissions.accessibility {
            addAction("Grant Accessibility Access…", action: #selector(requestAccessibility), to: menu)
        }
        if !status.permissions.screen_recording {
            addAction("Grant Screen Recording Access…", action: #selector(requestScreenRecording), to: menu)
        }
        addAction("Recheck Permissions", action: #selector(recheckPermissions), to: menu)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
    }

    private func addAction(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func enableAutomation() {
        Desktop.enableAutomation()
        recheckPermissions()
    }

    @objc private func pauseAutomation() {
        Desktop.pauseAutomation()
        recheckPermissions()
    }
    @objc private func requestAccessibility() {
        Desktop.requestAccessibilityPermission()
        recheckPermissions()
    }

    @objc private func requestScreenRecording() {
        Desktop.requestScreenRecordingPermission()
        recheckPermissions()
    }

    @objc private func recheckPermissions() {
        if let menu = statusItem?.menu { rebuild(menu) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

func runStdinLoop() {
    while let line = readLine() {
        handleLine(line)
    }
    Desktop.pauseAutomation()
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

func handleLine(_ line: String) {
    guard !line.isEmpty else { return }
    write(process(line))
}

func process(_ line: String) -> Response {
    guard let data = line.data(using: .utf8),
          let request = try? Request.decode(from: data)
    else {
        logError("invalid_request: malformed frame")
        return Response.failure(id: -1, code: "invalid_request", message: "malformed request")
    }

    switch request.method {
    case "ping":
        return Response.ok(id: request.id, result: .object(["pong": .bool(true)]))
    case "status":
        return Response.ok(id: request.id, result: .encode(Desktop.status()))
    case "observe":
        return response(id: request.id, from: Desktop.observe(request.params))
    case "action":
        return response(id: request.id, from: Desktop.action(request.params))
    default:
        return Response.failure(
            id: request.id,
            code: "invalid_request",
            message: "unknown method: \(request.method)"
        )
    }
}

func response<T: Encodable>(id: Int, from result: Result<T, DesktopFailure>) -> Response {
    switch result {
    case .success(let value):
        return Response.ok(id: id, result: .encode(value))
    case .failure(let failure):
        return Response.failure(id: id, code: failure.code, message: failure.message)
    }
}

func write(_ response: Response) {
    FileHandle.standardOutput.write(response.encode())
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func logError(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}
