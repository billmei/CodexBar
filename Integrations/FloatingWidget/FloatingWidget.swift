import AppKit
import WebKit

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        let controlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        if event.type == .rightMouseDown || controlClick,
           let contentView = self.contentView,
           let menu = contentView.menu
        {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return
        }
        super.sendEvent(event)
    }
}

private final class DragHandle: NSView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        self.window?.performDrag(with: event)
    }
}

@main
@MainActor
final class FloatingWidget: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, WKNavigationDelegate {
    private static let defaultProviders = ["claude", "codex", "antigravity"]
    private let defaults = UserDefaults.standard
    private let feed = DashboardFeed()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var providerIDs = FloatingWidget.defaultProviders
    private var refreshTask: Task<Void, Never>?
    private var rawSnapshot = ""
    private var status = "Loading usage…"
    private var webReady = false

    private let panel = FloatingPanel(
        contentRect: NSRect(x: 0, y: 0, width: 448, height: 162),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false)

    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    static func main() {
        let app = NSApplication.shared
        let widget = FloatingWidget()
        app.delegate = widget
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(widget) {}
    }

    func applicationDidFinishLaunching(_: Notification) {
        self.providerIDs = self.defaults.stringArray(forKey: "ProviderIDs") ?? Self.defaultProviders
        self.configurePanel()
        self.configureStatusItem()
        let saved = self.defaults.string(forKey: "PanelOrigin").map(NSPointFromString)
        self.placePanel(at: saved)
        self.reloadUsage()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if !self.panel.isVisible { self.reloadUsage() }
        return false
    }

    func applicationDidChangeScreenParameters(_: Notification) {
        self.placePanel(at: self.panel.frame.origin)
    }

    func windowDidMove(_: Notification) {
        self.defaults.set(NSStringFromPoint(self.panel.frame.origin), forKey: "PanelOrigin")
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        self.webReady = true
        self.updatePage()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.webReady = false
        webView.reload()
    }

    private func configurePanel() {
        self.panel.title = "CodexBar Floating Widget"
        self.panel.delegate = self
        self.panel.isFloatingPanel = true
        self.panel.level = .statusBar
        self.panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .ignoresCycle]
        self.panel.hidesOnDeactivate = false
        self.panel.isOpaque = false
        self.panel.backgroundColor = .clear
        self.panel.hasShadow = true

        let content = NSView(frame: NSRect(origin: .zero, size: self.panel.frame.size))
        content.menu = self.controlsMenu()
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        self.webView.frame = content.bounds
        self.webView.autoresizingMask = [.width, .height]
        self.webView.navigationDelegate = self
        content.addSubview(self.webView)

        let handle = DragHandle(frame: NSRect(
            x: 0, y: content.bounds.height - 14, width: content.bounds.width, height: 14))
        handle.autoresizingMask = [.width, .minYMargin]
        content.addSubview(handle)
        self.panel.contentView = content

        if let page = Bundle.main.url(forResource: "index", withExtension: "html") {
            self.webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    private func configureStatusItem() {
        let icon = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: self.panel.title)
        self.statusItem.button?.image = icon
        self.statusItem.button?.toolTip = self.panel.title
        self.statusItem.menu = self.controlsMenu()
        self.statusItem.isVisible = !self.defaults.bool(forKey: "MenuBarIconHidden")
    }

    private func controlsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        self.menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let reload = menu.addItem(withTitle: "Reload Usage", action: #selector(self.reloadUsage), keyEquivalent: "")
        reload.target = self
        let visibility = menu.addItem(
            withTitle: self.panel.isVisible ? "Hide Widget" : "Show Widget",
            action: #selector(self.toggleVisibility),
            keyEquivalent: "")
        visibility.target = self
        let providers = menu.addItem(
            withTitle: "Choose Providers…",
            action: #selector(self.chooseProviders),
            keyEquivalent: "")
        providers.target = self
        let icon = menu.addItem(
            withTitle: self.statusItem.isVisible ? "Hide Menu Bar Icon" : "Show Menu Bar Icon",
            action: #selector(self.toggleMenuBarIcon),
            keyEquivalent: "")
        icon.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(
            withTitle: "Quit Floating Widget",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.target = NSApp
    }

    @objc private func toggleMenuBarIcon() {
        let shouldHide = self.statusItem.isVisible
        self.defaults.set(shouldHide, forKey: "MenuBarIconHidden")
        self.statusItem.isVisible = !shouldHide
    }

    private func placePanel(at origin: NSPoint?) {
        let size = NSSize(width: CGFloat(148 * self.providerIDs.count + 4), height: 162)
        let preferred = origin.map { NSRect(origin: $0, size: size) }
        let screen = preferred.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let desired = origin ?? NSPoint(x: bounds.maxX - size.width - 16, y: bounds.maxY - size.height - 16)
        let position = NSPoint(
            x: max(bounds.minX, min(desired.x, bounds.maxX - size.width)),
            y: max(bounds.minY, min(desired.y, bounds.maxY - size.height)))
        self.panel.setFrame(NSRect(origin: position, size: size), display: true)
    }

    @objc private func reloadUsage() {
        if !self.panel.isVisible { self.panel.orderFrontRegardless() }
        self.refreshTask?.cancel()
        if self.rawSnapshot.isEmpty { self.publish(snapshot: "", status: "Loading usage…") }
        self.refreshTask = Task { [weak self, feed = self.feed] in
            while !Task.isCancelled {
                let delay: Duration
                do {
                    let snapshot = try await feed.snapshot()
                    guard !Task.isCancelled else { return }
                    self?.publish(snapshot: snapshot, status: "")
                    delay = .seconds(60)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.publish(snapshot: "", status: error.localizedDescription)
                    delay = .seconds(10)
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    @objc private func toggleVisibility() {
        if self.panel.isVisible {
            self.refreshTask?.cancel()
            self.refreshTask = nil
            self.panel.orderOut(nil)
        } else {
            self.reloadUsage()
        }
    }

    @objc private func chooseProviders() {
        let alert = NSAlert()
        alert.messageText = "Choose Providers"
        alert.informativeText = "Enter one to three CodexBar provider IDs, separated by commas."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(string: self.providerIDs.joined(separator: ", "))
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            let ids = input.stringValue.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if (1...3).contains(ids.count),
               Set(ids).count == ids.count,
               ids.allSatisfy({ $0.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil })
            {
                self.providerIDs = ids
                self.defaults.set(ids, forKey: "ProviderIDs")
                self.placePanel(at: self.panel.frame.origin)
                self.updatePage()
                return
            }
            alert.informativeText = "Enter one to three different IDs. Use letters, numbers, hyphens or underscores."
        }
    }

    private func publish(snapshot: String, status: String) {
        self.rawSnapshot = snapshot
        self.status = status
        self.updatePage()
    }

    private func updatePage() {
        guard self.webReady else { return }
        // Pass values as arguments so provider text never becomes JavaScript source.
        self.webView.callAsyncJavaScript(
            "window.updateWidget(snapshot, providerIDs, status)",
            arguments: ["snapshot": self.rawSnapshot, "providerIDs": self.providerIDs, "status": self.status],
            in: nil,
            in: .page,
            completionHandler: nil)
    }
}
