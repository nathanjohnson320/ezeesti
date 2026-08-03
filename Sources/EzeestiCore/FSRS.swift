import Foundation

/// FSRS-4.5 scheduler (open spaced repetition). Ratings match Anki/FSRS: Again/Hard/Good/Easy.
public enum FSRSRating: Int, Codable, Sendable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

public enum FSRSState: Int, Codable, Sendable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3
}

public struct FSRSParameters: Sendable {
    public var requestRetention: Double
    public var maximumInterval: Double
    public var w: [Double]

    public static let `default` = FSRSParameters(
        requestRetention: 0.9,
        maximumInterval: 36500,
        // Default FSRS-4.5 weights
        w: [
            0.40255, 1.18385, 3.173, 15.69105, 7.1949,
            0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
            1.01925, 1.9395, 0.11, 0.29605, 2.2698,
            0.2315, 2.9898, 0.51655, 0.6621,
        ]
    )

    public init(requestRetention: Double, maximumInterval: Double, w: [Double]) {
        self.requestRetention = requestRetention
        self.maximumInterval = maximumInterval
        self.w = w
    }
}

public struct FSRSCard: Sendable, Hashable {
    public var stability: Double
    public var difficulty: Double
    public var elapsedDays: Double
    public var scheduledDays: Double
    public var reps: Int
    public var lapses: Int
    public var state: FSRSState
    public var due: Date
    public var lastReview: Date?

    public init(
        stability: Double = 0,
        difficulty: Double = 0,
        elapsedDays: Double = 0,
        scheduledDays: Double = 0,
        reps: Int = 0,
        lapses: Int = 0,
        state: FSRSState = .new,
        due: Date = Date(),
        lastReview: Date? = nil
    ) {
        self.stability = stability
        self.difficulty = difficulty
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.reps = reps
        self.lapses = lapses
        self.state = state
        self.due = due
        self.lastReview = lastReview
    }

    public static func newCard(due: Date = Date()) -> FSRSCard {
        FSRSCard(due: due)
    }
}

public struct FSRSScheduler: Sendable {
    public let parameters: FSRSParameters

    public init(parameters: FSRSParameters = .default) {
        self.parameters = parameters
    }

    public func review(_ card: FSRSCard, rating: FSRSRating, now: Date = Date()) -> FSRSCard {
        var next = card
        next.elapsedDays = card.lastReview.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 0
        next.lastReview = now
        next.reps += 1

        switch card.state {
        case .new:
            next = reviewNew(next, rating: rating, now: now)
        case .learning, .relearning:
            next = reviewLearning(next, rating: rating, now: now)
        case .review:
            next = reviewReview(next, rating: rating, now: now)
        }
        return next
    }

    private func reviewNew(_ card: FSRSCard, rating: FSRSRating, now: Date) -> FSRSCard {
        var next = card
        next.difficulty = initDifficulty(rating)
        next.stability = initStability(rating)

        switch rating {
        case .again:
            next.state = .learning
            next.lapses += 1
            next.scheduledDays = 0
            next.due = now.addingTimeInterval(60) // 1 minute
        case .hard:
            next.state = .learning
            next.scheduledDays = 0
            next.due = now.addingTimeInterval(5 * 60)
        case .good:
            next.state = .learning
            next.scheduledDays = 0
            next.due = now.addingTimeInterval(10 * 60)
        case .easy:
            next.state = .review
            let interval = nextInterval(stability: next.stability)
            next.scheduledDays = interval
            next.due = now.addingTimeInterval(interval * 86_400)
        }
        return next
    }

