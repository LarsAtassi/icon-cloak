import AppKit
import ApplicationServices
import Carbon.HIToolbox

// IconCloak — hides menu bar icons on macOS 27.
//
// Expanded:   [app menus]  (notch)  [» divider] [hidden icons] [| toggle] [visible icons]
// Collapsed:  [app menus][divider filler] (notch) [toggle filler] [«] [visible icons]
//
// "»" collapses, "|" marks the boundary: everything left of it gets hidden. macOS 27 places
// status items right of the notch first, then left of it after the app menus, and only
// then in its own "«" overflow. When collapsing, the toggle fills the free space right of
// the notch and the divider (pushed to the left side) fills the space after the app menus,
// so the icons left of the toggle fit nowhere and end up in the overflow. The left filler is resized whenever the frontmost app changes, which
// needs the Accessibility permission to read where the app menus end.
// See docs/how-it-works.md for the details.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var toggle: NSStatusItem!
    private var divider: NSStatusItem!
    private var collapsed = false

    /// Status item windows are this much wider than `length` (button padding).
    private let itemPadding: CGFloat = 16
    private let margin: CGFloat = 8

    /// Toggle frame measured while expanded; its right edge stays put when collapsed.
    private var expandedToggleFrame: NSRect?

    /// Watches macOS's overflow button while collapsed: clicking it ("«" → "»") expands IconCloak.
    private var overflowWatch: Timer?
    private var overflowBaseline: String?
    private var glyphsHidden = false
    /// Roles are assigned by position once macOS has laid out both items.
    private var rolesReady = false
    private let collapseImage: NSImage? = {
        let image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: "Hide menu bar icons")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        return image
    }()
    /// Same size as `collapseImage`, fully transparent.
    private lazy var clearCollapseImage: NSImage? = collapseImage.map { NSImage(size: $0.size) }
    /// Frame of macOS's overflow button (global top-left coords), refreshed while collapsed.
    private var overflowButtonFrame: CGRect?
    private var clickTap: CFMachPort?
    private var swallowNextMouseUp = false

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
        toggle.isVisible = true
        divider.isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.ensureOrder()
            self.rolesReady = true
            self.configureButtons()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.moveDividerToFront() }
        }
        // Keep "»" in front: after a ⌘-drag in the menu bar, move it back if an icon ended up
        // left of it (global mouse monitors need Accessibility).
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, !self.collapsed, event.modifierFlags.contains(.command),
                  let screen = NSScreen.main, NSEvent.mouseLocation.y > screen.frame.maxY - 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.moveDividerToFront() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateLeftFiller() }

        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log("Launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), accessibility=\(trusted)")
        if trusted {
            installClickTap()
        } else {
            // Without Accessibility, clicks on "«" can't be caught and the left filler can't be
            // sized. Pick the permission up as soon as it's granted — no relaunch needed.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, AXIsProcessTrusted() else { return }
                timer.invalidate()
                self.log("accessibility granted")
                self.installClickTap()
                self.updateLeftFiller()
            }
        }

        #if ICONCLOAK_DEV
        installDevControls()
        #endif
    }

    // MARK: - Collapse / expand

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(on: [toggle, divider].first { $0.button === sender } ?? toggle)
        } else if sender === toggle.button && !collapsed {
            return // "|" is only a boundary marker
        } else {
            setCollapsed(!collapsed)
        }
    }

    private func setCollapsed(_ value: Bool) {
        guard value != collapsed, rolesReady else { return }
        if value { expandedToggleFrame = toggle.button?.window?.frame }
        collapsed = value
        if value {
            toggle.length = rightFillerLength()
            updateLeftFiller()
        } else {
            divider.length = NSStatusItem.variableLength
        }
        if value {
            configureButtons()
        } else {
            // macOS animates our items shrinking from filler width (~300 ms); revealing "»" and
            // "|" only afterwards keeps them from sliding in from the far left.
            glyphsHidden = true
            configureButtons()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                glyphsHidden = false
                configureButtons()
            }
        }
        value ? startOverflowWatch() : stopOverflowWatch()
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

    // MARK: - Overflow button

    /// Clicking macOS's "«" re-lays out the menu bar and shows overflow icons left of the notch,
    /// where our left filler sits. Instead we treat the click as "expand". The button's label
    /// changes when clicked; compare against the label seen after collapsing (locale-independent).
    private func startOverflowWatch() {
        overflowBaseline = nil
        overflowWatch?.invalidate()
        overflowWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.collapsed, let (label, frame) = self.overflowButton() else { return }
            self.overflowButtonFrame = frame
            guard let baseline = self.overflowBaseline else { self.overflowBaseline = label; return }
            if label != baseline {
                self.log("overflow button changed (\(baseline) → \(label)): expanding")
                self.setCollapsed(false)
            }
        }
    }

    private func stopOverflowWatch() {
        overflowWatch?.invalidate()
        overflowWatch = nil
        overflowButtonFrame = nil
    }

    /// Catches clicks on the overflow button while collapsed and expands IconCloak instead,
    /// so macOS never opens its overflow (which would briefly show the icons elsewhere).
    private func installClickTap() {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        clickTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: { _, type, event, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.clickTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .leftMouseUp, me.swallowNextMouseUp {
                me.swallowNextMouseUp = false
                return nil
            }
            if type == .leftMouseDown, me.collapsed, let frame = me.overflowButtonFrame,
               frame.insetBy(dx: -4, dy: 0).contains(event.location) {
                me.swallowNextMouseUp = true
                DispatchQueue.main.async { me.setCollapsed(false) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let clickTap else { log("click tap unavailable (accessibility?)"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, clickTap, 0), .commonModes)
    }

    /// The overflow button: the action-less AXButton inside MenuBarAgent's "Menu Extras" menu bar.
    /// Returns its label and frame (global top-left coordinates).
    private func overflowButton() -> (String, CGRect)? {
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.executableURL?.lastPathComponent == "MenuBarAgent"
        }) else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        for bar in axChildren(app) where axString(bar, kAXRoleAttribute) == kAXMenuBarRole {
            for el in axChildren(bar) where axString(el, kAXRoleAttribute) == kAXButtonRole {
                let label = (axString(el, kAXTitleAttribute) ?? "") + (axString(el, kAXDescriptionAttribute) ?? "")
                if !label.isEmpty { return (label, axFrame(el)) }
            }
        }
        return nil
    }

    private func axFrame(_ el: AXUIElement) -> CGRect {
        var posValue: CFTypeRef?, sizeValue: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeValue)
        if let posValue { AXValueGetValue(posValue as! AXValue, .cgPoint, &pos) }
        if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) }
        return CGRect(origin: pos, size: size)
    }

    private func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
        return v as? [AXUIElement] ?? []
    }

    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        return v as? String
    }

    // MARK: - Moving "»" to the front

    /// ⌘-drags "»" in front of the leftmost menu bar icon, so all icons between it and "|" are
    /// the hidden section. Item positions are owned by MenuBarAgent and can't be set through
    /// an API, so this simulates the drag (needs Accessibility) and puts the cursor back.
    @objc private func moveDividerToFront() {
        guard !collapsed, AXIsProcessTrusted(),
              let screen = divider.button?.window?.screen,
              let dividerFrame = divider.button?.window?.frame,
              let notchRight = screen.auxiliaryTopRightArea?.minX ?? Optional(screen.frame.minX),
              let leftmost = menuBarItemFrames().filter({ $0.minX >= notchRight }).min(by: { $0.minX < $1.minX })
        else { return }
        guard dividerFrame.minX > leftmost.minX + 2 else { return } // already in front

        // AppKit and CoreGraphics share the x axis; y is the menu bar's vertical center.
        let y = screen.frame.maxY - (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) + leftmost.midY
        let from = CGPoint(x: dividerFrame.midX, y: y)
        let to = CGPoint(x: leftmost.minX + 3, y: y)
        let restore = CGEvent(source: nil)?.location
        log("moving » from x=\(Int(from.x)) to x=\(Int(to.x))")

        func post(_ type: CGEventType, _ point: CGPoint) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        post(.leftMouseDown, from)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) { post(.leftMouseDragged, p) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(steps + 3)) {
            post(.leftMouseUp, to)
            if let restore { CGWarpMouseCursorPosition(restore) }
        }
    }

    /// Frames (global top-left coordinates) of all status items MenuBarAgent is drawing.
    private func menuBarItemFrames() -> [CGRect] {
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.executableURL?.lastPathComponent == "MenuBarAgent"
        }) else { return [] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        return axChildren(app)
            .filter { axString($0, kAXRoleAttribute) == kAXWindowRole }
            .flatMap { axChildren($0) }
            .map { axFrame($0) }
            .filter { $0.width > 0 && $0.width < 200 }
    }

    // MARK: - Items

    private func configureButtons() {
        for item in [toggle!, divider!] {
            item.button?.target = self
            item.button?.action = #selector(itemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // "»" (a double chevron mirroring macOS's own "«"/"»") collapses; "|" marks the right
        // edge of the hidden section. Collapsed, both are empty fillers.
        // While macOS animates the expand, the glyphs are drawn transparent: they already take
        // their final width (so nothing shifts when they appear) but don't slide in visibly.
        divider.button?.title = ""
        divider.button?.image = collapsed ? nil : (glyphsHidden ? clearCollapseImage : collapseImage)
        divider.button?.appearsDisabled = false
        toggle.button?.image = nil
        toggle.button?.attributedTitle = NSAttributedString(string: collapsed ? "" : "|", attributes: [
            .foregroundColor: glyphsHidden ? NSColor.clear : NSColor.tertiaryLabelColor,
            .font: NSFont.menuBarFont(ofSize: 0),
        ])
        toggle.button?.appearsDisabled = true
        if !collapsed {
            toggle.length = NSStatusItem.variableLength
            if divider.length != NSStatusItem.variableLength { divider.length = NSStatusItem.variableLength }
        }
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
        menu.addItem(withTitle: "Hide/Show Icons  ⌃⌥⌘H", action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move » to the Far Left", action: #selector(moveDividerToFront), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit IconCloak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    // MARK: - Development controls

    #if ICONCLOAK_DEV
    /// Remote control for automated testing, compiled only into dev builds
    /// (`scripts/build-app.sh --dev`). Any local process can post these notifications, and
    /// IconCloak holds the Accessibility permission, so this must never ship in a release.
    /// Usage: `build/ctl collapse|expand|log|axdump|pressoverflow|click:x,y|cmddrag:x1,x2`.
    private func installDevControls() {
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.iconcloak.cmd"), object: nil, queue: .main) { [weak self] note in
            guard let self, let cmd = note.object as? String else { return }
            switch cmd {
            case "collapse": self.setCollapsed(true)
            case "expand": self.setCollapsed(false)
            case "log": self.logState(label: "manual")
            case "axdump": self.dumpMenuBarAgent(press: false)
            case "pressoverflow": self.dumpMenuBarAgent(press: true)
            case let c where c.hasPrefix("cmddrag:"):
                // "cmddrag:x1,x2" — ⌘-drags along the menu bar from x1 to x2.
                let p = c.dropFirst(8).split(separator: ",").compactMap { Double($0) }
                guard p.count == 2 else { return }
                func post(_ type: CGEventType, _ x: Double) {
                    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: 19), mouseButton: .left)
                    e?.flags = .maskCommand
                    e?.post(tap: .cghidEventTap)
                }
                post(.leftMouseDown, p[0])
                for i in 1...12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) { post(.leftMouseDragged, p[0] + (p[1] - p[0]) * Double(i) / 12) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { post(.leftMouseUp, p[1]) }
            case let c where c.hasPrefix("click:"):
                // "click:x,y" in global top-left coordinates — simulates a real mouse click.
                let p = c.dropFirst(6).split(separator: ",").compactMap { Double($0) }
                guard p.count == 2 else { return }
                let point = CGPoint(x: p[0], y: p[1])
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                self.log("clicked \(point)")
            default: break
            }
        }
    }

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
    #endif

    // MARK: - Diagnostics

    @objc private func toggleFromMenu() { setCollapsed(!collapsed) }
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
