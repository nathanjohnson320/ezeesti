import XCTest
@testable import EzeestiASR

final class TranscriptCleanerTests: XCTestCase {
    func testStripsTrailingThankYou() {
        let cleaned = TranscriptCleaner.clean("Ma lähen poodi. Thank you.")
        XCTAssertEqual(cleaned, "Ma lähen poodi.")
    }

    func testStripsTrailingAitah() {
        let cleaned = TranscriptCleaner.clean("Ma lähen poodi. Aitäh")
        XCTAssertTrue(cleaned.lowercased().hasPrefix("ma lähen poodi"))
        XCTAssertFalse(cleaned.lowercased().contains("aitäh"))
    }

    func testRejectsRepetitionLoopFromHum() {
        // Real failure mode: short "Mmm" decoded as looping Estonian gibberish.
        let garbage = """
        Aitäh sulle edaspidisele jõudnud. Räägi edaspidiseks ja edaspidiseks, edaspidiseks \
        küsimust, küsimust, küsimust, küsimust, küsimust, küsimust, küsimust, küsimust, \
        küsimust, küsimust, küsimust, küsimust, küsimust, küsimust, küsimust, küsimust.
        """
        let cleaned = TranscriptCleaner.clean(garbage)
        XCTAssertEqual(cleaned, "", "Repetition loops should be treated as empty / no speech")
    }

    func testCollapsesShortConsecutiveRepeatsButKeepsSentence() {
        let cleaned = TranscriptCleaner.clean("Ma lähen lähen poodi.")
        XCTAssertEqual(cleaned, "Ma lähen lähen poodi.")
    }

    func testAllowsNaturalDoubleWord() {
        let cleaned = TranscriptCleaner.clean("Ei ei, ma lähen poodi.")
        XCTAssertEqual(cleaned, "Ei ei, ma lähen poodi.")
    }

    func testKeepsNormalShortUtterance() {
        let cleaned = TranscriptCleaner.clean("Ma lähen poodi.")
        XCTAssertEqual(cleaned, "Ma lähen poodi.")
    }

    func testDetectsHighSingleTokenFrequency() {
        let words = Array(repeating: "küsimust", count: 8).joined(separator: ", ")
        XCTAssertTrue(TranscriptCleaner.looksLikeRepetitionHallucination(words))
    }
}
