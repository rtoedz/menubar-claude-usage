import AppKit
import SwiftUI

/// Borderless panel that can take key focus, so SwiftUI buttons and menus work
/// inside it without activating the app.
private final class UsagePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let panelWidth: CGFloat = 320
    private static let panelGap: CGFloat = 6

    private var statusItem: NSStatusItem!
    private let manager = UsageManager()

    // The popover is a plain panel positioned once, when it opens, instead of an
    // NSPopover anchored to the status item. NSPopover keeps re-anchoring to the
    // item's window, and whenever the menu bar hides (full-screen apps, auto-hide)
    // that window sits above the screen — so any layout change in the open popover
    // threw it to the top-left corner.
    private var panel: UsagePanel?
    private var clickMonitor: Any?
    private var panelTop: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon. (Info.plist LSUIElement covers the
        // bundled app; this reinforces it for `swift run`.)
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPanel()

        manager.onUpdate = { [weak self] title in
            self?.statusItem.button?.title = title
        }
        manager.start()

        // Debug aid: exercise the login-item registration and log the result.
        if let v = ProcessInfo.processInfo.environment["CUB_TEST_LOGIN"] {
            let result = manager.setLaunchAtLogin(v != "0")
            NSLog("ClaudeUsageBar login-item enabled -> %@", String(result))
        }

        // Debug aid: fire a sample notification (disabled — requires Developer ID signing).
        // if ProcessInfo.processInfo.environment["CUB_TEST_NOTIFY"] != nil {
        //     DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        //         self?.manager.sendTestNotification()
        //     }
        // }

        if let path = ProcessInfo.processInfo.environment["CUB_RENDER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.renderPopover(to: path)
            }
        }

        // Debug aid: render the popover UI in a fixed standalone window so it
        // can be screenshotted regardless of the notch / menu-bar crowding.
        if ProcessInfo.processInfo.environment["CUB_DEBUG_POPOVER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.showDebugWindow()
            }
        }
    }

    private var debugWindow: NSWindow?

    /// Debug aid: render the popover straight to a PNG (needs no screen-recording
    /// permission) and quit. `CUB_RENDER=/path/out.png`.
    private func renderPopover(to path: String) {
        let renderer = ImageRenderer(content: styled(PopoverView(manager: manager)).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { NSLog("ClaudeUsageBar render failed"); NSApp.terminate(nil); return }
        try? png.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }

    private func showDebugWindow() {
        let host = NSHostingController(rootView: PopoverView(manager: manager))
        host.sizingOptions = [.preferredContentSize]
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable]
        win.title = "ClaudeUsageBar (debug)"
        win.setFrameOrigin(NSPoint(x: 200, y: 400))
        win.makeKeyAndOrderFront(nil)
        win.level = .floating
        debugWindow = win
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = "◌ …"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            closePanel()
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: Context menu (right-click)

    private func showContextMenu() {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshData), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshData() {
        Task { await manager.fetch(force: true) }
    }

    // MARK: Panel

    private func styled<V: View>(_ content: V) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func setupPanel() {
        let host = NSHostingView(rootView: styled(PopoverView(manager: manager) { [weak self] height in
            self?.resizePanel(to: height)
        }))
        host.sizingOptions = []

        let panel = UsagePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onCancel = { [weak self] in self?.closePanel() }
        self.panel = panel
    }

    private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
            Task { await manager.fetch() }
        }
    }

    private func showPanel() {
        guard let panel, let buttonWindow = statusItem.button?.window else { return }
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]

        // The item's window sits above the screen while the menu bar is hidden, so
        // fall back to the click position for the horizontal anchor.
        let onScreen = buttonWindow.frame.maxY <= screen.frame.maxY + 1
        let anchorX = onScreen ? buttonWindow.frame.midX : NSEvent.mouseLocation.x

        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        panelTop = screen.frame.maxY - barHeight - Self.panelGap

        let visible = screen.visibleFrame
        let x = min(max(anchorX - Self.panelWidth / 2, visible.minX + 8),
                    visible.maxX - Self.panelWidth - 8)
        let height = panel.frame.height
        panel.setFrame(NSRect(x: x, y: panelTop - height, width: Self.panelWidth, height: height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    /// Keeps the top edge fixed and grows or shrinks downward with the content.
    private func resizePanel(to height: CGFloat) {
        guard let panel else { return }
        let h = ceil(height)
        guard panel.frame.height != h else { return }
        var frame = panel.frame
        let top = panel.isVisible ? panelTop : frame.maxY
        frame.size = NSSize(width: Self.panelWidth, height: h)
        frame.origin.y = top - h
        panel.setFrame(frame, display: true)
    }
}
