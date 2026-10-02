import XCTest
@testable import MacNative

final class DecoderTests: XCTestCase {
    private var sample: Data { Data(String(repeating: "MacNative depot chunk test. ", count: 300).utf8) + Data(0...255) }

    func testVZipLZMA() throws {
        let url = Bundle.module.url(forResource: "vzip_fixture", withExtension: "hex")!
        let vz = Data(hex: try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let out = try DepotChunk.decompress(vz, expectedSize: sample.count)
        XCTAssertEqual(out, sample)
    }

    func testAdler32ZeroSeed() {
        // Matches SteamKit2's Adler32.Calculate(0, data); value computed by the fixture generator.
        XCTAssertEqual(DepotChunk.adler32(sample), 0x610E_57D8)
    }

    func testZipStoredAndDeflated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = dir.appendingPathComponent("p.txt")
        try Data(String(repeating: "hello steam ", count: 5000).utf8).write(to: payload)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "t.zip", "p.txt"]
        try zip.run(); zip.waitUntilExit()
        XCTAssertEqual(try Zip.firstEntry(Data(contentsOf: dir.appendingPathComponent("t.zip"))), try Data(contentsOf: payload))
    }

    func testProtobufRoundTrip() throws {
        var w = ProtoWriter()
        w.uint32(1, 65580)
        w.string(2, "gabe")
        w.fixed64(3, 76_561_197_960_287_930)
        w.message(4) { $0.bool(1, true) }
        let m = try ProtoMessage(w.data)
        XCTAssertEqual(m.uint32(1), 65580)
        XCTAssertEqual(m.string(2), "gabe")
        XCTAssertEqual(m.uint64(3), 76_561_197_960_287_930)
        XCTAssertEqual(m.message(4)?.bool(1), true)
    }

    func testVDF() {
        let kv = VDF.parse(#"""
        "appinfo" { "common" { "name" "Half-Life" "type" "Game" } "depots" { "71" { "manifests" { "public" { "gid" "123" } } } } }
        """#)
        XCTAssertEqual(kv["appinfo"]?["common"]?["name"]?.string, "Half-Life")
        let app = SteamAppInfo(appID: 70, kv: kv["appinfo"]!)
        XCTAssertEqual(app?.depots.first?.manifests["public"], 123)
    }
}
