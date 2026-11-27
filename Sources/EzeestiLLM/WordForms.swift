import Foundation
import EzeestiCore

/// Shared lemma context for Words-mode EstLLM prompts.
public struct WordFormsContext: Sendable {
    public let lemma: String
    public let glossEnglish: String?
    public let pos: String?
    public let cefr: CEFRLevel

    public init(lemma: String, glossEnglish: String? = nil, pos: String? = nil, cefr: CEFRLevel) {
        self.lemma = lemma
        self.glossEnglish = glossEnglish
        self.pos = pos
        self.cefr = cefr
    }

    fileprivate var userPreamble: String {
        var lines: [String] = [
            "CEFR level: \(cefr.rawValue)",
            "Lemma: \(lemma)",
        ]
        if let pos, !pos.isEmpty {
            lines.append("POS: \(pos)")
        }
        if let glossEnglish, !glossEnglish.isEmpty {
            lines.append("English gloss hint: \(glossEnglish)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Fast call: drill cloze forms only (no full case table).
public struct WordDrillFormsPrompt {
    public let context: WordFormsContext

    public init(context: WordFormsContext) {
        self.context = context
    }

    public var system: String {
        """
        You are an Estonian morphology tutor for CEFR \(context.cefr.rawValue) learners.
        Always respond with ONLY valid JSON. Keys:
        - lemma: the citation form (same as input)
        - glossEnglish: short English gloss
        - commonForms: exactly 3 objects for the MOST common everyday forms of this word
        - extraForms: 1 or 2 less common but useful forms to sprinkle in later

        Each form object keys:
        - surface: the Estonian inflected form (correct spelling)
        - label: Estonian grammar name first, English in parentheses (e.g. "nimetav ainsus (nominative singular)")
        - cloze: one short Estonian sentence with ___ where the form belongs (use exactly three underscores)
        - clozeEnglish: natural English translation of the full sentence (with the form filled in)
        - reason: one short English clause explaining WHY this form is required; name the Estonian case/form
        - distractors: array of 2 wrong Estonian lookalikes, never the correct surface

        Form priority by POS:
        - Noun (s) / adjective: nimetav, omastav, osastav ainsus first; then a useful plural/case.
        - Verb (v): ma-infinitiiv, da-infinitiiv, olevik 3. pööre first; then another person/tense.
        - Other: citation form + two high-frequency related forms.

        Rules:
        - Spell every Estonian form correctly.
        - Cloze sentences stay at \(context.cefr.rawValue), about 4–10 words, one sentence each.
        - Never wrap JSON in markdown fences. No commentary.

        Example shape:
        {"lemma":"mees","glossEnglish":"man","commonForms":[{"surface":"mees","label":"nimetav ainsus (nominative singular)","cloze":"___ käib poes.","clozeEnglish":"The man goes to the store.","reason":"Subject → nimetav ainsus.","distractors":["mehe","meest"]}],"extraForms":[{"surface":"mehele","label":"alaleütlev ainsus (allative singular)","cloze":"Anna raamat ___ .","clozeEnglish":"Give the book to the man.","reason":"Recipient uses alaleütlev.","distractors":["mehega","mehel"]}]}
        """
    }

    public var user: String {
        context.userPreamble + "\nReturn JSON with 3 commonForms and 1–2 extraForms only (no paradigm)."
    }
}

/// Slower call: full case / conjugation table only.
public struct WordParadigmPrompt {
    public let context: WordFormsContext

    public init(context: WordFormsContext) {
        self.context = context
    }

    public var system: String {
        """
        You are an Estonian morphology tutor. Return ONLY valid JSON for a full inflection table.
        Keys:
        - lemma: the citation form
        - paradigm:
          - kind: "cases" for nouns/adjectives, "verb" for verbs, "other" otherwise
          - rows: array of {nameEt, nameEn, singular, plural}

        For kind "cases", include ALL 14 cases in this order (ainsus + mitmus each):
        nimetav, omastav, osastav, sisseütlev, seesütlev, seestütlev, alaleütlev, alalütlev, alaltütlev, saav, rajav, olev, ilmaütlev, kaasaütlev
        (English: nominative, genitive, partitive, illative, inessive, elative, allative, adessive, ablative, translative, terminative, essive, abessive, comitative)

        For kind "verb", include at least:
        ma-infinitiiv, da-infinitiiv, olevik 1./2./3. pööre ainsus, olevik 1./2./3. pööre mitmus, lihtminevik 3. pööre ainsus
        Put each form in singular; leave plural "".

        Spell every Estonian form correctly. No markdown fences. No commentary.

        Example:
        {"lemma":"mees","paradigm":{"kind":"cases","rows":[{"nameEt":"nimetav","nameEn":"nominative","singular":"mees","plural":"mehed"},{"nameEt":"omastav","nameEn":"genitive","singular":"mehe","plural":"meeste"}]}}
        """
    }

    public var user: String {
        context.userPreamble + "\nReturn JSON with lemma and full paradigm only."
    }
}

/// One inflected form plus a cloze sentence for drill practice.
public struct WordFormEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(surface)|\(label)" }
    public let surface: String
    public let label: String
    public let cloze: String
    public let clozeEnglish: String
    /// Short English note explaining why this form fits the cloze.
    public let reason: String
    public let distractors: [String]

    public init(
        surface: String,
        label: String,
        cloze: String,
        clozeEnglish: String,
        reason: String = "",
        distractors: [String] = []
    ) {
        self.surface = surface
        self.label = label
        self.cloze = cloze
        self.clozeEnglish = clozeEnglish
        self.reason = reason
        self.distractors = distractors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surface = try container.decode(String.self, forKey: .surface)
        label = try container.decode(String.self, forKey: .label)
        cloze = try container.decode(String.self, forKey: .cloze)
        clozeEnglish = try container.decodeIfPresent(String.self, forKey: .clozeEnglish) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        distractors = try container.decodeIfPresent([String].self, forKey: .distractors) ?? []
    }
}

/// One row of a full case / conjugation paradigm table.
public struct WordParadigmRow: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(nameEt)|\(singular)|\(plural)" }
    public let nameEt: String
    public let nameEn: String
    public let singular: String
    public let plural: String

    public init(nameEt: String, nameEn: String, singular: String, plural: String = "") {
        self.nameEt = nameEt
        self.nameEn = nameEn
        self.singular = singular
        self.plural = plural
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nameEt = try container.decode(String.self, forKey: .nameEt)
        nameEn = try container.decodeIfPresent(String.self, forKey: .nameEn) ?? ""
        singular = try container.decodeIfPresent(String.self, forKey: .singular) ?? ""
        plural = try container.decodeIfPresent(String.self, forKey: .plural) ?? ""
    }
}

/// Full inflection table shown on the Words reveal screen.
public struct WordParadigm: Codable, Sendable, Hashable {
    public let kind: String
    public let rows: [WordParadigmRow]

    public init(kind: String, rows: [WordParadigmRow]) {
        self.kind = kind
        self.rows = rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "cases"
        rows = try container.decodeIfPresent([WordParadigmRow].self, forKey: .rows) ?? []
    }

    public var isCases: Bool { kind.lowercased() == "cases" }
    public var isVerb: Bool { kind.lowercased() == "verb" }
}

/// Combined Words pack assembled from the drill + paradigm EstLLM calls.
public struct WordFormsPack: Codable, Sendable, Hashable {
    public let lemma: String
    public let glossEnglish: String
    public let paradigm: WordParadigm?
    public let commonForms: [WordFormEntry]
    public let extraForms: [WordFormEntry]

    public init(
        lemma: String,
        glossEnglish: String,
        paradigm: WordParadigm? = nil,
        commonForms: [WordFormEntry],
        extraForms: [WordFormEntry] = []
    ) {
        self.lemma = lemma
        self.glossEnglish = glossEnglish
        self.paradigm = paradigm
        self.commonForms = commonForms
        self.extraForms = extraForms
    }

    public var allForms: [WordFormEntry] {
        commonForms + extraForms
    }

    public func withParadigm(_ paradigm: WordParadigm?) -> WordFormsPack {
        WordFormsPack(
            lemma: lemma,
            glossEnglish: glossEnglish,
            paradigm: paradigm,
            commonForms: commonForms,
            extraForms: extraForms
        )
    }
}

/// How a single Words-mode drill item is answered.
public enum WordDrillModality: String, Codable, Sendable, CaseIterable, Hashable {
    case chips
    case type
    case speak
}

/// One queued drill: a form + random modality + chip options when needed.
public struct WordDrillItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let form: WordFormEntry
    public let modality: WordDrillModality
    public let chipOptions: [String]
    public let isExtra: Bool

    public init(
        id: String = UUID().uuidString,
        form: WordFormEntry,
        modality: WordDrillModality,
        chipOptions: [String] = [],
        isExtra: Bool = false
    ) {
        self.id = id
        self.form = form
        self.modality = modality
        self.chipOptions = chipOptions
        self.isExtra = isExtra
    }
}

private struct WordDrillFormsPayload: Codable {
    let lemma: String
    let glossEnglish: String?
    let commonForms: [WordFormEntry]?
    let extraForms: [WordFormEntry]?
}

private struct WordParadigmPayload: Codable {
    let lemma: String?
    let paradigm: WordParadigm?
}

/// Parses EstLLM word-form / paradigm JSON.
public enum WordFormsParser {
    public static func parseDrills(_ raw: String, expectedLemma: String? = nil) -> WordFormsPack? {
        guard let payload = LLMJSON.decodeIfPresent(WordDrillFormsPayload.self, from: raw) else { return nil }
        let lemma = payload.lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lemma.isEmpty else { return nil }
        if let expectedLemma {
            let want = EstonianTokenizer.normalize(expectedLemma)
            let got = EstonianTokenizer.normalize(lemma)
            guard want == got || got.hasPrefix(want) || want.hasPrefix(got) else { return nil }
        }

        let common = (payload.commonForms ?? []).compactMap(sanitize(entry:)).prefix(3)
        guard common.count >= 2 else { return nil }
        let extras = (payload.extraForms ?? []).compactMap(sanitize(entry:)).prefix(2)

        return WordFormsPack(
            lemma: lemma,
            glossEnglish: (payload.glossEnglish ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            paradigm: nil,
            commonForms: Array(common),
            extraForms: Array(extras)
        )
    }

    public static func parseParadigm(_ raw: String, expectedLemma: String? = nil) -> WordParadigm? {
        guard let payload = LLMJSON.decodeIfPresent(WordParadigmPayload.self, from: raw) else {
            // Allow a bare paradigm object.
            if let paradigm = LLMJSON.decodeIfPresent(WordParadigm.self, from: raw) {
                return sanitize(paradigm: paradigm)
            }
            return nil
        }
        if let expectedLemma, let lemma = payload.lemma {
            let want = EstonianTokenizer.normalize(expectedLemma)
            let got = EstonianTokenizer.normalize(lemma)
            guard want == got || got.hasPrefix(want) || want.hasPrefix(got) || lemma.isEmpty else {
                return nil
            }
        }
        return sanitize(paradigm: payload.paradigm)
    }

    /// Build a short Speakly-style drill queue: each common form once, then sprinkle extras.
    public static func makeDrillQueue(from pack: WordFormsPack, maxItems: Int = 6) -> [WordDrillItem] {
        var items: [WordDrillItem] = []
        let modalities = WordDrillModality.allCases

        for (index, form) in pack.commonForms.enumerated() {
            guard items.count < maxItems else { break }
            let modality = modalities[index % modalities.count]
            items.append(
                WordDrillItem(
                    form: form,
                    modality: modality,
                    chipOptions: chipOptions(for: form, pack: pack),
                    isExtra: false
                )
            )
        }

        for (offset, form) in pack.extraForms.enumerated() {
            guard items.count < maxItems else { break }
            let modality = modalities[(pack.commonForms.count + offset) % modalities.count]
            items.append(
                WordDrillItem(
                    form: form,
                    modality: modality,
                    chipOptions: chipOptions(for: form, pack: pack),
                    isExtra: true
                )
            )
        }

        let commonCount = min(pack.commonForms.count, items.count)
        if commonCount > 1 {
            let head = Array(items.prefix(commonCount)).shuffled()
            let tail = Array(items.dropFirst(commonCount))
            items = head + tail
        }
        return items
    }

    /// Soft answer check for typed / spoken / chip responses.
    public static func answersMatch(_ response: String, expected: String) -> Bool {
        let a = EstonianTokenizer.normalize(response.trimmingCharacters(in: .whitespacesAndNewlines))
        let b = EstonianTokenizer.normalize(expected.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if foldDiacritics(a) == foldDiacritics(b) { return true }
        let tokens = EstonianTokenizer.wordLemmas(in: a)
        if tokens.contains(b) || tokens.contains(where: { foldDiacritics($0) == foldDiacritics(b) }) {
            return true
        }
        return false
    }

    /// EstLLM sometimes emits `ĝ` (not used in Estonian) inside case names like `seesüĝtlev`.
    private static let canonicalCases: [(et: String, en: String)] = [
        ("nimetav", "nominative"),
        ("omastav", "genitive"),
        ("osastav", "partitive"),
        ("sisseütlev", "illative"),
        ("seesütlev", "inessive"),
        ("seestütlev", "elative"),
        ("alaleütlev", "allative"),
        ("alalütlev", "adessive"),
        ("alaltütlev", "ablative"),
        ("saav", "translative"),
        ("rajav", "terminative"),
        ("olev", "essive"),
        ("ilmaütlev", "abessive"),
        ("kaasaütlev", "comitative"),
    ]

    /// Re-canonicalize a cached or LLM paradigm (fixes garbled case labels).
    public static func sanitizeParadigm(_ paradigm: WordParadigm) -> WordParadigm? {
        sanitize(paradigm: paradigm)
    }

    private static func sanitize(paradigm: WordParadigm?) -> WordParadigm? {
        guard let paradigm else { return nil }
        let kind = paradigm.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCases = kind.lowercased() == "cases"
        let useCaseOrder = isCases && paradigm.rows.count == canonicalCases.count
        let rows = paradigm.rows.enumerated().compactMap { index, row -> WordParadigmRow? in
            var nameEt = scrubEstonianLabel(row.nameEt)
            var nameEn = row.nameEn.trimmingCharacters(in: .whitespacesAndNewlines)
            let singular = scrubEstonianLabel(row.singular)
            let plural = scrubEstonianLabel(row.plural)
            guard !nameEt.isEmpty, !singular.isEmpty || !plural.isEmpty else { return nil }

            if isCases,
               let canonical = resolveCaseName(
                nameEt: nameEt,
                nameEn: nameEn,
                index: useCaseOrder ? index : nil
               ) {
                nameEt = canonical.et
                nameEn = canonical.en
            }

            return WordParadigmRow(nameEt: nameEt, nameEn: nameEn, singular: singular, plural: plural)
        }
        guard !rows.isEmpty else { return nil }
        return WordParadigm(kind: kind, rows: rows)
    }

    private static func resolveCaseName(
        nameEt: String,
        nameEn: String,
        index: Int?
    ) -> (et: String, en: String)? {
        let enKey = nameEn.lowercased()
        if let match = canonicalCases.first(where: { $0.en == enKey }) {
            return match
        }
        let etKey = EstonianTokenizer.normalize(nameEt)
        if let match = canonicalCases.first(where: { $0.et == etKey }) {
            return match
        }
        // Positional fallback only for a full 14-case table in standard order.
        if let index, canonicalCases.indices.contains(index) {
            return canonicalCases[index]
        }
        return nil
    }

    /// Drop model junk characters that never appear in Estonian orthography.
    private static func scrubEstonianLabel(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ĝ", with: "")
            .replacingOccurrences(of: "Ĝ", with: "")
    }

    private static func sanitize(entry: WordFormEntry) -> WordFormEntry? {
        let surface = entry.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloze = entry.cloze.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let clozeEnglish = entry.clozeEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = entry.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surface.isEmpty, !cloze.isEmpty, cloze.contains("___") else { return nil }
        let distractors = entry.distractors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && EstonianTokenizer.normalize($0) != EstonianTokenizer.normalize(surface) }
        return WordFormEntry(
            surface: surface,
            label: label.isEmpty ? "form" : label,
            cloze: cloze,
            clozeEnglish: clozeEnglish,
            reason: reason,
            distractors: Array(distractors.prefix(3))
        )
    }

    private static func chipOptions(for form: WordFormEntry, pack: WordFormsPack) -> [String] {
        var options: [String] = [form.surface]
        for d in form.distractors where options.count < 4 {
            if !options.contains(where: { EstonianTokenizer.normalize($0) == EstonianTokenizer.normalize(d) }) {
                options.append(d)
            }
        }
        for other in pack.allForms where options.count < 4 {
            let surface = other.surface
            if EstonianTokenizer.normalize(surface) == EstonianTokenizer.normalize(form.surface) { continue }
            if options.contains(where: { EstonianTokenizer.normalize($0) == EstonianTokenizer.normalize(surface) }) {
                continue
            }
            options.append(surface)
        }
        return options.shuffled()
    }

    private static func foldDiacritics(_ text: String) -> String {
        text
            .replacingOccurrences(of: "õ", with: "o")
            .replacingOccurrences(of: "ö", with: "o")
            .replacingOccurrences(of: "ä", with: "a")
            .replacingOccurrences(of: "ü", with: "u")
            .replacingOccurrences(of: "š", with: "s")
            .replacingOccurrences(of: "ž", with: "z")
    }
}
