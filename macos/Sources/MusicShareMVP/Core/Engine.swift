import Foundation
import Combine
import Starscream
import Network

enum PeerDisplay: String {
    case discovered = "discovered"
    case connecting = "connecting…"
    case connected = "connected"
    case unreachable = "unreachable"
    case gone = "gone"
}

final class Engine: ObservableObject, WebSocketDelegate {

    struct PeerView: Identifiable, Equatable {
        let id: String
        let name: String
        let addr: String
        let state: PeerDisplay
        let note: String
        let remoteState: String
    }

    final class Peer {
        enum Phase { case idle, waitingAck, ready }
        let id: String                       // device id, or provisional "manual:<host:port>"
        var name: String
        var hostPort: String?
        var manual: Bool                     // we dialed manually — no mDNS expiry
        var incomingOnly = false             // created by inbound socket; never auto-dial
        var display: PeerDisplay = .discovered
        var phase: Phase = .idle
        var client: Starscream.WebSocket?
        var server: ServerConn?
        var sockOpen = false
        var helloSentId: String?
        var deadline: Date?                  // caller: hello_ack deadline from socket open
        var lastPingAt = Date.distantPast
        var pingPeerTs: [String: Double] = [:]   // ping id -> ping.ts (sender clock)
        var pingLocalMs: [String: Double] = [:]  // ping id -> our local send ms
        var lastPongAt: Date?
        var lastRttMs: Double?
        var lastSeenSeq: Int?
        var latest: (track: String, status: String, pos: Double, seq: Int, recv: Date)?
        var seenIds: [String] = []
        var backoff = 0
        var nextDialAt: Date?
        var dialStart: Date?
        var foundToAttemptMs = 0
        var foundAt = Date()
        var lastAnnounce = Date()
        var suppressReconnect = false
        var smokeSent = false
        init(id: String, name: String, hostPort: String?, manual: Bool) {
            self.id = id; self.name = name; self.hostPort = hostPort; self.manual = manual
        }
        var isLive: Bool { client != nil || server != nil }
    }

    private struct OwnState {
        var track = "Fake Track 01", status = "stopped", pos = 0.0, seq = 1
    }

    // ----- published on main -----
    @Published var peersView: [PeerView] = []
    @Published var logLines: [String] = []
    @Published var displayName: String
    @Published var listenPort = 0
    @Published var permissionProblem = false
    @Published var ownTrack = "Fake Track 01"
    @Published var ownStatus = "stopped"
    @Published var ownPosition: Double = 0
    @Published var ownSeq = 1

    let identity: DeviceIdentity
    let headless: Bool
    let logger: StructuredLogger
    let queue = DispatchQueue(label: "musicshare.engine")
    var onReady: ((String, Int) -> Void)?

    private var cli: CLIOptions
    private var server: RFCServer!
    private var currentName: String
    private var peers: [String: Peer] = [:]
    private var accepted: [UUID: ServerConn] = [:]
    private var own = OwnState()
    private var tAppStart = Date()
    private var tDiscoveryStart: Date?
    private var announceLive = false, browseLive = false, liveLogged = false
    private var firstPeerSeen = false
    private var myListenPort = 0
    private var readyFired = false
    private var statusTicks = 0
    private var tick: DispatchSourceTimer?
    private var pathMon: NWPathMonitor?
    fileprivate var discovery: Discovery?
    private var publisherName: String
    private var retriedNameOnce = false
    private var discoveryKnown = Set<String>()

    init(cli: CLIOptions) {
        self.cli = cli
        identity = cli.identity
        headless = cli.headless
        currentName = cli.identity.name
        publisherName = cli.identity.name
        displayName = cli.identity.name
        logger = StructuredLogger(localId: cli.identity.id, logDir: cli.logDir,
                                  echoStdout: cli.headless, queue: DispatchQueue(label: "musicshare.log"))
    }

