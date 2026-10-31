import Foundation
import Network
import CryptoKit

/// Minimal RFC 6455 server: unfragmented text/close/ping/pong frames only.
/// Chosen over Starscream's WebSocketServer because it cannot report the port
/// bound for an auto (port 0) listener, which discovery + READY require.
final class ServerConn {
    let uuid = UUID()
    let openAt = Date()
    var helloDeadline: Date?
    let remoteAddr: String
    var localAddr: String = "?"
    fileprivate let conn: NWConnection
    fileprivate var buffer = Data()
    fileprivate var upgraded = false
    fileprivate var closing = false

    init(_ conn: NWConnection) {
        self.conn = conn
        remoteAddr = ServerConn.describe(conn.endpoint) ?? "?"
    }

    static func describe(_ ep: NWEndpoint?) -> String? {
        guard case .hostPort(let host, let port)? = ep else { return nil }
        let h: String
        switch host {
        case .name(let n, _): h = n
        case .ipv4(let a): h = a.debugDescription
        case .ipv6(let a): h = a.debugDescription
        @unknown default: h = "\(host)"
        }
        return "\(h):\(port.rawValue)"
    }

    func send(text: String) {
        guard !closing else { return }
        conn.send(content: FrameCodec.encode(opcode: 0x1, payload: Data(text.utf8)),
                  completion: .contentProcessed { _ in })
    }

    func sendClose(code: UInt16, reason: String) {
        guard !closing else { return }
        closing = true
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xff)])
        payload.append(contentsOf: Array(reason.utf8.prefix(120)))
        conn.send(content: FrameCodec.encode(opcode: 0x8, payload: payload),
                  completion: .contentProcessed { _ in self.cancel() })
    }

    fileprivate func cancel() {
        conn.cancel()
    }
}

enum FrameCodec {
    static func encode(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(127)
            for i in (0..<8).reversed() { out.append(UInt8((UInt64(n) >> (8 * i)) & 0xFF)) }
        }
        out.append(payload)
        return out
    }

    enum Result {
        case needMore
        case oversize
        case frame(opcode: UInt8, payload: Data)
    }

    /// One complete frame from the front of `buffer`; consumes it on success.
    static func decode(_ buffer: inout Data, maxPayload: Int) -> Result {
        guard buffer.count >= 2 else { return .needMore }
        let b0 = buffer[buffer.startIndex], b1 = buffer[buffer.startIndex + 1]
        let fin = b0 & 0x80 != 0, opcode = b0 & 0x0F
        let masked = b1 & 0x80 != 0
        var len = Int(b1 & 0x7F)
        var offset = 2
        if len == 126 {
            guard buffer.count >= 4 else { return .needMore }
            len = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            offset = 4
        } else if len == 127 {
            guard buffer.count >= 10 else { return .needMore }
            var v = 0
            for i in 0..<8 { v = v << 8 | Int(buffer[buffer.startIndex + 2 + i]) }
            len = v; offset = 10
        }
        var key: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return .needMore }
            key = [UInt8](buffer[(buffer.startIndex + offset)..<buffer.index(buffer.startIndex + offset, offsetBy: 4)])
            offset += 4
        }
        if len > maxPayload { return .oversize }
        guard buffer.count >= offset + len else { return .needMore }
        let start = buffer.index(buffer.startIndex, offsetBy: offset)
        var payload = Data(buffer[start..<buffer.index(start, offsetBy: len)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= key[i % 4] }
        }
        buffer.removeSubrange(buffer.startIndex..<buffer.index(start, offsetBy: len))
        if !fin { return .frame(opcode: 0xF, payload: Data()) } // fragmentation unsupported
        return .frame(opcode: opcode, payload: payload)
    }
}

final class RFCServer {
    enum Event {
        case listening(port: Int)
        case listenFailed(String)
        case opened(ServerConn)
        case text(ServerConn, String, remoteAddr: String)
        case closed(ServerConn, code: UInt16, reason: String, byPeer: Bool)
    }
    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var listener: NWListener?
    private var boundPort = 0
    private var conns: [UUID: ServerConn] = [:]
    private let maxMsg = 1 << 20

    init(queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
        self.queue = queue; self.onEvent = onEvent
    }

