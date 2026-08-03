import XCTest
@testable import EzeestiCore

final class FSRSTests: XCTestCase {
    func testNewCardGoodAdvances() {
        let scheduler = FSRSScheduler()
        let card = FSRSCard.newCard()
        let next = scheduler.review(card, rating: .good)
        XCTAssertEqual(next.state, .learning)
        XCTAssertGreaterThan(next.reps, 0)
    }

    func testTokenizerSplitsWords() {
        let tokens = EstonianTokenizer.tokenize("Ma lähen poodi!")
        let words = tokens.filter(\.isWord).map(\.normalized)
        XCTAssertEqual(words, ["ma", "lähen", "poodi"])
    }
}
