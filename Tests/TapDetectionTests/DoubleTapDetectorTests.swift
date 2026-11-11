import XCTest
@testable import TapDetection

final class DoubleTapDetectorTests: XCTestCase {
    /// Feeds samples and returns the indexes that fired.
    private func run(_ samples: [ModifierSample], _ detector: inout DoubleTapDetector) -> [Int] {
        samples.enumerated().compactMap { detector.handle($0.element) ? $0.offset : nil }
    }

    private func run(_ samples: [ModifierSample]) -> [Int] {
        var detector = DoubleTapDetector()
        return run(samples, &detector)
    }

    private func down(_ t: TimeInterval, others: Bool = false, dirty: Bool = false) -> ModifierSample {
        ModifierSample(option: true, others: others, interference: dirty, time: t)
    }

    private func up(_ t: TimeInterval, others: Bool = false, dirty: Bool = false) -> ModifierSample {
        ModifierSample(option: false, others: others, interference: dirty, time: t)
    }

    private func clean(_ start: TimeInterval) -> [ModifierSample] {
        [down(start), up(start + 0.08), down(start + 0.2), up(start + 0.28)]
    }

    func testCleanDoubleTapFiresOnSecondRelease() {
        XCTAssertEqual(run(clean(10)), [3])
    }

    func testSingleTapDoesNothing() {
        XCTAssertEqual(run([down(1), up(1.1)]), [])
    }

    func testGapTooLong() {
        XCTAssertEqual(run([down(1), up(1.08), down(1.5), up(1.58)]), [])
    }

    func testGapAtLimitFires() {
        XCTAssertEqual(run([down(1), up(1.1), down(1.44), up(1.5)]), [3])
    }

    func testSlowSecondPressStartsANewTap() {
        // Too slow to pair with the first, but it pairs with the next one.
        XCTAssertEqual(run([down(1), up(1.08), down(2), up(2.08), down(2.2), up(2.28)]), [5])
    }

    func testHoldingOptionNeverFires() {
        XCTAssertEqual(run([down(1), up(1.9)]), [])
        XCTAssertEqual(run([down(1), up(1.08), down(1.2), up(2.5)]), [])
        XCTAssertEqual(run([down(1), up(1.6), down(1.7), up(1.78)]), [])
    }

    func testOptionPlusKeyBetweenPressAndRelease() {
        // ⌥V: a key goes down while Option is held, seen at release.
        XCTAssertEqual(run([down(1), up(1.1, dirty: true), down(1.2), up(1.28)]), [])
        XCTAssertEqual(run([down(1), up(1.08), down(1.2), up(1.28, dirty: true)]), [])
    }

    func testKeyBetweenTheTaps() {
        // A key typed between the two taps: the second press starts over.
        XCTAssertEqual(run([down(1), up(1.08), down(1.2, dirty: true), up(1.28)]), [])
    }

    func testTypingBeforeTheFirstTapIsFine() {
        XCTAssertEqual(run([down(1, dirty: true), up(1.08), down(1.2), up(1.28)]), [3])
    }

    func testOptionDragOrClick() {
        // Mouse held or clicked during either tap.
        XCTAssertEqual(run([down(1), up(1.08, dirty: true), down(1.2), up(1.28)]), [])
        XCTAssertEqual(run([down(1), up(1.08), down(1.2), up(1.28, dirty: true)]), [])
    }

    func testOtherModifiers() {
        // ⌥⌘ chord, then release in pieces.
        XCTAssertEqual(run([down(1), down(1.05, others: true), up(1.1, others: true), up(1.15),
                            down(1.2), up(1.28)]), [])
        // ⇧ pressed and released between the taps.
        XCTAssertEqual(run([down(1), up(1.08), up(1.12, others: true), up(1.16), down(1.2), up(1.28)]), [])
        // Second tap made while ⌘ is held.
        XCTAssertEqual(run([down(1), up(1.08), down(1.2, others: true), up(1.28, others: true)]), [])
    }

    func testFlagsChangeWithoutOptionEdge() {
        // Caps lock toggles, or the other Option key joins in while one is held.
        XCTAssertEqual(run([down(1), up(1.08), up(1.1), down(1.2), up(1.28)]), [])
        XCTAssertEqual(run([down(1), down(1.04), up(1.08), down(1.2), up(1.28)]), [])
    }

    func testEitherOptionKey() {
        // Left then right Option: the detector only sees "an Option key".
        XCTAssertEqual(run(clean(3)), [3])
    }

    func testTripleTapFiresOnce() {
        XCTAssertEqual(run([down(1), up(1.06), down(1.15), up(1.21), down(1.3), up(1.36)]), [3])
    }

    func testTwoDoubleTapsInARow() {
        XCTAssertEqual(run(clean(1) + clean(3)), [3, 7])
    }

    func testFourQuickTapsFireTwice() {
        XCTAssertEqual(run([down(1), up(1.06), down(1.15), up(1.21), down(1.3), up(1.36), down(1.45), up(1.51)]), [3, 7])
    }

    func testResetDropsAHalfDoneTap() {
        var detector = DoubleTapDetector()
        XCTAssertEqual(run([down(1), up(1.08)], &detector), [])
        detector.reset()
        XCTAssertEqual(run([down(1.2), up(1.28)], &detector), [])
    }

    func testReleaseWithoutSeenPressIsIgnored() {
        // Started watching while Option was already held.
        XCTAssertEqual(run([up(1), down(1.2), up(1.28)]), [])
    }
}