    func start(pinPort: Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let l = pinPort > 0
                ? try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(pinPort))!)
                : try NWListener(using: params)
            listener = l
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready:
                    let p = Int(l.port?.rawValue ?? 0)
                    self.boundPort = p
                    self.onEvent(.listening(port: p))
                case .failed(let e): self.onEvent(.listenFailed("\(e)"))
                case .cancelled: break
                default: break
                }
            }
            l.start(queue: queue)
        } catch {
            onEvent(.listenFailed("bind \(pinPort): \(error)"))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in conns.values { c.cancel() }
        conns.removeAll()
    }

    private func accept(_ c: NWConnection) {
        let sc = ServerConn(c)
        sc.localAddr = "0.0.0.0:\(boundPort)"
        conns[sc.uuid] = sc
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .failed, .cancelled:
                self.drop(sc, code: 1006, reason: "tcp closed", byPeer: true)
            default: break
            }
        }
        c.start(queue: queue)
        receive(sc)
    }

    private func drop(_ sc: ServerConn, code: UInt16, reason: String, byPeer: Bool) {
        guard conns.removeValue(forKey: sc.uuid) != nil else { return }
        sc.cancel()
        onEvent(.closed(sc, code: code, reason: reason, byPeer: byPeer))
    }

    private func receive(_ sc: ServerConn) {
        sc.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { _ = error; self.drop(sc, code: 1006, reason: "read error", byPeer: true); return }
            if let data, !data.isEmpty { sc.buffer.append(data); self.process(sc) }
            if isComplete { self.drop(sc, code: 1006, reason: "peer closed", byPeer: true); return }
            self.receive(sc)
        }
    }

    private func process(_ sc: ServerConn) {
        if !sc.upgraded {
            guard let end = sc.buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if sc.buffer.count > 16384 { drop(sc, code: 1011, reason: "oversize handshake", byPeer: false) }
                return
            }
            let head = String(data: sc.buffer[sc.buffer.startIndex..<end.lowerBound], encoding: .utf8) ?? ""
            sc.buffer.removeSubrange(sc.buffer.startIndex..<end.upperBound)
            guard let key = HTTPHandshake.webSocketKey(from: head),
                  let accept = HTTPHandshake.acceptHeader(for: key) else {
                sc.conn.send(content: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8),
                             completion: .contentProcessed { _ in self.drop(sc, code: 1011, reason: "bad handshake request", byPeer: false) })
                return
            }
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            sc.upgraded = true
            sc.conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                self.onEvent(.opened(sc))
                self.drainFrames(sc)
            })
            return
        }
        drainFrames(sc)
    }

    private func drainFrames(_ sc: ServerConn) {
        while true {
            let frame: FrameCodec.Result
            frame = FrameCodec.decode(&sc.buffer, maxPayload: maxMsg)
            switch frame {
            case .needMore: return
            case .oversize:
                drop(sc, code: 1011, reason: "frame exceeds max size", byPeer: false); return
            case .frame(let opcode, let payload):
                switch opcode {
                case 0x1:
                    guard let s = String(data: payload, encoding: .utf8) else {
                        drop(sc, code: 1011, reason: "invalid utf-8 text frame", byPeer: false); return
                    }
                    onEvent(.text(sc, s, remoteAddr: sc.remoteAddr))
                case 0x8:
                    var code: UInt16 = 1005
                    if payload.count >= 2 {
                        code = UInt16(payload[payload.startIndex]) << 8
                            | UInt16(payload[payload.startIndex + 1])
                    }
                    let reason = payload.count > 2
                        ? String(data: payload[(payload.startIndex + 2)...], encoding: .utf8) ?? "" : ""
                    drop(sc, code: code, reason: reason, byPeer: true)
                    return
                case 0x9:
                    sc.conn.send(content: FrameCodec.encode(opcode: 0xA, payload: payload),
                                 completion: .contentProcessed { _ in })
                case 0xA: break // unsolicited ws-level pong, ignore
                default:
                    drop(sc, code: 1011, reason: "unexpected opcode \(opcode)", byPeer: false); return
                }
            }
        }
    }
}

enum HTTPHandshake {
    static let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func webSocketKey(from request: String) -> String? {
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static func acceptHeader(for key: String) -> String? {
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }
}
