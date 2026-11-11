import AppKit
import CoreGraphics
import TapDetection

/// Watches for a double tap of Option anywhere through a listen-only event
/// tap on modifier changes. Needs Input Monitoring; it never asks for it on
/// its own and starts by itself once the permission is granted.
///
/// The tap receives flagsChanged only, never key presses. Whether a key or
/// mouse button went down in between comes from the system's
/// seconds-since-last-event counters, which carry timing and no key.
@MainActor
final class OptionDoubleTap {
    private let action: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoubleTapDetector()
    private var lastSample: TimeInterval = 0
    private var poll: Timer?
    private var activation: NSObjectProtocol?
    private(set) var wanted = false

    /// Called when the permission or the running state changes.
    var onStatus: ((_ granted: Bool) -> Void)?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    static var permitted: Bool { CGPreflightListenEventAccess() }

    /// Adds Toss to Input Monitoring (showing the system prompt the first time)
    /// and opens that pane.
    static func requestPermission() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Turns detection on or off. While on and not yet permitted, it re-checks
    /// every two seconds and whenever Toss becomes active.
    func setEnabled(_ enabled: Bool) {
        wanted = enabled
        if enabled {
            if activation == nil {
                activation = NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
            }
            check()
        } else {
            stopTap()
            poll?.invalidate()
            poll = nil
            if let activation { NotificationCenter.default.removeObserver(activation) }
            activation = nil
            onStatus?(false)
        }
    }

    private func check() {
        guard wanted else { return }
        let granted = Self.permitted
        if granted, tap == nil { startTap() }
        if !granted, tap != nil { stopTap() }
        let running = tap != nil
        if running {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        onStatus?(running)
    }

    private func startTap() {
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<OptionDoubleTap>.fromOpaque(info).takeUnretainedValue()
            let flags = event.flags
            MainActor.assumeIsolated { monitor.received(type, flags: flags) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        detector.reset()
        lastSample = ProcessInfo.processInfo.systemUptime
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        detector.reset()
    }

    private func received(_ type: CGEventType, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system paused the tap, or the permission went away.
            detector.reset()
            if Self.permitted, let tap { CGEvent.tapEnable(tap: tap, enable: true) } else { stopTap(); check() }
            return
        case .flagsChanged:
            break
        default:
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSample
        lastSample = now
        let sample = ModifierSample(
            option: flags.contains(.maskAlternate),
            others: !flags.intersection([.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty,
            interference: Self.somethingElseHappened(within: elapsed),
            time: now
        )
        if detector.handle(sample) { action() }
    }

    /// A key or mouse button went down in the last `seconds`, or a button is held.
    private static func somethingElseHappened(within seconds: TimeInterval) -> Bool {
        if NSEvent.pressedMouseButtons != 0 { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < seconds }
    }
}
