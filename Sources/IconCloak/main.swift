import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Prototype: hide menu bar icons on macOS 27.
//
// Expanded:   [app menus]  (notch)  [hidden icons] [|] [‹] [visible icons]
// Collapsed:  [app menus][divider filler] (notch) [toggle filler] [»] [visible icons]
//
// macOS 27 places status items right of the notch first, then left of it after the
// app menus, and only then in its "»" overflow menu. When collapsing, the toggle fills
// the free space right of the notch and the divider (pushed to the left side) fills
// the space after the app menus — so the icons left of the divider fit nowhere and
// end up in "»". The left filler is resized whenever the frontmost app changes, which
// needs the Accessibility permission to read where the app menus end.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var toggle: NSStatusItem!
    private var divider: NSStatusItem!
    private var collapsed = false

    /// Status item windows are this much wider than `length` (button padding).
    private let itemPadding: CGFloat = 16
    private let margin: CGFloat = 8

    /// Toggle frame measured while expanded; its right edge stays put when collapsed.
    private var expandedToggleFrame: NSRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 27 decides the initial order itself, so roles are assigned by position
        // (see ensureOrder): the left item is the divider, the right one the toggle.
        toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "IconCloak.toggle"
        divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider.autosaveName = "IconCloak.divider"
        configureButtons()
        registerHotKey()
        // Frames are only valid once macOS has laid the items out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.ensureOrder() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateLeftFiller() }

        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log("Launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), accessibility=\(trusted)")

        // Test control: post distributed notification "dev.iconcloak.cmd" with object
        // "collapse" | "expand" | "log" (see scripts/ctl.swift).
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.iconcloak.cmd"), object: nil, queue: .main) { [weak self] note in
            guard let self, let cmd = note.object as? String else { return }
            switch cmd {
            case "collapse": self.setCollapsed(true)
            case "expand": self.setCollapsed(false)
            case "log": self.logState(label: "manual")
            case "axdump": self.dumpMenuBarAgent(press: false)
            case "pressoverflow": self.dumpMenuBarAgent(press: true)
            default: break
            }
        }
    }

    // MARK: - Collapse / expand

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(on: [toggle, divider].first { $0.button === sender } ?? toggle)
        } else {
            setCollapsed(!collapsed)
        }
    }

    private func setCollapsed(_ value: Bool) {
        guard value != collapsed else { return }
        if value {
            ensureOrder()
            expandedToggleFrame = toggle.button?.window?.frame
        }
        collapsed = value
        if value {
            toggle.length = rightFillerLength()
            updateLeftFiller()
        } else {
            toggle.length = NSStatusItem.variableLength
            divider.length = NSStatusItem.variableLength
        }
        configureButtons()
        log("---- \(value ? "COLLAPSE" : "EXPAND") ----")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.logState(label: value ? "collapsed" : "expanded") }
    }

    /// Fill from the notch's right edge (or the app menus' end without a notch) up to the toggle's right edge.
    private func rightFillerLength() -> CGFloat {
        guard let frame = expandedToggleFrame, let screen = toggle.button?.window?.screen else { return 0 }
        let start = screen.auxiliaryTopRightArea?.minX ?? appMenusEndX(on: screen) ?? frame.minX
        let length = frame.maxX - start - margin - itemPadding
        log("right filler: toggleMaxX=\(frame.maxX) start=\(start) → \(length)")
        return max(length, 0)
    }

    /// Fill the space between the frontmost app's menus and the notch's left edge.
    private func updateLeftFiller() {
        guard collapsed, let screen = toggle.button?.window?.screen ?? NSScreen.main else { return }
        guard let notchLeft = screen.auxiliaryTopLeftArea?.maxX else {
            divider.length = 0 // No notch: the right filler already spans the whole bar.
            return
        }
        guard let menusEnd = appMenusEndX(on: screen) else {
            log("left filler: can't read app menus (accessibility not granted?)")
            return
        }
        let length = max(notchLeft - menusEnd - margin - itemPadding, 0)
        divider.length = length
        log("left filler: menusEnd=\(menusEnd) notchLeft=\(notchLeft) → \(length)")
    }

    /// Right edge (screen x) of the frontmost app's menu bar items, via Accessibility.
    private func appMenusEndX(on screen: NSScreen) -> CGFloat? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.menuBarOwningApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBar) == .success else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        var maxX: CGFloat = screen.frame.minX
        for item in items {
            var posValue: CFTypeRef?, sizeValue: CFTypeRef?
            var pos = CGPoint.zero, size = CGSize.zero
            AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posValue)
            AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue)
            if let posValue { AXValueGetValue(posValue as! AXValue, .cgPoint, &pos) }
            if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) }
            // Only items on this screen's menu bar (AX uses the same x axis as AppKit).
            if pos.x >= screen.frame.minX, pos.x < screen.frame.maxX { maxX = max(maxX, pos.x + size.width) }
        }
        return maxX
    }

    // MARK: - Items

    private func configureButtons() {
        for item in [toggle!, divider!] {
            item.button?.target = self
            item.button?.action = #selector(itemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        toggle.button?.title = collapsed ? "" : "‹"
        toggle.button?.appearsDisabled = false
        divider.button?.title = collapsed ? "" : "|"
        divider.button?.appearsDisabled = true
    }

    /// Swap roles if the user (or macOS) put the toggle left of the divider.
    private func ensureOrder() {
        guard !collapsed, let t = toggle.button?.window?.frame, let d = divider.button?.window?.frame, t.minX < d.minX else { return }
        swap(&toggle, &divider)
        configureButtons()
        log("swapped roles: toggle was left of divider")
    }

    private func showMenu(on item: NSStatusItem) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Log diagnostics", action: #selector(logNow), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Open log", action: #selector(openLog), keyEquivalent: "l").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit IconCloak Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Global ⌃⌥⌘H toggles collapse (Carbon hot keys need no permissions).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.setCollapsed(!me.collapsed) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: OSType(0x49434C4B), id: 1), GetApplicationEventTarget(), 0, &ref)
    }

    // MARK: - Diagnostics

    /// Logs the accessibility tree of the processes that draw the menu bar. With `press`,
    /// also presses the first element that looks like the overflow ("»") button.
    private func dumpMenuBarAgent(press: Bool) {
        let names: Set<String> = ["MenuBarAgent", "ControlCenter", "SystemUIServer"]
        var pressed = false
        for app in NSWorkspace.shared.runningApplications {
            let exe = app.executableURL?.lastPathComponent ?? ""
            guard names.contains(exe) else { continue }
            log("== AX tree of \(exe) (pid \(app.processIdentifier))")
            func attr(_ el: AXUIElement, _ name: String) -> String {
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return "" }
                if CFGetTypeID(v) == AXValueGetTypeID() {
                    var p = CGPoint.zero, s = CGSize.zero
                    if AXValueGetValue(v as! AXValue, .cgPoint, &p) { return "\(Int(p.x)),\(Int(p.y))" }
                    if AXValueGetValue(v as! AXValue, .cgSize, &s) { return "\(Int(s.width))x\(Int(s.height))" }
                }
                return "\(v)"
            }
            func walk(_ el: AXUIElement, depth: Int) {
                guard depth < 8 else { return }
                var actions: CFArray?
                AXUIElementCopyActionNames(el, &actions)
                let acts = (actions as? [String] ?? []).joined(separator: ",")
                let fields = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXIdentifier", "AXHelp"].map { attr(el, $0) }
                log(String(repeating: "  ", count: depth) + fields.filter { !$0.isEmpty }.joined(separator: " | ")
                    + " @\(attr(el, "AXPosition")) \(attr(el, "AXSize")) [\(acts)]")
                let text = fields.joined(separator: " ").lowercased()
                if press, !pressed, text.contains("overflow") || text.contains("more") || text.contains("hidden") {
                    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
                    log(">>> pressed this element: \(err.rawValue)")
                    pressed = true
                }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
                   let kids = children as? [AXUIElement] {
                    kids.forEach { walk($0, depth: depth + 1) }
                }
            }
            walk(AXUIElementCreateApplication(app.processIdentifier), depth: 0)
        }
        if press && !pressed { log(">>> no overflow-like element found") }
    }

    @objc private func logNow() { logState(label: "manual") }
    @objc private func openLog() { NSWorkspace.shared.open(logURL) }

    private func logState(label: String) {
        let screen = toggle.button?.window?.screen
        log("[\(label)] notchLeft=\(screen?.auxiliaryTopLeftArea?.maxX ?? -1) notchRight=\(screen?.auxiliaryTopRightArea?.minX ?? -1) frontmost=\(NSWorkspace.shared.menuBarOwningApplication?.localizedName ?? "?")")
        log("[\(label)] divider.length=\(divider.length) window=\(divider.button?.window?.frame ?? .zero)")
        log("[\(label)] toggle.length=\(toggle.length) window=\(toggle.button?.window?.frame ?? .zero)")
    }

    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/IconCloak.log")

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        print(line, terminator: "")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
