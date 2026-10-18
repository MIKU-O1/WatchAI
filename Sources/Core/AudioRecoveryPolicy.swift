import Foundation

/// Ignore healthy delayed notifications; bound restarts while a route settles.
/// Times use monotonic system uptime.
struct AudioRecoveryPolicy {
    enum Action: Equatable { case ignore, restart, fail }
    private var restarts: [TimeInterval] = []

    mutating func action(isRunning: Bool, formatMatches: Bool, now: TimeInterval) -> Action {
        guard !isRunning || !formatMatches else { return .ignore }
        restarts.removeAll { now - $0 >= 10 }
        guard restarts.count < 3 else { return .fail }
        restarts.append(now)
        return .restart
    }
}
