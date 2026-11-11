import AppKit

/// Debug mode for checking the UI without a Telegram login.
///
///     TOSS_PREVIEW=panel|setup|settings|lab   which UI to show (lab: material variants)
///     TOSS_PREVIEW_STATE=demo|clipboard|card:link|card:text|card:image|card:files|shaketest
///     TOSS_PREVIEW_BACKDROP=<image>   lab/panel: image filling the screen behind the panel
///     TOSS_PREVIEW_MATERIAL=<PanelMaterial>   override the panel material
///     TOSS_PREVIEW_REDUCE_MOTION=1   act as if Reduce Motion were on
///     TOSS_PREVIEW_DISPLAY=<CGDirectDisplayID>   screen for the panel
///
/// Fake contacts, simulated sends, no keychain or TDLib access.
struct PreviewMode {
    enum Screen: String { case panel, setup, settings, lab }
    enum State: Equatable {
        case demo
        case clipboard
        case sendCheck
        case dragCheck
        case sendRing(Double)
        case card(String)
        case shakeTest
    }

    let screenKind: Screen
    let state: State
    let screen: NSScreen?

    /// A pinned panel stays up so it can be screenshotted.
    var pinned: Bool {
        guard screenKind == .panel else { return false }
        switch state {
        case .demo, .clipboard, .shakeTest, .sendCheck, .dragCheck: return false
        case .card, .sendRing: return true
        }
    }

    static let demoLink = URL(string: "https://www.apple.com/macos/")!

    static func fromEnvironment() -> PreviewMode? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TOSS_PREVIEW"], !raw.isEmpty else { return nil }
        let kind = Screen(rawValue: raw) ?? .panel
        var state = State.demo
        if let value = env["TOSS_PREVIEW_STATE"] {
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts.first {
            case "card": state = .card(parts.count > 1 ? parts[1] : "link")
            case "shaketest": state = .shakeTest
            case "clipboard": state = .clipboard
            case "sendcheck": state = .sendCheck
            case "dragcheck": state = .dragCheck
            case "sendring": state = .sendRing(parts.count > 1 ? Double(parts[1]) ?? 0.65 : 0.65)
            default: state = .demo
            }
        }
        var screen: NSScreen?
        if let id = env["TOSS_PREVIEW_DISPLAY"].flatMap(UInt32.init) {
            screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
        }
        return PreviewMode(screenKind: kind, state: state, screen: screen)
    }

    var targets: [Target] {
        [
            Target(id: 1, name: L("Me"), photoPath: nil, isSavedMessages: true),
            Target(id: 2, name: "Rodrigo", photoPath: nil, isSavedMessages: false),
            Target(id: 3, name: "Amina", photoPath: nil, isSavedMessages: false),
            Target(id: 4, name: "Design Team", photoPath: nil, isSavedMessages: false),
            Target(id: 6, name: "Chris", photoPath: nil, isSavedMessages: false),
        ]
    }

    var snapshot: DragReader.Snapshot {
        var snapshot = DragReader.Snapshot()
        snapshot.link = Self.demoLink
        snapshot.linkTitle = "macOS Tahoe – Apple"
        return snapshot
    }

    /// Fake upload: chat 4 fails on its first try, the rest succeed at different speeds.
    func simulateSend(to id: Int64, attempt: Int, progress: @escaping (Double) -> Void) async throws {
        let duration: Double = [2: 0.8, 3: 0.75, 4: 0.6, 6: 1.1][id] ?? 0.8
        let steps = 12
        for step in 1...steps {
            try await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1e9))
            if id == 4, attempt == 1, step == steps / 2 {
                throw TDError(code: 403, message: "CHAT_WRITE_FORBIDDEN")
            }
            progress(Double(step) / Double(steps))
        }
    }
}

/// Scripted pointer paths for previews and screen recordings.
@MainActor
struct PreviewScript {
    let model: DropCoordinator
    let preview: PreviewMode

    private var size: CGSize { PanelMetrics.size }

    func run() {
        switch preview.state {
        case .demo: demo()
        case .clipboard: clipboardDemo()
        case .sendCheck: sendCheck()
        case .dragCheck: dragCheck()
        case .sendRing(let progress):
            model.scriptedSendRing(progress, pasteboard: Self.scratch(link: true))
        case .card(let kind): card(kind)
        case .shakeTest: shakeTest()
        }
    }

