import AppKit

/// Notices drags anywhere on screen. A drag writes to the shared drag
/// pasteboard, so a changed change count after mouse-down means something is
/// being dragged. Mouse monitors need no Accessibility permission.
@MainActor
final class DragWatcher {
    var onMove: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?
    /// Esc pressed during the drag (the system cancels the drag itself).
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var timer: Timer?
    private(set) var isDragging = false

    func start() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(down) }
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }) { monitors.append(dragged) }
    }

    private func mouseDown() {
        baseline = NSPasteboard(name: .drag).changeCount
    }

    private func mouseDragged() {
        guard !isDragging, NSPasteboard(name: .drag).changeCount != baseline else { return }
        isDragging = true
        // Poll while the button is down: once the cursor is over our own panel,
        // global monitors stop seeing events.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            timer?.invalidate()
            timer = nil
            isDragging = false
            baseline = NSPasteboard(name: .drag).changeCount
            onEnd?()
        } else {
            if CGEventSource.keyState(.combinedSessionState, key: 0x35) { onEscape?() }
            onMove?(NSEvent.mouseLocation)
        }
    }
}
