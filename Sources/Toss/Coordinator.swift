import AppKit
import Combine
import SwiftUI

/// Drives the drop experience: when the panel shows, the preview card that
/// follows the cursor, picking several chats by dwelling on them, and the
/// parallel sends.
@MainActor
final class DropCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// A drag Toss can send is over the panel or the menu bar.
        case dragging
        /// Released over a target; sends are running or showing results.
        case delivering
        /// Released elsewhere or Esc: the card flies back and the panel closes.
        case cancelled
    }

    enum CardState: Equatable { case hidden, lifting, shown, flyingBack }

    /// What the panel is doing: following a live drag, or holding content
    /// staged for a confirm (the clipboard, or a drag after it was dropped).
    enum Source: Equatable { case drag, staged }

    /// What the ring around an avatar (or a failed chip) is filling toward.
    struct Dwell: Equatable {
        enum Kind: Equatable { case pick, retry, send }
        let kind: Kind
        let targetID: Int64
        var progress: Double
    }

    struct Delivery: Identifiable, Equatable {
        enum State: Equatable {
            case sending(Double?)
            case sent
            case failed(String)

            var isFinished: Bool { if case .sending = self { false } else { true } }
        }

        let target: Target
        /// What the send really is now.
        var state: State
        /// What the chip shows: finished results are revealed one after another.
        var shown: State
        var attempt = 0
        var id: Int64 { target.id }
    }

    /// The success bloom, in panel coordinates.
    struct Glow: Equatable {
        let id = UUID()
        let start: CGPoint
        let end: CGPoint
    }

    @Published private(set) var targets: [Target] = []
    @Published private(set) var phase: Phase = .idle
    /// Pointer in panel coordinates (top-left origin), for the dot spotlight.
    @Published private(set) var cursor: CGPoint?
    @Published private(set) var card: CardContent?
    @Published private(set) var cardState: CardState = .hidden
    @Published private(set) var cardPoint = PanelMetrics.cardRest
    /// Where the card came from, so a cancel can send it back there.
    @Published private(set) var cardOrigin = PanelMetrics.cardRest
    /// Picked chat ids, oldest first.
    @Published private(set) var picks: [Int64] = [] {
        didSet { if picks != oldValue { picksChanged() } }
    }
    /// Clipboard mode: how far the hold-to-send ring around the card has filled.
    @Published private(set) var sendProgress: Double = 0
    /// The card's laid-out size, reported by the panel view.
    var cardSize = PanelMetrics.cardSize
    /// The target under the pointer: an avatar, a menu bar avatar, or (with
    /// nothing picked) the panel column.
    @Published private(set) var hovered: Int?
    @Published private(set) var dwell: Dwell?
    @Published private(set) var deliveries: [Delivery] = []
    @Published private(set) var glow: Glow?
    @Published private(set) var showsFailureReason = false
    @Published var presentation: PanelPresentation = .hidden
    @Published private(set) var source: Source = .drag

    let preview: PreviewMode?
    private let status = StatusItemController()
    private lazy var panel = DropPanelController(model: self)
    private let watcher = DragWatcher()
    private var hideWork: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []

    /// The drag being sent, kept so a failed chat can be retried.
    private var items: [OutgoingItem] = []
    private var dropPoint: CGPoint?
    private var dwellStart: Date?
    private var dwellKey: (Dwell.Kind, Int64)?
    /// A completed dwell doesn't repeat until the pointer leaves that target.
    private var dwellConsumed = false
    private var revealQueue: [Int64] = []
    private var nextReveal = Date.distantPast
    private var revealTimerRunning = false
    private let shake = ShakeDetector()
    private var lastPoint: (CGPoint, Date)?
    private var speed: CGFloat = 0
    /// Staged mode: what will be sent (the clipboard when the panel opened, or the dropped drag).
    private var staged: DragReader.Snapshot?
    /// Staged drags: file promises are received right at the drop; the send waits for this.
    private var stagedResolution: Task<DragReader.Snapshot, Never>?
    /// Staged drags close by flying the card back; the clipboard just closes.
    private var stagedFromDrag = false
    /// Clipboard mode: the app to give focus back to.
    private var previousApp: NSRunningApplication?
    private var outsideClickMonitor: Any?

    /// Time to hold still on an avatar to pick it.
    static let dwellDuration: TimeInterval = 0.5
    /// Time to hold still on the card to send to the picks.
    static let sendDwellDuration: TimeInterval = 1.5
    /// Clipboard mode: the card only takes a hold once the pointer has come
    /// onto it (or moved on it) since it opened or the picks last changed.
    private var sendArmed = false
    private var armAnchor: CGPoint?

    var menuProvider: (() -> NSMenu)? {
        get { status.menuProvider }
        set { status.menuProvider = newValue }
    }

    init(preview: PreviewMode?) {
        self.preview = preview
        status.onHover = { [weak self] index in self?.statusHovered(index) ?? [] }
        status.onExit = {}
        status.onDrop = { [weak self] index, info in self?.dropOnStatus(index, info: info) ?? false }
        status.onClick = { [weak self] in self?.toggleClipboard() }
        watcher.onMove = { [weak self] point in self?.dragMoved(to: point) }
        watcher.onEnd = { [weak self] in self?.dragEnded() }
        watcher.onEscape = { [weak self] in self?.cancel() }
        watcher.start()

        if let preview {
            targets = preview.targets
        } else {
            let telegram = Telegram.shared
            let preferences = Preferences.shared
            telegram.objectWillChange.merge(with: preferences.objectWillChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshTargets() }
                .store(in: &subscriptions)
            refreshTargets()
        }
        renderStatus()
    }

    private var isEnabled: Bool {
        !targets.isEmpty && (preview != nil || Telegram.shared.step == .ready)
    }

    func refreshTargets() {
        let telegram = Telegram.shared
        guard telegram.step == .ready else {
            targets = []
            renderStatus()
            return
        }
        let fresh = Preferences.shared.targetChatIDs.compactMap { id in
            telegram.chats[id].map(telegram.target(for:))
        }
        if fresh != targets { targets = fresh }
        picks.removeAll { id in !fresh.contains { $0.id == id } }
        renderStatus()
    }

    private func renderStatus() {
        status.update(targets: targets, highlighted: phase == .dragging ? hovered : nil)
    }

    func index(of id: Int64) -> Int? { targets.firstIndex { $0.id == id } }
    func target(_ id: Int64) -> Target? { targets.first { $0.id == id } }

    // MARK: - Panel placement

    private func anchorX(on screen: NSScreen) -> CGFloat {
        guard let anchor = status.anchor else { return screen.frame.maxX - 220 }
        return screen.frame.maxX - (anchor.screen.frame.maxX - anchor.x)
    }

    private func showPanel(on screen: NSScreen? = nil) {
        cancelHide()
        let screen = screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? status.anchor?.screen ?? NSScreen.main
        guard let screen else { return }
        panel.show(on: screen, anchorX: anchorX(on: screen))
    }

    private func hidePanel(after delay: TimeInterval = 0) {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.hide()
            self.endClipboardFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                guard let self, self.presentation == .hidden else { return }
                self.reset()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func reset() {
        pointerTarget = nil
        cursor = nil
        card = nil
        cardState = .hidden
        picks = []
        hovered = nil
        dwell = nil
        dwellKey = nil
        deliveries = []
        glow = nil
        showsFailureReason = false
        items = []
        revealQueue = []
        shake.reset()
        staged = nil
        stagedResolution = nil
        stagedFromDrag = false
        source = .drag
        phase = .idle
        sendArmed = false
        armAnchor = nil
        sendProgress = 0
        renderStatus()
    }

    // MARK: - Drag tracking

    /// Global pointer position while the mouse button is held during a drag.
    private func dragMoved(to point: NSPoint) {
        guard isEnabled else { return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
        let anchor = anchorX(on: screen)
        switch phase {
        case .idle:
            guard point.y > screen.frame.maxY - 120, abs(point.x - anchor) < 280 else { return }
            let snapshot = DragReader.snapshot(NSPasteboard(name: .drag))
            guard let content = CardLoader.shared.content(for: snapshot) else { return }
            showPanel(on: screen)
            begin(with: content, at: panelPoint(point))
            track(panelPoint(point), statusIndex: status.index(atScreen: point))
        case .dragging where source == .staged:
            break
        case .dragging:
            let menuBarStrip = NSRect(x: anchor - 300, y: screen.frame.maxY - 60, width: 600, height: 60)
            if picks.isEmpty, !panel.frame.insetBy(dx: -80, dy: -80).contains(point), !menuBarStrip.contains(point) {
                hidePanel()
                phase = .cancelled
                return
            }
            track(panelPoint(point), statusIndex: status.index(atScreen: point))
        case .delivering, .cancelled:
            break
        }
    }

    private func panelPoint(_ screenPoint: NSPoint) -> CGPoint {
        let frame = panel.frame
        return CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    }

    private func dragEnded() {
        // performDragOperation lands just after mouse-up; give it a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .dragging where self.source == .drag: self.cancel()
            case .cancelled where self.presentation == .hidden: self.reset()
            default: break
            }
        }
    }

    /// Opens a drag session with a card for what's being dragged.
    func begin(with content: CardContent, at point: CGPoint) {
        cancelHide()
        reset()
        card = content
        phase = .dragging
        let start = CGPoint(x: clampCardX(point.x), y: PanelMetrics.size.height - 30)
        cardOrigin = start
        cardPoint = start
        cardState = .lifting
        DispatchQueue.main.async { [weak self] in
            withAnimation(Motion.spring(response: 0.45, damping: 0.7)) { self?.cardState = .shown }
        }
    }

    private func clampCardX(_ x: CGFloat) -> CGFloat {
        let half = PanelMetrics.cardSize.width / 2 + 14
        return min(max(x, half), PanelMetrics.size.width - half)
    }

    /// One pointer sample during a drag (real or scripted), in panel coordinates.
    func track(_ point: CGPoint, statusIndex: Int? = nil) {
        guard phase == .dragging else { return }
        let now = Date()
        noteSpeed(point, now)

        let inside = CGRect(origin: .zero, size: PanelMetrics.size).contains(point)
        cursor = inside ? point : nil
        // The card trails the pointer a little below it, inside the panel.
        let y = min(max(point.y + 40, PanelMetrics.cardTopLimit), PanelMetrics.cardBottomLimit)
        let follow = CGPoint(x: clampCardX(point.x), y: y)
        if follow != cardPoint {
            withAnimation(Motion.follow) { cardPoint = follow }
        }

        let avatar = statusIndex ?? (inside ? avatarIndex(at: point) : nil)
        var hover = avatar
        if hover == nil, picks.isEmpty, inside { hover = column(at: point) }
        if hover != hovered {
            hovered = hover
            renderStatus()
        }

        if !picks.isEmpty, shake.add(point, at: now) {
            withAnimation(Motion.spring(response: 0.42, damping: 0.62)) { _ = picks.popLast() }
            resetDwell()
            return
        }
        updateDwell(avatar.map { (.pick, targets[$0].id) }, now: now)
    }

    private func noteSpeed(_ point: CGPoint, _ now: Date) {
        if let (last, time) = lastPoint {
            let dt = max(now.timeIntervalSince(time), 1.0 / 240)
            let instant = hypot(point.x - last.x, point.y - last.y) / dt
            speed = speed * 0.6 + instant * 0.4
        }
        lastPoint = (point, now)
    }

    private func avatarIndex(at point: CGPoint) -> Int? {
        targets.indices.first { index in
            let center = PanelMetrics.avatarCenter(index, of: targets.count)
            return hypot(point.x - center.x, point.y - center.y) <= PanelMetrics.avatarDiameter / 2 + 7
        }
    }

    func column(at point: CGPoint) -> Int? {
        guard !targets.isEmpty else { return nil }
        let index = Int(point.x / (PanelMetrics.size.width / CGFloat(targets.count)))
        return min(max(index, 0), targets.count - 1)
    }

    // MARK: - Dwell (pick, unpick, retry)

    private func updateDwell(_ key: (Dwell.Kind, Int64)?, now: Date) {
        guard let key else {
            resetDwell()
            return
        }
        if let current = dwellKey, current.0 == key.0, current.1 == key.1 {
            guard !dwellConsumed, let start = dwellStart else { return }
            let duration = key.0 == .send ? Self.sendDwellDuration : Self.dwellDuration
            let progress = min(1, now.timeIntervalSince(start) / duration)
            // Show the ring only once the pointer has clearly stopped here.
            if key.0 == .send {
                sendProgress = progress > 0.1 ? progress : 0
            } else {
                dwell = progress > 0.12 ? Dwell(kind: key.0, targetID: key.1, progress: progress) : nil
            }
            if progress >= 1 {
                dwellConsumed = true
                completeDwell(key)
            }
        } else {
            resetDwell()
            dwellKey = key
            // Passing over at speed doesn't start a pick.
            dwellStart = speed < 260 ? now : nil
            if dwellStart == nil { dwellKey = nil }
        }
    }

    private func consumeDwell() {
        dwellConsumed = true
        if dwell != nil { withAnimation(.easeOut(duration: 0.12)) { dwell = nil } }
        unwindSendRing()
    }

    private func resetDwell() {
        dwellKey = nil
        dwellStart = nil
        dwellConsumed = false
        if dwell != nil { withAnimation(.easeOut(duration: 0.15)) { dwell = nil } }
        unwindSendRing()
    }

    private func unwindSendRing() {
        if sendProgress > 0 { withAnimation(.easeOut(duration: 0.25)) { sendProgress = 0 } }
    }

    private func completeDwell(_ key: (Dwell.Kind, Int64)) {
        withAnimation(.easeOut(duration: 0.12)) { dwell = nil }
        switch key.0 {
        case .pick:
            if source == .staged, staged == nil { return }
            withAnimation(Motion.spring(response: 0.42, damping: 0.62)) {
                if let index = picks.firstIndex(of: key.1) {
                    picks.remove(at: index)
                } else {
                    picks.append(key.1)
                }
            }
            if picks.isEmpty, source == .drag, let point = cursor { hovered = column(at: point) }
        case .retry:
            retry(key.1)
        case .send:
            unwindSendRing()
            guard source == .staged, !picks.isEmpty else { return }
            sendClipboard(adding: nil)
        }
    }

    /// Pointer over the panel with no drag (moving to a failed chip to retry it).
    /// Pointer over the panel with no drag: choosing chats in clipboard mode,
    /// or moving to a failed chip to retry it.
    func pointerMoved(_ point: CGPoint?) {
        let now = Date()
        switch phase {
        case .dragging where source == .staged:
            cursor = point
            if let point { noteSpeed(point, now) } else { lastPoint = nil }
            let avatar = point.flatMap(avatarIndex)
            if avatar != hovered {
                hovered = avatar
                renderStatus()
            }
            let onCard = point.map(cardContains) ?? false
            if let point, onCard {
                // Already on the card: it counts once the pointer moves noticeably.
                if !sendArmed {
                    if let anchor = armAnchor {
                        if hypot(point.x - anchor.x, point.y - anchor.y) > 14 { sendArmed = true }
                    } else {
                        armAnchor = point
                    }
                }
            } else {
                // Off the card: coming back onto it counts.
                sendArmed = true
                armAnchor = nil
            }
            let sendKey: (Dwell.Kind, Int64)? = onCard && sendArmed && !picks.isEmpty ? (.send, 0) : nil
            pointerTarget = avatar.map { (.pick, targets[$0].id) } ?? sendKey
            updateDwell(pointerTarget, now: now)
        case .delivering:
            cursor = point
            if point != nil { keepResultsOpen() }
            let failed = point.flatMap { point in
                deliveries.indices.first { index in
                    guard case .failed = deliveries[index].shown else { return false }
                    let center = PanelMetrics.resultCenter(index, of: deliveries.count)
                    return hypot(point.x - center.x, point.y - center.y) <= PanelMetrics.resultDiameter / 2 + 8
                }
            }
            speed = 0
            pointerTarget = failed.map { (.retry, deliveries[$0].id) }
            updateDwell(pointerTarget, now: now)
        default:
            return
        }
        keepDwellTicking()
    }

    /// Mouse-moved events stop when the pointer rests; keep the ring filling.
    private func keepDwellTicking() {
        guard pointerTarget != nil, dwellTimer == nil else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let key = self.pointerTarget,
                      self.phase == .delivering || (self.phase == .dragging && self.source == .staged) else {
                    timer.invalidate()
                    self?.dwellTimer = nil
                    return
                }
                self.speed *= 0.6
                self.updateDwell(key, now: Date())
            }
        }
    }

    private var dwellTimer: Timer?
    /// What the resting pointer is over (no-drag modes), so the ring keeps filling.
    private var pointerTarget: (Dwell.Kind, Int64)?

    // MARK: - Status item

    private func statusHovered(_ index: Int) -> NSDragOperation {
        guard isEnabled, phase == .dragging || phase == .idle else { return [] }
        if phase == .idle {
            let snapshot = DragReader.snapshot(NSPasteboard(name: .drag))
            guard let content = CardLoader.shared.content(for: snapshot) else { return [] }
            showPanel(on: status.anchor?.screen)
            begin(with: content, at: PanelMetrics.avatarCenter(index, of: targets.count))
        }
        return .copy
    }

    // MARK: - Drop

    var acceptsDrop: Bool { isEnabled && phase == .dragging && source == .drag }

    func dropOnPanel(at point: CGPoint, info: NSDraggingInfo) -> Bool {
        guard acceptsDrop else { return false }
        return drop(DragReader.snapshot(info.draggingPasteboard), at: point, avatar: avatarIndex(at: point))
    }

    private func dropOnStatus(_ index: Int, info: NSDraggingInfo) -> Bool {
        guard acceptsDrop else { return false }
        if !panel.isVisible { showPanel(on: status.anchor?.screen) }
        return drop(DragReader.snapshot(info.draggingPasteboard),
                    at: PanelMetrics.avatarCenter(index, of: targets.count), avatar: index)
    }

    /// A release over the panel or a menu bar avatar. With confirm on, it only
    /// stages: the avatar joins the picks and the panel waits like the
    /// clipboard panel. With confirm off, it sends at once.
    private func drop(_ snapshot: DragReader.Snapshot, at point: CGPoint, avatar: Int?, takeFocus: Bool = true) -> Bool {
        guard Preferences.shared.confirmDrops else {
            return deliver(snapshot, adding: avatar ?? (picks.isEmpty ? column(at: point) : nil), at: point)
        }
        guard !snapshot.isEmpty, !picks.isEmpty || avatar != nil else { return false }
        stage(snapshot, adding: avatar, at: point, takeFocus: takeFocus)
        return true
    }

    private func stage(_ snapshot: DragReader.Snapshot, adding avatar: Int?, at point: CGPoint, takeFocus: Bool) {
        cancelHide()
        // Promised files (Photos, Mail, browsers) must be received now, while
        // the source still honours the drop; the send uses what arrived.
        stagedResolution = snapshot.promises.isEmpty ? nil : Task { await DragReader.resolved(snapshot) }
        staged = snapshot
        stagedFromDrag = true
        source = .staged
        resetDwell()
        pointerTarget = nil
        hovered = nil
        cursor = CGRect(origin: .zero, size: PanelMetrics.size).contains(point) ? point : nil
        // Dropped on an avatar: resting there afterwards must not unpick it.
        if let avatar, targets.indices.contains(avatar) {
            dwellKey = (.pick, targets[avatar].id)
            dwellConsumed = true
        }
        withAnimation(Motion.spring(response: 0.45, damping: 0.72)) {
            if let avatar, targets.indices.contains(avatar), !picks.contains(targets[avatar].id) {
                picks.append(targets[avatar].id)
            }
            cardPoint = PanelMetrics.cardClipboard
            cardState = .shown
        }
        // The pointer usually ends up resting where the card lands.
        sendArmed = false
        armAnchor = cursor
        renderStatus()
        if takeFocus { takeStagedFocus() }
    }

    /// The staged panel takes keys without activating Toss; a click outside closes it.
    private func takeStagedFocus() {
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.makeKey()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeClipboard() }
        }
    }

    /// Picks plus the avatar dropped on (if any); with nothing picked, just that one.
    @discardableResult
    func deliver(_ snapshot: DragReader.Snapshot, adding index: Int?, at point: CGPoint,
                 resolution: Task<DragReader.Snapshot, Never>? = nil) -> Bool {
        var ids = picks
        if let index, targets.indices.contains(index), !ids.contains(targets[index].id) {
            ids.append(targets[index].id)
        }
        let recipients = ids.compactMap(target)
        guard !recipients.isEmpty, !snapshot.isEmpty else { return false }
        cancelHide()
        resetDwell()
        pointerTarget = nil
        dropPoint = point
        showsFailureReason = false
        withAnimation(Motion.spring(response: 0.5, damping: 0.68)) {
            phase = .delivering
            hovered = nil
            cursor = nil
            cardPoint = PanelMetrics.cardDelivering
            deliveries = recipients.map { Delivery(target: $0, state: .sending(nil), shown: .sending(nil)) }
        }
        renderStatus()
        let imagesAsPhotos = Preferences.shared.imagesAsPhotos
        Task { [weak self] in
            let resolved = await resolution?.value ?? snapshot
            let payloads = await DragReader.payloads(from: resolved)
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try OutgoingBuilder.build(payloads, imagesAsPhotos: imagesAsPhotos)
                }.value
                guard let self else { return }
                self.items = items
                for recipient in recipients { self.send(to: recipient.id) }
            } catch {
                guard let self else { return }
                for recipient in recipients {
                    self.finish(recipient.id, .failed(Telegram.describeSendError(error)))
                }
            }
        }
        return true
    }

    private func send(to id: Int64) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }) else { return }
        deliveries[index].attempt += 1
        let attempt = deliveries[index].attempt
        let items = self.items
        Task { [weak self] in
            guard let self else { return }
            let progress: (Double) -> Void = { [weak self] value in self?.setProgress(value, for: id, attempt: attempt) }
            do {
                if let preview = self.preview {
                    try await preview.simulateSend(to: id, attempt: attempt, progress: progress)
                } else {
                    try await Telegram.shared.send(items, to: id, progress: progress)
                }
                self.finish(id, .sent, attempt: attempt)
            } catch {
                self.finish(id, .failed(Telegram.describeSendError(error)), attempt: attempt)
            }
        }
    }

    private func retry(_ id: Int64) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }), !items.isEmpty || preview != nil else { return }
        keepResultsOpen()
        withAnimation(Motion.spring(response: 0.35, damping: 0.7)) {
            deliveries[index].state = .sending(nil)
            deliveries[index].shown = .sending(nil)
            showsFailureReason = false
            glow = nil
        }
        send(to: id)
    }

    private func setProgress(_ value: Double, for id: Int64, attempt: Int) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }), deliveries[index].attempt == attempt,
              case .sending = deliveries[index].state else { return }
        deliveries[index].state = .sending(value)
        deliveries[index].shown = .sending(value)
    }

    private func finish(_ id: Int64, _ state: Delivery.State, attempt: Int? = nil) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }) else { return }
        if let attempt, deliveries[index].attempt != attempt { return }
        deliveries[index].state = state
        revealQueue.append(id)
        revealNext()
    }

    /// Shows finished results one by one, at least `stagger` apart.
    private func revealNext() {
        guard !revealTimerRunning, !revealQueue.isEmpty else { return }
        let stagger: TimeInterval = 0.16
        let wait = max(0, nextReveal.timeIntervalSinceNow)
        revealTimerRunning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.revealTimerRunning = false
            guard !self.revealQueue.isEmpty else { return }
            let id = self.revealQueue.removeFirst()
            if let index = self.deliveries.firstIndex(where: { $0.id == id }) {
                withAnimation(Motion.spring(response: 0.38, damping: 0.58)) {
                    self.deliveries[index].shown = self.deliveries[index].state
                }
            }
            self.nextReveal = Date().addingTimeInterval(stagger)
            self.resultsChanged()
            self.revealNext()
        }
    }

    private func resultsChanged() {
        guard deliveries.allSatisfy({ $0.shown.isFinished }) else { return }
        let failed = deliveries.filter { if case .failed = $0.shown { true } else { false } }
        if failed.isEmpty {
            let end: CGPoint
            if deliveries.count == 1, let index = index(of: deliveries[0].id) {
                end = CGPoint(x: PanelMetrics.avatarCenter(index, of: targets.count).x, y: -6)
            } else {
                end = CGPoint(x: PanelMetrics.size.width / 2, y: -6)
            }
            glow = Glow(start: PanelMetrics.cardDelivering, end: end)
            SentSound.play()
            if preview?.pinned != true { hidePanel(after: 1.4) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                guard let self, self.phase == .delivering,
                      self.deliveries.contains(where: { if case .failed = $0.shown { true } else { false } }) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { self.showsFailureReason = true }
            }
            keepResultsOpen()
        }
    }

    /// With a failure on screen, the panel waits for a retry; it closes a few
    /// seconds after the pointer stops visiting it.
    private func keepResultsOpen() {
        guard preview?.pinned != true, phase == .delivering else { return }
        let pending = deliveries.contains { !$0.shown.isFinished }
        if !pending, deliveries.allSatisfy({ $0.shown == .sent }) { return }
        hidePanel(after: 5)
    }

    func panelClicked(at point: CGPoint) {
        if phase == .dragging, source == .staged {
            if let index = avatarIndex(at: point) {
                // The click decides; a ring filling under the pointer stops.
                if dwellKey?.1 == targets[index].id { consumeDwell() }
                if picks.isEmpty {
                    sendClipboard(adding: index)
                } else {
                    toggle(targets[index].id)
                }
            } else if !picks.isEmpty, cardContains(point) {
                consumeDwell()
                sendClipboard(adding: nil)
            }
            return
        }
        guard phase == .delivering || preview?.pinned == true else { return }
        hidePanel()
    }

    // MARK: - Clipboard

    /// The card plus a little margin, in panel coordinates.
    private func cardContains(_ point: CGPoint) -> Bool {
        let rect = CGRect(x: cardPoint.x - cardSize.width / 2, y: cardPoint.y - cardSize.height / 2,
                          width: cardSize.width, height: cardSize.height)
        return rect.insetBy(dx: -6, dy: -6).contains(point)
    }

    /// A pick changed while choosing from the clipboard: a pointer resting on
    /// the card must not send on that alone.
    private func picksChanged() {
        guard source == .staged, phase == .dragging else { return }
        if pointerTarget?.0 == .send {
            pointerTarget = nil
            resetDwell()
        }
        if cursor.map(cardContains) ?? true {
            sendArmed = false
            armAnchor = cursor
        }
    }

    /// The shortcut or a click on the avatars: open with the clipboard, or close.
    func toggleClipboard() {
        if source == .staged, phase != .idle {
            closeClipboard()
        } else if phase == .idle {
            openClipboard()
        }
    }

    /// Reads the clipboard once and shows it on a card that stays put.
    func openClipboard(pasteboard: NSPasteboard = .general, takeFocus: Bool = true, on screen: NSScreen? = nil) {
        // Also while the last results fade out: the new clipboard takes over.
        let fading = presentation == .closing && phase == .delivering && deliveries.allSatisfy(\.shown.isFinished)
        guard isEnabled, phase == .idle || presentation == .hidden || fading else {
            return
        }
        cancelHide()
        reset()
        let snapshot = DragReader.snapshot(pasteboard)
        let content = CardLoader.shared.content(for: snapshot)
        source = .staged
        staged = content == nil ? nil : snapshot
        card = content ?? .empty
        phase = .dragging
        cardOrigin = PanelMetrics.cardClipboard
        cardPoint = PanelMetrics.cardClipboard
        cardState = .lifting
        showPanel(on: screen ?? status.anchor?.screen)
        DispatchQueue.main.async { [weak self] in
            withAnimation(Motion.spring(response: 0.45, damping: 0.7)) { self?.cardState = .shown }
        }
        if takeFocus { takeStagedFocus() }
        // Nothing sendable: show the calm empty card briefly, then go.
        if content == nil { hidePanel(after: 1.1) }
    }

    /// Esc, a click outside, or the shortcut again: close without sending.
    func closeClipboard() {
        guard source == .staged, phase != .idle else { return }
        if phase == .dragging, stagedFromDrag {
            phase = .cancelled
            resetDwell()
            hovered = nil
            renderStatus()
            withAnimation(Motion.spring(response: 0.42, damping: 0.8)) {
                cardState = .flyingBack
                cardPoint = cardOrigin
                picks = []
            }
            hidePanel(after: 0.32)
            return
        }
        if phase == .dragging {
            resetDwell()
            hovered = nil
            withAnimation(Motion.spring(response: 0.42, damping: 0.8)) { picks = [] }
        }
        hidePanel()
    }

    func key(_ key: PanelKey) -> Bool {
        guard source == .staged, phase != .idle else { return false }
        switch key {
        case .escape:
            closeClipboard()
        case .send:
            guard phase == .dragging else { return phase == .delivering }
            if !picks.isEmpty { sendClipboard(adding: nil) }
        case .digit(let number):
            guard phase == .dragging, targets.indices.contains(number - 1) else { return false }
            toggle(targets[number - 1].id)
        }
        return true
    }

    private func toggle(_ id: Int64) {
        guard staged != nil else { return }
        // A ring filling on this avatar must not toggle it a second time.
        if dwellKey?.1 == id { consumeDwell() }
        withAnimation(Motion.spring(response: 0.42, damping: 0.62)) {
            if let index = picks.firstIndex(of: id) { picks.remove(at: index) } else { picks.append(id) }
        }
    }

    private func sendClipboard(adding index: Int?) {
        guard let staged else { return }
        let point = index.map { PanelMetrics.avatarCenter($0, of: targets.count) } ?? PanelMetrics.cardClipboard
        deliver(staged, adding: index, at: point, resolution: stagedResolution)
    }

    /// Clipboard mode leaves without having activated Toss; if anything did
    /// activate it, hand focus back to where the user was.
    private func endClipboardFocus() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        if NSApp.isActive, let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        previousApp = nil
    }

    // MARK: - Cancel

    /// Released outside the panel, or Esc: the card goes back where it came from.
    func cancel() {
        guard phase == .dragging, source == .drag else { return }
        phase = .cancelled
        resetDwell()
        hovered = nil
        renderStatus()
        withAnimation(Motion.spring(response: 0.42, damping: 0.8)) {
            cardState = .flyingBack
            cardPoint = cardOrigin
            picks = []
        }
        hidePanel(after: 0.32)
    }

    // MARK: - Labels

    /// The chats a release right now would send to.
    var pendingRecipients: [Target] {
        var ids = picks
        if let hovered, targets.indices.contains(hovered), !ids.contains(targets[hovered].id) {
            ids.append(targets[hovered].id)
        }
        return ids.compactMap(target)
    }

    static func names(_ targets: [Target]) -> String {
        switch targets.count {
        case 0: ""
        case 1: targets[0].name
        case 2: "\(targets[0].name), \(targets[1].name)"
        default: "\(targets[0].name), \(targets[1].name) +\(targets.count - 2)"
        }
    }

    // MARK: - Preview

    func showPreviewState() {
        guard let preview else { return }
        let screen = preview.screen ?? status.anchor?.screen ?? NSScreen.main
        showPanel(on: screen)
        PreviewScript(model: self, preview: preview).run()
    }

    /// For the preview script: a fake drop with the preview's content.
    func scriptedDrop(at point: CGPoint) {
        guard phase == .dragging, source == .drag else { return }
        if !drop(preview?.snapshot ?? DragReader.Snapshot(), at: point, avatar: avatarIndex(at: point), takeFocus: false) {
            cancel()
        }
    }

    func scriptedShow() { showPanel(on: preview?.screen) }

    var isStagedDrag: Bool { source == .staged && stagedFromDrag }

    /// For stills: the hold-to-send ring stopped partway, with two picks.
    func scriptedSendRing(_ progress: Double, pasteboard: NSPasteboard) {
        openClipboard(pasteboard: pasteboard, takeFocus: false, on: preview?.screen)
        picks = [3, 6]
        cursor = PanelMetrics.cardClipboard
        sendProgress = progress
    }
}

