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
    private let overflowButtonRoom: CGFloat = 24

    /// Distance from the toggle's right edge to its screen's right edge, measured while expanded.
    /// Status items sit at the same distance from the right on every display's menu bar, so this
    /// locates the toggle on any display.
    private var toggleRightInset: CGFloat?
    /// Every display has its own menu bar, but an item has one width for all of them, so the
    /// fillers are sized for the display the user is on (the one with the pointer).
    private var fillerScreen: NSScreen?
    private var screenWatch: Timer?
    private var missingToggleChecks = 0
    /// Room right of "|" that only exists while collapsed: macOS moves items it never hides
    /// (the microphone/camera pill, a recording indicator) next to the visible icons then.
    /// Learned while collapsed and reused on the next hide.
    private var collapsedExtra: CGFloat = 0
    private var expandedInset: CGFloat?
    private var shrinkSteps = 0
    private var lastMeasuredInset: CGFloat?
    private var misplacedFillerChecks = 0
    private var ownDragUntil = Date.distantPast // IconCloak's own simulated drag is in progress
    private var repairedFiller = false      // once per hide
    private var shrunkSinceResize = false
    private var regrowCycles = 0            // shrink → grow back cycles in this hide
    /// When the fillers were last resized; the menu bar takes a moment to settle afterwards.
    private var lastFillerResize = Date.distantPast
    private var hoverReleased = false

    /// Watches macOS's overflow button while collapsed: clicking it ("«" → "»") expands IconCloak.
    private var overflowWatch: Timer?
    private var overflowBaseline: String?
    private var glyphsHidden = false
    /// Draw our own "«" at the right end of the toggle filler, next to the visible icons. Only
    /// needed when macOS's "«" ends up far from them (on displays without a notch it sits near
    /// the center, where apps drawing a fake notch can even cover it).
    private var ownExpandButton = false
    private var ownExpandPending = 0
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
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var swallowNextMouseUp = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two instances would fight over the menu bar (e.g. a second copy started from another
        // folder), so only the first one keeps running.
        let me = NSRunningApplication.current
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != me }) {
            log("another IconCloak is already running, quitting \(Bundle.main.bundlePath)")
            NSApp.terminate(nil)
            return
        }
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
        let settings = SettingsModel.shared
        settings.onAutoHideChanged = { [weak self] in
            self?.autoHideSuspended = false
            self?.scheduleAutoHide()
            self?.log("auto-hide: \(self?.autoHideDelay.map { "\($0) s" } ?? "off")")
        }
        settings.onShortcutChanged = { [weak self] in self?.registerHotKey() }
        settings.onArrangeItems = { [weak self] in self?.arrangeItems() }
        settings.onOpenLog = { [weak self] in self?.openLog() }
        settings.onDisplayModeChanged = { [weak self] in
            guard let self else { return }
            self.log("hide on main display only: \(UserDefaults.standard.bool(forKey: "hideOnMainDisplayOnly"))")
            self.fillerScreen = nil
            self.autoHideSuspended = false
            self.updateFillers()
        }
        settings.logMessage = { [weak self] in self?.log($0) }
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
            // Not IconCloak's own simulated drags: reacting to them would loop.
            guard let self, Date() >= self.ownDragUntil,
                  !self.collapsed, event.modifierFlags.contains(.command),
                  let screen = self.screenWithPointer(), NSEvent.mouseLocation.y > screen.frame.maxY - 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.arrangeItems() }
        }

        // didLaunchApplicationNotification skips apps without a Dock icon, which are most apps
        // that add menu bar icons, so watch the list of running apps instead.
        launchWatch = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let apps = change.newValue ?? []
            DispatchQueue.main.async { apps.forEach { self?.appLaunched($0) } }
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
        // While collapsed, the fillers cover most of the menu bar (even around the notch). Only
        // our own "«" at the right end of the toggle filler reacts; the rest is dead space.
        if collapsed && sender !== divider.button && !clickIsOnOwnExpandButton() { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(on: [toggle, divider, filler].first { $0.button === sender } ?? toggle)
        } else if sender === toggle.button && !collapsed {
            return // "|" is only a boundary marker
        } else {
            setCollapsed(!collapsed)
        }
    }

    /// Whether the current click is on the "«" drawn at the right end of the toggle filler.
    private func clickIsOnOwnExpandButton() -> Bool {
        guard ownExpandButton, let inset = toggleRightInset, let screen = screenWithPointer() else { return false }
        let toggleRight = screen.frame.maxX - inset
        let x = NSEvent.mouseLocation.x
        return x >= toggleRight - 36 && x <= toggleRight + 4
    }

    private func setCollapsed(_ value: Bool) {
        guard value != collapsed, rolesReady, !arranging else { return }
        if value, !hoverReleased, AXIsProcessTrusted(), foreignTooltipVisible() {
            hoverReleased = true
            releaseHover(reason: "before hiding")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.setCollapsed(true) }
            return
        }
        hoverReleased = false
        if value, let screen = targetScreen(), let frame = itemFrame(Label.toggle, on: screen) {
            expandedInset = screen.frame.maxX - frame.maxX
            toggleRightInset = screen.frame.maxX - frame.maxX + collapsedExtra
            shrinkSteps = 0
            regrowCycles = 0
            shrunkSinceResize = false
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
            ownExpandPending = 0
            updateCovers()
            filler.length = NSStatusItem.variableLength
        }
        if value {
            glyphsHidden = false
            configureButtons()
        } else {
            // macOS animates our items shrinking from filler width (~300 ms); revealing "»" and
            // "|" only afterwards keeps them from sliding in from the far left. A peek for a new
            // icon keeps them invisible throughout, so no "»" flashes up on the far left.
            glyphsHidden = true
            configureButtons()
            if !peeking {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                    glyphsHidden = false
                    configureButtons()
                }
            }
        }
        value ? startOverflowWatch() : stopOverflowWatch()
        if value { autoHideTimer?.invalidate() } else if !peeking { scheduleAutoHide() }
        log("---- \(value ? "COLLAPSE" : "EXPAND") ----")
        if !value && !peeking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.adoptNewStatusItems() }
        }
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
        guard let inset = toggleRightInset, let screen = targetScreen() else {
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
        // Leave room for macOS's "«": since macOS 27.2 it needs its own space next to the filler
        // instead of squeezing into it, and a filler that leaves none gets pushed aside.
        let toggleLength = toggleRight - notchRight - margin - itemPadding - overflowButtonRoom
        let fillerLength = notchLeft - menusEnd - margin - itemPadding
        fillerScreen = screen
        if toggle.length != max(toggleLength, 0) || filler.length != max(fillerLength, 0) { lastFillerResize = Date() }
        if toggle.length != max(toggleLength, 0) {
            toggle.length = max(toggleLength, 0)
            if ownExpandButton { configureButtons() } // the "«" image is as wide as the filler
        }
        if filler.length != max(fillerLength, 0) { filler.length = max(fillerLength, 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateOwnExpandButton() }
        log("fillers for \(screen.localizedName) \(Int(screen.frame.width)) pt\(screen.auxiliaryTopLeftArea != nil ? ", notch" : ""): "
            + "menus end at \(Int(menusWidth)), toggle \(Int(toggleLength)), filler \(Int(fillerLength))")
    }

    /// While collapsed, re-size the fillers when the pointer moves to another display, or when
    /// the visible icons right of "|" change width (an icon appears, disappears or shows changing
    /// text): the right filler is sized to end exactly where they begin.
    private func startScreenWatch() {
        screenWatch?.invalidate()
        missingToggleChecks = 0
        misplacedFillerChecks = 0
        lastMeasuredInset = nil
        screenWatch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.collapsed, let screen = self.targetScreen() else { return }
            if screen != self.fillerScreen { return self.updateFillers() }
            self.updateOwnExpandButton()
            guard AXIsProcessTrusted(), !self.menuBarItemFrames().isEmpty else { return }
            let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
            // In place = still on the right side of the notch. Its left end may reach under the
            // notch (macOS 27.2 allows that); pushed aside, it ends up left of the notch.
            let toggleFrame = self.itemFrame(Label.toggle, on: screen)
            // The filler must be left of "|". If it ended up right of it (e.g. after an icon was
            // dropped between them), no filler width works: re-arrange once, then hide again.
            if let fillerFrame = self.itemFrame(Label.filler, on: screen), fillerFrame.maxX > notchRight + 4,
               fillerFrame.maxX >= (toggleFrame?.maxX ?? 0) - 2 {
                self.misplacedFillerChecks += 1
                guard self.misplacedFillerChecks >= 2, !self.repairedFiller else { return }
                self.repairedFiller = true
                self.log("filler is right of |: re-arranging")
                self.setCollapsed(false)
                self.arrangeItems { self.setCollapsed(true) }
                return
            }
            self.misplacedFillerChecks = 0
            if let frame = toggleFrame, frame.maxX > notchRight + 4 {
                // Its right edge shows exactly how much sits right of it.
                self.missingToggleChecks = 0
                self.shrinkSteps = 0
                self.repairedFiller = false
                let inset = screen.frame.maxX - frame.maxX
                // Only act on a measurement seen twice in a row: while macOS animates a change,
                // the filler passes through in-between positions.
                defer { self.lastMeasuredInset = inset }
                guard let last = self.lastMeasuredInset, abs(inset - last) <= 2 else { return }
                if let old = self.toggleRightInset, abs(inset - old) > 2 {
                    // Growing back after shrinking, over and over, means the measured room doesn't
                    // fit after all: stop instead of cycling forever.
                    if self.shrunkSinceResize {
                        self.regrowCycles += 1
                        if self.regrowCycles >= 3 {
                            self.log("filler keeps getting pushed aside: showing the icons, auto-hide paused")
                            self.autoHideSuspended = true
                            self.setCollapsed(false)
                            return
                        }
                    }
                    self.shrunkSinceResize = false
                    self.log("room right of | changed (\(Int(old)) → \(Int(inset)) pt): resizing fillers")
                    self.toggleRightInset = inset
                    if let expanded = self.expandedInset { self.collapsedExtra = max(0, inset - expanded) }
                    self.fillerScreen = nil
                    self.updateFillers()
                }
            } else {
                // Pushed aside: more sits right of "|" than measured (visible icons grew, or macOS
                // added an item it never hides). Shrink the filler step by step until it fits again;
                // once it does, the branch above measures the exact room.
                self.missingToggleChecks += 1
                guard self.missingToggleChecks >= 2 else { return }
                self.missingToggleChecks = 0
                self.shrinkSteps += 1
                guard self.shrinkSteps <= 6, let inset = self.toggleRightInset else {
                    self.log("right filler doesn't fit even after shrinking: showing the icons, auto-hide paused")
                    self.autoHideSuspended = true
                    self.setCollapsed(false)
                    return
                }
                self.shrunkSinceResize = true
                self.log("right filler pushed aside: shrinking it (step \(self.shrinkSteps))")
                // Growing steps (32, 64, 128 … pt) settle a large jump quickly; if that overshoots,
                // the in-place branch measures the exact room and grows the filler back.
                self.toggleRightInset = inset + min(32 * pow(2, CGFloat(self.shrinkSteps - 1)), 256)
                self.fillerScreen = nil
                self.updateFillers()
            }
        }
    }

    /// Safety net: if macOS didn't move anything into its overflow (e.g. a filler didn't fit and
    /// was dropped), there'd be no "«" to click and no "»" either — so expand again.
    private func verifyCollapse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.collapsed, AXIsProcessTrusted(), let screen = self.targetScreen() else { return }
            let onScreen = self.overflowButtons().contains {
                $0.frame.midX >= screen.frame.minX && $0.frame.midX < screen.frame.maxX
            }
            // If MenuBarAgent's accessibility tree can't be read at all (it sometimes gets stuck
            // until it's restarted), the result can't be checked, so don't treat it as a failure.
            guard !self.menuBarItemFrames().isEmpty else {
                self.log("can't read the menu bar layout (MenuBarAgent accessibility), skipping the check")
                return
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

    /// Without a notch, macOS puts its "«" near the middle of the menu bar, far from the visible
    /// icons. Then IconCloak draws its own "«" next to them and covers macOS's with a small window
    /// (clicks still reach it and are caught by the click tap).
    /// Shows our own "«" (and covers macOS's) when macOS's "«" is far from the visible icons,
    /// as on displays without a notch where it sits near the middle. On a notched display it's
    /// usually right next to them, where ours would go. While macOS relays out the menu bar its
    /// "«" is briefly missing or in between, so a change only counts once it's seen on three
    /// checks in a row (called every 0.3 s while collapsed).
    private func updateOwnExpandButton() {
        guard collapsed, let inset = toggleRightInset, let screen = targetScreen() else { return }
        // Right after a resize macOS may still be moving its "«" between the fillers.
        guard Date().timeIntervalSince(lastFillerResize) > 1.5 else { ownExpandPending = 0; return }
        let toggleRight = screen.frame.maxX - inset
        let system = overflowButtons().map(\.frame).filter { $0.midX >= screen.frame.minX && $0.midX < screen.frame.maxX }
        guard !system.isEmpty else { return } // mid-relayout: keep the current state
        let wanted = system.allSatisfy { abs(toggleRight - $0.maxX) > 48 }
        guard wanted != ownExpandButton else { ownExpandPending = 0; return }
        ownExpandPending += 1
        guard ownExpandPending >= 3 else { return }
        ownExpandPending = 0
        ownExpandButton = wanted
        log("own « button: \(wanted ? "shown" : "hidden") on \(screen.localizedName)")
        configureButtons()
        updateCovers()
    }

    // MARK: - Covering macOS's "«"

    private var covers: [NSPanel] = []
    /// Closest to the menu bar's own background in tests (none match it exactly).
    private var coverMaterial: NSVisualEffectView.Material = .popover

    /// Keeps a cover over each of macOS's "«" buttons while collapsed. Called often (from the
    /// overflow watch), so existing covers are only moved, not rebuilt, to avoid flicker.
    private func updateCovers(_ frames: [CGRect]? = nil) {
        guard collapsed, ownExpandButton, let primary = NSScreen.screens.first else {
            covers.forEach { $0.orderOut(nil) }
            covers = []
            return
        }
        // AX frames are top-left based on the primary display; AppKit windows bottom-left.
        let top = primary.frame.maxY
        var sources: [CGRect] = frames ?? overflowButtons().map(\.frame)
        if let inset = toggleRightInset, let screen = targetScreen() {
            let toggleRight = screen.frame.maxX - inset
            sources.removeAll { $0.midX >= screen.frame.minX && $0.midX < screen.frame.maxX && abs(toggleRight - $0.maxX) <= 48 }
        }
        let rects: [NSRect] = sources.map { (f: CGRect) -> NSRect in
            NSRect(x: f.minX - 2, y: top - f.maxY - 1, width: f.width + 4, height: f.height + 2)
        }
        while covers.count > rects.count { covers.removeLast().orderOut(nil) }
        while covers.count < rects.count { covers.append(makeCover()) }
        for (panel, rect) in zip(covers, rects) where panel.frame != rect || !panel.isVisible {
            panel.setFrame(rect, display: true)
            (panel.contentView as? NSVisualEffectView)?.material = coverMaterial
            // The menu bar has its own light/dark appearance (it follows the wallpaper, not the
            // system setting); our status item button reports it.
            panel.appearance = toggle.button?.effectiveAppearance
            panel.orderFrontRegardless()
        }
    }

    private func makeCover() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let effect = NSVisualEffectView()
        effect.material = coverMaterial
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect
        return panel
    }

    /// The display hiding is set up for: the main display (the one with the menu bar in the
    /// Displays arrangement) when "Only hide icons on the main display" is on, otherwise the
    /// display with the pointer.
    private func targetScreen() -> NSScreen? {
        if UserDefaults.standard.bool(forKey: "hideOnMainDisplayOnly"), let main = NSScreen.screens.first { return main }
        return screenWithPointer()
    }

    /// Another app's tooltip currently on screen (e.g. after resting the pointer on an icon).
    private func foreignTooltipVisible() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let tooltipLevel = 103 // tooltip window level on macOS 27
        return windows.contains {
            ($0[kCGWindowLayer as String] as? Int) == tooltipLevel && ($0[kCGWindowOwnerPID as String] as? pid_t) != getpid()
        }
    }

    /// A tooltip whose icon goes into the overflow stays on screen for good: the icon vanished
    /// under the pointer, so its app never got a "mouse exited" (and only real pointer movement
    /// over its visible icon clears it). So before hiding, move the pointer off the menu bar for
    /// a moment, which delivers that event, and put it back without events (so no new hover
    /// starts on an icon that's about to disappear).
    private func releaseHover(reason: String) {
        guard let location = CGEvent(source: nil)?.location else { return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: location.x, y: location.y + 150),
                mouseButton: .left)?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { CGWarpMouseCursorPosition(location) }
        log("released hover \(reason) (another app's tooltip was showing)")
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
        // Not much faster: frequent polling of MenuBarAgent's accessibility tree seems to make it
        // get stuck (it then reports itself as its own child until restarted).
        overflowWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.collapsed else { return }
            let buttons = self.overflowButtons()
            self.overflowButtonFrames = buttons.map(\.frame)
            self.updateCovers(self.overflowButtonFrames)
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
               me.overflowButtonFrames.contains(where: { $0.insetBy(dx: -4, dy: 0).contains(event.location) }),
               !me.isCoveredByAnotherApp(event.location) {
                me.swallowNextMouseUp = true
                DispatchQueue.main.async { me.setCollapsed(false) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let clickTap else { log("click tap unavailable (accessibility?)"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, clickTap, 0), .commonModes)
    }

    /// Whether another app's window sits above the menu bar at `point` (e.g. an app drawing a
    /// fake notch over the middle of the menu bar). Clicks there belong to that app.
    private func isCoveredByAnotherApp(_ point: CGPoint) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuBarLevel = Int(CGWindowLevelForKey(.statusWindow))
        let ignored: Set<String> = ["IconCloak", "MenuBarAgent", "Window Server"]
        return windows.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer > menuBarLevel,
                  let owner = window[kCGWindowOwnerName as String] as? String, !ignored.contains(owner),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
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

    // MARK: - New icons

    // macOS puts a new menu bar icon at the far left, which in IconCloak's layout is the hidden
    // section. So icons of apps IconCloak hasn't seen before are moved right of "|" (visible).
    // While collapsed, hidden icons aren't visible to accessibility at all, so a first launch of
    // an unknown app gets a short peek: expand, move its icon, collapse again.

    private var peeking = false
    private var launchWatch: NSKeyValueObservation?

    /// Apps (bundle IDs) whose menu bar icons IconCloak has seen; their placement is the user's.
    private var knownIconApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "knownIconApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "knownIconApps") }
    }
    /// Apps that were checked once and turned out to have no menu bar icon.
    private var appsWithoutIcons: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "appsWithoutIcons") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "appsWithoutIcons") }
    }

    /// Visible menu bar icons per app, from each app's own accessibility (AXExtrasMenuBar).
    /// Icons in the overflow aren't listed.
    private func statusItemsByApp() -> [(app: String, frame: CGRect)] {
        var result: [(app: String, frame: CGRect)] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != getpid(), let id = app.bundleIdentifier else { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXExtrasMenuBarAttribute as CFString, &bar) == .success, let bar else { continue }
            for item in axChildren(bar as! AXUIElement) { result.append((id, axFrame(item))) }
        }
        return result
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, app.processIdentifier != getpid(),
              !knownIconApps.contains(id), !appsWithoutIcons.contains(id) else { return }
        // Give the app a moment to create its icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            // Background-only apps (most launches) can't have menu bar icons.
            guard let self, !app.isTerminated, app.activationPolicy != .prohibited,
                  AXIsProcessTrusted(), !self.arranging, !self.peeking else { return }
            if !self.collapsed { return self.adoptNewStatusItems(checking: id) }
            self.log("peeking for a new icon of \(app.localizedName ?? id)")
            self.peeking = true
            self.setCollapsed(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.adoptNewStatusItems(checking: id) {
                    self.peeking = false
                    self.setCollapsed(true)
                }
            }
        }
    }

    /// Moves icons of apps not seen before from the hidden section to right of "|", then
    /// remembers all apps with visible icons. `checking` marks an app as icon-less if it has none.
    private func adoptNewStatusItems(checking app: String? = nil, completion: (() -> Void)? = nil) {
        guard !collapsed, !arranging, AXIsProcessTrusted(), let screen = targetScreen() else { completion?(); return }
        // Not while the user holds a mouse button (see `drag`); look again shortly.
        if NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.adoptNewStatusItems(checking: app, completion: completion) }
            return
        }
        let items = statusItemsByApp().filter { $0.frame.midX >= screen.frame.minX && $0.frame.midX < screen.frame.maxX }
        var known = knownIconApps
        if let app, !items.contains(where: { $0.app == app }) { appsWithoutIcons.insert(app) }
        // First run: everything already in the menu bar is where the user wants it.
        if known.isEmpty {
            knownIconApps = Set(items.map(\.app))
            completion?()
            return
        }
        guard let boundary = itemFrame(Label.toggle, on: screen) else { completion?(); return }
        let newHidden = items.filter { !known.contains($0.app) && $0.frame.midX < boundary.minX }
        known.formUnion(items.map(\.app))
        knownIconApps = known
        // Many unknown icons at once are an existing arrangement (e.g. settings were lost), not
        // new apps, so they're only remembered. New apps come one or two at a time.
        guard let item = newHidden.first, newHidden.count <= 3 else { completion?(); return }
        log("new icon of \(item.app) in the hidden section: moving it right of |")
        arranging = true
        // Dropping onto the right part of "|" inserts after it.
        drag(from: item.frame.midX, to: boundary.maxX - 5, on: screen) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.arranging = false
                // Several new icons are handled one at a time (positions change after a move):
                // forget the others again so the next round finds them.
                var known = self.knownIconApps
                newHidden.dropFirst().forEach { known.remove($0.app) }
                self.knownIconApps = known
                // The move can leave the (invisible) filler on the wrong side of "|", which
                // would keep the icons from hiding. Re-arranging fixes that, then looks again.
                self.arrangeItems(then: completion)
            }
        }
    }

    // MARK: - Arranging the items

    /// Item positions are owned by MenuBarAgent and can't be set through an API, so IconCloak
    /// arranges its items with simulated ⌘-drags (needs Accessibility) and puts the cursor back:
    /// the filler directly left of "|", then "»" in front of the leftmost icon.
    @objc private func arrangeItems() { arrangeItems(then: nil) }

    /// Puts the filler directly left of "|" and "»" in front, then checks for new icons.
    private func arrangeItems(then completion: (() -> Void)?) {
        guard !collapsed, !arranging, AXIsProcessTrusted(), let screen = screenWithPointer() else { completion?(); return }
        arranging = true
        filler.length = NSStatusItem.variableLength
        filler.isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let done = { [self] in
                arranging = false
                configureButtons() // hides the filler again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Wait for that drag to finish, if there is one.
                    let wait = self.moveDividerToFront() ? 1.2 : 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.adoptNewStatusItems(completion: completion) }
                }
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
    /// Returns whether a drag was started.
    @discardableResult private func moveDividerToFront() -> Bool {
        guard !collapsed, !arranging, AXIsProcessTrusted(), let screen = screenWithPointer(),
              let dividerFrame = itemFrame(Label.divider, on: screen)
        else { return false }
        // Only this display's menu bar (every display has one), right of the notch if there is one.
        let start = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
        guard let leftmost = menuBarItemFrames()
            .filter({ $0.minX >= start && $0.maxX <= screen.frame.maxX })
            .min(by: { $0.minX < $1.minX })
        else { return false }
        guard dividerFrame.minX > leftmost.minX + 2 else { return false } // already in front
        log("moving » from x=\(Int(dividerFrame.midX)) to x=\(Int(leftmost.minX + 3))")
        drag(from: dividerFrame.midX, to: leftmost.minX + 3, on: screen)
        return true
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
    ///
    /// Keep this event sequence exactly as it is. macOS reorders status items with a WindowServer
    /// window drag, and extra simulated events around the drop (a pointer move right after it,
    /// key events for ⌘) have left the WindowServer unable to track any drag, the user's
    /// included, until logout. Verify changes with one drag and the system log
    /// (WindowServer, "window drag trait gesture" must not appear).
    private func drag(from x0: CGFloat, to x1: CGFloat, on screen: NSScreen?, completion: (() -> Void)? = nil) {
        // Never while the user holds a mouse button (e.g. is dragging an icon): two drags at once
        // don't work, and this one would take the pointer away mid-drag.
        guard let screen, let primary = NSScreen.screens.first, NSEvent.pressedMouseButtons == 0 else { completion?(); return }
        ownDragUntil = Date().addingTimeInterval(2)
        // CoreGraphics uses top-left coordinates from the primary display; x is shared with AppKit.
        let y = primary.frame.maxY - screen.frame.maxY + 12
        let restore = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, _ x: CGFloat) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        // macOS 27.2 only picks an item up after a short hold, and drops it reliably only after
        // the pointer has rested at the target, so: move there, hold, drag in steps, rest, release.
        post(.mouseMoved, x0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { post(.leftMouseDown, x0) }
        let hold = 0.3, steps = 24, stepTime = 0.015
        for i in 1...steps {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold + stepTime * Double(i)) { post(.leftMouseDragged, x) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold + stepTime * Double(steps) + 0.2) {
            post(.leftMouseUp, x1)
            if let restore { CGWarpMouseCursorPosition(restore) }
            completion?()
            // The icon under the drop point never saw the pointer leave (the warp sends no
            // events), so its tooltip can appear at the restored position and stay for good.
            // Clear it, but only once macOS is completely done with the drop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.releaseStrandedHover() }
        }
    }

    /// See `drag`: a tooltip left behind by one of IconCloak's own drags.
    private func releaseStrandedHover() {
        guard Date() >= ownDragUntil, !collapsed, NSEvent.pressedMouseButtons == 0, foreignTooltipVisible() else { return }
        releaseHover(reason: "after moving an item")
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
        menu.addItem(withTitle: "\(collapsed ? "Show" : "Hide") Icons  \(Shortcut.current.description)",
                     action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit IconCloak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Not `item.menu`: a menu attached to a status item is as wide as the item, and the
        // fillers are very wide. Popped up at the item's right edge, it sizes to its content.
        guard let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX - 24, y: button.bounds.minY - 4), in: button)
    }

    @objc private func showSettings() { SettingsWindow.shared.show() }

    /// The configurable global shortcut (Carbon hot keys need no permissions).
    private func registerHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
                let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
                DispatchQueue.main.async { me.setCollapsed(!me.collapsed) }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let shortcut = Shortcut.current
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: OSType(0x49434C4B), id: 1),
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        log("shortcut \(shortcut.description)\(status == noErr ? "" : " could not be registered (already in use?)")")
    }

    // MARK: - Development controls

    #if ICONCLOAK_DEV
    static var evLines: [String] = []
    /// Remote control for automated testing, compiled only into dev builds
    /// (`scripts/build-app.sh --dev`). Any local process can post these notifications, and
    /// IconCloak holds the Accessibility permission, so this must never ship in a release.
    /// Usage: `build/ctl collapse|expand|log|axdump|extras|trace|evlog:<s>|nowatch|misplace|fillervis:0/1|pressoverflow|click:x,y|cmddrag:x1,x2|autohide:<s>|len:<item>,<n>|front|arrange`.
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
            case "misplace":
                // Puts the filler right of "|" (a broken order) to test the repair.
                guard !self.collapsed, let screen = self.targetScreen() else { return }
                self.filler.length = NSStatusItem.variableLength
                self.filler.isVisible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let f = self.itemFrame(Label.filler, on: screen), let t = self.itemFrame(Label.toggle, on: screen) else { return }
                    self.log("misplacing filler (x=\(Int(f.midX)) → \(Int(t.maxX - 3)))")
                    self.drag(from: f.midX, to: t.maxX - 3, on: screen) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.configureButtons() }
                    }
                }
            case "fillervis:1": self.filler.length = NSStatusItem.variableLength; self.filler.isVisible = true
            case "fillervis:0": self.filler.isVisible = false
            case let c where c.hasPrefix("evlog:"):
                // Logs every mouse / modifier event the session sees for N seconds (listen-only).
                let seconds = Double(c.dropFirst(6)) ?? 5
                var mask: CGEventMask = 0
                for t in [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .flagsChanged, .keyDown, .keyUp] { mask |= CGEventMask(1 << t.rawValue) }
                let start = CFAbsoluteTimeGetCurrent()
                Self.evLines = []
                guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                                  eventsOfInterest: mask, callback: { _, type, e, _ in
                    let f: (CGEventField) -> Int64 = { e.getIntegerValueField($0) }
                    AppDelegate.evLines.append(String(format: "%.3f type=%d loc=%.0f,%.0f flags=%llx num=%lld click=%lld dx=%lld dy=%lld sub=%lld press=%.2f btn=%lld user=%llx pid=%lld state=%lld key=%lld",
                        CFAbsoluteTimeGetCurrent(), type.rawValue, e.location.x, e.location.y, e.flags.rawValue,
                        f(.mouseEventNumber), f(.mouseEventClickState), f(.mouseEventDeltaX), f(.mouseEventDeltaY), f(.mouseEventSubtype),
                        e.getDoubleValueField(.mouseEventPressure), f(.mouseEventButtonNumber), f(.eventSourceUserData),
                        f(.eventSourceUnixProcessID), f(.eventSourceStateID), f(.keyboardEventKeycode)))
                    return Unmanaged.passUnretained(e)
                }, userInfo: nil) else { self.log("evlog: no tap"); return }
                let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
                self.log("evlog started")
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                    let path = NSTemporaryDirectory() + "iconcloak-evlog.txt"
                    let lines = AppDelegate.evLines.map { l -> String in
                        guard let t = Double(l.prefix(while: { $0 != " " })) else { return l }
                        return String(format: "%7.3f", t - start) + l.drop(while: { $0 != " " })
                    }
                    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    self.log("evlog: \(lines.count) events → \(path)")
                }
            case "nowatch": self.screenWatch?.invalidate(); self.log("screen watch stopped")
            case "trace":
                // Logs where "|" and the filler are, every 0.15 s for 4 s.
                for i in 0..<27 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                        guard let screen = self.targetScreen() else { return }
                        let t = self.itemFrame(Label.toggle, on: screen).map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "none"
                        let f = self.itemFrame(Label.filler, on: screen).map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "none"
                        let o = self.overflowButtons().map { "\(Int($0.frame.minX))" }.joined(separator: ",")
                        self.log("trace \(i): | \(t)  filler \(f)  « \(o)")
                    }
                }
            case "menu": self.showMenu(on: self.collapsed ? self.toggle : self.divider)
            case "settings": SettingsWindow.shared.show()
            case let c where c.hasPrefix("cover:"):
                let names: [String: NSVisualEffectView.Material] = [
                    "titlebar": .titlebar, "menu": .menu, "popover": .popover, "sidebar": .sidebar,
                    "headerView": .headerView, "sheet": .sheet, "windowBackground": .windowBackground,
                    "hudWindow": .hudWindow, "fullScreenUI": .fullScreenUI, "toolTip": .toolTip,
                    "contentBackground": .contentBackground, "underWindowBackground": .underWindowBackground,
                    "underPageBackground": .underPageBackground,
                ]
                if let m = names[String(c.dropFirst(6))] { self.coverMaterial = m; self.updateCovers() }
            case "extras":
                // Status items per app, from each app's own accessibility (AXExtrasMenuBar).
                var total = 0
                for app in NSWorkspace.shared.runningApplications {
                    let ax = AXUIElementCreateApplication(app.processIdentifier)
                    var bar: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(ax, kAXExtrasMenuBarAttribute as CFString, &bar) == .success, let bar else { continue }
                    let items = self.axChildren(bar as! AXUIElement)
                    total += items.count
                    let desc = items.map { "\(self.axString($0, kAXDescriptionAttribute) ?? self.axString($0, kAXTitleAttribute) ?? "?") @\(Int(self.axFrame($0).minX))" }
                    self.log("extras \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "-")): \(desc)")
                }
                self.log("extras total: \(total)")
            case "front": self.moveDividerToFront()
            case "arrange": self.arrangeItems()
            case "collapse": self.setCollapsed(true)
            case "expand": self.setCollapsed(false)
            case "log": self.logState(label: "manual")
            case "axdump": self.dumpMenuBarAgent(press: false)
            case "pressoverflow": self.dumpMenuBarAgent(press: true)
            case let c where c.hasPrefix("cmddrag:"):
                // "cmddrag:x1,x2" — ⌘-drags along the main display's menu bar from x1 to x2.
                let p = c.dropFirst(8).split(separator: ",").compactMap { Double($0) }
                guard p.count == 2 else { return }
                self.drag(from: p[0], to: p[1], on: NSScreen.screens.first)
            case let c where c.hasPrefix("move:"):
                // "move:x,y" — real mouse-moved events around x,y (lets apps see a hover).
                let p = c.dropFirst(5).split(separator: ",").compactMap { Double($0) }
                guard p.count == 2 else { return }
                for (i, dx) in [0.0, 1, 2, 1, 0].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: p[0] + dx, y: p[1]), mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                }
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
