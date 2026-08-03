import Foundation

public struct LearnerProgress: Sendable, Equatable {
    public let knownCount: Int
    public let learningCount: Int
    public let dueCount: Int
    public let workingLevel: CEFRLevel
    public let levelLabel: String
    public let coverageByLevel: [CEFRLevel: Double]
    public let knownByLevel: [CEFRLevel: Int]
    public let lexiconByLevel: [CEFRLevel: Int]

    public init(
        knownCount: Int,
        learningCount: Int,
        dueCount: Int,
        workingLevel: CEFRLevel,
        levelLabel: String,
        coverageByLevel: [CEFRLevel: Double],
        knownByLevel: [CEFRLevel: Int],
        lexiconByLevel: [CEFRLevel: Int]
    ) {
        self.knownCount = knownCount
        self.learningCount = learningCount
        self.dueCount = dueCount
        self.workingLevel = workingLevel
        self.levelLabel = levelLabel
        self.coverageByLevel = coverageByLevel
        self.knownByLevel = knownByLevel
        self.lexiconByLevel = lexiconByLevel
    }

    public static let empty = LearnerProgress(
        knownCount: 0,
        learningCount: 0,
        dueCount: 0,
        workingLevel: .a1,
        levelLabel: "A1 · starting",
        coverageByLevel: [:],
        knownByLevel: [:],
        lexiconByLevel: [:]
    )

    /// Working level = first CEFR band where known coverage of tagged lexicon is below `mastery`.
    public static func estimate(
        knownLemmas: Set<String>,
        learningCount: Int,
        dueCount: Int,
        lexiconByLevel: [CEFRLevel: Set<String>],
        mastery: Double = 0.7
    ) -> LearnerProgress {
        var coverage: [CEFRLevel: Double] = [:]
        var knownCounts: [CEFRLevel: Int] = [:]
        var totals: [CEFRLevel: Int] = [:]

        for level in CEFRLevel.allCases {
            let lemmas = lexiconByLevel[level] ?? []
            totals[level] = lemmas.count
            let knownAtLevel = lemmas.intersection(knownLemmas).count
            knownCounts[level] = knownAtLevel
            coverage[level] = lemmas.isEmpty ? 1 : Double(knownAtLevel) / Double(lemmas.count)
        }

        var working: CEFRLevel = .a1
        for level in CEFRLevel.allCases {
            working = level
            if (coverage[level] ?? 0) < mastery {
                break
            }
        }

        let pct = Int(((coverage[working] ?? 0) * 100).rounded())
        let label: String
        if knownLemmas.isEmpty && learningCount == 0 {
            label = "\(working.rawValue) · starting"
        } else if (coverage[working] ?? 0) >= mastery, working == .c1 {
            label = "C1 · strong coverage"
        } else {
            label = "\(working.rawValue) · \(pct)% of band"
        }

        return LearnerProgress(
            knownCount: knownLemmas.count,
            learningCount: learningCount,
            dueCount: dueCount,
            workingLevel: working,
            levelLabel: label,
            coverageByLevel: coverage,
            knownByLevel: knownCounts,
            lexiconByLevel: totals
        )
    }

    public static func recommendText(
        from texts: [GradedText],
        workingLevel: CEFRLevel,
        knownLemmas: Set<String>
    ) -> GradedText? {
        guard !texts.isEmpty else { return nil }

        func score(_ text: GradedText) -> Double {
            let report = GradedTextCatalog.familiarity(text: text, knownLemmas: knownLemmas)
            let known = report.knownRatio
            // Prefer readable-but-stretch texts (~70–92% known).
            let sweet: Double
            if known < 0.55 { sweet = known }
            else if known > 0.95 { sweet = 0.2 }
            else { sweet = 1.0 - abs(known - 0.85) }

            let levelBonus: Double
            if text.cefr == workingLevel { levelBonus = 1.0 }
            else if text.cefr.rawValue < workingLevel.rawValue { levelBonus = 0.4 }
            else { levelBonus = 0.6 }
            return sweet * 2 + levelBonus
        }

        return texts.max(by: { score($0) < score($1) })
    }
}