    func start() {
        DispatchQueue.main.async { [weak self] in self?.installLogHook() }
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func installLogHook() {
        logger.onHumanLine = { [weak self] line in
            DispatchQueue.main.async {
                guard let self else { return }
                self.logLines.append(line)
                if self.logLines.count > 500 { self.logLines.removeFirst(self.logLines.count - 500) }
            }
        }
    }

    private func startOnQueue() {
        logger.log("app_start", detail: "v=\(Wire.appVersion) name=\(currentName) portPin=\(cli.port)")
        server = RFCServer(queue: queue) { [weak self] ev in self?.serverEvent(ev) }
        server.start(pinPort: cli.port)
        pathMon = NWPathMonitor()
        pathMon?.pathUpdateHandler = { [weak self] p in
            self?.logger.log("net_change", detail: "path status=\(p.status)")
        }
        pathMon?.start(queue: queue)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        tick = t
        if !cli.connectTarget.isEmpty { manualConnect(cli.connectTarget) }
    }

    // MARK: - Listener server events (engine queue)

    private func serverEvent(_ ev: RFCServer.Event) {
        switch ev {
        case .listening(let port):
            myListenPort = port
            if readyFired {
                logger.log("announce", level: "warning", detail: "listener re-ready on port \(port), refreshing advertisement")
                DispatchQueue.main.async { [weak self] in
                    guard let self, let d = self.discovery else { return }
                    d.advertise(name: self.publisherName, port: port, id: self.identity.id, displayName: self.currentName)
                }
                return
            }
            readyFired = true
            tDiscoveryStart = Date()
            logger.log("discovery_start", localAddr: "0.0.0.0:\(port)",
                       detail: "ws listener ready (appStartToLiveMs=\(msSince(tAppStart)))")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.listenPort = port
                self.startDiscoveryServices(port: port)
                self.onReady?(self.identity.id, port)
            }
        case .listenFailed(let err):
            logger.log("error", level: "error", error: err, detail: "ws listener failed to bind")
        case .opened(let conn):
            accepted[conn.uuid] = conn
            logger.log("connect_attempt", localAddr: conn.localAddr, remoteAddr: conn.remoteAddr,
                       detail: "inbound socket accepted, awaiting hello (callee)")
        case .text(let conn, let text, _):
            let p = peerFor(server: conn) ?? Peer(id: "?pending:\(conn.uuid)", name: conn.remoteAddr,
                                                  hostPort: conn.remoteAddr, manual: true)
            handleIncoming(p, serverConn: conn, text: text)
        case .closed(let conn, let code, let reason, let byPeer):
            guard accepted.removeValue(forKey: conn.uuid) != nil else { return }
            if let p = peerFor(server: conn) {
                socketDied(p, code: code, reason: reason, byPeer: byPeer, remoteAddr: conn.remoteAddr, viaClient: false)
            } else {
                logger.log("disconnect", level: "warning", remoteAddr: conn.remoteAddr,
                           detail: "code=\(code) reason=\(reason) pre-handshake socket dropped")
            }
        }
    }

    private func peerFor(server conn: ServerConn) -> Peer? { peers.values.first { $0.server === conn } }
    private func peerFor(client: WebSocketClient) -> Peer? { peers.values.first { $0.client === client } }

    // MARK: - Discovery (delegates arrive on main, hop to queue)

    private func startDiscoveryServices(port: Int) {
        logger.log("permission_request", detail: "mDNS publish + browse \(Wire.serviceType)")
        let d = Discovery(engine: self)
        discovery = d
        d.advertise(name: publisherName, port: port, id: identity.id, displayName: currentName)
        d.beginBrowsing()
    }

    func onAdvertiseStarted(name: String) { queue.async { [self] in
        self.announceLive = true
        self.logger.log("announce", remoteAddr: "0.0.0.0:\(self.myListenPort)",
                        detail: "advertised \(Wire.serviceType) instance=\(name)")
        self.maybeLogLive()
    }}

    func onAdvertiseFailed(domain: String, code: Int, name: String) { queue.async { [self] in
        let permission = self.isPermissionError(domain: domain, code: code)
        self.logger.log(permission ? "permission_denied" : "error", level: "error",
                        error: "Domain=\(domain) Code=\(code)",
                        detail: "publish \(name) — " + (permission ? "local network permission required" : "failed"))
        if permission { self.markPermissionProblem() }
        if code == -65548, !self.retriedNameOnce { // kDNSServiceErr_NameConflict (two instances on one machine)
            self.retriedNameOnce = true
            let alt = "\(self.publisherName)-\(self.identity.id.prefix(8))"
            self.publisherName = alt
            self.logger.log("announce", level: "warning", detail: "name conflict, republishing as \(alt)")
            DispatchQueue.main.async {
                self.discovery?.publish(name: alt, port: self.myListenPort, id: self.identity.id, displayName: self.currentName)
            }
        }
    }}

    func onBrowseStarted() { queue.async { [self] in
        guard !self.browseLive else { return }   // re-fires on every 45 s re-browse; log once
        self.browseLive = true
        self.logger.log("discovery_start", detail: "browsing \(Wire.serviceType)")
        self.maybeLogLive()
    }}

    func onBrowseFailed(domain: String, code: Int) { queue.async { [self] in
        let permission = self.isPermissionError(domain: domain, code: code)
        self.logger.log(permission ? "permission_denied" : "error", level: "error",
                        error: "Domain=\(domain) Code=\(code)",
                        detail: "browse — " + (permission ? "local network permission required" : "failed"))
        if permission { self.markPermissionProblem() }
    }}

    func onResolveFailed(domain: String, code: Int, serviceName: String) { queue.async { [self] in
        let permission = self.isPermissionError(domain: domain, code: code)
        self.logger.log(permission ? "permission_denied" : "error", level: "error",
                        error: "Domain=\(domain) Code=\(code)", detail: "resolve \(serviceName)")
        if permission { self.markPermissionProblem() }
    }}