/// Spots a quick side-to-side shake: three fast direction changes within
/// 0.6 s, each stroke at least 40 pt long. Ordinary moves between avatars
/// are one or two strokes and slower, so they don't trigger it.
final class ShakeDetector {
    private struct Stroke { var direction: CGFloat; var length: CGFloat; var peak: CGFloat; var end: Date }
    private var strokes: [Stroke] = []
    private var last: (CGPoint, Date)?
    private var cooldownUntil = Date.distantPast

    func reset() {
        strokes = []
        last = nil
    }

    /// Returns true once per shake.
    func add(_ point: CGPoint, at time: Date) -> Bool {
        defer { last = (point, time) }
        guard let (previous, previousTime) = last else { return false }
        let dx = point.x - previous.x
        let dt = max(time.timeIntervalSince(previousTime), 1.0 / 240)
        guard abs(dx) > 0.5 else { return false }
        let direction: CGFloat = dx > 0 ? 1 : -1
        let speed = abs(dx) / dt
        if var current = strokes.last, current.direction == direction {
            current.length += abs(dx)
            current.peak = max(current.peak, speed)
            current.end = time
            strokes[strokes.count - 1] = current
        } else {
            strokes.append(Stroke(direction: direction, length: abs(dx), peak: speed, end: time))
        }
        strokes.removeAll { time.timeIntervalSince($0.end) > 0.6 }
        let strong = strokes.filter { $0.length >= 40 && $0.peak >= 900 }
        guard time >= cooldownUntil, strong.count >= 4 else { return false }
        strokes = []
        cooldownUntil = time.addingTimeInterval(0.8)
        return true
    }
}

/// Springs everywhere, or short fades when Reduce Motion is on.
enum Motion {
    static var reduce: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || ProcessInfo.processInfo.environment["TOSS_PREVIEW_REDUCE_MOTION"] == "1"
    }

    static func spring(response: Double, damping: Double) -> Animation {
        reduce ? .easeInOut(duration: 0.18) : .spring(response: response, dampingFraction: damping)
    }

    /// The card trailing the pointer.
    static var follow: Animation? {
        reduce ? nil : .interactiveSpring(response: 0.32, dampingFraction: 0.78)
    }
}

enum SentSound {
    private static let sound: NSSound? = {
        let candidates = [
            "/System/Library/Frameworks/Social.framework/Versions/A/Resources/Sent.aiff",
            "/System/Library/PrivateFrameworks/IMDaemonCore.framework/Versions/A/Resources/Sent Message.aiff",
            "/System/Library/Sounds/Pop.aiff",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) { return sound }
        }
        return NSSound(named: "Pop")
    }()

    @MainActor static func play() {
        guard Preferences.shared.playSound else { return }
        sound?.stop()
        sound?.play()
    }
}

