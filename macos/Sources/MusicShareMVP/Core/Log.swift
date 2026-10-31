import Foundation

final class StructuredLogger {
    let localId: String
    let fileURL: URL
    private let echoStdout: Bool
    private let queue: DispatchQueue
    private let handle: FileHandle?
    private let isoFmt = ISO8601DateFormatter()
    /// Called on `queue` with a human-readable line for in-app display.
    var onHumanLine: ((String) -> Void)?

    init(localId: String, logDir: URL?, echoStdout: Bool, queue: DispatchQueue) {
        self.localId = localId
        self.echoStdout = echoStdout
        self.queue = queue
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dir = logDir ?? IdentityStore.appSupportDir().appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        fileURL = dir.appendingPathComponent("session-\(stamp)-\(localId.prefix(8)).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    func log(_ event: String,
             level: String = "info",
             remoteId: String? = nil,
             localAddr: String? = nil,
             remoteAddr: String? = nil,
             elapsedDiscoveryMs: Int? = nil,
             elapsedConnMs: Int? = nil,
             rttMs: Double? = nil,
             error: String? = nil,
             detail: String? = nil,
             extra: [String: Any] = [:]) {
        var obj: [String: Any] = ["ts": isoFmt.string(from: Date()),
                                  "level": level, "event": event, "localId": localId]
        if let remoteId { obj["remoteId"] = remoteId }
        if let localAddr { obj["localAddr"] = localAddr }
        if let remoteAddr { obj["remoteAddr"] = remoteAddr }
        if let elapsedDiscoveryMs { obj["elapsedDiscoveryMs"] = elapsedDiscoveryMs }
        if let elapsedConnMs { obj["elapsedConnMs"] = elapsedConnMs }
        if let rttMs {
            // NSDecimalNumber keeps JSON text free of binary-float artifacts (0.29999999…)
            obj["rttMs"] = NSDecimalNumber(string: String(format: "%.2f", rttMs))
        }
        if let error { obj["error"] = error }
        if let detail { obj["detail"] = detail }
        for (k, v) in extra { obj[k] = v }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        queue.async { [handle, echoStdout, isoFmt] in
            try? handle?.write(contentsOf: data)
            try? handle?.write(contentsOf: Data("\n".utf8))
            if echoStdout {
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            let short = "\(event)" + (detail.map { " \($0)" } ?? "")
                + (error.map { " error=\($0)" } ?? "")
                + (remoteId.map { " remote=\($0.prefix(8))" } ?? "")
            self.onHumanLine?("\(isoFmt.string(from: Date())) [\(level)] \(short)")
        }
    }

    /// Blocks until every queued line has been written (call before process exit).
    func drain() { queue.sync {} }
}
