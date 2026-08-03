import XCTest
@testable import EzeestiCore

final class LessonCatalogTests: XCTestCase {
    func testBundledLessonsLoad() throws {
        let packs = try LessonCatalog.loadBundled()
        XCTAssertFalse(packs.isEmpty)
        XCTAssertTrue(packs.contains(where: { $0.id == "a2-minema-illative" }))
    }
}
