import Darwin
import Foundation

/// Checks for folders that may live on a drive that comes and goes.
///
/// Never create anything under a path before checking it here: when a drive isn't mounted,
/// `/Volumes/<name>` can end up as a plain local folder, and macOS then mounts the real drive as
/// `/Volumes/<name> 1`.
enum InstallLocation {
    enum Status: Equatable {
        case available
        case driveDisconnected(String)
        case folderMissing(String)
        case notWritable(String)

        var message: String {
            switch self {
            case .available: "Ready"
            case .driveDisconnected(let drive):
                "“\(drive)” isn't connected. Connect it, or change the game install location in Settings → System."
            case .folderMissing(let path):
                "The game install folder \(path) no longer exists. Choose another in Settings → System."
            case .notWritable(let path):
                "MacNative can't write to \(path). The drive may be read-only. Choose another folder in Settings → System."
            }
        }
    }

    struct Failure: LocalizedError {
        var status: Status
        var errorDescription: String? { status.message }
    }

    /// The folder MacNative owns inside the one the player picked, so it never mixes with their files.
    static func gamesRoot(in folder: URL) -> URL {
        folder.appendingPathComponent("MacNative", isDirectory: true)
    }

    /// The name of the unmounted drive a path lives on, or nil if the path isn't on a missing drive.
    /// A folder that merely doesn't exist on a connected disk is not a missing drive.
    static func missingVolume(of path: String) -> String? {
        // Resolving turns the boot volume's `/Volumes/Macintosh HD` symlink into `/`.
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let parts = resolved.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return isMountPoint("/Volumes/\(parts[2])") ? nil : parts[2]
    }

    /// Whether a volume is mounted exactly at this path, not merely a folder sitting there.
    static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return mountedOn == path
    }

    static func status(of folder: URL) -> Status {
        if let drive = missingVolume(of: folder.path) { return .driveDisconnected(drive) }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .folderMissing(folder.path)
        }
        return fm.isWritableFile(atPath: folder.path) ? .available : .notWritable(folder.path)
    }

    /// `status(of:)` plus a real write, since permission checks can pass on drives that refuse writes.
    static func statusForChoosing(_ folder: URL) -> Status {
        let current = status(of: folder)
        guard current == .available else { return current }
        let probe = folder.appendingPathComponent(".macnative-write-test-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return .notWritable(folder.path) }
        try? FileManager.default.removeItem(at: probe)
        return .available
    }

    /// Free space on the volume holding `url`. The "important usage" figure can read 0 on external
    /// file systems, which would wrongly fail every install, so fall back to the plain figure.
    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
