import AppKit
import SwiftUI

/// Panel geometry. The glass, radius and dots follow Hoy's demo; the panel is
/// taller to hold a row of avatars and the preview card.
enum PanelMetrics {
    static let size = CGSize(width: 348, height: 204)
    static let cornerRadius: CGFloat = 40
    /// Gap between the menu bar and the panel's top edge.
    static let gap: CGFloat = 9
    /// The pill the panel grows out of, just under the avatars.
    static let seedSize = CGSize(width: 46, height: 30)
    /// Transparent margin around the panel for its shadow.
    static let margin: CGFloat = 24

    static let avatarDiameter: CGFloat = 34
    static let avatarRowY: CGFloat = 40
    static let cardSize = CGSize(width: 176, height: 48)
    static let chipDiameter: CGFloat = 22
    static let resultDiameter: CGFloat = 32
    static let labelY: CGFloat = size.height - 24

    static var windowSize: CGSize {
        CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
    }

    static func avatarCenter(_ index: Int, of count: Int) -> CGPoint {
        let column = size.width / CGFloat(max(count, 1))
        return CGPoint(x: column * (CGFloat(index) + 0.5), y: avatarRowY)
    }

    /// Highest the card's center may go while dragging: just under the avatars.
    static let cardTopLimit = avatarRowY + avatarDiameter / 2 + cardSize.height / 2 + 10
    static let cardBottomLimit = labelY - 14 - cardSize.height / 2 - 4
    /// Clipboard mode: the card sits still in the middle.
    static let cardClipboard = CGPoint(x: size.width / 2, y: 106)
    static let cardRest = CGPoint(x: size.width / 2, y: 112)
    /// Where the card settles once released.
    static let cardDelivering = CGPoint(x: size.width / 2, y: 62)

    /// Picked chips stack on the card's top-right corner, newest on top.
    static func chipSlot(_ order: Int, card: CGPoint) -> CGPoint {
        CGPoint(x: card.x + cardSize.width / 2 - 8 - CGFloat(order) * 13,
                y: card.y - cardSize.height / 2 - 1)
    }

    static func resultCenter(_ index: Int, of count: Int) -> CGPoint {
        let spacing: CGFloat = resultDiameter + 14
        let width = spacing * CGFloat(count - 1)
        return CGPoint(x: size.width / 2 - width / 2 + spacing * CGFloat(index), y: 128)
    }
}

/// How the panel's glass is rendered. `TOSS_PREVIEW_MATERIAL` overrides it for testing.
enum PanelMaterial: String, CaseIterable {
    case glassRegular, glassClear, ultraThin, hud, darkBlur

    static var current: PanelMaterial {
        ProcessInfo.processInfo.environment["TOSS_PREVIEW_MATERIAL"].flatMap(PanelMaterial.init) ?? .ultraThin
    }

    /// Black overlay on top of the material.
    static var dim: Double {
        ProcessInfo.processInfo.environment["TOSS_PREVIEW_DIM"].flatMap(Double.init) ?? 0.04
    }
}

/// Lifecycle of the panel window, driven by the controller and animated in SwiftUI.
enum PanelPresentation: Equatable {
    case hidden, seed, open, closing
}

/// A borderless panel that can take keyboard focus without activating Toss.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Keys the panel understands in clipboard mode.
enum PanelKey: Equatable {
    case escape, send, digit(Int)

    init?(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: self = .escape
        case 36, 76, 49: self = .send // Return, Enter, Space
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) else { return nil }
            self = .digit(digit)
        }
    }
}

/// The translucent panel that drops down under the menu bar during a drag.
@MainActor
final class DropPanelController {
    private let panel: NSPanel
    private let dropView = DropView()
    private let model: DropCoordinator
    private var generation = 0

