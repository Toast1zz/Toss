import Foundation

/// What a modifier-flags change looks like to the detector. Only modifier
/// state and timing go in; no key identities.
public struct ModifierSample: Equatable, Sendable {
    /// Either Option key is down.
    public var option: Bool
    /// ⌘, ⌃, ⇧ or fn is down.
    public var others: Bool
    /// A key was pressed, a mouse button was pressed, or a button is held,
    /// since the previous sample.
    public var interference: Bool
    /// Seconds, on any monotonic clock.
    public var time: TimeInterval

    public init(option: Bool, others: Bool = false, interference: Bool = false, time: TimeInterval) {
        self.option = option
        self.others = others
        self.interference = interference
        self.time = time
    }
}

/// Recognises two clean taps of Option: press, release, press, release, with
/// nothing else in between and each step quick.
public struct DoubleTapDetector: Sendable {
    /// Longest a single tap may hold Option down.
    public var maxHold: TimeInterval
    /// Longest gap between the first release and the second press.
    public var maxGap: TimeInterval

    enum State: Equatable {
        case idle
        case firstDown(TimeInterval)
        case firstUp(TimeInterval)
        case secondDown(TimeInterval)
    }

    private(set) var state: State = .idle
    private var optionDown = false

    public init(maxHold: TimeInterval = 0.35, maxGap: TimeInterval = 0.35) {
        self.maxHold = maxHold
        self.maxGap = maxGap
    }

    /// Feeds one flags change. Returns true when it completes a double tap.
    public mutating func handle(_ sample: ModifierSample) -> Bool {
        let wasDown = optionDown
        optionDown = sample.option

        // Another modifier, or no Option edge at all (caps lock, the other
        // Option key joining in): not a clean tap.
        if sample.others || wasDown == sample.option {
            state = .idle
            return false
        }

        if sample.option {
            // Press. Anything since the last sample spoils what came before,
            // but this press can still start a fresh tap.
            if !sample.interference, case .firstUp(let released) = state, sample.time - released <= maxGap {
                state = .secondDown(sample.time)
            } else {
                state = .firstDown(sample.time)
            }
            return false
        }

        // Release.
        guard !sample.interference else {
            state = .idle
            return false
        }
        switch state {
        case .firstDown(let pressed) where sample.time - pressed <= maxHold:
            state = .firstUp(sample.time)
            return false
        case .secondDown(let pressed) where sample.time - pressed <= maxHold:
            state = .idle
            return true
        default:
            state = .idle
            return false
        }
    }

    public mutating func reset() {
        state = .idle
        optionDown = false
    }
}