    func onPeerInvalid(serviceName: String, reason: String) { queue.async { [self] in
        self.logger.log("error", level: "error", error: reason, detail: "resolved \(serviceName) unusable, ignored")
    }}

    func onPeerFound(id: String, name: String, hostPort: String) { queue.async { [self] in
        if id == self.identity.id { return }
        self.discoveryKnown.insert(id)
        let elapsedD = self.tDiscoveryStart.map { self.msSince($0) }
        if let p = self.peers[id] {
            p.hostPort = hostPort; p.name = name; p.lastAnnounce = Date(); p.incomingOnly = false
            if p.display == .gone {
                p.display = .discovered; p.backoff = 0; p.nextDialAt = Date(); p.suppressReconnect = false
                self.logger.log("peer_found", remoteId: id, remoteAddr: hostPort,
                                detail: "reappeared; reconnect schedule resumed")
            } else if p.display == .unreachable && !p.isLive {
                p.nextDialAt = Date()
            } else {
                self.logger.log("peer_found", remoteId: id, remoteAddr: hostPort, elapsedDiscoveryMs: elapsedD,
                                detail: "re-announced")
            }
        } else {
            let p = Peer(id: id, name: name, hostPort: hostPort, manual: false)
            p.foundAt = Date(); p.lastAnnounce = Date()
            self.peers[id] = p
            let first = !self.firstPeerSeen
            self.firstPeerSeen = true
            self.logger.log("peer_found", remoteId: id, remoteAddr: hostPort, elapsedDiscoveryMs: elapsedD,
                            detail: first ? "first; appStartToFirstPeerMs=\(self.msSince(self.tAppStart))" : "new peer")
            self.applyTieBreak(p)
        }
        self.publishUI()
    }}

    func onServiceRemoved(id: String?) { queue.async { [self] in
        if let id, let p = self.peers[id] { self.markGone(p, reason: "mDNS service removed") }
        self.publishUI()
    }}

    private func applyTieBreak(_ p: Peer) {
        // smaller id dials (contract §3); callee just waits for the inbound socket
        guard p.hostPort != nil, identity.id < p.id else { return }
        p.nextDialAt = Date()
    }

    private func markGone(_ p: Peer, reason: String) {
        p.display = .gone
        p.nextDialAt = nil
        logger.log("peer_lost", remoteId: p.id, remoteAddr: p.hostPort, detail: reason)
        p.suppressReconnect = true
        if p.isLive { closeSocket(p, code: 1000, reason: reason) }
        p.phase = .idle
    }

    private func maybeLogLive() {
        guard !liveLogged, announceLive, browseLive else { return }
        liveLogged = true
        logger.log("discovery_start", detail: "discovery live (appStartToLiveMs=\(msSince(tAppStart)))")
        logger.log("permission_granted", detail: "publish + browse callbacks observed")
    }

    // dns_sd.h (Xcode 27 SDK): NoAuth=-65555, Firewall=-65550, ServiceNotRunning=-65563,
    // PolicyDenied=-65570, NotPermitted=-65571. These are the codes seen when macOS 15+
    // Local Network privacy or the firewall blocks mDNS publish/browse.
    private static let permissionCodes: Set<Int> = [-65563, -65555, -65550, -65570, -65571]

    private func isPermissionError(domain: String, code: Int) -> Bool {
        Engine.permissionCodes.contains(code)
    }

    private func markPermissionProblem() {
        DispatchQueue.main.async { self.permissionProblem = true }
    }

    // MARK: - Outbound connections

    func manualConnect(_ hostPort: String) { queue.async { [self] in
        let parts = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, Int(parts[1]).map({ (1..<65535).contains($0) }) == true,
              let url = URL(string: "ws://\(hostPort)") else {
            self.logger.log("connect_attempt", level: "error", remoteAddr: hostPort,
                            error: "bad host:port '\(hostPort)'", detail: "manual connect rejected")
            self.logger.log("connect_failed", level: "error", remoteAddr: hostPort, error: "invalid address")
            return
        }
        let key = "manual:\(hostPort)"
        let p = self.peers[key] ?? Peer(id: key, name: hostPort, hostPort: hostPort, manual: true)
        p.hostPort = hostPort
        self.peers[key] = p
        if p.isLive || p.phase != .idle {
            self.logger.log("disconnect", level: "warning", remoteId: p.id, remoteAddr: hostPort,
                            detail: "superseded by newer manual connect (4003)")
            self.closeSocket(p, code: 4003, reason: "superseded by newer manual connect")
        }
        p.suppressReconnect = false
        p.display = .connecting
        self.dial(p, url: url)
        self.publishUI()
    }}

