import XCTest
@testable import MacNative

final class CompatTests: XCTestCase {
    func testDatabaseParsesAndApplies() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../compat/games.json").standardizedFileURL
        struct File: Decodable { var schema: Int; var games: [CompatEntry] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.schema, 1)
        let l4d2 = try XCTUnwrap(file.games.first { $0.key == "steam:550" })
        XCTAssertEqual(l4d2.status, .works)
        XCTAssertEqual(l4d2.apply(to: .default).graphics, .wined3d)
    }

    func testConfigKeys() throws {
        let json = #"{"store":"steam","id":"1","title":"T","status":"playable","revision":2,"config":{"graphics":"dxmt","windowsVersion":"win7","fpsLimit":60,"retinaMode":true,"launchArguments":"-dx11","environment":{"DXVK_HUD":"fps"}}}"#
        let e = try JSONDecoder().decode(CompatEntry.self, from: Data(json.utf8))
        let c = e.apply(to: .default)
        XCTAssertEqual(c.graphics, .dxmt)
        XCTAssertEqual(c.windowsVersion, .win7)
        XCTAssertEqual(c.fpsLimit, 60)
        XCTAssertTrue(c.retinaMode)
        XCTAssertEqual(c.launchArguments, "-dx11")
        XCTAssertEqual(c.environment.first?.value, "fps")
    }
}
