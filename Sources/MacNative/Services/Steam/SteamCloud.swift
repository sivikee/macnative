import Foundation
import CryptoKit

/// Steam Auto-Cloud for native Steam games, following GameNative's approach:
/// download newer saves before launch, upload changes after the game exits.
///
/// Cloud file names look like `%WinMyDocuments%My Games/Game/save1.sav` (Auto-Cloud) or plain
/// `save1.sav` (ISteamRemoteStorage, which gbe_fork stores in Steam's userdata folder).
struct SteamCloud {
    let session: SteamSession
    let appID: UInt32
    let account: SteamSession.Account
    let prefix: URL
    let installDir: URL
    let patterns: [SteamAppInfo.SavePattern]

    struct Report {
        var downloaded = 0
        var uploaded = 0
        var deleted = 0
        var conflicts: [String] = []
        var skipped = 0
    }

    struct RemoteFile {
        var cloudName: String
        var sha: Data
        var timestamp: UInt64
        var size: Int
    }

    /// What was in sync last time: cloud name → SHA-1 (hex). Basis for telling who changed what.
    private struct SyncState: Codable {
        var files: [String: String] = [:]
        var paths: [String: String] = [:]   // cloud name → local path (for deletion tracking)
    }

    static var stateDir: URL {
        let d = SteamInstaller.root.appendingPathComponent("cloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var stateURL: URL { Self.stateDir.appendingPathComponent("\(account.accountID)-\(appID).json") }
    private func loadState() -> SyncState {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState()
    }
    private func saveState(_ s: SyncState) { try? JSONEncoder().encode(s).write(to: stateURL, options: .atomic) }

    // MARK: Paths

    private var userDir: URL { prefix.appendingPathComponent("drive_c/users/\(NSUserName())", isDirectory: true) }

    /// Where ISteamRemoteStorage files live (and where gbe_fork is told to keep them).
    static func remoteStorageDir(prefix: URL, accountID: UInt32, appID: UInt32) -> URL {
        prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/userdata/\(accountID)/\(appID)/remote", isDirectory: true)
    }

    private func rootURL(_ root: String) -> URL? {
        switch root.lowercased() {
        case "gameinstall": installDir
        case "winmydocuments": userDir.appendingPathComponent("Documents")
        case "winappdatalocal": userDir.appendingPathComponent("AppData/Local")
        case "winappdatalocallow": userDir.appendingPathComponent("AppData/LocalLow")
        case "winappdataroaming": userDir.appendingPathComponent("AppData/Roaming")
        case "winsavedgames": userDir.appendingPathComponent("Saved Games")
        case "winprogramdata": prefix.appendingPathComponent("drive_c/ProgramData")
        case "steamuserdata", "default", "": Self.remoteStorageDir(prefix: prefix, accountID: account.accountID, appID: appID)
        default: nil
        }
    }

    private func substitute(_ path: String) -> String {
        path.replacingOccurrences(of: "{64BitSteamID}", with: String(account.steamID))
            .replacingOccurrences(of: "{Steam3AccountID}", with: String(account.accountID))
    }

    /// Maps a cloud file name to its file inside the prefix.
    func localURL(for cloudName: String) -> URL? {
        guard cloudName.hasPrefix("%") else {
            return rootURL("default")?.appendingPathComponent(cloudName)
        }
        let afterFirst = cloudName.dropFirst()
        guard let end = afterFirst.firstIndex(of: "%") else { return nil }
        let token = String(afterFirst[afterFirst.startIndex..<end])
        let rest = String(afterFirst[afterFirst.index(after: end)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rootURL(token)?.appendingPathComponent(rest)
    }

    // MARK: Remote list

    func remoteFiles() async throws -> [RemoteFile] {
        let r = try await session.connection.call("Cloud.GetAppFileChangelist#1") { w in
            w.uint32(1, appID)
            w.uint64(2, 0)                 // full list, not a delta
        }
        let prefixes = (r.fields[4] ?? []).compactMap { v -> String? in
            if case let .bytes(d) = v { return String(decoding: d, as: UTF8.self) }
            return nil
        }
        return r.messages(2).compactMap { f in
            guard let name = f.string(1) else { return nil }
            // persist_state 2 = deleted
            if f.int32(5) == 2 { return nil }
            var cloudName = name
            if let i = f.uint32(7).map(Int.init), prefixes.indices.contains(i) { cloudName = prefixes[i] + name }
            return RemoteFile(cloudName: cloudName, sha: f.bytes(2) ?? Data(),
                              timestamp: f.uint64(3) ?? 0, size: Int(f.uint32(4) ?? 0))
        }
    }

    // MARK: Before launch

    /// Brings local saves up to date with the cloud.
    func download() async throws -> Report {
        var report = Report()
        var state = loadState()
        let remote = try await remoteFiles()
        for file in remote {
            try Task.checkCancellation()
            guard let local = localURL(for: file.cloudName) else { report.skipped += 1; continue }
            let remoteHex = file.sha.hexString
            let localHex = Self.sha1(local)?.hexString
            defer {
                state.paths[file.cloudName] = local.path
            }
            if localHex == remoteHex { state.files[file.cloudName] = remoteHex; continue }

            let base = state.files[file.cloudName]
            let localChanged = localHex != nil && localHex != base
            let remoteChanged = remoteHex != base
            if localChanged && remoteChanged {
                // Both sides moved since the last sync: keep the newer one.
                let localTime = (try? local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                    .timeIntervalSince1970 ?? 0
                report.conflicts.append(file.cloudName)
                if localTime >= Double(file.timestamp) { continue }      // local wins; uploaded after play
            } else if localChanged {
                continue                                                // local is newer; upload later
            }
            try await fetch(file, to: local)
            state.files[file.cloudName] = remoteHex
            report.downloaded += 1
        }
        saveState(state)
        return report
    }

    private func fetch(_ file: RemoteFile, to local: URL) async throws {
        let r = try await session.connection.call("Cloud.ClientFileDownload#1") { w in
            w.uint32(1, appID)
            w.string(2, file.cloudName)
        }
        guard let host = r.string(7), let path = r.string(8) else { throw SteamError(message: "No download URL for \(file.cloudName)") }
        if r.bool(11) == true { throw SteamError(message: "\(file.cloudName) is encrypted; not supported yet") }
        var request = URLRequest(url: URL(string: "\(r.bool(9) == false ? "http" : "https")://\(host)\(path)")!)
        for h in r.messages(10) { if let n = h.string(1), let v = h.string(2) { request.setValue(v, forHTTPHeaderField: n) } }
        let (body, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SteamError(message: "Cloud download failed for \(file.cloudName)") }
        // A compressed size different from the raw size means the payload is a one-entry zip.
        let data = (r.uint32(2) ?? 0) != (r.uint32(3) ?? 0) ? try Zip.firstEntry(body) : body
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: local, options: .atomic)
        if file.timestamp > 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(file.timestamp))],
                                                   ofItemAtPath: local.path)
        }
    }