    private func reviewLearning(_ card: FSRSCard, rating: FSRSRating, now: Date) -> FSRSCard {
        var next = card
        next.difficulty = nextDifficulty(d: card.difficulty, rating: rating)
        next.stability = nextStabilityShort(s: card.stability, rating: rating)

        switch rating {
        case .again:
            next.state = .relearning
            next.lapses += 1
            next.scheduledDays = 0
            next.due = now.addingTimeInterval(60)
        case .hard:
            next.state = card.state
            next.scheduledDays = 0
            next.due = now.addingTimeInterval(5 * 60)
        case .good:
            next.state = .review
            let interval = nextInterval(stability: next.stability)
            next.scheduledDays = interval
            next.due = now.addingTimeInterval(interval * 86_400)
        case .easy:
            next.state = .review
            let interval = nextInterval(stability: next.stability) * 1.3
            next.scheduledDays = min(interval, parameters.maximumInterval)
            next.due = now.addingTimeInterval(next.scheduledDays * 86_400)
        }
        return next
    }

    private func reviewReview(_ card: FSRSCard, rating: FSRSRating, now: Date) -> FSRSCard {
        var next = card
        let retrievability = forgettingCurve(elapsed: card.elapsedDays, stability: card.stability)
        next.difficulty = nextDifficulty(d: card.difficulty, rating: rating)

        switch rating {
        case .again:
            next.lapses += 1
            next.stability = nextStabilityFail(d: next.difficulty, s: card.stability, r: retrievability)
            next.state = .relearning
            next.scheduledDays = 0
            next.due = now.addingTimeInterval(60)
        case .hard, .good, .easy:
            next.stability = nextStabilitySuccess(
                d: next.difficulty,
                s: card.stability,
                r: retrievability,
                rating: rating
            )
            next.state = .review
            var interval = nextInterval(stability: next.stability)
            if rating == .hard { interval = max(1, interval * 1.2 / 1.5) }
            if rating == .easy { interval *= 1.3 }
            next.scheduledDays = min(interval, parameters.maximumInterval)
            next.due = now.addingTimeInterval(next.scheduledDays * 86_400)
        }
        return next
    }

    private func initStability(_ rating: FSRSRating) -> Double {
        max(0.1, parameters.w[rating.rawValue - 1])
    }

    private func initDifficulty(_ rating: FSRSRating) -> Double {
        constrainDifficulty(parameters.w[4] - Double(rating.rawValue - 3) * parameters.w[5])
    }

    private func nextDifficulty(d: Double, rating: FSRSRating) -> Double {
        let next = d - parameters.w[6] * Double(rating.rawValue - 3)
        return constrainDifficulty(meanReversion(parameters.w[4], next))
    }

    private func constrainDifficulty(_ d: Double) -> Double {
        min(10, max(1, d))
    }

    private func meanReversion(_ start: Double, _ current: Double) -> Double {
        parameters.w[7] * start + (1 - parameters.w[7]) * current
    }

    private func nextStabilityShort(s: Double, rating: FSRSRating) -> Double {
        s * exp(parameters.w[8] * (Double(rating.rawValue) - 3) * parameters.w[9])
    }

    private func nextStabilityFail(d: Double, s: Double, r: Double) -> Double {
        parameters.w[11]
            * pow(d, -parameters.w[12])
            * (pow(s + 1, parameters.w[13]) - 1)
            * exp((1 - r) * parameters.w[14])
    }

    private func nextStabilitySuccess(d: Double, s: Double, r: Double, rating: FSRSRating) -> Double {
        let hardPenalty = rating == .hard ? parameters.w[15] : 1
        let easyBonus = rating == .easy ? parameters.w[16] : 1
        return s * (
            exp(parameters.w[8])
                * (11 - d)
                * pow(s, -parameters.w[9])
                * (exp((1 - r) * parameters.w[10]) - 1)
                * hardPenalty
                * easyBonus
            + 1
        )
    }

    private func forgettingCurve(elapsed: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + elapsed / (9 * stability), -1)
    }

    private func nextInterval(stability: Double) -> Double {
        // Approximate interval for target retention from stability (FSRS-4.5 style).
        let days = stability * 9 * (1 / parameters.requestRetention - 1)
        return max(1, min(parameters.maximumInterval, days.rounded()))
    }
}
