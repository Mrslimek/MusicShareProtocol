import Foundation

enum Wire {
    static let serviceType = "_musicshare._tcp."
    static let serviceDomain = "local."
    static let protoV = 1
    static let appVersion = "0.1.0"
    static let platform = "macos"

    static let handshakeTimeout: TimeInterval = 5
    static let pingInterval: TimeInterval = 5
    static let pongTimeout: TimeInterval = 10
    static let peerExpiry: TimeInterval = 60
    static let statusValues = ["playing", "paused", "stopped"]
    static let goodbyeReasons = ["app_shutdown", "user_close", "manual"]

    static func backoffDelay(attempt index: Int) -> TimeInterval {
        let bases: [TimeInterval] = [1.5, 3, 6, 12, 24]
        let base = index < bases.count ? bases[index] : 30
        return base * Double.random(in: 0.8...1.2) // ±20 % jitter
    }

    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    static func build(type: String, from: String, replyTo: String? = nil,
                      extra: [String: Any] = [:]) -> [String: Any] {
        var obj: [String: Any] = ["v": protoV, "type": type,
                                  "id": UUID().uuidString.lowercased(),
                                  "from": from, "ts": nowMs()]
        if let replyTo { obj["replyTo"] = replyTo }
        for (k, v) in extra { obj[k] = v }
        return obj
    }

    /// Parses the shared envelope. Returns nil + reason when the frame is not a valid message.
    static func parse(_ text: String) -> (msg: Message, error: String?) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (Message(type: "", id: "", from: "", ts: 0), "not a JSON object")
        }
        let type = obj["type"] as? String
        let id = obj["id"] as? String
        let from = obj["from"] as? String
        let ts = obj["ts"] as? Double
        var missing: [String] = []
        if (obj["v"] as? Int) != protoV { missing.append("v") }
        if type == nil { missing.append("type") }
        if id == nil { missing.append("id") }
        if from == nil { missing.append("from") }
        if ts == nil { missing.append("ts") }
        if !missing.isEmpty {
            return (Message(type: type ?? "?", id: id ?? "?", from: from ?? "?", ts: ts ?? 0),
                    "missing/invalid envelope fields: \(missing.joined(separator: ","))")
        }
        var fields = obj
        ["v", "type", "id", "from", "ts", "replyTo"].forEach { fields.removeValue(forKey: $0) }
        return (Message(type: type!, id: id!, from: from!, ts: ts!,
                        replyTo: obj["replyTo"] as? String, fields: fields), nil)
    }

    static func encodeJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // DNS-SD TXT records: repeated 1-byte length + "key=value"
    static func encodeTXT(_ items: [(String, String)]) -> Data {
        var out = Data()
        for (k, v) in items {
            let pair = Array("\(k)=\(v)".utf8)
            guard !pair.isEmpty, pair.count <= 255 else { continue }
            out.append(UInt8(pair.count))
            out.append(contentsOf: pair)
        }
        return out
    }

    static func decodeTXT(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        var out: [String: String] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            let len = Int(data[i]); i = data.index(i, offsetBy: 1)
            guard len > 0, i < data.endIndex else { break }
            let end = min(data.index(i, offsetBy: len), data.endIndex)
            if let s = String(data: data[i..<end], encoding: .utf8) {
                if let eq = s.firstIndex(of: "=") {
                    out[String(s[..<eq])] = String(s[s.index(after: eq)...])
                } else { out[s] = "" }
            }
            i = end
        }
        return out
    }
}

struct Message {
    let type: String
    let id: String
    let from: String
    let ts: Double
    var replyTo: String?
    var fields: [String: Any] = [:]

    func str(_ key: String) -> String? { fields[key] as? String }
    func num(_ key: String) -> Double? { fields[key] as? Double }
    func int(_ key: String) -> Int? {
        if let i = fields[key] as? Int { return i }
        return (fields[key] as? Double).map { Int($0) }
    }
}
