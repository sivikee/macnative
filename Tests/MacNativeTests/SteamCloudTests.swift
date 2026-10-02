import XCTest
@testable import MacNative

final class SteamCloudTests: XCTestCase {
    private func cloud(_ prefix: URL) -> SteamCloud {
        SteamCloud(session: SteamSession(), appID: 288470,
                   account: .init(accountName: "t", steamID: 76_561_197_960_287_930, refreshToken: ""),
                   prefix: prefix, installDir: URL(fileURLWithPath: "/games/Fable"),
                   patterns: [.init(root: "WinMyDocuments", path: "My Games/Fable", pattern: "*.sav", recursive: false)])
    }

    func testCloudNameMapping() {
        let prefix = URL(fileURLWithPath: "/p")
        let c = cloud(prefix)
        let user = NSUserName()
        XCTAssertEqual(c.localURL(for: "%WinMyDocuments%My Games/Fable/save1.sav")?.path,
                       "/p/drive_c/users/\(user)/Documents/My Games/Fable/save1.sav")
        XCTAssertEqual(c.localURL(for: "%WinAppDataLocal%Default/file")?.path,
                       "/p/drive_c/users/\(user)/AppData/Local/Default/file")
        XCTAssertEqual(c.localURL(for: "%GameInstall%saves/a.dat")?.path, "/games/Fable/saves/a.dat")
        // ISteamRemoteStorage files: Steam's userdata layout, where gbe_fork is told to save.
        XCTAssertEqual(c.localURL(for: "profile.bin")?.path,
                       "/p/drive_c/Program Files (x86)/Steam/userdata/22202/288470/remote/profile.bin")
        XCTAssertNil(c.localURL(for: "%UnknownRoot%x"))
    }
}
