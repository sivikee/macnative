import XCTest
@testable import MacNative

final class UpdaterTests: XCTestCase {
    @MainActor func testVersionCompare() {
        XCTAssertEqual(Updater.compare("0.1.1", "0.1.0"), 1)
        XCTAssertEqual(Updater.compare("0.1.10", "0.1.9"), 1)
        XCTAssertEqual(Updater.compare("0.2", "0.1.9"), 1)
        XCTAssertEqual(Updater.compare("0.1.0", "0.1"), 0)
        XCTAssertEqual(Updater.compare("0.1.0", "0.1.1"), -1)
    }
}
