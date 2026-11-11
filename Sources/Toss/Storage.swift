import Foundation

enum AppPaths {
    /// ~/Library/Application Support/<bundle id>
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.toast.toss", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var tdlib: URL { support.appendingPathComponent("tdlib", isDirectory: true) }
    static var tdlibDatabase: URL { tdlib.appendingPathComponent("db", isDirectory: true) }
    static var tdlibFiles: URL { tdlib.appendingPathComponent("files", isDirectory: true) }

    /// Scratch space for converted images, dropped text clippings and file promises.
    static var outbox: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Toss-outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newOutboxFolder() -> URL {
        let url = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Small user preferences kept in UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let maxTargets = 6

    private let defaults = UserDefaults.standard

    /// Chat ids shown in the menu bar, in order.
    @Published var targetChatIDs: [Int64] {
        didSet { defaults.set(targetChatIDs.map { NSNumber(value: $0) }, forKey: "targetChatIDs") }
    }

    /// Send images as compressed photos (true) or as original files (false).
    @Published var imagesAsPhotos: Bool {
        didSet { defaults.set(imagesAsPhotos, forKey: "imagesAsPhotos") }
    }

    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: "playSound") }
    }

    /// Global shortcut that opens the panel with the clipboard.
    @Published var clipboardShortcut: Shortcut {
        didSet { defaults.set(clipboardShortcut.stored, forKey: "clipboardShortcut") }
    }

    /// Set when another app already holds the shortcut.
    @Published var shortcutUnavailable = false

    /// Drag and drop waits for a confirm on the card; off sends on release.
    /// The clipboard panel always confirms.
    @Published var confirmDrops: Bool {
        didSet { defaults.set(confirmDrops, forKey: "confirmDrops") }
    }

    /// How the clipboard panel opens. The shortcut works in both modes.
    @Published var clipboardTrigger: ClipboardTrigger {
        didSet { defaults.set(clipboardTrigger.rawValue, forKey: "clipboardTrigger") }
    }

    /// The Option double tap is being watched (Input Monitoring granted).
    @Published var doubleTapActive = false

    /// Whether the default target list has been seeded after the first login.
    var didSeedTargets: Bool {
        get { defaults.bool(forKey: "didSeedTargets") }
        set { defaults.set(newValue, forKey: "didSeedTargets") }
    }

    private init() {
        targetChatIDs = (defaults.array(forKey: "targetChatIDs") as? [NSNumber])?.map(\.int64Value) ?? []
        imagesAsPhotos = defaults.object(forKey: "imagesAsPhotos") as? Bool ?? true
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        confirmDrops = defaults.object(forKey: "confirmDrops") as? Bool ?? true
        clipboardTrigger = defaults.string(forKey: "clipboardTrigger").flatMap(ClipboardTrigger.init(rawValue:)) ?? .doubleOption
        clipboardShortcut = (defaults.dictionary(forKey: "clipboardShortcut")).flatMap(Shortcut.init(stored:)) ?? .default
    }

    func resetAccountState() {
        targetChatIDs = []
        didSeedTargets = false
    }
}

enum ClipboardTrigger: String {
    /// Tap Option twice; the shortcut stays on as a fallback.
    case doubleOption
    /// Only the shortcut.
    case shortcut
}

/// A key plus Carbon modifier flags, as RegisterEventHotKey wants them.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key as typed, for display (e.g. "V").
    var key: String

    // Carbon modifier bits (cmdKey, shiftKey, optionKey, controlKey).
    static let command: UInt32 = 1 << 8, shift: UInt32 = 1 << 9, option: UInt32 = 1 << 11, control: UInt32 = 1 << 12

    /// ⌥⌘V
    static let `default` = Shortcut(keyCode: 9, modifiers: command | option, key: "V")

    var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }

    var stored: [String: Any] { ["keyCode": keyCode, "modifiers": modifiers, "key": key] }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init?(stored: [String: Any]) {
        guard let keyCode = (stored["keyCode"] as? NSNumber)?.uint32Value,
              let modifiers = (stored["modifiers"] as? NSNumber)?.uint32Value,
              let key = stored["key"] as? String else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: key)
    }
}

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}