    init(model: DropCoordinator) {
        self.model = model
        let size = PanelMetrics.windowSize
        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityIdentifier("tossDropPanel")

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        // On top of the SwiftUI content so it receives every drag event.
        dropView.frame = container.bounds
        dropView.autoresizingMask = [.width, .height]
        container.addSubview(dropView)
        panel.contentView = container

        let margin = PanelMetrics.margin
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - margin, y: point.y - margin) }
        dropView.onHover = { [weak model] _ in model?.acceptsDrop == true ? .copy : [] }
        dropView.onDrop = { [weak model] point, info in
            model?.dropOnPanel(at: local(point), info: info) ?? false
        }
        dropView.onPointer = { [weak model] point in model?.pointerMoved(point.map(local)) }
        dropView.onClick = { [weak model] point, event in
            guard event.type == .leftMouseDown else { return }
            model?.panelClicked(at: local(point))
        }
        dropView.onKey = { [weak model] event in
            guard let key = PanelKey(event) else { return false }
            return model?.key(key) ?? false
        }
    }

    /// Clipboard mode: take keyboard focus (Toss itself stays inactive).
    func makeKey() {
        panel.makeKey()
        panel.makeFirstResponder(dropView)
    }

    var isKey: Bool { panel.isKeyWindow }

    var isVisible: Bool { panel.isVisible && model.presentation != .closing && model.presentation != .hidden }

    /// The panel's own rectangle in screen coordinates (without the margin).
    var frame: NSRect { panel.frame.insetBy(dx: PanelMetrics.margin, dy: PanelMetrics.margin) }

    func show(on screen: NSScreen, anchorX: CGFloat) {
        generation += 1
        let size = PanelMetrics.windowSize
        let menuBarBottom = min(screen.visibleFrame.maxY, screen.frame.maxY - NSStatusBar.system.thickness)
        let half = PanelMetrics.size.width / 2
        let centerX = min(max(anchorX, screen.frame.minX + half + 8), screen.frame.maxX - half - 8)
        let top = menuBarBottom - PanelMetrics.gap + PanelMetrics.margin
        let frame = NSRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)

        if panel.isVisible, model.presentation == .open || model.presentation == .seed, panel.screen == screen {
            panel.setFrame(frame, display: true)
            return
        }
        panel.setFrame(frame, display: false)
        model.presentation = .seed
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Let SwiftUI lay out the seed pill before springing open.
        DispatchQueue.main.async { [model] in
            withAnimation(Motion.spring(response: 0.42, damping: 0.74)) {
                model.presentation = .open
            }
        }
    }

    func hide() {
        guard panel.isVisible, model.presentation != .closing else { return }
        generation += 1
        let current = generation
        withAnimation(.easeIn(duration: 0.2)) {
            model.presentation = .closing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
            self.model.presentation = .hidden
        }
    }
}

// MARK: - SwiftUI content

struct PanelView: View {
    @ObservedObject var model: DropCoordinator
    @ObservedObject private var cards = CardLoader.shared

    private var isOpen: Bool { model.presentation == .open }

    var body: some View {
        let full = PanelMetrics.size
        let seed = PanelMetrics.seedSize
        let size = model.presentation == .seed ? seed : full
        let radius = model.presentation == .seed ? seed.height / 2 : PanelMetrics.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            PanelSurface(material: PanelMaterial.current, cornerRadius: radius)
            ZStack(alignment: .topLeading) {
                DotGrid(cursor: model.cursor)
                if let glow = model.glow {
                    GlowBloom(glow: glow).id(glow.id)
                }
                avatarRow
                cardLayer
                chips
                label
                    .frame(width: full.width - 56)
                    .position(x: full.width / 2, y: PanelMetrics.labelY)
            }
            .frame(width: full.width, height: full.height)
            .opacity(isOpen ? 1 : 0)
            .animation(.easeOut(duration: isOpen ? 0.25 : 0.12).delay(isOpen ? 0.08 : 0), value: isOpen)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(rimColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 3)
        .scaleEffect(model.presentation == .closing ? 0.9 : 1, anchor: .top)
        .opacity(model.presentation == .closing ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, PanelMetrics.margin)
        .environment(\.colorScheme, .dark)
    }

    private var hasFailure: Bool {
        model.phase == .delivering && model.deliveries.allSatisfy(\.shown.isFinished)
            && model.deliveries.contains { if case .failed = $0.shown { true } else { false } }
    }

    private var rimColor: Color { hasFailure ? .red.opacity(0.45) : .white.opacity(0.16) }

    // MARK: Avatars

