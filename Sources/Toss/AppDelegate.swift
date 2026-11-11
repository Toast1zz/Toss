import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: DropCoordinator?
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private let preview = PreviewMode.fromEnvironment()
    private var hotKey: HotKey?
    private var optionTap: OptionDoubleTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(Data("Toss: TDLib \(TDClient.version ?? "unavailable")\n".utf8))
        try? FileManager.default.removeItem(at: AppPaths.outbox)

        let coordinator = DropCoordinator(preview: preview)
        coordinator.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        self.coordinator = coordinator

        if let preview {
            showBackdrop(for: preview)
            switch preview.screenKind {
            case .panel:
                // Let the menu bar place the status item first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { coordinator.showPreviewState() }
            case .setup: showSetup()
            case .settings: showSettings()
            case .lab: showMaterialLab(on: preview.screen)
            }
            return
        }

        let telegram = Telegram.shared
        telegram.$step
            .removeDuplicates()
            .sink { [weak self] step in self?.stepChanged(step) }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .tossOpenSettings)
            .sink { [weak self] _ in self?.showSettings() }
            .store(in: &subscriptions)

        hotKey = HotKey { [weak coordinator] in coordinator?.toggleClipboard() }
        applyShortcut()
        Preferences.shared.$clipboardShortcut
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyShortcut() }
            .store(in: &subscriptions)
        let optionTap = OptionDoubleTap { [weak coordinator] in coordinator?.toggleClipboard() }
        optionTap.onStatus = { active in
            if Preferences.shared.doubleTapActive != active { Preferences.shared.doubleTapActive = active }
        }
        self.optionTap = optionTap
        Preferences.shared.$clipboardTrigger
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak optionTap] trigger in optionTap?.setEnabled(trigger == .doubleOption) }
            .store(in: &subscriptions)
        // While the recorder in Settings listens, the old shortcut must not fire.
        NotificationCenter.default.publisher(for: .tossRecordingShortcut)
            .sink { [weak self] note in
                if note.object as? Bool == true { self?.hotKey?.unregister() } else { self?.applyShortcut() }
            }
            .store(in: &subscriptions)
        telegram.start()
    }

    private func applyShortcut() {
        let preferences = Preferences.shared
        let registered = hotKey?.register(preferences.clipboardShortcut) ?? false
        if preferences.shortcutUnavailable == registered { preferences.shortcutUnavailable = !registered }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard preview == nil else { return }
        Telegram.shared.shutdown()
    }

    private func stepChanged(_ step: Telegram.Step) {
        switch step {
        case .credentials, .phone, .code, .password, .email, .emailCode, .blocked:
            showSetup()
        case .ready, .starting, .loggingOut:
            break
        }
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if preview == nil, Telegram.shared.step != .ready {
            menu.addItem(withTitle: L("Sign In…"), action: #selector(openSetup), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit Toss"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openSetup() { showSetup() }

    @objc private func openSettings() {
        if preview == nil, Telegram.shared.step != .ready {
            showSetup()
        } else {
            showSettings()
        }
    }

    // MARK: - Windows

    private var previewWindows: [NSWindow] = []

    /// Preview only: an image behind the panel so it can be compared with a reference frame.
    private func showBackdrop(for preview: PreviewMode) {
        guard let path = ProcessInfo.processInfo.environment["TOSS_PREVIEW_BACKDROP"],
              let image = NSImage(contentsOfFile: path),
              let screen = preview.screen ?? NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.ignoresMouseEvents = true
        window.level = .normal
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        previewWindows.append(window)
    }

    private func showMaterialLab(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let hosting = NSHostingView(rootView: MaterialLabView())
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.level = .floating
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - hosting.fittingSize.width / 2,
                                      y: screen.visibleFrame.maxY - hosting.fittingSize.height))
        window.orderFrontRegardless()
        previewWindows.append(window)
    }

    private func showSetup() {
        if setupWindow == nil {
            let previewStep: Telegram.Step? = preview == nil ? nil : .credentials
            let view = SetupView(telegram: Telegram.shared, preview: previewStep) { [weak self] in
                self?.setupWindow?.close()
                self?.showSettings()
            }
            setupWindow = makeWindow(title: "Toss", content: view, identifier: "tossSetupWindow")
        }
        present(setupWindow)
    }

    private func showSettings() {
        setupWindow?.close()
        if settingsWindow == nil {
            let view = SettingsView(telegram: Telegram.shared, preferences: Preferences.shared,
                                    previewTargets: preview?.targets)
            settingsWindow = makeWindow(title: L("Toss Settings"), content: view, identifier: "tossSettingsWindow")
        }
        present(settingsWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content, identifier: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        if preview == nil {
            // Called from a status-menu action while another app is active; the
            // cooperative NSApp.activate() is refused then, so the window stayed
            // behind until a second click. Wait for the menu to close, then force it.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        } else {
            // Preview builds run on a test display; never take focus from the user.
            if let screen = preview?.screen {
                let frame = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                              y: frame.midY - window.frame.height / 2))
            }
            window.orderFrontRegardless()
        }
    }
}
