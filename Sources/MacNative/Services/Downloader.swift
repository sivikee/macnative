import Foundation

/// Streams a file to disk while reporting progress. Uses a dedicated delegate-based session
/// so progress works for multi-gigabyte game installers.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (_ received: Int64, _ total: Int64) -> Void

    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var progress: Progress?
    private var directory: URL!
    private var task: URLSessionDownloadTask?

    /// Downloads `request` into `directory`. The final filename is taken from the server
    /// (after redirects) unless `fileName` is provided.
    static func download(_ request: URLRequest, into directory: URL, fileName: String? = nil,
                         progress: Progress? = nil) async throws -> URL {
        let d = Downloader()
        return try await d.start(request, directory: directory, fileName: fileName, progress: progress)
    }

    static func download(_ url: URL, into directory: URL, fileName: String? = nil,
                         progress: Progress? = nil) async throws -> URL {
        try await download(URLRequest(url: url), into: directory, fileName: fileName, progress: progress)
    }

    private func start(_ request: URLRequest, directory: URL, fileName: String?,
                       progress: Progress?) async throws -> URL {
        self.progress = progress
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            let (tmp, response) = try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey:
                    "HTTP \(http.statusCode) for \(request.url?.absoluteString ?? "")"])
            }
            let name = fileName
                ?? response.suggestedFilename
                ?? response.url?.lastPathComponent
                ?? request.url?.lastPathComponent
                ?? UUID().uuidString
            let target = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            return target
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns, so move it somewhere stable first.
        let keep = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            if let response = downloadTask.response {
                continuation?.resume(returning: (keep, response))
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
