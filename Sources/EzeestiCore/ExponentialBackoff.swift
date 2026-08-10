import Foundation

/// Simple spaced-repetition intervals: 1 → 2 → 4 → … days, capped.
public enum ExponentialBackoff: Sendable {
    public static let initialIntervalDays: Double = 1
    public static let maxIntervalDays: Double = 180
    public static let secondsPerDay: TimeInterval = 86_400

    public static func nextSuccessInterval(currentDays: Double) -> Double {
        let base = max(currentDays, initialIntervalDays)
        return min(base * 2, maxIntervalDays)
    }

    public static func dueDate(from now: Date, intervalDays: Double) -> Date {
        now.addingTimeInterval(max(intervalDays, 0) * secondsPerDay)
    }
}