    // MARK: After exit

    /// Uploads new/changed saves and deletes ones removed locally.
    func upload() async throws -> Report {
        var report = Report()
        var state = loadState()
        let remote = try await remoteFiles()
        let remoteByName = Dictionary(remote.map { ($0.cloudName, $0) }, uniquingKeysWith: { a, _ in a })

        // Local files: everything matching the save patterns, plus the remote-storage folder,
        // named the way the cloud already knows them when possible.
        var local: [String: URL] = [:]
        let knownByPath = Dictionary(remote.compactMap { f in localURL(for: f.cloudName).map { ($0.standardizedFileURL.path, f.cloudName) } },
                                     uniquingKeysWith: { a, _ in a })
        for (url, cloudName) in enumerateLocalSaves() {
            local[knownByPath[url.standardizedFileURL.path] ?? cloudName] = url
        }

        var toUpload: [(String, URL, Data)] = []
        for (name, url) in local {
            guard let data = try? Data(contentsOf: url) else { continue }
            let hex = Data(Insecure.SHA1.hash(data: data)).hexString
            if remoteByName[name]?.sha.hexString == hex { state.files[name] = hex; continue }
            toUpload.append((name, url, data))
        }
        // Deleted locally since the last sync, and unchanged in the cloud since then.
        let toDelete = state.files.compactMap { name, hex -> String? in
            guard local[name] == nil, let r = remoteByName[name], r.sha.hexString == hex,
                  let path = state.paths[name], !FileManager.default.fileExists(atPath: path) else { return nil }
            return name
        }
        guard !toUpload.isEmpty || !toDelete.isEmpty else { saveState(state); return report }

        let clientID = await session.clientInstanceID
        let batch = try await session.connection.call("Cloud.BeginAppUploadBatch#1") { w in
            w.uint32(1, appID)
            w.string(2, SteamAuth.deviceName)
            for (name, _, _) in toUpload { w.string(3, name) }
            for name in toDelete { w.string(4, name) }
            w.uint64(5, clientID)
        }
        let batchID = batch.uint64(1) ?? 0
        var ok = true
        for (name, url, data) in toUpload {
            do {
                try await put(name, url: url, data: data, batchID: batchID)
                state.files[name] = Data(Insecure.SHA1.hash(data: data)).hexString
                state.paths[name] = url.path
                report.uploaded += 1
            } catch {
                ok = false
            }
        }
        for name in toDelete {
            _ = try? await session.connection.call("Cloud.ClientDeleteFile#1") { w in
                w.uint32(1, appID); w.string(2, name); w.bool(3, true); w.uint64(4, batchID)
            }
            state.files[name] = nil
            state.paths[name] = nil
            report.deleted += 1
        }
        _ = try? await session.connection.call("Cloud.CompleteAppUploadBatchBlocking#1") { w in
            w.uint32(1, appID); w.uint64(2, batchID); w.uint32(3, ok ? 1 : 2)
        }
        saveState(state)
        return report
    }

