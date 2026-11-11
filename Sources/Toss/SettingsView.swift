import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var telegram: Telegram
    @ObservedObject var preferences: Preferences
    /// Preview mode: fake chats, no account actions.
    var previewTargets: [Target]?

    @State private var showingPicker = false
    @State private var confirmLogout = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private var selected: [Target] {
        if let previewTargets { return previewTargets }
        return preferences.targetChatIDs.compactMap { id in
            telegram.chats[id].map { target(for: $0) }
        }
    }

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(selected) { target in
                        HStack(spacing: 10) {
                            AvatarView(target: target, size: 28)
                            Text(target.name).lineLimit(1)
                            Spacer()
                            Button {
                                preferences.targetChatIDs.removeAll { $0 == target.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in preferences.targetChatIDs.move(fromOffsets: from, toOffset: to) }
                }
                .frame(minHeight: 40 * CGFloat(max(selected.count, 1)))
                Button("Add Chat…") { showingPicker = true }
                    .disabled(selected.count >= Preferences.maxTargets || previewTargets != nil)
            } header: {
                Text("Menu Bar")
            }

            Section {
                Toggle("Send images as photos", isOn: $preferences.imagesAsPhotos)
                Toggle("Play sound", isOn: $preferences.playSound)
                Toggle("Confirm before sending", isOn: $preferences.confirmDrops)
                LabeledContent("Send clipboard") {
                    Picker("Send clipboard", selection: $preferences.clipboardTrigger) {
                        Text("Double-tap ⌥").tag(ClipboardTrigger.doubleOption)
                        Text("Shortcut").tag(ClipboardTrigger.shortcut)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if preferences.clipboardTrigger == .doubleOption, !preferences.doubleTapActive {
                    LabeledContent {
                        Button("Allow…") { OptionDoubleTap.requestPermission() }
                            .controlSize(.small)
                    } label: {
                        Text("Needs Input Monitoring")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(LocalizedStringKey(preferences.clipboardTrigger == .doubleOption ? "Or press" : "Shortcut")) {
                    ShortcutRecorder(shortcut: $preferences.clipboardShortcut,
                                     unavailable: preferences.shortcutUnavailable)
                }
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                HStack {
                    Text(telegram.accountName ?? "—")
                    Spacer()
                    Button("Log Out", role: .destructive) { confirmLogout = true }
                        .disabled(previewTargets != nil || telegram.step != .ready)
                }
            } header: {
                Text("Account")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 680)
        .sheet(isPresented: $showingPicker) {
            ChatPicker(telegram: telegram, preferences: preferences) { showingPicker = false }
        }
        .confirmationDialog("Log out of Telegram?", isPresented: $confirmLogout) {
            Button("Log Out", role: .destructive) {
                preferences.resetAccountState()
                telegram.logOut()
            }
        }
    }

    private func target(for chat: ChatInfo) -> Target {
        telegram.target(for: chat)
    }
}

/// Searchable list of recent chats to add to the menu bar.
struct ChatPicker: View {
    @ObservedObject var telegram: Telegram
    @ObservedObject var preferences: Preferences
    var onClose: () -> Void

    @State private var query = ""
    @State private var remote: [ChatInfo] = []

    private var results: [ChatInfo] {
        let recent = telegram.recentChats
        guard !query.isEmpty else { return recent }
        let local = recent.filter { telegram.displayName($0).localizedCaseInsensitiveContains(query) }
        let extra = remote.filter { chat in !local.contains { $0.id == chat.id } }
        return local + extra
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("chatSearchField")
            }
            .padding(10)
            Divider()
            List(results) { chat in
                let isAdded = preferences.targetChatIDs.contains(chat.id)
                Button {
                    guard !isAdded, preferences.targetChatIDs.count < Preferences.maxTargets else { return }
                    preferences.targetChatIDs.append(chat.id)
                    onClose()
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(target: telegram.target(for: chat), size: 30)
                        Text(telegram.displayName(chat)).lineLimit(1)
                        Spacer()
                        if isAdded { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onAppear { telegram.loadPhoto(for: chat.id) }
            }
            .listStyle(.plain)
            Divider()
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 360, height: 440)
        .task(id: query) {
            guard !query.isEmpty else { remote = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            remote = await telegram.search(query)
        }
    }
}

/// Click, then press the new shortcut. Esc cancels; ⌫ restores the default.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    var unavailable = false
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Type shortcut") : shortcut.display)
                .font(.system(size: 12, weight: .medium).monospaced())
                .foregroundStyle(recording ? Color.accentColor : (unavailable ? Color.red : Color.primary))
                .frame(minWidth: 72)
        }
        .help(unavailable ? L("Used by another app") : "")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        NotificationCenter.default.post(name: .tossRecordingShortcut, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        NotificationCenter.default.post(name: .tossRecordingShortcut, object: false)
    }

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            stop()
            return
        case 51, 117: // ⌫, ⌦
            shortcut = .default
            stop()
            return
        default:
            break
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Shortcut.command }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.control) { modifiers |= Shortcut.control }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        // Needs ⌘, ⌥ or ⌃ so it can't swallow ordinary typing.
        guard modifiers & (Shortcut.command | Shortcut.option | Shortcut.control) != 0 else {
            NSSound.beep()
            return
        }
        shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: Self.name(event))
        stop()
    }

    private static func name(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