    private func dial(_ p: Peer, url: URL? = nil) {
        guard let hostPort = p.hostPort, p.client == nil, p.server == nil else { return }
        let u = url ?? URL(string: "ws://\(hostPort)")
        guard let u2 = u else {
            logger.log("connect_failed", remoteId: p.id, remoteAddr: hostPort, error: "unparsable url")
            return
        }
        p.phase = .waitingAck
        p.sockOpen = false
        p.dialStart = Date()
        p.nextDialAt = nil
        p.display = .connecting
        p.foundToAttemptMs = msSince(p.foundAt)
        logger.log("connect_attempt", remoteId: p.id, remoteAddr: hostPort,
                   detail: "caller dialing ws://\(hostPort)", extra: ["foundToAttemptMs": p.foundToAttemptMs])
        let ws = Starscream.WebSocket(request: URLRequest(url: u2))
        ws.callbackQueue = queue
        ws.delegate = self
        p.client = ws
        ws.connect()
    }

    /// newest-wins: attach the chosen socket for this peer, close any other one with 4003.
    private func adopt(_ p: Peer, client: Starscream.WebSocket? = nil, serverConn: ServerConn? = nil) {
        if let old = p.client, old !== client {
            p.client = nil
            logger.log("disconnect", level: "warning", remoteId: p.id,
                       detail: "superseded by newer connection (4003)")
            old.disconnect(closeCode: 4003)
        }
        if let old = p.server, old !== serverConn {
            p.server = nil
            accepted.removeValue(forKey: old.uuid)
            logger.log("disconnect", level: "warning", remoteId: p.id,
                       detail: "superseded by newer connection (4003)")
            old.sendClose(code: 4003, reason: "superseded by newer connection")
        }
        if let client { p.client = client }
        if let serverConn { p.server = serverConn }
    }

    private func closeSocket(_ p: Peer, code: UInt16, reason: String) {
        if let c = p.client { p.client = nil; c.disconnect(closeCode: code) }
        if let s = p.server {
            p.server = nil
            accepted.removeValue(forKey: s.uuid)
            s.sendClose(code: code, reason: reason)
        }
    }

    private func scheduleReconnect(_ p: Peer) {
        // hostPort == nil: unknown inbound-only peer, we have no address to dial — nothing to schedule
        guard !p.suppressReconnect, p.display != .gone, p.hostPort != nil else { return }
        let delay = Wire.backoffDelay(attempt: p.backoff)
        p.backoff += 1
        p.nextDialAt = Date().addingTimeInterval(delay)
        logger.log("reconnect_scheduled", remoteId: p.id, remoteAddr: p.hostPort,
                   detail: "attempt=\(p.backoff) in \(String(format: "%.1f", delay))s (±20%)")
    }

    private func markUnreachable(_ p: Peer, why: String) {
        guard p.display != .gone else { return }
        p.display = .unreachable
        logger.log("error", level: "warning", remoteId: p.id, remoteAddr: p.hostPort,
                   detail: "unreachable: \(why); remote state unknown")
    }

    private func socketDied(_ p: Peer, code: UInt16, reason: String, byPeer: Bool,
                            remoteAddr: String?, viaClient: Bool) {
        // Drop only the dead transport's reference; a surviving socket (simultaneous-open
        // supersession) must keep carrying the session.
        if viaClient { p.client = nil; p.sockOpen = false } else { p.server = nil }
        let wasPhase = p.phase
        p.pingPeerTs.removeAll(); p.pingLocalMs.removeAll()
        logger.log("disconnect", remoteId: p.id, remoteAddr: remoteAddr ?? p.hostPort,
                   detail: "code=\(code) reason=\(reason.isEmpty ? "-" : reason) \(byPeer ? "byPeer" : "byUs")")
        if p.isLive {
            // Duplicate / simultaneous-open transport closed while the peer's other socket survives.
            if viaClient, wasPhase == .waitingAck { p.phase = .idle; p.deadline = nil }
            else if wasPhase == .ready { p.lastPingAt = Date() } // keepalive restarts on the surviving socket
            logger.log("error", level: "warning", remoteId: p.id, remoteAddr: p.hostPort,
                       detail: "duplicate socket closed (code \(code)); peer still connected via other socket")
            publishUI()
            return
        }
        p.phase = .idle
        p.deadline = nil
        if p.suppressReconnect || p.display == .gone { publishUI(); return }
        if wasPhase == .waitingAck {
            logger.log("connect_failed", remoteId: p.id, remoteAddr: p.hostPort,
                       elapsedConnMs: p.dialStart.map { msSince($0) },
                       error: "socket closed before hello_ack (code \(code))")
        }
        if wasPhase != .idle { markUnreachable(p, why: "socket closed code=\(code)") }
        scheduleReconnect(p)
        publishUI()
    }

