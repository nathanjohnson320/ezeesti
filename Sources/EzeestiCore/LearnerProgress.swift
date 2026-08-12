import Foundation

/// Snapshot of a learner’s known/learning coverage across CEFR bands.
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

    /// Working level = first CEFR band whose known coverage is below `mastery`.
    /// Higher bands are only considered after lower bands clear the threshold.
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

    /// Pick teachable lemmas for the next read-aloud sentence.
    /// Prefers a due word first, then already-learning, then an unknown high-frequency content word.
    ///
    /// - Parameter lexicon: Catalog used for lookups (defaults to the shared bundled lexicon).
    public static func targetLemmasForPassage(
        workingLevel: CEFRLevel,
        knownLemmas: Set<String>,
        learningLemmas: Set<String> = [],
        dueLemmas: [String] = [],
        alreadyFocused: Set<String> = [],
        limit: Int = 1,
        lexicon: LexiconCatalog = .shared
    ) -> [LexiconEntry] {
        lexicon.loadBundledIfNeeded()
        let cap = max(1, limit)
        var picked: [LexiconEntry] = []
        var pickedKeys = Set<String>()
        let functionWords = GradedTextCatalog.baselineFunctionWords

        for raw in dueLemmas {
            guard picked.count < cap else { break }
            let key = EstonianTokenizer.normalize(raw)
            guard !pickedKeys.contains(key) else { continue }
            if let entry = lexicon.entry(forSurface: raw) ?? lexicon.entry(forSurface: key) {
                picked.append(entry)
            } else {
                picked.append(LexiconEntry(lemma: key, cefr: workingLevel, pos: nil, freqRank: nil))
            }
            pickedKeys.insert(key)
        }

        guard picked.count < cap else { return picked }

        let bands: [CEFRLevel]
        switch workingLevel {
        case .a1:
            bands = [.a1]
        case .a2:
            bands = [.a1, .a2]
        default:
            bands = [.a1, .a2, workingLevel]
        }

        var pool: [LexiconEntry] = []
        for band in bands {
            pool.append(contentsOf: lexicon.lemmas(at: band))
        }

        struct Ranked {
            let entry: LexiconEntry
            let key: String
            let isLearning: Bool
            let isContent: Bool
            let alreadyUsed: Bool
            let freq: Int
        }

        let ranked: [Ranked] = pool.compactMap { entry in
            let key = EstonianTokenizer.normalize(entry.lemma)
            if pickedKeys.contains(key) { return nil }
            if knownLemmas.contains(key) { return nil }
            if functionWords.contains(key), !learningLemmas.contains(key) { return nil }
            if !entry.isPassageFocusCandidate, !learningLemmas.contains(key) { return nil }
            return Ranked(
                entry: entry,
                key: key,
                isLearning: learningLemmas.contains(key),
                isContent: entry.isPassageFocusCandidate,
                alreadyUsed: alreadyFocused.contains(key),
                freq: entry.freqRank ?? 50_000
            )
        }
        .sorted { lhs, rhs in
            if lhs.isLearning != rhs.isLearning { return lhs.isLearning && !rhs.isLearning }
            if lhs.isContent != rhs.isContent { return lhs.isContent && !rhs.isContent }
            if lhs.alreadyUsed != rhs.alreadyUsed { return !lhs.alreadyUsed && rhs.alreadyUsed }
            if lhs.freq != rhs.freq { return lhs.freq < rhs.freq }
            return lhs.entry.lemma < rhs.entry.lemma
        }

        for item in ranked {
            guard picked.count < cap else { break }
            guard !pickedKeys.contains(item.key) else { continue }
            picked.append(item.entry)
            pickedKeys.insert(item.key)
        }

        return picked
    }
}
