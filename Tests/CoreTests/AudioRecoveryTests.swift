import XCTest
@testable import WatchAICore

final class AudioRecoveryTests: XCTestCase {
    func testHealthyDelayedNotificationsDoNotEndCallOrExhaustRecovery() {
        var policy = AudioRecoveryPolicy()
        for _ in 0..<20 {
            XCTAssertEqual(policy.action(isRunning: true, formatMatches: true, now: 1), .ignore)
        }
        XCTAssertEqual(policy.action(isRunning: false, formatMatches: true, now: 2), .restart)
    }

    func testChangedFormatNeedsRecoveryEvenIfEngineRuns() {
        var policy = AudioRecoveryPolicy()
        XCTAssertEqual(policy.action(isRunning: true, formatMatches: false, now: 1), .restart)
    }

    func testRepeatedUnstableRouteIsBoundedButLaterRouteCanRecover() {
        var policy = AudioRecoveryPolicy()
        for time in [1.0, 2, 3] {
            XCTAssertEqual(policy.action(isRunning: false, formatMatches: true, now: time), .restart)
        }
        XCTAssertEqual(policy.action(isRunning: false, formatMatches: true, now: 4), .fail)
        XCTAssertEqual(policy.action(isRunning: false, formatMatches: true, now: 13), .restart)
    }
}