    // MARK: - Starscream delegate (arrives on engine queue)

    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        guard let p = peerFor(client: client) else { return } // superseded/stale socket, already logged
        switch event {
        case .connected:
            p.sockOpen = true
            p.deadline = Date().addingTimeInterval(Wire.handshakeTimeout)
            sendHello(p)
        case .text(let text):
            handleIncoming(p, serverConn: nil, text: text)
        case .disconnected(let reason, let code):
            socketDied(p, code: code, reason: reason, byPeer: true, remoteAddr: p.hostPort, viaClient: true)
        case .error(let e):
            socketDied(p, code: 1006, reason: e.map { "\($0)" } ?? "error", byPeer: true, remoteAddr: p.hostPort, viaClient: true)
        case .peerClosed, .cancelled:
            socketDied(p, code: 1006, reason: "closed by peer", byPeer: true, remoteAddr: p.hostPort, viaClient: true)
        default:
            break
        }
    }

    // MARK: - Inbound messages

    private func handleIncoming(_ p0: Peer, serverConn: ServerConn?, text: String) {
        let (msg, parseErr) = Wire.parse(text)
        if let parseErr {
            logger.log("message_malformed", remoteId: p0.id, error: parseErr, detail: "text=\(text.prefix(140))")
            return
        }
        if p0.seenIds.contains(msg.id) {
            logger.log("message_duplicate", remoteId: msg.from,
                       detail: "id=\(msg.id.prefix(8)) type=\(msg.type) — ignored")
            return
        }
        p0.seenIds.append(msg.id)
        if p0.seenIds.count > 128 { p0.seenIds.removeFirst(p0.seenIds.count - 128) }
        p0.lastAnnounce = Date()
        logger.log("msg_recv", remoteId: msg.from, remoteAddr: p0.hostPort,
                   detail: "type=\(msg.type) id=\(msg.id.prefix(8))")
        let p = peers[p0.id] ?? p0
        switch msg.type {
        case "hello":
            if let conn = serverConn { handleHello(msg, conn: conn) }
            else { logger.log("message_malformed", remoteId: msg.from, error: "hello on caller socket") }
        case "hello_ack": handleHelloAck(p, msg)
        case "ping":
            let pong = Wire.build(type: "pong", from: identity.id, replyTo: msg.id)
            sendRaw(p, pong, logEvent: nil, detail: "pong")
        case "pong": handlePong(p, msg)
        case "state_update": handleState(p, msg)
        case "test":
            logger.log("msg_recv", remoteId: msg.from, detail: "test text=\(msg.str("text") ?? "-")")
        case "goodbye": handleGoodbye(p, msg)
        default:
            logger.log("message_unknown", remoteId: msg.from, detail: "type=\(msg.type) ignored (kept connected)")
        }
    }

    private func handleHello(_ msg: Message, conn: ServerConn) {
        guard let name = msg.str("name"), msg.str("platform") != nil, msg.str("appVersion") != nil else {
            logger.log("message_malformed", remoteId: msg.from, error: "hello missing name/platform/appVersion")
            conn.sendClose(code: 4002, reason: "bad hello")
            return
        }
        let id = msg.from
        let known = discoveryKnown.contains(id)
        let p = peers[id] ?? Peer(id: id, name: name, hostPort: known ? conn.remoteAddr : nil, manual: !known)
        if peers[id] == nil {
            peers[id] = p
            p.foundAt = Date(); p.lastAnnounce = Date()
            p.incomingOnly = !known
            firstPeerSeen = true
            logger.log("peer_found", remoteId: id, remoteAddr: conn.remoteAddr,
                       detail: "via inbound connection")
        }
        p.name = name
        adopt(p, serverConn: conn)
        p.phase = .ready
        p.deadline = nil
        p.display = .connected
        p.lastPingAt = Date(); p.lastPongAt = Date(); p.backoff = 0
        // Fresh keepalive budget for the new transport (D8): outstanding pings belong to the dead
        // socket, and the watchdog keys on the oldest unanswered ping — without this clear it
        // fires within one tick of connect_ok and reject-loops every redial after a silent death.
        p.pingPeerTs.removeAll(); p.pingLocalMs.removeAll()
        let ack = Wire.build(type: "hello_ack", from: identity.id, replyTo: msg.id,
                             extra: ["name": currentName, "platform": Wire.platform, "appVersion": Wire.appVersion])
        sendRaw(p, ack, logEvent: "handshake_ack", detail: "hello_ack sent (callee)")
        logger.log("connect_ok", remoteId: id, localAddr: conn.localAddr, remoteAddr: conn.remoteAddr,
                   elapsedConnMs: msSince(p.foundAt),
                   detail: "callee: hello received + ack sent")
        sendStateSnapshot(p)
        afterHandshake(p)
        publishUI()
    }

    private func handleHelloAck(_ p: Peer, _ msg: Message) {
        guard p.phase == .waitingAck, p.client != nil else {
            logger.log("message_unknown", remoteId: msg.from, detail: "hello_ack outside handshake ignored")
            return
        }
        guard msg.replyTo == p.helloSentId else {
            logger.log("message_malformed", remoteId: msg.from, error: "hello_ack replyTo mismatch")
            return
        }
        guard msg.from == p.id || p.id.hasPrefix("manual:") else {
            logger.log("message_malformed", remoteId: msg.from, error: "hello_ack from \(msg.from) ≠ expected \(p.id)")
            return
        }
        logger.log("handshake_ack", remoteId: msg.from, detail: "hello_ack received (caller)")
        let realId = msg.from
        var target = p
        if p.id.hasPrefix("manual:") {
            let socket = p.client!
            self.peers.removeValue(forKey: p.id)
            if let existing = self.peers[realId] {
                target = existing
                adopt(existing, client: socket)
            } else {
                let rk = Peer(id: realId, name: msg.str("name") ?? p.name, hostPort: p.hostPort, manual: true)
                rk.client = socket
                rk.foundAt = p.foundAt; rk.dialStart = p.dialStart
                rk.foundToAttemptMs = p.foundToAttemptMs; rk.seenIds = p.seenIds
                self.peers[realId] = rk
                target = rk
            }
        }
        // §3 newest-wins: this dial just completed, so any older socket for the peer is superseded
        if let sock = target.client ?? p.client { adopt(target, client: sock) }
        target.phase = .ready
        target.deadline = nil
        target.display = .connected
        target.name = msg.str("name") ?? target.name
        target.lastPingAt = Date(); target.lastPongAt = Date()
        // Same fresh-budget clear as the callee path (D8): stale unanswered pings from the
        // previous transport must not gate the socket that just completed its handshake.
        target.pingPeerTs.removeAll(); target.pingLocalMs.removeAll()
        target.backoff = 0
        let elapsed = target.dialStart.map { msSince($0) } ?? 0
        logger.log("connect_ok", remoteId: realId, remoteAddr: target.hostPort, elapsedConnMs: elapsed,
                   detail: "caller: handshake complete",
                   extra: ["attemptToOkMs": elapsed, "foundToAttemptMs": target.foundToAttemptMs])
        sendStateSnapshot(target)
        afterHandshake(target)
        publishUI()
    }

    private func afterHandshake(_ p: Peer) {
        guard headless, !p.smokeSent else { return }
        p.smokeSent = true
        let t = Wire.build(type: "test", from: identity.id, extra: ["text": "smoke-hello from \(currentName)"])
        sendRaw(p, t, logEvent: nil, detail: "test")
    }

    private func handleGoodbye(_ p: Peer, _ msg: Message) {
        logger.log("msg_recv", remoteId: msg.from, detail: "goodbye reason=\(msg.str("reason") ?? "-")")
        closeSocket(p, code: 1000, reason: "peer said goodbye")
        p.phase = .idle
        markUnreachable(p, why: "goodbye from peer")
        scheduleReconnect(p)
        publishUI()
    }

    private func handlePong(_ p: Peer, _ msg: Message) {
        guard let replyTo = msg.replyTo, let sentPeerTs = p.pingPeerTs.removeValue(forKey: replyTo) else {
            logger.log("message_unknown", remoteId: p.id,
                       detail: "pong with unknown replyTo=\(msg.replyTo ?? "-")")
            return
        }
        let local = p.pingLocalMs.removeValue(forKey: replyTo) ?? Wire.nowMs()
        let rtt = msg.ts - sentPeerTs      // contract formula pong.ts − ping.ts
        let delta = Wire.nowMs() - local  // cheap local send→receive delta
        p.lastRttMs = rtt
        p.lastPongAt = Date()
        logger.log("pong_recv", remoteId: p.id, rttMs: rtt, detail: "localDeltaMs=\(Int(delta))")
        logger.log("rtt", remoteId: p.id, rttMs: rtt, detail: "ping_sent→pong_recv")
    }

    private func handleState(_ p: Peer, _ msg: Message) {
        guard let track = msg.str("track"), let status = msg.str("status"),
              let pos = msg.num("positionSec"), let seq = msg.int("seq"),
              Wire.statusValues.contains(status) else {
            logger.log("message_malformed", remoteId: msg.from,
                       error: "state_update missing/invalid track|status|positionSec|seq")
            return
        }
        let recv = Date()
        if let last = p.lastSeenSeq, seq <= last {
            let iso = ISO8601DateFormatter()
            logger.log("state_conflict", level: "warning", remoteId: msg.from,
                       detail: "seq=\(seq) <= lastSeq=\(last); prevRecvAt=" +
                              "\(p.latest.map { iso.string(from: $0.recv) } ?? "-") newRecvAt=\(iso.string(from: recv))",
                       extra: ["seq": seq, "lastSeq": last])
        }
        p.lastSeenSeq = seq
        p.latest = (track, status, pos, seq, recv)
        logger.log("state_recv", remoteId: msg.from,
                   detail: "\"\(track)\" \(status) @\(String(format: "%.1f", pos))s — newest displayed, no resolution",
                   extra: ["seq": seq])
        publishUI()
    }

    // MARK: - Sending

    private func sendHello(_ p: Peer) {
        let hello = Wire.build(type: "hello", from: identity.id,
                               extra: ["name": currentName, "platform": Wire.platform, "appVersion": Wire.appVersion])
        p.helloSentId = hello["id"] as? String
        sendRaw(p, hello, logEvent: "handshake_sent", detail: "hello sent (caller)")
    }

    private func sendStateSnapshot(_ p: Peer) {
        sendState(p, note: "post-handshake snapshot (same seq)")
    }

    private func sendState(_ p: Peer, note: String) {
        let obj = Wire.build(type: "state_update", from: identity.id, extra: [
            "track": own.track, "status": own.status, "positionSec": own.pos, "seq": own.seq])
        sendRaw(p, obj, logEvent: "state_sent", detail: "seq=\(own.seq) \(note)")
    }

    private func sendRaw(_ p: Peer, _ obj: [String: Any], logEvent: String?, detail: String?) {
        let type = obj["type"] as? String ?? "?"
        let text = Wire.encodeJSON(obj)
        if let c = p.client {
            c.write(string: text)
        } else if let s = p.server {
            s.send(text: text)
        } else {
            logger.log("error", level: "error", remoteId: p.id, error: "no socket — \(type) dropped")
            return
        }
        if let logEvent {
            logger.log(logEvent, remoteId: p.id, detail: detail)
        } else {
            logger.log("msg_sent", remoteId: p.id,
                       detail: "type=\(type) id=\((obj["id"] as? String)?.prefix(8) ?? "?")")
        }
    }

    // MARK: - UI mutators

    func setOwnPlayback(track: String?, status: String?, position: Double?, broadcast: Bool) {
        queue.async { [self] in
            let changed = (track != nil && track != self.own.track)
                || (status != nil && status != self.own.status)
                || (position != nil && position != self.own.pos)
            if let track { self.own.track = track }
            if let status { self.own.status = status }
            if let position { self.own.pos = position }
            if changed { self.own.seq += 1 }
            DispatchQueue.main.async {
                self.ownTrack = self.own.track; self.ownStatus = self.own.status
                self.ownPosition = self.own.pos; self.ownSeq = self.own.seq
            }
            if changed || broadcast { self.broadcastState(note: changed ? "auto-broadcast on change" : "broadcast") }
        }
    }

    func broadcastManual() {
        queue.async { [self] in self.broadcastState(note: "manual broadcast (same seq)") }
    }

    private func broadcastState(note: String) {
        let ready = peers.values.filter { $0.phase == .ready }
        if ready.isEmpty {
            logger.log("error", level: "warning", error: "broadcast attempt failed: no connected peers")
            return
        }
        for p in ready { sendState(p, note: note) }
    }

    func sendTest(_ text: String, peerId: String) {
        queue.async { [self] in
            guard let p = self.peers[peerId], p.phase == .ready else {
                self.logger.log("msg_sent", level: "warning", remoteId: peerId,
                                error: "test attempt failed: peer not connected", detail: "type=test")
                return
            }
            let obj = Wire.build(type: "test", from: self.identity.id, extra: ["text": text])
            self.sendRaw(p, obj, logEvent: nil, detail: "test")
        }
    }

    func setName(_ name: String) {
        queue.async { [self] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, Array(trimmed.utf8).count <= 128 else {
                self.logger.log("announce", level: "warning", error: "name invalid (empty or >128 utf8 bytes)")
                return
            }
            self.currentName = trimmed
            IdentityStore.updateName(trimmed)
            DispatchQueue.main.async {
                self.displayName = trimmed
                self.discovery?.updateTXTName(trimmed)
            }
            self.logger.log("announce", detail: "name → \(trimmed), TXT re-announced")
        }
    }

    // MARK: - Tick

    private func onTick() {
        let now = Date()
        var dueDials: [Peer] = []
        for conn in accepted.values where peerFor(server: conn) == nil {
            // callee handshake timeout: no hello within 5 s of socket open
            conn.helloDeadline = conn.helloDeadline ?? conn.openAt.addingTimeInterval(Wire.handshakeTimeout)
            if let d = conn.helloDeadline, now >= d {
                logger.log("handshake_timeout", level: "warning", remoteAddr: conn.remoteAddr,
                           error: "no hello within 5s (callee)")
                accepted.removeValue(forKey: conn.uuid)
                conn.sendClose(code: 4002, reason: "handshake timeout")
            }
        }
        for p in peers.values {
            if p.phase == .waitingAck, !p.sockOpen, let d = p.dialStart,
               now.timeIntervalSince(d) > Wire.handshakeTimeout {
                logger.log("connect_failed", remoteId: p.id, remoteAddr: p.hostPort, elapsedConnMs: msSince(d),
                           error: "no socket established within \(Int(Wire.handshakeTimeout))s (connect timeout)")
                if let c = p.client { p.client = nil; c.disconnect(closeCode: 1011) }
                p.phase = .idle
                markUnreachable(p, why: "dial unreachable")
                scheduleReconnect(p)
                continue
            }
            if p.phase == .waitingAck, p.sockOpen, let d = p.deadline, now >= d {
                logger.log("connect_timeout", level: "warning", remoteId: p.id, remoteAddr: p.hostPort,
                           elapsedConnMs: p.dialStart.map { msSince($0) },
                           error: "handshake timeout: no hello_ack within 5s of socket open")
                logger.log("handshake_timeout", level: "warning", remoteId: p.id, detail: "caller close 4002")
                p.phase = .idle
                closeSocket(p, code: 4002, reason: "handshake timeout")
                markUnreachable(p, why: "handshake timeout (remote state unknown)")
                scheduleReconnect(p)
                continue
            }
            if p.phase == .ready {
                if now.timeIntervalSince(p.lastPingAt) >= Wire.pingInterval {
                    p.lastPingAt = now
                    let ping = Wire.build(type: "ping", from: identity.id)
                    if let pid = ping["id"] as? String {
                        p.pingPeerTs[pid] = ping["ts"] as? Double ?? Wire.nowMs()
                        p.pingLocalMs[pid] = Wire.nowMs()
                    }
                    sendRaw(p, ping, logEvent: "ping_sent", detail: nil)
                }
                if let oldest = p.pingLocalMs.values.min(), Wire.nowMs() - oldest > Wire.pongTimeout * 1000 {
                    let sincePong = p.lastPongAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
                    logger.log("keepalive_timeout", level: "warning", remoteId: p.id, remoteAddr: p.hostPort,
                               detail: "no pong 10s after ping — unreachable (remote state unknown); " +
                                       "lastPong→timeoutMs=\(sincePong)",
                               extra: ["lastPongToTimeoutMs": sincePong])
                    p.phase = .idle
                    // Drop the ping bookkeeping here, as socketDied does: this close unmaps the
                    // conn (accepted/refs), so socketDied never runs for it and the stale
                    // unanswered pings would otherwise poison the next handshake's fresh budget.
                    p.pingPeerTs.removeAll(); p.pingLocalMs.removeAll()
                    closeSocket(p, code: 1000, reason: "keepalive timeout")
                    markUnreachable(p, why: "keepalive timeout")
                    scheduleReconnect(p)
                }
            }
            if p.phase == .idle, p.display != .gone, !p.incomingOnly,
               let due = p.nextDialAt, now >= due, p.hostPort != nil,
               identity.id < p.id || p.manual {
                dueDials.append(p)
            }
            if !p.manual, p.display != .gone, p.phase != .ready,
               now.timeIntervalSince(p.lastAnnounce) > Wire.peerExpiry {
                markGone(p, reason: "no re-announcement for \(Int(Wire.peerExpiry))s")
            }
        }
        for p in dueDials { dial(p) }
        publishUI()
        if headless {
            statusTicks += 1
            if statusTicks >= 30 {
                statusTicks = 0
                let disc = peers.values.filter { $0.display != .gone }.count
                let conn = peers.values.filter { $0.phase == .ready }.count
                let rtt = peers.values.compactMap { $0.lastRttMs }.max().map { String(Int($0)) } ?? "-"
                FileHandle.standardOutput.write(Data("STATUS discovered=\(disc) connected=\(conn) last_rtt=\(rtt)\n".utf8))
            }
        }
    }

    // MARK: - Shutdown

    /// Call from the main thread. Sends goodbye, flushes, closes, unregisters, drains logs.
    func shutdown(reason: String) {
        let sem = DispatchSemaphore(value: 0)
        queue.async { [self] in
            var n = 0
            for p in self.peers.values where p.phase == .ready {
                let bye = Wire.build(type: "goodbye", from: self.identity.id, extra: ["reason": reason])
                self.sendRaw(p, bye, logEvent: nil, detail: "goodbye")
                p.suppressReconnect = true
                p.phase = .idle
                n += 1
            }
            self.logger.log("app_stop", detail: "goodbye→\(n) peers, closing listener")
            // give queued WS writes time to flush before the close frame / cancel
            self.queue.asyncAfter(deadline: .now() + 0.15) {
                for p in self.peers.values where p.isLive { self.closeSocket(p, code: 1000, reason: reason) }
                self.tick?.cancel()
                self.pathMon?.cancel()
                self.server.stop()
                self.logger.log("discovery_stop", detail: "unregister mDNS service, close listener")
                self.logger.drain()
                DispatchQueue.main.async {
                    self.discovery?.unregister()
                    sem.signal()
                }
            }
        }
        // pump main runloop so the unregister hop can run
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        _ = sem.wait(timeout: .now() + 0.8)
    }

    // MARK: - Snapshot

    private func publishUI() {
        let snap = peers.values.sorted { $0.id < $1.id }.map { p -> PeerView in
            let st = p.latest.map { "\($0.track) | \($0.status) | \(String(format: "%.1f", $0.pos))s | seq \($0.seq)" } ?? "-"
            return PeerView(id: p.id, name: p.name, addr: p.hostPort ?? "-", state: p.display,
                            note: p.manual ? "manual" : (p.incomingOnly ? "inbound" : ""), remoteState: st)
        }
        DispatchQueue.main.async { self.peersView = snap }
    }

    private func msSince(_ d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
}

