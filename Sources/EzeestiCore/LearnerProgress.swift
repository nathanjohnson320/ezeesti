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

    /// True when the best available text is already too familiar — time to generate a new one.
    public static func shouldGenerateNewText(
        from texts: [GradedText],
        workingLevel: CEFRLevel,
        knownLemmas: Set<String>,
        exhaustedKnownRatio: Double = 0.90
    ) -> Bool {
        guard let best = recommendText(from: texts, workingLevel: workingLevel, knownLemmas: knownLemmas) else {
            return true
        }
        let report = GradedTextCatalog.familiarity(text: best, knownLemmas: knownLemmas)
        return report.knownRatio >= exhaustedKnownRatio
    }

    /// Pick one teachable lemma for the next read-aloud sentence.
    /// Prefers a due word first, then already-learning, then an unknown high-frequency content word.
    public static func targetLemmasForPassage(
        workingLevel: CEFRLevel,
        knownLemmas: Set<String>,
        learningLemmas: Set<String> = [],
        dueLemmas: [String] = [],
        alreadyFocused: Set<String> = [],
        limit: Int = 1
    ) -> [LexiconEntry] {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let cap = max(1, limit)
        var picked: [LexiconEntry] = []
        var pickedKeys = Set<String>()

        for raw in dueLemmas {
            guard picked.count < cap else { break }
            let key = EstonianTokenizer.normalize(raw)
            guard !pickedKeys.contains(key) else { continue }
            if let entry = LexiconCatalog.shared.entry(forSurface: raw)
                ?? LexiconCatalog.shared.entry(forSurface: key) {
                picked.append(entry)
            } else {
                picked.append(LexiconEntry(lemma: key, cefr: workingLevel, pos: "", freqRank: nil))
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
            pool.append(contentsOf: LexiconCatalog.shared.lemmas(at: band))
        }

        let ranked = pool
            .filter { entry in
                let key = EstonianTokenizer.normalize(entry.lemma)
                if pickedKeys.contains(key) { return false }
                // Due known words are already handled above; skip other known lemmas.
                if knownLemmas.contains(key) { return false }
                // Skip ultra-short glue already in seed (ma, ja, on…) unless learning.
                if GradedTextCatalog.fallbackSeed.contains(key), !learningLemmas.contains(key) {
                    return false
                }
                // Prefer content words; allow function words only if already learning them.
                if !entry.isPassageFocusCandidate, !learningLemmas.contains(key) {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lKey = EstonianTokenizer.normalize(lhs.lemma)
                let rKey = EstonianTokenizer.normalize(rhs.lemma)
                let lLearning = learningLemmas.contains(lKey)
                let rLearning = learningLemmas.contains(rKey)
                if lLearning != rLearning { return lLearning && !rLearning }
                let lContent = lhs.isPassageFocusCandidate
                let rContent = rhs.isPassageFocusCandidate
                if lContent != rContent { return lContent && !rContent }
                let lUsed = alreadyFocused.contains(lKey)
                let rUsed = alreadyFocused.contains(rKey)
                if lUsed != rUsed { return !lUsed && rUsed }
                let lFreq = lhs.freqRank ?? 50_000
                let rFreq = rhs.freqRank ?? 50_000
                if lFreq != rFreq { return lFreq < rFreq }
                return lhs.lemma < rhs.lemma
            }

        for entry in ranked {
            guard picked.count < cap else { break }
            let key = EstonianTokenizer.normalize(entry.lemma)
            guard !pickedKeys.contains(key) else { continue }
            picked.append(entry)
            pickedKeys.insert(key)
        }

        return picked
    }

    public static func focusLemmas(in texts: [GradedText]) -> Set<String> {
        var set = Set<String>()
        for text in texts {
            for word in text.focusWords {
                set.insert(EstonianTokenizer.normalize(word))
            }
        }
        return set
    }
}