    private var avatarRow: some View {
        let count = model.targets.count
        let delivering = model.phase == .delivering
        return ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
            let picked = model.picks.contains(target.id)
            let isHovered = model.hovered == index && !picked && model.phase == .dragging
            let ring = model.dwell.flatMap { $0.kind == .pick && $0.targetID == target.id ? $0.progress : nil }
            ZStack {
                Circle().fill(.white).frame(width: PanelMetrics.avatarDiameter + 3.2)
                    .opacity(isHovered ? 1 : 0)
                AvatarView(target: target, size: PanelMetrics.avatarDiameter)
                    .clipShape(Circle())
                if let ring {
                    Circle()
                        .trim(from: 0, to: ring)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: PanelMetrics.avatarDiameter + 10, height: PanelMetrics.avatarDiameter + 10)
                        .shadow(color: .white.opacity(0.5), radius: 3)
                }
            }
            .scaleEffect(isHovered ? 1.06 : 1)
            .opacity(delivering ? 0 : (picked ? 0.28 : 1))
            .animation(Motion.spring(response: 0.3, damping: 0.7), value: isHovered)
            .animation(.easeOut(duration: 0.2), value: picked)
            .animation(.easeOut(duration: 0.25), value: delivering)
            .position(PanelMetrics.avatarCenter(index, of: count))
        }
    }

    // MARK: Card

    @ViewBuilder
    private var cardLayer: some View {
        if let card = model.card {
            let state = model.cardState
            let delivering = model.phase == .delivering
            CardView(content: card, cards: cards)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.cardSize = $0 }
                .overlay { SendRing(progress: model.sendProgress, cornerRadius: card.cornerRadius) }
                .scaleEffect(state == .shown ? (delivering ? 0.94 : 1) : (state == .lifting ? 0.6 : 0.72))
                .opacity(state == .shown ? 1 : 0)
                .position(model.cardPoint)
                .allowsHitTesting(false)
        }
    }

    // MARK: Chips (picks on the card, then send results)

    private var chips: some View {
        let count = model.targets.count
        return ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
            let delivery = model.deliveries.firstIndex { $0.id == target.id }
            let pickOrder = model.picks.firstIndex(of: target.id)
            let placement: (CGPoint, CGFloat, Bool) = {
                if model.phase == .delivering, let delivery {
                    return (PanelMetrics.resultCenter(delivery, of: model.deliveries.count), PanelMetrics.resultDiameter, true)
                }
                if let pickOrder {
                    return (PanelMetrics.chipSlot(pickOrder, card: model.cardPoint), PanelMetrics.chipDiameter, true)
                }
                return (PanelMetrics.avatarCenter(index, of: count), PanelMetrics.avatarDiameter, false)
            }()
            let retryRing = model.dwell.flatMap { $0.kind == .retry && $0.targetID == target.id ? $0.progress : nil }
            ChipView(target: target, diameter: placement.1,
                     state: model.phase == .delivering ? delivery.map { model.deliveries[$0].shown } : nil,
                     retryProgress: retryRing)
                // Shows at once when picked; after an unpick it fades as it lands.
                .opacity(placement.2 ? 1 : 0)
                .animation(placement.2 ? .easeOut(duration: 0.08) : .easeIn(duration: 0.14).delay(0.26), value: placement.2)
                .position(placement.0)
                .zIndex(Double(pickOrder ?? delivery ?? -1))
                .allowsHitTesting(false)
        }
    }

    // MARK: Label

    private var labelFont: Font { .system(size: 13, weight: .medium) }

    @ViewBuilder
    private var label: some View {
        Group {
            switch model.phase {
            case .idle, .cancelled:
                Color.clear.frame(width: 1, height: 16).id("empty")
            case .dragging where model.source == .staged:
                clipboardLabel
            case .dragging:
                let recipients = model.pendingRecipients
                if recipients.isEmpty {
                    Color.clear.frame(width: 1, height: 16).id("empty")
                } else {
                    let names = DropCoordinator.names(recipients)
                    Text("Drop to \(names)").id("drop-\(names)")
                }
            case .delivering:
                deliveringLabel
            }
        }
        .font(labelFont)
        .foregroundStyle(.white.opacity(0.94))
        .lineLimit(1)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 0.5)
        .transition(.blurReplace)
        .animation(.easeInOut(duration: 0.2), value: labelKey)
    }

    /// Clipboard mode: a hovered avatar is named (a click sends there); with
    /// picks, just their names; the card itself is what sends.
    @ViewBuilder
    private var clipboardLabel: some View {
        if !model.picks.isEmpty {
            let names = DropCoordinator.names(model.picks.compactMap(model.target))
            Text(names)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
                .id("send-\(names)")
        } else if let hovered = model.hovered, model.targets.indices.contains(hovered) {
            Text("Send to \(model.targets[hovered].name)").id("hover-\(hovered)")
        } else {
            Color.clear.frame(width: 1, height: 16).id("empty")
        }
    }

    @ViewBuilder
    private var deliveringLabel: some View {
        let all = model.deliveries.map(\.target)
        if !model.deliveries.allSatisfy(\.shown.isFinished) {
            let pending = model.deliveries.filter { !$0.shown.isFinished }.map(\.target)
            Text("Sending to \(DropCoordinator.names(pending))").id("sending")
        } else if let firstFailure = model.deliveries.first(where: { if case .failed = $0.shown { true } else { false } }) {
            let failed = model.deliveries.filter { if case .failed = $0.shown { true } else { false } }.map(\.target)
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 0.95, green: 0.3, blue: 0.3))
                if model.showsFailureReason, case .failed(let reason) = firstFailure.shown {
                    Text(reason).id("reason")
                } else {
                    Text("Not sent to \(DropCoordinator.names(failed))").id("failed")
                }
            }
            .id(model.showsFailureReason ? "failed-reason" : "failed-title")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 0.2, green: 0.8, blue: 0.35))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                Text("Sent to \(DropCoordinator.names(all))")
            }
            .id("sent")
        }
    }

    private var labelKey: String {
        switch model.phase {
        case .idle, .cancelled: return "empty"
        case .dragging where model.source == .staged:
            let hover = model.hovered.map { "\($0)" } ?? "-"
            return "clip-" + DropCoordinator.names(model.picks.compactMap(model.target)) + hover
        case .dragging: return "drop-" + DropCoordinator.names(model.pendingRecipients)
        case .delivering:
            let finished = model.deliveries.allSatisfy(\.shown.isFinished)
            return "deliver-\(finished)-\(hasFailure)-\(model.showsFailureReason)"
        }
    }
}

