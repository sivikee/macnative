import XCTest
@testable import MacNative

final class InstallLocationTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macnative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFolderOnConnectedDiskIsAvailable() throws {
        let folder = try temporaryFolder()
        XCTAssertEqual(InstallLocation.status(of: folder), .available)
        XCTAssertEqual(InstallLocation.statusForChoosing(folder), .available)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "the write test cleans up")
    }

    func testMissingFolderOnConnectedDiskIsNotAMissingDrive() throws {
        let folder = try temporaryFolder().appendingPathComponent("gone")
        XCTAssertNil(InstallLocation.missingVolume(of: folder.path))
        XCTAssertEqual(InstallLocation.status(of: folder), .folderMissing(folder.path))
    }

    func testUnmountedDriveIsReportedAndNothingIsCreated() {
        let name = "MacNativeNoSuchDrive-\(UUID().uuidString)"
        let folder = URL(fileURLWithPath: "/Volumes/\(name)/Games", isDirectory: true)
        XCTAssertEqual(InstallLocation.missingVolume(of: folder.path), name)
        XCTAssertEqual(InstallLocation.status(of: folder), .driveDisconnected(name))
        XCTAssertEqual(InstallLocation.statusForChoosing(folder), .driveDisconnected(name))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/\(name)"))
    }

    func testMountPointDetection() throws {
        XCTAssertTrue(InstallLocation.isMountPoint("/"))
        XCTAssertFalse(InstallLocation.isMountPoint(try temporaryFolder().path), "a plain folder is not a mounted drive")
        XCTAssertFalse(InstallLocation.isMountPoint("/Volumes/MacNativeNoSuchDrive"))
    }

    func testGamesRootStaysInsideChosenFolder() {
        let root = InstallLocation.gamesRoot(in: URL(fileURLWithPath: "/Volumes/T7/Games", isDirectory: true))
        XCTAssertEqual(root.path, "/Volumes/T7/Games/MacNative")
    }

    func testSettingDecodesAndDefaultsToDataFolder() throws {
        let json = #"{"installLocationPath":"/Volumes/T7/Games"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.installLocationPath, "/Volumes/T7/Games")
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).installLocationPath,
                     "existing settings keep the default location")
    }

    /// The real thing: a disk image mounted, used, then ejected like a drive being unplugged.
    func testRealVolumeMountAndEject() throws {
        for fileSystem in ["ExFAT", "HFS+", "APFS"] {
            try checkMountAndEject(fileSystem)
        }
    }

    private func checkMountAndEject(_ fileSystem: String) throws {
        // exFAT volume names are limited to 15 characters.
        let name = "MN\(UUID().uuidString.prefix(8))"
        let image = try temporaryFolder().appendingPathComponent("drive.dmg")
        func hdiutil(_ args: String...) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard try hdiutil("create", "-size", "40m", "-fs", fileSystem, "-volname", name, image.path) == 0,
              try hdiutil("attach", image.path, "-nobrowse") == 0 else {
            throw XCTSkip("Can't create or mount a \(fileSystem) disk image here")
        }
        let volume = "/Volumes/\(name)"
        var mounted = true
        defer { if mounted { _ = try? hdiutil("detach", volume, "-force") } }

        let folder = URL(fileURLWithPath: volume + "/Games", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(InstallLocation.isMountPoint(volume), fileSystem)
        XCTAssertNil(InstallLocation.missingVolume(of: folder.path), fileSystem)
        XCTAssertEqual(InstallLocation.statusForChoosing(folder), .available, fileSystem)
        XCTAssertGreaterThan(InstallLocation.freeBytes(at: folder) ?? 0, 0, "\(fileSystem) free space must not read 0")

        // An open file would block the eject, the same way a leaked download descriptor would.
        XCTAssertEqual(try hdiutil("detach", volume), 0, fileSystem)
        mounted = false
        XCTAssertEqual(InstallLocation.missingVolume(of: folder.path), name, fileSystem)
        XCTAssertEqual(InstallLocation.status(of: folder), .driveDisconnected(name), fileSystem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume), "checking must not create the mount point")

        // Writing to the path now fails with an error rather than leaving a stray local folder.
        XCTAssertThrowsError(try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume))
    }
}