    private func avatar(_ index: Int) -> CGPoint {
        PanelMetrics.avatarCenter(index, of: model.targets.count)
    }

    /// One card kind, pinned with the pointer over Rodrigo's column.
    private func card(_ kind: String) {
        let content: CardContent
        switch kind {
        case "text":
            content = .text("Lunch at 1? The place on the corner\nhas a new menu, and I booked a table\nfor four. Bring the slides.")
        case "image":
            let image = NSImage(size: NSSize(width: 168, height: 116), flipped: false) { rect in
                NSGradient(colors: [NSColor(hex: 0xFF9A5A), NSColor(hex: 0xE0457B), NSColor(hex: 0x6A5CFF)])?
                    .draw(in: rect, angle: -35)
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: 112, y: 70, width: 26, height: 26)).fill()
                return true
            }
            content = .image(image)
        case "files":
            content = .files(names: ["Q3 Roadmap.pdf", "Notes.md", "Budget.numbers"],
                             icon: NSWorkspace.shared.icon(for: .pdf))
        default:
            content = CardLoader.shared.content(for: preview.snapshot) ?? .link(PreviewMode.demoLink)
        }
        model.begin(with: content, at: CGPoint(x: size.width / 2, y: size.height))
        play(path(from: CGPoint(x: size.width / 2, y: size.height + 10), to: CGPoint(x: avatar(1).x, y: 100), start: 0.2, duration: 0.5))
    }

    /// The recorded demo: a link is dragged in, two people picked, one unpicked,
    /// another picked, then dropped on a fifth; one send fails and is retried by
    /// hovering it. Then a text drag is cancelled. Repeats.
    private func demo() {
        var samples: [(TimeInterval, () -> Void)] = []
        func move(_ from: CGPoint, _ to: CGPoint, _ start: TimeInterval, _ duration: TimeInterval) {
            for (time, point) in path(from: from, to: to, start: start, duration: duration) {
                samples.append((time, { model.track(point) }))
            }
        }
        func hold(_ point: CGPoint, _ start: TimeInterval, _ duration: TimeInterval) {
            let frames = Int(duration * 60)
            for frame in 0...frames {
                samples.append((start + Double(frame) / 60, { model.track(point) }))
            }
        }
        func at(_ time: TimeInterval, _ action: @escaping () -> Void) { samples.append((time, action)) }

        let entry = CGPoint(x: size.width * 0.62, y: size.height + 20)
        let a1 = avatar(1), a2 = avatar(2), a3 = avatar(3), a4 = avatar(4)
        let below = { (p: CGPoint) in CGPoint(x: p.x, y: p.y + 58) }

        at(0) {
            model.scriptedShow()
            if let content = CardLoader.shared.content(for: preview.snapshot) {
                model.begin(with: content, at: entry)
            }
        }
        move(entry, CGPoint(x: size.width * 0.5, y: 120), 0.15, 0.55)
        // Pick Rodrigo.
        move(CGPoint(x: size.width * 0.5, y: 120), a1, 0.8, 0.5)
        hold(a1, 1.3, 0.75)
        // Pick Amina.
        move(a1, below(a1), 2.1, 0.2)
        move(below(a1), a2, 2.3, 0.35)
        hold(a2, 2.65, 0.75)
        // Back to Rodrigo: unpick.
        move(a2, below(a2), 3.45, 0.2)
        move(below(a2), a1, 3.65, 0.35)
        hold(a1, 4.0, 0.75)
        // Pick Design Team, passing over Amina without stopping.
        move(a1, below(a1), 4.8, 0.2)
        move(below(a1), a3, 5.0, 0.45)
        hold(a3, 5.45, 0.75)
        // Drop on Chris (not picked): Amina, Design Team and Chris.
        move(a3, below(a3), 6.25, 0.2)
        move(below(a3), a4, 6.45, 0.35)
        hold(a4, 6.8, 0.25)
        at(7.1) { model.scriptedDrop(at: a4) }
        // Hover the failed chip to retry it (Design Team is second of three).
        let failedChip = PanelMetrics.resultCenter(1, of: 3)
        for (time, point) in path(from: CGPoint(x: size.width * 0.8, y: size.height - 20), to: failedChip, start: 9.9, duration: 0.45) {
            samples.append((time, { model.pointerMoved(point) }))
        }
        at(10.36) { model.pointerMoved(failedChip) }
        at(11.8) { model.pointerMoved(nil) }

        // A text drag that is let go outside the panel.
        at(13.6) {
            model.scriptedShow()
            model.begin(with: .text("Lunch at 1? The place on the corner\nhas a new menu, and I booked a table."),
                        at: CGPoint(x: size.width * 0.3, y: size.height))
        }
        move(CGPoint(x: size.width * 0.3, y: size.height + 10), CGPoint(x: size.width * 0.45, y: 110), 13.75, 0.5)
        move(CGPoint(x: size.width * 0.45, y: 110), CGPoint(x: size.width * 0.75, y: 150), 14.3, 0.5)
        at(15.0) { model.cancel() }
        at(16.8) { PreviewScript(model: model, preview: preview).demo() }
        schedule(samples)
    }

    /// Clipboard mode with a private scratch pasteboard (the real clipboard is
    /// never read or written): a copied link, picks by dwell, number keys and
    /// clicks, then a hold on the card (slipping off once); one failure retried. Then an empty
    /// clipboard, then copied text clicked straight onto one avatar. Repeats.
    private func clipboardDemo() {
        var samples: [(TimeInterval, () -> Void)] = []
        func move(_ from: CGPoint, _ to: CGPoint, _ start: TimeInterval, _ duration: TimeInterval) {
            for (time, point) in path(from: from, to: to, start: start, duration: duration) {
                samples.append((time, { model.pointerMoved(point) }))
            }
        }
        func hold(_ point: CGPoint, _ start: TimeInterval, _ duration: TimeInterval) {
            // Real mouse-moved events stop while resting; the coordinator keeps the ring going itself.
            samples.append((start, { model.pointerMoved(point) }))
            samples.append((start + duration, { model.pointerMoved(point) }))
        }
        func at(_ time: TimeInterval, _ action: @escaping () -> Void) { samples.append((time, action)) }
        func scratch(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.toast.toss.preview-clipboard"))
            pasteboard.clearContents()
            fill(pasteboard)
            return pasteboard
        }

        let a1 = avatar(1), a4 = avatar(4)
        let card = PanelMetrics.cardClipboard
        let below = CGPoint(x: size.width * 0.5, y: 150)
        let offCard = CGPoint(x: card.x + 40, y: 158)

        at(0) {
            let pasteboard = scratch { pasteboard in
                pasteboard.declareTypes([.URL, DragReader.urlNameType, .string], owner: nil)
                pasteboard.setString(PreviewMode.demoLink.absoluteString, forType: .URL)
                pasteboard.setString("macOS Tahoe – Apple", forType: DragReader.urlNameType)
                pasteboard.setString(PreviewMode.demoLink.absoluteString, forType: .string)
            }
            model.openClipboard(pasteboard: pasteboard, takeFocus: false, on: preview.screen)
        }
        // Dwell on Rodrigo: picked.
        move(CGPoint(x: size.width * 0.6, y: size.height + 30), below, 0.5, 0.4)
        move(below, a1, 0.95, 0.4)
        hold(a1, 1.35, 0.75)
        // Number key 3: Amina.
        move(a1, CGPoint(x: a1.x + 30, y: 150), 2.2, 0.3)
        at(2.7) { _ = model.key(.digit(3)) }
        // Dwell on Rodrigo again: unpicked.
        move(CGPoint(x: a1.x + 30, y: 150), a1, 3.2, 0.35)
        hold(a1, 3.55, 0.75)
        // Key 4: Design Team. Click Chris: picked too.
        at(4.5) { _ = model.key(.digit(4)) }
        move(a1, a4, 4.9, 0.6)
        at(5.52) { model.panelClicked(at: a4) }
        // Onto the card and hold; slip off partway (the ring unwinds), come back and hold: sent.
        move(a4, card, 6.0, 0.5)
        hold(card, 6.5, 0.45)
        move(card, offCard, 6.95, 0.2)
        move(offCard, card, 7.45, 0.25)
        hold(card, 7.7, 1.7)
        // Retry the failed chip (Design Team, second of three) by hovering it.
        let failedChip = PanelMetrics.resultCenter(1, of: 3)
        move(card, failedChip, 11.7, 0.4)
        hold(failedChip, 12.1, 0.7)
        at(13.7) { model.pointerMoved(nil) }

        // Empty clipboard: a calm card, then it closes on its own.
        at(15.5) {
            let pasteboard = scratch { _ in }
            model.openClipboard(pasteboard: pasteboard, takeFocus: false, on: preview.screen)
        }
        // Copied text, no picks: one click on Rodrigo sends straight away.
        at(17.7) {
            let pasteboard = scratch { pasteboard in
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString("Lunch at 1? The place on the corner has a new menu, and I booked a table for four.", forType: .string)
            }
            model.openClipboard(pasteboard: pasteboard, takeFocus: false, on: preview.screen)
        }
        move(CGPoint(x: size.width * 0.3, y: size.height + 30), a1, 18.2, 0.5)
        at(18.72) { model.panelClicked(at: a1) }
        at(19.9) { model.pointerMoved(nil) }
        at(22.3) {
            NSPasteboard(name: NSPasteboard.Name("app.toast.toss.preview-clipboard")).releaseGlobally()
            PreviewScript(model: model, preview: preview).clipboardDemo()
        }
        schedule(samples)
    }

    static func scratch(link: Bool) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.toast.toss.preview-clipboard"))
        pasteboard.clearContents()
        if link {
            pasteboard.declareTypes([.URL, DragReader.urlNameType, .string], owner: nil)
            pasteboard.setString(PreviewMode.demoLink.absoluteString, forType: .URL)
            pasteboard.setString("macOS Tahoe – Apple", forType: DragReader.urlNameType)
            pasteboard.setString(PreviewMode.demoLink.absoluteString, forType: .string)
        }
        return pasteboard
    }

    /// Scripted checks of hold-to-send on the card; logs PASS/FAIL per check, then quits.
    private func sendCheck() {
        var samples: [(TimeInterval, () -> Void)] = []
        var failures = 0
        let began = Date()
        func at(_ time: TimeInterval, _ action: @escaping () -> Void) { samples.append((time, action)) }
        func move(_ from: CGPoint, _ to: CGPoint, _ start: TimeInterval, _ duration: TimeInterval) {
            for (time, point) in path(from: from, to: to, start: start, duration: duration) {
                samples.append((time, { model.pointerMoved(point) }))
            }
        }
        func check(_ time: TimeInterval, _ name: String, _ condition: @escaping () -> Bool) {
            at(time) {
                let ok = condition()
                if !ok { failures += 1 }
                FileHandle.standardError.write(Data("sendcheck: \(ok ? "PASS" : "FAIL") \(name) (at \(String(format: "%.2f", Date().timeIntervalSince(began)))/\(time) presentation=\(model.presentation) phase=\(model.phase) ring=\(String(format: "%.2f", model.sendProgress)) picks=\(model.picks))\n".utf8))
            }
        }
        func open(_ time: TimeInterval) {
            at(time) { model.openClipboard(pasteboard: Self.scratch(link: true), takeFocus: false, on: preview.screen) }
        }
        func close(_ time: TimeInterval) { at(time) { model.closeClipboard() } }
        let card = PanelMetrics.cardClipboard
        let nudged = CGPoint(x: card.x + 20, y: card.y)
        let off = CGPoint(x: card.x, y: 160)
        let sending: () -> Bool = { model.phase == .delivering }
        let choosing: () -> Bool = { model.phase == .dragging }

        // 1. Pointer already on the card when a pick happens: resting doesn't send; a nudge does.
        var t = 0.0
        open(t)
        at(t + 0.6) { model.pointerMoved(card) }
        at(t + 0.8) { _ = model.key(.digit(2)) }
        at(t + 1.0) { model.pointerMoved(card) }
        at(t + 2.4) { model.pointerMoved(card) }
        check(t + 2.6, "resting on the card after a pick does not send", { choosing() && model.sendProgress == 0 })
        move(card, nudged, t + 2.7, 0.2)
        check(t + 3.35, "after a nudge the ring fills", { choosing() && model.sendProgress > 0 })
        check(t + 3.9, "0.9 s into the hold it has not sent", choosing)
        check(t + 4.7, "after a nudge a 1.5 s hold sends", sending)
        close(t + 5.4)

        // 2. Pick with the pointer off the card, then come onto it.
        t = 6.4
        open(t)
        at(t + 0.5) { model.pointerMoved(off) }
        at(t + 0.7) { _ = model.key(.digit(2)) }
        move(off, card, t + 1.0, 0.25)
        check(t + 1.75, "half a second on the card is not enough", choosing)
        at(t + 2.0) { model.pointerMoved(card) }
        check(t + 2.35, "1.1 s on the card is not enough", choosing)
        check(t + 3.1, "coming onto the card and holding sends", sending)
        close(t + 4.0)

        // 3. No picks: holding on the card does nothing. Leaving cancels. Space sends.
        t = 11.4
        open(t)
        move(off, card, t + 0.5, 0.25)
        at(t + 2.4) { model.pointerMoved(card) }
        check(t + 2.6, "no picks: holding on the card does nothing", { choosing() && model.sendProgress == 0 })
        at(t + 2.8) { _ = model.key(.digit(2)) }
        check(t + 4.0, "pick by key with the pointer on the card does not send", { choosing() && model.sendProgress == 0 })
        move(card, off, t + 4.1, 0.15)
        move(off, card, t + 4.4, 0.15)
        // As soon as the ring is a third round, slip off (polled, so a busy main thread can't skew it).
        at(t + 4.6) {
            @MainActor func poll(_ tries: Int) {
                if choosing(), model.sendProgress > 0.33 {
                    FileHandle.standardError.write(Data("sendcheck: PASS back on the card the ring fills (ring=\(String(format: "%.2f", model.sendProgress)))\n".utf8))
                    model.pointerMoved(off)
                } else if tries > 0, choosing() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { MainActor.assumeIsolated { poll(tries - 1) } }
                } else {
                    failures += 1
                    FileHandle.standardError.write(Data("sendcheck: FAIL back on the card the ring fills (phase=\(model.phase))\n".utf8))
                    model.pointerMoved(off)
                }
            }
            poll(150)
        }
        check(t + 5.8, "moving off cancels and the ring unwinds", { choosing() && model.sendProgress == 0 })
        at(t + 6.0) {
            let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: " ",
                                         charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            let ok = space.flatMap(PanelKey.init) == .send && enter.flatMap(PanelKey.init) == .send
            if !ok { failures += 1 }
            FileHandle.standardError.write(Data("sendcheck: \(ok ? "PASS" : "FAIL") Space and Return map to send\n".utf8))
            _ = model.key(.send)
        }
        check(t + 6.2, "Space sends", sending)
        close(t + 7.1)

        // 4. Clicking the card sends; with no picks, clicking the card does nothing.
        t = 19.5
        open(t)
        at(t + 0.5) { model.pointerMoved(off); model.panelClicked(at: card) }
        check(t + 0.7, "no picks: clicking the card does nothing", choosing)
        at(t + 0.8) { _ = model.key(.digit(3)) }
        at(t + 1.0) { model.panelClicked(at: card) }
        check(t + 1.2, "clicking the card sends", sending)
        close(t + 2.1)

        // 5. No picks: clicking an avatar still sends straight to it.
        t = 22.7
        open(t)
        at(t + 0.5) { model.panelClicked(at: avatar(1)) }
        check(t + 0.7, "no picks: clicking an avatar sends", { sending() && model.deliveries.map(\.id) == [2] })
        close(t + 1.6)
        at(t + 2.6) {
            NSPasteboard(name: NSPasteboard.Name("app.toast.toss.preview-clipboard")).releaseGlobally()
            FileHandle.standardError.write(Data("sendcheck: done, \(failures) failed\n".utf8))
            NSApp.terminate(nil)
        }
        schedule(samples)
    }

    /// Scripted checks of the confirm step for drag and drop; logs PASS/FAIL, then quits.
    /// Sends are simulated (preview mode); nothing reaches Telegram.
    private func dragCheck() {
        var samples: [(TimeInterval, () -> Void)] = []
        var failures = 0
        func at(_ time: TimeInterval, _ action: @escaping () -> Void) { samples.append((time, action)) }
        func check(_ time: TimeInterval, _ name: String, _ condition: @escaping () -> Bool) {
            at(time) {
                let ok = condition()
                if !ok { failures += 1 }
                FileHandle.standardError.write(Data("dragcheck: \(ok ? "PASS" : "FAIL") \(name) (phase=\(model.phase) source=\(model.source) picks=\(model.picks) sent=\(model.deliveries.map(\.id)))\n".utf8))
            }
        }
        let start = CGPoint(x: size.width / 2, y: 150)
        /// A drag from below the panel to `to`, then (optionally) resting there.
        func drag(_ t: TimeInterval, to: CGPoint, rest: TimeInterval = 0) {
            at(t) {
                model.scriptedShow()
                model.begin(with: .link(PreviewMode.demoLink), at: start)
            }
            for (time, point) in path(from: start, to: to, start: t + 0.1, duration: 0.35) {
                samples.append((time, { model.track(point) }))
            }
            if rest > 0 {
                for frame in 0...Int(rest * 60) { samples.append((t + 0.46 + Double(frame) / 60, { model.track(to) })) }
            }
        }
        let card = PanelMetrics.cardClipboard
        let blank = CGPoint(x: size.width / 2, y: 150)
        let staged: () -> Bool = { model.phase == .dragging && model.isStagedDrag && model.deliveries.isEmpty }
        let sending: () -> Bool = { model.phase == .delivering }
        let gone: () -> Bool = { model.phase != .dragging && model.phase != .delivering && model.deliveries.isEmpty }
        at(0) { Preferences.shared.confirmDrops = true }

        // 1. Release on Rodrigo: picked, staged, card centred, nothing sent; resting there keeps the pick.
        var t = 0.2
        drag(t, to: avatar(1))
        at(t + 0.55) { model.scriptedDrop(at: avatar(1)) }
        check(t + 0.7, "release on an avatar stages instead of sending", { staged() && model.picks == [2] })
        at(t + 0.75) { model.pointerMoved(avatar(1)) }
        at(t + 1.7) { model.pointerMoved(avatar(1)) }
        check(t + 1.9, "resting on the dropped-on avatar keeps it picked", { staged() && model.picks == [2] })
        check(t + 1.9, "card settled in the centre slot", { model.cardPoint == card })
        at(t + 2.0) { _ = model.key(.digit(3)) }
        check(t + 2.1, "number key adds a pick", { staged() && model.picks == [2, 3] })
        at(t + 2.2) { model.pointerMoved(CGPoint(x: card.x, y: 165)) }
        for (time, point) in path(from: CGPoint(x: card.x, y: 165), to: card, start: t + 2.3, duration: 0.25) {
            samples.append((time, { model.pointerMoved(point) }))
        }
        at(t + 3.0) { model.pointerMoved(card) }
        check(t + 3.3, "1 s on the card has not sent", staged)
        at(t + 3.9) { model.pointerMoved(card) }
        check(t + 4.45, "1.5 s hold on the card sends to the picks", { sending() && model.deliveries.map(\.id) == [2, 3] })
        at(t + 4.6) { model.closeClipboard() }

        // 2. Release over the panel with no picks: cancelled as before.
        t = 5.6
        drag(t, to: blank)
        at(t + 0.55) { model.scriptedDrop(at: blank) }
        check(t + 0.8, "no picks and not on an avatar cancels", gone)

        // 3. Pick by dwell during the drag, release over the card spot: staged; a resting pointer
        //    doesn't send; Esc flies the card back.
        t = 7.4
        drag(t, to: avatar(2), rest: 0.7)
        for (time, point) in path(from: avatar(2), to: card, start: t + 1.25, duration: 0.3) {
            samples.append((time, { model.track(point) }))
        }
        at(t + 1.6) { model.scriptedDrop(at: card) }
        check(t + 1.7, "release over the panel with a pick stages and keeps it", { staged() && model.picks == [3] })
        at(t + 1.75) { model.pointerMoved(card) }
        at(t + 3.6) { model.pointerMoved(card) }
        check(t + 3.8, "pointer resting on the card after the drop doesn't send", staged)
        at(t + 3.9) { _ = model.key(.escape) }
        check(t + 4.0, "Esc cancels with the fly-back", { model.phase == .cancelled && model.cardState == .flyingBack && model.deliveries.isEmpty })

        // 4. Staged, then click the card: sends.
        t = 12.4
        drag(t, to: avatar(4))
        at(t + 0.55) { model.scriptedDrop(at: avatar(4)) }
        at(t + 0.8) { model.panelClicked(at: card) }
        check(t + 0.9, "clicking the card sends", { sending() && model.deliveries.map(\.id) == [6] })
        at(t + 1.0) { model.closeClipboard() }

        // 5. Clicking an avatar while staged toggles it (picks are never empty here).
        t = 14.6
        drag(t, to: avatar(1))
        at(t + 0.55) { model.scriptedDrop(at: avatar(1)) }
        at(t + 0.7) { model.panelClicked(at: avatar(3)) }
        check(t + 0.8, "clicking an avatar while staged adds it", { staged() && model.picks == [2, 4] })
        at(t + 0.9) { model.panelClicked(at: avatar(1)) }
        check(t + 1.0, "clicking a picked avatar removes it", { staged() && model.picks == [4] })
        at(t + 1.1) { _ = model.key(.send) }
        check(t + 1.2, "Return sends", { sending() && model.deliveries.map(\.id) == [4] })
        at(t + 1.3) { model.closeClipboard() }

        // 6. Confirm off: release on an avatar sends at once.
        t = 16.8
        at(t) { Preferences.shared.confirmDrops = false }
        drag(t + 0.1, to: avatar(1))
        at(t + 0.65) { model.scriptedDrop(at: avatar(1)) }
        check(t + 0.8, "confirm off: release on an avatar sends immediately", { sending() && model.deliveries.map(\.id) == [2] })
        at(t + 0.9) { Preferences.shared.confirmDrops = true; model.closeClipboard() }

        at(t + 2.6) {
            FileHandle.standardError.write(Data("dragcheck: done, \(failures) failed\n".utf8))
            NSApp.terminate(nil)
        }
        schedule(samples)
    }

    /// Feeds ordinary moves, then a shake, and logs whether each removed a pick.
    private func shakeTest() {
        var samples: [(TimeInterval, () -> Void)] = []
        let start = CGPoint(x: size.width / 2, y: 130)
        samples.append((0, {
            model.scriptedShow()
            model.begin(with: .text("Shake test"), at: start)
        }))
        // Pick two so there is something to remove.
        for (index, base) in [(1, 0.3), (2, 1.5)] {
            for (time, point) in path(from: start, to: avatar(index), start: base, duration: 0.35) {
                samples.append((time, { model.track(point) }))
            }
            for frame in 0...45 {
                samples.append((base + 0.35 + Double(frame) / 60, { model.track(avatar(index)) }))
            }
        }
        // Normal: brisk back-and-forth between two avatars (about 600 pt/s).
        var t = 3.0
        for leg in 0..<4 {
            let from = leg % 2 == 0 ? avatar(0) : avatar(3), to = leg % 2 == 0 ? avatar(3) : avatar(0)
            for (time, point) in path(from: CGPoint(x: from.x, y: 120), to: CGPoint(x: to.x, y: 120), start: t, duration: 0.35) {
                samples.append((time, { model.track(point) }))
            }
            t += 0.38
        }
        samples.append((t + 0.1, { FileHandle.standardError.write(Data("shaketest: picks after normal moves = \(model.picks.count)\n".utf8)) }))
        // Shake: 5 strokes of 70 pt at about 1400 pt/s.
        t += 0.4
        for leg in 0..<5 {
            let left = CGPoint(x: 140, y: 130), right = CGPoint(x: 210, y: 130)
            for (time, point) in path(from: leg % 2 == 0 ? left : right, to: leg % 2 == 0 ? right : left, start: t, duration: 0.07) {
                samples.append((time, { model.track(point) }))
            }
            t += 0.075
        }
        samples.append((t + 0.1, { FileHandle.standardError.write(Data("shaketest: picks after shake = \(model.picks.count)\n".utf8)) }))
        schedule(samples)
    }

    private func path(from: CGPoint, to: CGPoint, start: TimeInterval, duration: TimeInterval) -> [(TimeInterval, CGPoint)] {
        let frames = max(1, Int(duration * 60))
        return (0...frames).map { frame in
            let t = CGFloat(frame) / CGFloat(frames)
            let eased = t * t * (3 - 2 * t)
            return (start + Double(frame) / 60,
                    CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased))
        }
    }

    private func play(_ samples: [(TimeInterval, CGPoint)]) {
        schedule(samples.map { sample in (sample.0, { model.track(sample.1) }) })
    }

    private func schedule(_ samples: [(TimeInterval, () -> Void)]) {
        let start = DispatchTime.now()
        for (time, action) in samples {
            DispatchQueue.main.asyncAfter(deadline: start + time) {
                MainActor.assumeIsolated { action() }
            }
        }
    }
}