/// The small floating preview of what's being dragged.
extension CardContent {
    /// Corner radius of the card's own background, for rings drawn around it.
    var cornerRadius: CGFloat {
        if case .image = self { return 10 }
        return 14
    }
}

struct CardView: View {
    let content: CardContent
    @ObservedObject var cards: CardLoader

    var body: some View {
        Group {
            switch content {
            case .link(let url):
                HStack(spacing: 9) {
                    Group {
                        if let icon = cards.icon(for: url) {
                            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "globe").font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cards.title(for: url))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(url.host() ?? "")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(width: PanelMetrics.cardSize.width, height: PanelMetrics.cardSize.height)
                .background(cardBackground)
            case .text(let text):
                Text(String(text.prefix(400)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(width: PanelMetrics.cardSize.width)
                    .background(cardBackground)
            case .image(let image):
                Group {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 84, height: 58)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            case .empty:
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 88, height: PanelMetrics.cardSize.height)
                    .background(cardBackground.opacity(0.7))
            case .files(let names, let icon):
                HStack(spacing: 9) {
                    Group {
                        if let first = names.first, let thumb = fileThumbnail(first) {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        } else if let icon {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "doc.fill").foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(names.first ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if names.count > 1 {
                        Text("\(names.count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.2)))
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: PanelMetrics.cardSize.width, height: PanelMetrics.cardSize.height)
                .background(cardBackground)
            }
        }
    }

    private func fileThumbnail(_ name: String) -> NSImage? {
        cards.thumbnails.first { $0.key.lastPathComponent == name }?.value
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return shape.fill(.white.opacity(0.13))
            .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }
}

/// A chat on the card (picked) or in the results row (sending, sent, failed).
struct ChipView: View {
    let target: Target
    let diameter: CGFloat
    let state: DropCoordinator.Delivery.State?
    let retryProgress: Double?

    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: diameter + 3, height: diameter + 3)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            AvatarView(target: target, size: diameter)
                .clipShape(Circle())
                .saturation(isFailed ? 0.3 : 1)
                .opacity(isFailed ? 0.7 : 1)
            if case .sending(let progress) = state {
                ProgressRing(progress: progress)
                    .frame(width: diameter + 9, height: diameter + 9)
                    .transition(.opacity)
            }
            if let retryProgress {
                Circle()
                    .trim(from: 0, to: retryProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter + 10, height: diameter + 10)
            }
            badge
                .offset(x: diameter * 0.36, y: diameter * 0.36)
        }
        .frame(width: diameter + 12, height: diameter + 12)
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(red: 0.2, green: 0.8, blue: 0.35))
                .font(.system(size: 13, weight: .bold))
                .background(Circle().fill(.white).padding(1))
                .transition(.scale(scale: 0.2).combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(red: 0.95, green: 0.3, blue: 0.3))
                .font(.system(size: 13, weight: .bold))
                .background(Circle().fill(.white).padding(1))
                .transition(.scale(scale: 0.2).combined(with: .opacity))
        default:
            EmptyView()
        }
    }
}

/// Hold-to-send around the clipboard card: a border that sweeps round like the
/// avatar pick ring. With Reduce Motion it brightens in place instead.
private struct SendRing: View {
    let progress: Double
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
        ZStack {
            shape.stroke(.white.opacity(0.16), lineWidth: 2.8)
            if Motion.reduce {
                shape.stroke(.white.opacity(0.95 * progress), lineWidth: 2.8)
            } else {
                shape.trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
                    .shadow(color: .white.opacity(0.6), radius: 4)
            }
        }
        .padding(-4)
        .opacity(progress > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: progress > 0)
        .allowsHitTesting(false)
    }
}