    private func put(_ name: String, url: URL, data: Data, batchID: UInt64) async throws {
        let sha = Data(Insecure.SHA1.hash(data: data))
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let begin = try await session.connection.call("Cloud.ClientBeginFileUpload#1") { w in
            w.uint32(1, appID)
            w.uint32(2, UInt32(data.count))
            w.uint32(3, UInt32(data.count))
            w.bytes(4, sha)
            w.uint64(5, UInt64(mtime.timeIntervalSince1970))
            w.string(6, name)
            w.uint32(7, 0xFFFF_FFFF)          // sync to all platforms
            w.bool(10, false)                 // no client-side encryption
            w.uint64(13, batchID)
        }
        var success = true
        for block in begin.messages(2) {
            guard let host = block.string(1), let path = block.string(2) else { success = false; break }
            var request = URLRequest(url: URL(string: "\(block.bool(3) == false ? "http" : "https")://\(host)\(path)")!)
            request.httpMethod = Self.httpMethod(block.int32(4) ?? 4)
            for h in block.messages(5) { if let n = h.string(1), let v = h.string(2) { request.setValue(v, forHTTPHeaderField: n) } }
            if let explicit = block.bytes(8), !explicit.isEmpty {
                request.httpBody = explicit
            } else {
                let offset = Int(block.uint64(6) ?? 0)
                let length = Int(block.uint32(7) ?? UInt32(data.count))
                request.httpBody = data.subdata(in: offset..<min(offset + length, data.count))
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            if !((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)) { success = false; break }
        }
        let commit = try await session.connection.call("Cloud.ClientCommitFileUpload#1") { w in
            w.bool(1, success)
            w.uint32(2, appID)
            w.bytes(3, sha)
            w.string(4, name)
        }
        guard success, commit.bool(1) == true else { throw SteamError(message: "Cloud upload failed for \(name)") }
    }

    /// EHTTPMethod values used by Steam's upload instructions.
    private static func httpMethod(_ v: Int32) -> String {
        switch v { case 1: "GET"; case 2: "HEAD"; case 3: "POST"; case 5: "DELETE"; case 6: "OPTIONS"; case 7: "PATCH"; default: "PUT" }
    }

    /// Local files that belong in the cloud, with the cloud name Steam would give a new one.
    private func enumerateLocalSaves() -> [(URL, String)] {
        var out: [(URL, String)] = []
        let fm = FileManager.default
        for p in patterns {
            guard let root = rootURL(p.root) else { continue }
            let rel = substitute(p.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = rel.isEmpty ? root : root.appendingPathComponent(rel)
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            while let url = e.nextObject() as? URL {
                let sub = String(url.path.dropFirst(base.path.count + 1))
                if !p.recursive, sub.contains("/") { e.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      fnmatch(p.pattern.lowercased(), url.lastPathComponent.lowercased(), 0) == 0 else { continue }
                let dir = rel.isEmpty ? "" : rel + "/"
                out.append((url, "%\(p.root)%\(dir)\(sub)"))
            }
        }
        let remoteDir = Self.remoteStorageDir(prefix: prefix, accountID: account.accountID, appID: appID)
        if let e = fm.enumerator(at: remoteDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let url = e.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                out.append((url, String(url.path.dropFirst(remoteDir.path.count + 1))))
            }
        }
        return out
    }

    // MARK: Launch bookkeeping

    /// Tells Steam this machine is about to run the game (lets it flag pending syncs elsewhere).
    func signalLaunch() async {
        let clientID = await session.clientInstanceID
        _ = try? await session.connection.call("Cloud.SignalAppLaunchIntent#1") { w in
            w.uint32(1, appID)
            w.uint64(2, clientID)
            w.string(3, SteamAuth.deviceName)
            w.bool(4, true)
            w.int32(5, 0)
        }
    }

    func signalExit(uploadsRequired: Bool, uploadsCompleted: Bool) async {
        let clientID = await session.clientInstanceID
        try? await session.connection.notify("Cloud.SignalAppExitSyncDone#1") { w in
            w.uint32(1, appID)
            w.uint64(2, clientID)
            w.bool(3, uploadsCompleted)
            w.bool(4, uploadsRequired)
        }
    }

    static func sha1(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Data(Insecure.SHA1.hash(data: data))
    }
}
