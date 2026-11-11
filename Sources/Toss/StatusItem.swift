import AppKit

/// The menu bar cluster of avatars. One status item draws all of them and a
/// transparent overlay makes each avatar a drop target.
///
/// At rest the avatars overlap like a stack of coins (right on top). The
/// hovered one gets a white ring and pushes its neighbours aside; the change
/// is animated frame by frame because a status item image can't animate.
@MainActor
final class StatusItemController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let overlay = DropView()
    private var targets: [Target] = []
    private var highlighted: Int?
    /// Per-avatar hover amount, 0…1, animated toward 0 or 1.
    private var hover: [CGFloat] = []
    private var animationTimer: Timer?

    var onHover: ((Int) -> NSDragOperation)?
    var onExit: (() -> Void)?
    var onDrop: ((Int, NSDraggingInfo) -> Bool)?
    var menuProvider: (() -> NSMenu)?
    /// A plain click on the cluster; right-click, ⌃-click or ⌥-click opens the menu.
    var onClick: (() -> Void)?

    init() {
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Toss")
        overlay.frame = button.bounds
        overlay.autoresizingMask = [.width, .height]
        button.addSubview(overlay)
        overlay.onClick = { [weak self] _, event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection([.control, .option])
            if event.type == .rightMouseDown || !flags.isEmpty || self.onClick == nil {
                self.showMenu()
            } else {
                self.onClick?()
            }
        }
        overlay.onHover = { [weak self] point in
            guard let self, let index = self.index(at: point.x) else { return [] }
            return self.onHover?(index) ?? []
        }
        overlay.onExit = { [weak self] in self?.onExit?() }
        overlay.onDrop = { [weak self] point, info in
            guard let self, let index = self.index(at: point.x) else { return false }
            return self.onDrop?(index, info) ?? false
        }
        render()
    }

    /// Center of the cluster in screen coordinates, and the screen it is on.
    var anchor: (x: CGFloat, screen: NSScreen)? {
        guard let window = item.button?.window, let screen = window.screen,
              window.frame.width > 0, window.frame.maxY >= screen.frame.maxY - 2 else { return nil }
        // Right after launch the status window hasn't been placed yet.
        return (window.frame.midX, screen)
    }

    /// The avatar under a screen point in the menu bar, if any.
    func index(atScreen point: NSPoint) -> Int? {
        guard let window = item.button?.window, anchor != nil else { return nil }
        let frame = window.frame
        guard point.x >= frame.minX, point.x <= frame.maxX, point.y >= frame.minY - 2 else { return nil }
        return index(at: point.x - frame.minX)
    }

    /// Screen x of one avatar's center (on the status item's own screen).
    func avatarCenterX(_ index: Int) -> CGFloat? {
        guard let window = item.button?.window, let button = item.button, targets.indices.contains(index),
              anchor != nil else { return nil }
        let origin = window.frame.minX + imageOriginX(in: button)
        return origin + layout().centers[index]
    }

    func update(targets: [Target], highlighted: Int?) {
        let targetsChanged = targets != self.targets
        guard targetsChanged || highlighted != self.highlighted || image == nil else { return }
        if targetsChanged || hover.count != targets.count {
            hover = targets.indices.map { $0 == highlighted ? 1 : 0 }
        }
        self.targets = targets
        self.highlighted = highlighted
        if targetsChanged { render() } else { animate() }
    }

    private var image: NSImage? { item.button?.image }

    private func showMenu() {
        guard let menu = menuProvider?(), let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: - Animation

    private func animate() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        step()
    }

    private func step() {
        var settled = true
        for index in hover.indices {
            let goal: CGFloat = index == highlighted ? 1 : 0
            let delta = goal - hover[index]
            if abs(delta) < 0.01 {
                hover[index] = goal
            } else {
                // Exponential approach ≈ 150 ms to settle; reads as a soft spring.
                hover[index] += delta * 0.28
                settled = false
            }
        }
        render()
        if settled {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    // MARK: - Geometry

    private var thickness: CGFloat { NSStatusBar.system.thickness }
    /// Resting avatar size; the ring of a hovered avatar fills the bar height.
    private var diameter: CGFloat { (thickness * 0.84).rounded() }
    private let ringWidth: CGFloat = 1.6
    private let padding: CGFloat = 2

    private struct Layout {
        var centers: [CGFloat]
        var width: CGFloat
    }

    /// Avatar centers for the current hover state. The image keeps the width
    /// of the hovered layout so neighbouring menu bar items never shift.
    private func layout() -> Layout {
        let d = diameter
        let hoveredOuter = d * 1.04 + ringWidth * 2
        let rest = d * 0.75
        let apart = hoveredOuter / 2 + d / 2 + 1.5
        func spacings(_ amount: (Int) -> CGFloat) -> [CGFloat] {
            guard targets.count > 1 else { return [] }
            return (0..<targets.count - 1).map { i in
                rest + (apart - rest) * max(amount(i), amount(i + 1))
            }
        }
        let current = spacings { self.hover.indices.contains($0) ? self.hover[$0] : 0 }
        // Widest layout: one avatar hovered in the middle of the row.
        let widest = targets.count > 1 ? rest * CGFloat(targets.count - 1) + (apart - rest) * 2 : 0
        let width = padding * 2 + hoveredOuter + widest
        let used = current.reduce(0, +)
        var x = (width - used) / 2
        var centers: [CGFloat] = []
        for index in targets.indices {
            centers.append(x)
            if index < current.count { x += current[index] }
        }
        return Layout(centers: centers, width: width)
    }

    private func imageOriginX(in button: NSStatusBarButton) -> CGFloat {
        (button.bounds.width - (button.image?.size.width ?? 0)) / 2
    }

    private func index(at x: CGFloat) -> Int? {
        guard !targets.isEmpty, let button = item.button else { return nil }
        let x = x - imageOriginX(in: button)
        let centers = layout().centers
        return centers.indices.min { abs(centers[$0] - x) < abs(centers[$1] - x) }
    }

    // MARK: - Drawing

    /// Shown when no chats are chosen (or before sign-in): the app icon's
    /// flicked card with two motion arcs, as a monochrome template.
    static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // The card, tilted up to the right.
            let card = NSBezierPath(roundedRect: NSRect(x: -4, y: -3, width: 8, height: 6), xRadius: 1.6, yRadius: 1.6)
            var transform = AffineTransform(translationByX: 11.5, byY: 6.5)
            transform.rotate(byDegrees: -24)
            card.transform(using: transform)
            card.fill()
            // Motion arcs trailing from the lower left.
            for (radius, alpha) in [(6.5, 1.0), (9.0, 0.55)] as [(CGFloat, CGFloat)] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: 11.5, y: 16.5), radius: radius, startAngle: 196, endAngle: 228)
                arc.lineWidth = 1.6
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Toss"
        return image
    }()

    private func render() {
        guard let button = item.button else { return }
        if targets.isEmpty {
            button.image = Self.glyph
            return
        }
        let layout = layout()
        let height = thickness
        let targets = self.targets, hover = self.hover
        let d = diameter, ring = ringWidth
        // Right overlaps left at rest; whatever is hovered draws last.
        let order = targets.indices.sorted { (hover[$0], $0) < (hover[$1], $1) }
        let image = NSImage(size: NSSize(width: layout.width, height: height), flipped: false) { _ in
            for index in order {
                let amount = hover[index]
                let photo = d * (1 + 0.04 * amount)
                let center = NSPoint(x: layout.centers[index], y: height / 2)
                let rect = NSRect(x: center.x - photo / 2, y: center.y - photo / 2, width: photo, height: photo)
                let outer = rect.insetBy(dx: -ring * amount, dy: -ring * amount)
                // A hairline gap keeps overlapping faces distinct on any menu bar.
                if let context = NSGraphicsContext.current {
                    context.compositingOperation = .clear
                    NSBezierPath(ovalIn: outer.insetBy(dx: -0.8, dy: -0.8)).fill()
                    context.compositingOperation = .sourceOver
                }
                if amount > 0.01 {
                    NSColor.white.withAlphaComponent(min(1, amount * 1.4)).setFill()
                    NSBezierPath(ovalIn: outer).fill()
                }
                AvatarRenderer.draw(targets[index], in: rect)
            }
            return true
        }
        image.isTemplate = false
        button.image = image
        button.setAccessibilityLabel(targets.map(\.name).joined(separator: ", "))
    }
}
