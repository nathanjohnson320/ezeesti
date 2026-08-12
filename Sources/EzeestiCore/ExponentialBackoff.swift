import Foundation

/// Simple spaced-repetition intervals: 1 → 2 → 4 → … days, capped.
public enum ExponentialBackoff: Sendable {
    /// Interval used when a card is first scheduled after a successful review.
    public static let initialIntervalDays: Double = 1
    /// Upper bound for success doubling (about six months).
    public static let maxIntervalDays: Double = 180
    /// Seconds in a calendar day used by `dueDate(from:intervalDays:)`.
    public static let secondsPerDay: TimeInterval = 86_400

    /// Doubles `currentDays` (floored at `initialIntervalDays`) up to `maxIntervalDays`.
    public static func nextSuccessInterval(currentDays: Double) -> Double {
        let base = max(currentDays, initialIntervalDays)
        return min(base * 2, maxIntervalDays)
    }

    /// Instant when a card next becomes due after `intervalDays` from `now`.
    public static func dueDate(from now: Date, intervalDays: Double) -> Date {
        now.addingTimeInterval(max(intervalDays, 0) * secondsPerDay)
    }
}
