import Foundation

enum ShellError: LocalizedError {
    case failed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, output):
            "\(command) exited with \(status)\n\(output.suffix(800))"
        }
    }
}

enum Shell {
    /// Runs a process to completion and returns its combined stdout/stderr.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Drain continuously so chatty processes never block on a full pipe.
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                buffer.append(handle.availableData)
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let output = buffer.string
                if p.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    cont.resume(throwing: ShellError.failed(
                        command: ([executable] + arguments).joined(separator: " "),
                        status: p.terminationStatus, output: output))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Extracts a .tar.xz / .tar.gz archive with the system `tar` (bsdtar handles both).
    /// `include` limits extraction to matching paths (bsdtar glob).
    static func extract(_ archive: URL, to destination: URL, stripComponents: Int = 0,
                        include: String? = nil) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["-xf", archive.path, "-C", destination.path]
        if stripComponents > 0 { args += ["--strip-components", String(stripComponents)] }
        if let include { args += ["--include", include] }
        try await run("/usr/bin/tar", args)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
