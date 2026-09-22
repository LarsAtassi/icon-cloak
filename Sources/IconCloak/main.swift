import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// IconCloak — hides menu bar icons on macOS 27.
//
// Expanded:   [app menus]  (notch)  [» divider] [hidden icons] [| toggle] [visible icons]
// Collapsed:  [app menus][filler] (notch) [toggle filler] [«] [visible icons]
//
// "»" collapses, "|" marks the boundary: everything left of it gets hidden. macOS 27 places
// status items right of the notch first, then left of it (filling from the notch outwards),
// and only then in its own "«" overflow. Displays without a notch behave as if they had a
// zero-width notch in the middle. When collapsing, the toggle fills the free space right of
// the notch, and a third, otherwise hidden item directly left of it (the filler) fills the
// space left of the notch up to the app menus — so the icons left of it fit nowhere and end
// up in the overflow. The filler is resized whenever the frontmost app or display changes,
// which needs the Accessibility permission to read where the app menus end.
// See docs/how-it-works.md for the details.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Label {
        static let divider = "IconCloak: hide icons"
        static let toggle = "IconCloak: boundary"
        static let filler = "IconCloak: filler"
    }
    private var toggle: NSStatusItem!   // "|": the boundary; right filler while collapsed
    private var divider: NSStatusItem!  // "»": the collapse button, far left
    /// Left filler while collapsed. Must sit directly left of the toggle: the space left of the
    /// notch fills from the notch outwards, so it has to come before the icons it pushes out.
    /// Hidden while expanded (a zero-length item would still leave a gap).
    private var filler: NSStatusItem!
    /// True while IconCloak rearranges its items with simulated ⌘-drags.
    private var arranging = false
    private var collapsed = false

    /// Status item windows are this much wider than `length` (button padding).
    private let itemPadding: CGFloat = 16
    private let margin: CGFloat = 8

    /// Distance from the toggle's right edge to its screen's right edge, measured while expanded.
    /// Status items sit at the same distance from the right on every display's menu bar, so this
    /// locates the toggle on any display.
    private var toggleRightInset: CGFloat?
    /// Every display has its own menu bar, but an item has one width for all of them, so the
    /// fillers are sized for the display the user is on (the one with the pointer).
    private var fillerScreen: NSScreen?
    private var screenWatch: Timer?

    /// Watches macOS's overflow button while collapsed: clicking it ("«" → "»") expands IconCloak.
    private var overflowWatch: Timer?
    private var overflowBaseline: String?
    private var glyphsHidden = false
    /// Draw our own "«" at the right end of the toggle filler, next to the visible icons. Only
    /// needed when macOS's "«" ends up far from them (on displays without a notch it sits near
    /// the center, where apps drawing a fake notch can even cover it).
    private var ownExpandButton = false
    private let expandImage: NSImage? = {
        let image = NSImage(systemSymbolName: "chevron.left.2", accessibilityDescription: "Show menu bar icons")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        return image
    }()
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
    /// Frames of macOS's overflow buttons, one per display (global top-left coords), refreshed
    /// while collapsed.
    private var overflowButtonFrames: [CGRect] = []
    private var clickTap: CFMachPort?
    private var swallowNextMouseUp = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 27 decides the initial order itself, so roles are assigned by position
        // (see ensureOrder): the left item is the divider, the right one the toggle.
        toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "IconCloak.toggle"
        divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider.autosaveName = "IconCloak.divider"
        filler = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        filler.autosaveName = "IconCloak.filler"
        configureButtons()
        registerHotKey()
        // Frames are only valid once macOS has laid the items out.
        toggle.isVisible = true
        divider.isVisible = true
        filler.isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.ensureOrder()
            self.rolesReady = true
            self.scheduleAutoHide()
            self.arrangeItems()
        }
        // Keep the arrangement after the user ⌘-drags something in the menu bar: "»" back in
        // front, the filler next to "|" (global mouse monitors need Accessibility).
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, !self.collapsed, event.modifierFlags.contains(.command),
                  let screen = self.screenWithPointer(), NSEvent.mouseLocation.y > screen.frame.maxY - 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.arrangeItems() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateFillers() }
        // Displays connected, disconnected or rearranged, or their resolution changed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.log("screen parameters changed: \(NSScreen.screens.map { "\($0.localizedName) \($0.frame)" })")
            self.fillerScreen = nil
            self.autoHideSuspended = false
            self.updateFillers()
        }

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
                self.updateFillers()
            }
        }

        #if ICONCLOAK_DEV
        installDevControls()
        #endif
    }

    // MARK: - Collapse / expand

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(on: [toggle, divider, filler].first { $0.button === sender } ?? toggle)
        } else if sender === toggle.button && !collapsed {
            return // "|" is only a boundary marker
        } else {
            setCollapsed(!collapsed)
        }
    }

    private func setCollapsed(_ value: Bool) {
        guard value != collapsed, rolesReady, !arranging else { return }
        if value, let screen = screenWithPointer(), let frame = itemFrame(Label.toggle, on: screen) {
            toggleRightInset = screen.frame.maxX - frame.maxX
        } else if value, let frame = toggle.button?.window?.frame,
                  let screen = NSScreen.screens.first(where: { $0.frame.minX <= frame.midX && frame.midX < $0.frame.maxX }) {
            toggleRightInset = screen.frame.maxX - frame.maxX
        }
        collapsed = value
        if value {
            fillerScreen = nil
            filler.isVisible = true
            updateFillers()
            startScreenWatch()
            verifyCollapse()
        } else {
            screenWatch?.invalidate()
            ownExpandButton = false
            filler.length = NSStatusItem.variableLength
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
        value ? autoHideTimer?.invalidate() : scheduleAutoHide()
        log("---- \(value ? "COLLAPSE" : "EXPAND") ----")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.logState(label: value ? "collapsed" : "expanded") }
    }

    // MARK: - Auto-hide

    private static let autoHidePresets = [5, 10, 15, 30, 60]
    private var autoHideTimer: Timer?
    /// Set when a collapse fails, so auto-hide doesn't retry every few seconds. Cleared by the
    /// next successful collapse or a display change.
    private var autoHideSuspended = false

    /// Seconds after expanding until IconCloak collapses again; nil when auto-hide is off.
    private var autoHideDelay: Int? {
        get {
            let seconds = UserDefaults.standard.integer(forKey: "autoHideDelay")
            return seconds > 0 ? seconds : nil
        }
        set {
            UserDefaults.standard.set(newValue ?? 0, forKey: "autoHideDelay")
            log("auto-hide: \(newValue.map { "\($0) s" } ?? "off")")
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide(after seconds: TimeInterval? = nil) {
        autoHideTimer?.invalidate()
        guard let delay = autoHideDelay, !collapsed, !autoHideSuspended else { return }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: seconds ?? TimeInterval(delay), repeats: false) { [weak self] _ in
            guard let self, !self.collapsed else { return }
            // Don't pull icons away while the user is using them: wait until the pointer has
            // left the menu bar and no menu is open.
            if self.userIsInMenuBar() {
                self.scheduleAutoHide(after: 1)
            } else {
                self.setCollapsed(true)
            }
        }
    }

    private func userIsInMenuBar() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 40)
            if mouse.y >= screen.frame.maxY - menuBarHeight { return true }
        }
        // An open menu (e.g. from a hidden icon) is a pop-up menu window of its app.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    @objc private func pickAutoHide(_ sender: NSMenuItem) {
        autoHideDelay = sender.tag > 0 ? sender.tag : nil
    }

    @objc private func pickCustomAutoHide() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.integerValue = autoHideDelay ?? 20
        let alert = NSAlert()
        alert.messageText = "Auto-Hide"
        alert.informativeText = "Hide icons again after how many seconds? (1–3600)"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let seconds = field.integerValue
        guard (1...3600).contains(seconds) else { NSSound.beep(); return }
        autoHideDelay = seconds
    }

    private func autoHideMenu() -> NSMenu {
        let menu = NSMenu()
        let current = autoHideDelay
        let off = menu.addItem(withTitle: "Off", action: #selector(pickAutoHide(_:)), keyEquivalent: "")
        off.target = self
        off.tag = 0
        off.state = current == nil ? .on : .off
        menu.addItem(.separator())
        for seconds in Self.autoHidePresets {
            let item = menu.addItem(withTitle: "After \(seconds) Seconds", action: #selector(pickAutoHide(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = current == seconds ? .on : .off
        }
        let isCustom = current.map { !Self.autoHidePresets.contains($0) } ?? false
        let custom = menu.addItem(withTitle: isCustom ? "Custom (\(current!) Seconds)…" : "Custom…",
                                  action: #selector(pickCustomAutoHide), keyEquivalent: "")
        custom.target = self
        custom.state = isCustom ? .on : .off
        return menu
    }

    // MARK: - Fillers

    /// Sizes the fillers for the display the pointer is on: the toggle fills the space right of
    /// the notch and the filler (pushed to the left side) the space between the app menus and
    /// the notch, so the icons left of them fit nowhere and go into macOS's overflow.
    ///
    /// Displays without a notch behave as if they had a zero-width notch in the middle: status
    /// items fill the right half first, then continue left of the center, and a single item can
    /// be at most half the display wide (a wider one is dropped). So the center is used as the notch.
    private func updateFillers() {
        guard collapsed else { return }
        guard let inset = toggleRightInset, let screen = screenWithPointer() else {
            log("fillers: no toggle position (inset=\(String(describing: toggleRightInset)), frame=\(String(describing: toggle.button?.window?.frame)))")
            return
        }
        guard let menusWidth = appMenusWidth() else {
            log("fillers: can't read app menus (accessibility not granted?)")
            return
        }
        let toggleRight = screen.frame.maxX - inset
        let menusEnd = screen.frame.minX + menusWidth
        let notchLeft = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX
        let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        let toggleLength = toggleRight - notchRight - margin - itemPadding
        let fillerLength = notchLeft - menusEnd - margin - itemPadding
        fillerScreen = screen
        if toggle.length != max(toggleLength, 0) {
            toggle.length = max(toggleLength, 0)
            if ownExpandButton { configureButtons() } // the "«" image is as wide as the filler
        }
        if filler.length != max(fillerLength, 0) { filler.length = max(fillerLength, 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateOwnExpandButton() }
        log("fillers for \(screen.localizedName) \(Int(screen.frame.width)) pt\(screen.auxiliaryTopLeftArea != nil ? ", notch" : ""): "
            + "menus end at \(Int(menusWidth)), toggle \(Int(toggleLength)), filler \(Int(fillerLength))")
    }

    /// While collapsed, re-size the fillers when the pointer moves to another display.
    private func startScreenWatch() {
        screenWatch?.invalidate()
        screenWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.collapsed, let screen = self.screenWithPointer(), screen != self.fillerScreen else { return }
            self.updateFillers()
        }
    }

    /// Safety net: if macOS didn't move anything into its overflow (e.g. a filler didn't fit and
    /// was dropped), there'd be no "«" to click and no "»" either — so expand again.
    private func verifyCollapse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.collapsed, AXIsProcessTrusted(), let screen = self.screenWithPointer() else { return }
            let onScreen = self.overflowButtons().contains {
                $0.frame.midX >= screen.frame.minX && $0.frame.midX < screen.frame.maxX
            }
            guard !onScreen else {
                self.autoHideSuspended = false
                self.updateOwnExpandButton()
                return
            }
            self.log("collapse failed (no overflow button): expanding again, auto-hide paused")
            self.autoHideSuspended = true
            self.setCollapsed(false)
        }
    }

    /// Shows our own "«" when macOS's is not right next to the visible icons on this display.
    private func updateOwnExpandButton() {
        guard collapsed, let inset = toggleRightInset, let screen = screenWithPointer() else { return }
        let toggleRight = screen.frame.maxX - inset
        let system = overflowButtons().map(\.frame).filter { $0.midX >= screen.frame.minX && $0.midX < screen.frame.maxX }
        let adjacent = system.contains { toggleRight - $0.maxX < 48 && toggleRight - $0.maxX > -48 }
        guard ownExpandButton == adjacent else { return } // already right
        ownExpandButton = !adjacent
        log("own « button: \(ownExpandButton ? "shown" : "hidden") (macOS's at \(system.map { Int($0.minX) }), toggle ends at \(Int(toggleRight)))")
        configureButtons()
    }

    private func screenWithPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Width of the frontmost app's menus (Apple menu to the last menu), via Accessibility.
    /// The same on every display's menu bar.
    private func appMenusWidth() -> CGFloat? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.menuBarOwningApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBar) == .success else { return nil }
        let frames = axChildren(menuBar as! AXUIElement).map { axFrame($0) }.filter { $0.width > 0 }
        guard let first = frames.min(by: { $0.minX < $1.minX }), let last = frames.max(by: { $0.maxX < $1.maxX }) else { return nil }
        // The Apple menu starts at its display's left edge.
        let displayLeft = NSScreen.screens.first { $0.frame.minX <= first.midX && first.midX < $0.frame.maxX }?.frame.minX ?? first.minX
        return last.maxX - displayLeft
    }

    // MARK: - Overflow button

    /// Clicking macOS's "«" re-lays out the menu bar and shows overflow icons left of the notch,
    /// where our left filler sits. Instead we treat the click as "expand". The button's label
    /// changes when clicked; compare against the label seen after collapsing (locale-independent).
    private func startOverflowWatch() {
        overflowBaseline = nil
        overflowWatch?.invalidate()
        overflowWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.collapsed else { return }
            let buttons = self.overflowButtons()
            self.overflowButtonFrames = buttons.map(\.frame)
            guard let first = buttons.first else { return }
            guard let baseline = self.overflowBaseline else { self.overflowBaseline = first.label; return }
            if let label = buttons.first(where: { $0.label != baseline })?.label {
                self.log("overflow button changed (\(baseline) → \(label)): expanding")
                self.setCollapsed(false)
            }
        }
    }

    private func stopOverflowWatch() {
        overflowWatch?.invalidate()
        overflowWatch = nil
        overflowButtonFrames = []
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
            if type == .leftMouseDown, me.collapsed,
               me.overflowButtonFrames.contains(where: { $0.insetBy(dx: -4, dy: 0).contains(event.location) }) {
                me.swallowNextMouseUp = true
                DispatchQueue.main.async { me.setCollapsed(false) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let clickTap else { log("click tap unavailable (accessibility?)"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, clickTap, 0), .commonModes)
    }

    /// macOS's overflow buttons, one per display's menu bar: the AXButtons directly inside
    /// MenuBarAgent's windows (status items are nested one level deeper). Label and frame
    /// (global top-left coordinates).
    private func overflowButtons() -> [(label: String, frame: CGRect)] {
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.executableURL?.lastPathComponent == "MenuBarAgent"
        }) else { return [] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        var result: [(label: String, frame: CGRect)] = []
        for window in axChildren(app) where axString(window, kAXRoleAttribute) == kAXWindowRole {
            for el in axChildren(window) where axString(el, kAXRoleAttribute) == kAXButtonRole {
                let label = (axString(el, kAXTitleAttribute) ?? "") + (axString(el, kAXDescriptionAttribute) ?? "")
                if !label.isEmpty { result.append((label, axFrame(el))) }
            }
        }
        return result
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

    // MARK: - Arranging the items

    /// Item positions are owned by MenuBarAgent and can't be set through an API, so IconCloak
    /// arranges its items with simulated ⌘-drags (needs Accessibility) and puts the cursor back:
    /// the filler directly left of "|", then "»" in front of the leftmost icon.
    @objc private func arrangeItems() {
        guard !collapsed, !arranging, AXIsProcessTrusted(), let screen = screenWithPointer() else { return }
        arranging = true
        filler.length = NSStatusItem.variableLength
        filler.isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let done = { [self] in
                arranging = false
                configureButtons() // hides the filler again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.moveDividerToFront() }
            }
            guard let f = itemFrame(Label.filler, on: screen), let t = itemFrame(Label.toggle, on: screen),
                  abs(f.maxX - t.minX) > 3 else { return done() }
            // Dropping onto the left part of "|" inserts before it; approaching from the left,
            // stop just short of it.
            let target = f.midX < t.minX ? t.minX - 4 : t.minX + 3
            log("moving filler next to | (x=\(Int(f.midX)) → \(Int(target)))")
            drag(from: f.midX, to: target, on: screen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
            }
        }
    }

    /// ⌘-drags "»" in front of the leftmost menu bar icon, so all icons between it and "|" are
    /// the hidden section.
    @objc private func moveDividerToFront() {
        guard !collapsed, !arranging, AXIsProcessTrusted(), let screen = screenWithPointer(),
              let dividerFrame = itemFrame(Label.divider, on: screen)
        else { return }
        // Only this display's menu bar (every display has one), right of the notch if there is one.
        let start = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
        guard let leftmost = menuBarItemFrames()
            .filter({ $0.minX >= start && $0.maxX <= screen.frame.maxX })
            .min(by: { $0.minX < $1.minX })
        else { return }
        guard dividerFrame.minX > leftmost.minX + 2 else { return } // already in front
        log("moving » from x=\(Int(dividerFrame.midX)) to x=\(Int(leftmost.minX + 3))")
        drag(from: dividerFrame.midX, to: leftmost.minX + 3, on: screen)
    }

    /// Where one of IconCloak's items actually is on `screen`'s menu bar (global top-left
    /// coordinates), found by its accessibility label in MenuBarAgent's tree.
    private func itemFrame(_ label: String, on screen: NSScreen) -> CGRect? {
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.executableURL?.lastPathComponent == "MenuBarAgent"
        }) else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        for window in axChildren(app) where axString(window, kAXRoleAttribute) == kAXWindowRole {
            for container in axChildren(window) {
                let frame = axFrame(container)
                guard frame.midX >= screen.frame.minX, frame.midX < screen.frame.maxX else { continue }
                let labels = axChildren(container).map {
                    (axString($0, kAXDescriptionAttribute) ?? "") + (axString($0, kAXTitleAttribute) ?? "")
                }
                if labels.contains(where: { $0.contains(label) }) { return frame }
            }
        }
        return nil
    }

    /// Simulates a ⌘-drag along the menu bar of `screen`, then restores the cursor.
    private func drag(from x0: CGFloat, to x1: CGFloat, on screen: NSScreen?, completion: (() -> Void)? = nil) {
        guard let screen, let primary = NSScreen.screens.first else { completion?(); return }
        // CoreGraphics uses top-left coordinates from the primary display; x is shared with AppKit.
        let y = primary.frame.maxY - screen.frame.maxY + 12
        let restore = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, _ x: CGFloat) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        post(.leftMouseDown, x0)
        let steps = 12
        for i in 1...steps {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) { post(.leftMouseDragged, x) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(steps + 3)) {
            post(.leftMouseUp, x1)
            if let restore { CGWarpMouseCursorPosition(restore) }
            completion?()
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
        // Labels make the items findable in MenuBarAgent's accessibility tree, which (unlike the
        // items' own window frames) reflects where they actually are.
        toggle.button?.setAccessibilityLabel(Label.toggle)
        divider.button?.setAccessibilityLabel(Label.divider)
        filler.button?.setAccessibilityLabel(Label.filler)
        for item in [toggle!, divider!, filler!] {
            item.button?.target = self
            item.button?.action = #selector(itemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // "»" (a double chevron mirroring macOS's own "«"/"»") collapses; "|" marks the right
        // edge of the hidden section. Collapsed, "|" and the filler are empty fillers, and "»"
        // goes into the overflow with the hidden icons.
        // While macOS animates the expand, the glyphs are drawn transparent: they already take
        // their final width (so nothing shifts when they appear) but don't slide in visibly.
        divider.button?.title = ""
        divider.button?.image = collapsed ? nil : (glyphsHidden ? clearCollapseImage : collapseImage)
        divider.button?.appearsDisabled = false
        toggle.button?.image = nil
        if collapsed && ownExpandButton, let expandImage {
            // macOS centers a status item's content, so draw "«" at the right edge of an image
            // as wide as the filler: it then sits next to the visible icons.
            let width = max(toggle.length, expandImage.size.width)
            let image = NSImage(size: NSSize(width: width, height: expandImage.size.height), flipped: false) { rect in
                expandImage.draw(in: NSRect(x: rect.maxX - expandImage.size.width - 2, y: 0,
                                            width: expandImage.size.width, height: expandImage.size.height))
                return true
            }
            image.isTemplate = true
            toggle.button?.attributedTitle = NSAttributedString(string: "")
            toggle.button?.image = image
            toggle.button?.appearsDisabled = false
        } else {
            toggle.button?.image = nil
            toggle.button?.attributedTitle = NSAttributedString(string: collapsed ? "" : "|", attributes: [
                .foregroundColor: glyphsHidden ? NSColor.clear : NSColor.tertiaryLabelColor,
                .font: NSFont.menuBarFont(ofSize: 0),
            ])
            toggle.button?.appearsDisabled = true
        }
        filler.button?.title = ""
        filler.button?.image = nil
        if !collapsed {
            toggle.length = NSStatusItem.variableLength
            if divider.length != NSStatusItem.variableLength { divider.length = NSStatusItem.variableLength }
            if rolesReady && !arranging { filler.isVisible = false }
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
        menu.addItem(withTitle: "Move » to the Far Left", action: #selector(arrangeItems), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let autoHide = menu.addItem(withTitle: "Auto-Hide", action: nil, keyEquivalent: "")
        autoHide.submenu = autoHideMenu()
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
    /// Usage: `build/ctl collapse|expand|log|axdump|pressoverflow|click:x,y|cmddrag:x1,x2|autohide:<s>`.
    private func installDevControls() {
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.iconcloak.cmd"), object: nil, queue: .main) { [weak self] note in
            guard let self, let cmd = note.object as? String else { return }
            switch cmd {
            case let c where c.hasPrefix("autohide:"): self.autoHideDelay = Int(c.dropFirst(9)).flatMap { $0 > 0 ? $0 : nil }
            case let c where c.hasPrefix("len:"):
                // "len:toggle,N" / "len:divider,N" — sets an item's length directly (N < 0: variable).
                let parts = c.dropFirst(4).split(separator: ",")
                guard parts.count == 2, let n = Double(parts[1]) else { return }
                let item = parts[0] == "toggle" ? self.toggle! : parts[0] == "filler" ? self.filler! : self.divider!
                item.length = n < 0 ? NSStatusItem.variableLength : CGFloat(n)
                self.log("len \(parts[0]) = \(n)")
            case "front": self.moveDividerToFront()
            case "arrange": self.arrangeItems()
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

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            log("launch at login: \(service.status == .enabled)")
        } catch {
            log("launch at login failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can also add IconCloak in System Settings → General → Login Items."
            alert.runModal()
        }
    }
    @objc private func openLog() { NSWorkspace.shared.open(logURL) }

    private func logState(label: String) {
        let screen = toggle.button?.window?.screen
        log("[\(label)] notchLeft=\(screen?.auxiliaryTopLeftArea?.maxX ?? -1) notchRight=\(screen?.auxiliaryTopRightArea?.minX ?? -1) frontmost=\(NSWorkspace.shared.menuBarOwningApplication?.localizedName ?? "?")")
        log("[\(label)] divider.length=\(divider.length) window=\(divider.button?.window?.frame ?? .zero)")
        log("[\(label)] filler.length=\(filler.length) visible=\(filler.isVisible) window=\(filler.button?.window?.frame ?? .zero)")
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
