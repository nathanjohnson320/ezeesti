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
}
