import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// A keyboard shortcut, stored in UserDefaults as a key code plus Carbon modifier flags.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey | cmdKey))

    static var current: Shortcut {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "shortcutKeyCode") != nil else { return .default }
            return Shortcut(keyCode: UInt32(defaults.integer(forKey: "shortcutKeyCode")),
                            modifiers: UInt32(defaults.integer(forKey: "shortcutModifiers")))
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: "shortcutKeyCode")
            UserDefaults.standard.set(Int(newValue.modifiers), forKey: "shortcutModifiers")
        }
    }

    /// e.g. "⌃⌥⌘H"
    var description: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    private static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        ]
        let letters = "ANSBCDEFGHIJKLMNOPQRSTUVWXYZ"
        let letterCodes: [UInt32] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (code, letter) in zip(letterCodes, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") { names[code] = String(letter) }
        _ = letters
        for (digit, code) in zip("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] as [UInt32]) { names[code] = String(digit) }
        return names
    }()

    /// The Carbon modifiers of an NSEvent, or nil when no modifier is held (those would grab the key globally).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32? {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon == 0 ? nil : carbon
    }
}

/// Bridges the settings window and the app: the window changes values, the app applies them.
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    var onAutoHideChanged: (() -> Void)?
    var onShortcutChanged: (() -> Void)?
    var onArrangeItems: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var logMessage: ((String) -> Void)?

    @Published var autoHideEnabled: Bool = UserDefaults.standard.integer(forKey: "autoHideDelay") > 0 {
        didSet { saveAutoHide() }
    }
    @Published var autoHideSeconds: Int = max(UserDefaults.standard.integer(forKey: "autoHideDelay"), 5) {
        didSet { saveAutoHide() }
    }
    @Published var shortcut: Shortcut = .current {
        didSet {
            Shortcut.current = shortcut
            onShortcutChanged?()
        }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                logMessage?("launch at login failed: \(error)")
                launchAtLoginError = error.localizedDescription
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var launchAtLoginError: String?

    private func saveAutoHide() {
        UserDefaults.standard.set(autoHideEnabled ? max(autoHideSeconds, 1) : 0, forKey: "autoHideDelay")
        onAutoHideChanged?()
    }
}

struct SettingsView: View {
    @ObservedObject var model = SettingsModel.shared
    @State private var recording = false

    var body: some View {
        Form {
            Section {
                Toggle("Hide icons automatically", isOn: $model.autoHideEnabled)
                HStack {
                    Text("After")
                    TextField("", value: $model.autoHideSeconds, format: .number)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $model.autoHideSeconds, in: 1...3600).labelsHidden()
                    Text("seconds")
                }
                .disabled(!model.autoHideEnabled)
                .foregroundStyle(model.autoHideEnabled ? .primary : .secondary)
                Text("IconCloak waits while the pointer is on the menu bar or a menu is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Shortcut to hide and show")
                    Spacer()
                    ShortcutRecorder(shortcut: $model.shortcut, recording: $recording)
                    Button("Reset") { model.shortcut = .default }
                        .disabled(model.shortcut == .default)
                }
            }
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                if let error = model.launchAtLoginError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                HStack {
                    Button("Move » to the Far Left") { model.onArrangeItems?() }
                    Button("Open Log") { model.onOpenLog?() }
                }
            }
            Section {
                HStack {
                    Text("IconCloak \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/LarsAtassi/icon-cloak")!)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Click to record: shows the shortcut and captures the next key combination.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    @Binding var recording: Bool

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = recording ? "Press keys…" : shortcut.description
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ShortcutRecorder
        private var monitor: Any?

        init(_ parent: ShortcutRecorder) { self.parent = parent }

        @objc func clicked() {
            guard monitor == nil else { return stop() }
            parent.recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
                guard let modifiers = Shortcut.carbonModifiers(from: event.modifierFlags) else {
                    NSSound.beep() // a shortcut without modifiers would swallow the key everywhere
                    return nil
                }
                self.parent.shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                self.stop()
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            parent.recording = false
        }
    }
}

/// The settings window; one instance, reused.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: controller)
            window.title = "IconCloak Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // The window doesn't pick up SwiftUI's height on its own.
            window.setContentSize(controller.view.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
