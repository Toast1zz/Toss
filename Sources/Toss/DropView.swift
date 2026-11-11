import AppKit

/// Transparent drag destination. Points are reported in flipped
/// (top-left origin) view coordinates to match SwiftUI.
final class DropView: NSView {
    var onHover: ((CGPoint) -> NSDragOperation)?
    var onExit: (() -> Void)?
    var onDrop: ((CGPoint, NSDraggingInfo) -> Bool)?
    /// Mouse down at a point; the event tells left from right click and modifiers.
    var onClick: ((CGPoint, NSEvent) -> Void)?
    /// Keys while the panel is key (clipboard mode). Returns true when handled.
    var onKey: ((NSEvent) -> Bool)?
    /// Pointer moves with no drag (for hover-to-retry); nil when it leaves.
    var onPointer: ((CGPoint?) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DragReader.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func point(_ info: NSDraggingInfo) -> CGPoint {
        convert(info.draggingLocation, from: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard DragReader.canRead(sender.draggingPasteboard) else { return [] }
        return onHover?(point(sender)) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard DragReader.canRead(sender.draggingPasteboard) else { return [] }
        return onHover?(point(sender)) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(point(sender), sender) ?? false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onPointer?(nil)
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil), event)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil), event)
    }
}
