import XCTest
@testable import EzeestiCore

final class ExponentialBackoffTests: XCTestCase {
    func testSuccessDoublesUntilCap() {
        XCTAssertEqual(ExponentialBackoff.nextSuccessInterval(currentDays: 1), 2)
        XCTAssertEqual(ExponentialBackoff.nextSuccessInterval(currentDays: 2), 4)
        XCTAssertEqual(ExponentialBackoff.nextSuccessInterval(currentDays: 90), 180)
        XCTAssertEqual(ExponentialBackoff.nextSuccessInterval(currentDays: 180), 180)
    }

    func testDueDateUsesIntervalDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let due = ExponentialBackoff.dueDate(from: now, intervalDays: 2)
        XCTAssertEqual(due.timeIntervalSince(now), 2 * 86_400, accuracy: 0.001)
    }

    func testTokenizerSplitsWords() {
        let tokens = EstonianTokenizer.tokenize("Ma lähen poodi!")
        let words = tokens.filter(\.isWord).map(\.normalized)
        XCTAssertEqual(words, ["ma", "lähen", "poodi"])
    }
}