/// Upload progress around a chip; spins while the size is still unknown.
private struct ProgressRing: View {
    let progress: Double?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: progress.map { max(0.04, $0) } ?? 0.28)
                .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(progress == nil ? (spin ? 270 : -90) : -90))
                .animation(.linear(duration: 0.15), value: progress)
        }
        .onAppear {
            guard !Motion.reduce else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// The panel's backdrop: a strong blur of what's behind, darkened while
/// keeping its hue, with a faint light rim.
struct PanelSurface: View {
    let material: PanelMaterial
    let cornerRadius: CGFloat
    var dim: Double = PanelMaterial.dim

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch material {
        case .glassRegular:
            if #available(macOS 26.0, *) {
                shape.fill(.clear).glassEffect(.regular.tint(.black.opacity(0.28)), in: shape)
            } else {
                BlurView(material: .hudWindow).overlay(Color.black.opacity(0.1))
            }
        case .glassClear:
            if #available(macOS 26.0, *) {
                shape.fill(.clear).glassEffect(.clear.tint(.black.opacity(0.3)), in: shape)
            } else {
                BlurView(material: .hudWindow)
            }
        case .ultraThin:
            shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(dim)))
        case .hud:
            BlurView(material: .hudWindow)
        case .darkBlur:
            BlurView(material: .fullScreenUI).overlay(Color.black.opacity(0.26))
        }
    }
}

private struct BlurView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Dot grid across the panel; dots near the cursor grow and brighten.
private struct DotGrid: View {
    let cursor: CGPoint?

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 10.5
            let radius: CGFloat = 60
            let columns = Int(size.width / spacing)
            let rows = Int(size.height / spacing)
            let insetX = (size.width - CGFloat(columns - 1) * spacing) / 2
            let insetY = (size.height - CGFloat(rows - 1) * spacing) / 2
            for row in 0..<rows {
                for column in 0..<columns {
                    let x = insetX + CGFloat(column) * spacing
                    let y = insetY + CGFloat(row) * spacing
                    var near: CGFloat = 0
                    if let cursor {
                        let distance = hypot(x - cursor.x, y - cursor.y)
                        let t = max(0, 1 - distance / radius)
                        near = t * t * (3 - 2 * t)
                    }
                    let dot = 1.25 + 1.0 * near
                    let opacity = 0.28 + 0.66 * near
                    let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: cursor)
    }
}

/// Mint bloom that rises from where the file went in toward the avatar.
private struct GlowBloom: View {
    let glow: DropCoordinator.Glow
    @State private var stage = 0

    var body: some View {
        let point = stage >= 2 ? glow.end : glow.start
        Circle()
            .fill(RadialGradient(
                colors: [Color(red: 0.86, green: 1, blue: 0.95), Color(red: 0.45, green: 1, blue: 0.8).opacity(0.55), .clear],
                center: .center, startRadius: 0, endRadius: 60))
            .frame(width: 120, height: 120)
            .scaleEffect(stage == 0 ? 0.4 : (stage >= 3 ? 1.4 : 1))
            .opacity(stage == 0 ? 0 : (stage >= 3 ? 0 : 0.95))
            .position(point)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.14)) { stage = 1 }
                withAnimation(.easeInOut(duration: 0.4).delay(0.12)) { stage = 2 }
                withAnimation(.easeOut(duration: 0.7).delay(0.5)) { stage = 3 }
            }
    }
}

// MARK: - Material lab (TOSS_PREVIEW=lab)

/// Every material variant stacked over a backdrop image, for side-by-side
/// comparison with the reference.
struct MaterialLabView: View {
    static let variants: [(PanelMaterial, Double)] = [
        (.ultraThin, 0), (.ultraThin, 0.06), (.ultraThin, 0.12), (.hud, 0), (.glassClear, 0),
    ]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(Self.variants.enumerated()), id: \.offset) { _, variant in
                PanelSurface(material: variant.0, cornerRadius: PanelMetrics.cornerRadius, dim: variant.1)
                    .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
        }
        .padding(20)
        .environment(\.colorScheme, .dark)
    }
}
