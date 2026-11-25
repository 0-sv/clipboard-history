import XCTest
@testable import ClipHistoryCore

final class StoreTests: XCTestCase {
    private var directory: URL!
    private var store: Store!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try Store(path: directory.appendingPathComponent("test.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func add(_ text: String, at seconds: TimeInterval) throws -> Int64 {
        try store.insert(
            kind: .text,
            text: text,
            hash: Store.hash(kind: .text, data: Data(text.utf8)),
            byteSize: text.utf8.count,
            now: Date(timeIntervalSince1970: seconds)
        )
    }

    func testNewestFirst() throws {
        try add("first", at: 1)
        try add("second", at: 2)
        XCTAssertEqual(try store.search("").map(\.preview), ["second", "first"])
    }

    func testDuplicateMovesToTopWithoutNewRow() throws {
        let first = try add("first", at: 1)
        try add("second", at: 2)
        let again = try add("first", at: 3)
        XCTAssertEqual(first, again)
        XCTAssertEqual(try store.count(), 2)
        XCTAssertEqual(try store.search("").map(\.preview), ["first", "second"])
    }

    func testSubstringSearchIgnoresCase() throws {
        try add("SELECT * FROM assessments", at: 1)
        try add("hello world", at: 2)
        XCTAssertEqual(try store.search("sessm").map(\.preview), ["SELECT * FROM assessments"])
        XCTAssertEqual(try store.search("from select").map(\.preview), ["SELECT * FROM assessments"])
    }

    func testShortQueryUsesLikeFallback() throws {
        try add("a 100% match", at: 1)
        try add("other", at: 2)
        XCTAssertEqual(try store.search("0%").map(\.preview), ["a 100% match"])
        XCTAssertEqual(try store.search("zz").count, 0)
    }

    func testQuotesInQueryDoNotBreakSearch() throws {
        try add("say \"hello\" now", at: 1)
        XCTAssertEqual(try store.search("\"hello\"").count, 1)
    }

    func testPinnedSortsFirstAndSurvivesClear() throws {
        let old = try add("old pinned", at: 1)
        try add("new", at: 2)
        try store.togglePin(id: old)
        XCTAssertEqual(try store.search("").map(\.preview), ["old pinned", "new"])
        XCTAssertEqual(try store.clear(), 1)
        XCTAssertEqual(try store.search("").map(\.preview), ["old pinned"])
    }

    func testDeleteRemovesFromSearchAndImageFile() throws {
        let image = directory.appendingPathComponent("a.png")
        try Data([1, 2, 3]).write(to: image)
        let id = try store.insert(kind: .image, text: "Image 1×1", imagePath: image.path, hash: "h", byteSize: 3)
        try store.delete(id: id)
        XCTAssertEqual(try store.search("Image").count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }

    func testDeleteSinceOnlyRemovesRecentItems() throws {
        try add("old", at: 100)
        try add("recent", at: 200)
        XCTAssertEqual(try store.deleteSince(Date(timeIntervalSince1970: 150)), 1)
        XCTAssertEqual(try store.search("").map(\.preview), ["old"])
    }

    func testPreviewIsTruncatedButFullTextIsKept() throws {
        let long = String(repeating: "x", count: 5000)
        let id = try add(long, at: 1)
        XCTAssertEqual(try store.search("").first?.preview.count, Store.previewLength)
        XCTAssertEqual(try store.fullText(id: id)?.count, 5000)
    }

    func testPagination() throws {
        for index in 0..<25 {
            try add("item \(index)", at: TimeInterval(index))
        }
        let page = try store.search("", limit: 10, offset: 10)
        XCTAssertEqual(page.first?.preview, "item 14")
        XCTAssertEqual(page.count, 10)
    }
}
