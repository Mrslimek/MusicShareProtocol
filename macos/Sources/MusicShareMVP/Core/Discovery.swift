import Foundation

/// mDNS advertiser + browser. NetService callbacks arrive on the runloop that started them (main).
///
/// NetServiceBrowser fires `didFind` only when a service newly appears in its view, so peers
/// would falsely hit the 60 s "no re-announcement" expiry while running for > 60 s. We stop and
/// restart the browse periodically (< 60 s); a fresh browse re-notifies `didFind` for every live
/// service, which refreshes each peer's announce timestamp and host:port.
final class Discovery: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
    private static let rebrowseInterval: TimeInterval = 45

    private weak var engine: Engine?
    private var publisher: NetService?
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var nameToId: [String: String] = [:]
    private var lastPublish: (name: String, port: Int, id: String, displayName: String)?
    private var rebrowseTimer: Timer?

    init(engine: Engine) { self.engine = engine }

    /// NetService error dicts key the dns-sd code under the PLURAL `NSNetServicesErrorCode`
    /// (value = DNSServiceErrorType, e.g. -65548 kDNSServiceErr_NameConflict, -65555 NoAuth). The
    /// previous singular-only lookup always missed it and surfaced `Code=0`. Read plural first, then
    /// the singular spelling, so the real code reaches `Engine.onAdvertiseFailed` (and its -65548
    /// name-conflict retry / permission classification).
    private func errDomain(_ d: [String: NSNumber]) -> Int {
        d["NSNetServicesErrorDomain"]?.intValue ?? d["NSNetServiceErrorDomain"]?.intValue ?? 0
    }
    private func errCode(_ d: [String: NSNumber]) -> Int {
        d["NSNetServicesErrorCode"]?.intValue ?? d["NSNetServiceErrorCode"]?.intValue ?? 0
    }

    func publish(name: String, port: Int, id: String, displayName: String) {
        let svc = NetService(domain: Wire.serviceDomain, type: Wire.serviceType, name: name, port: Int32(port))
        _ = svc.setTXTRecord(Wire.encodeTXT([("id", id), ("name", displayName), ("v", "\(Wire.protoV)")]))
        svc.delegate = self
        publisher?.stop()
        publisher = svc
        lastPublish = (name, port, id, displayName)
        svc.publish()
    }

    func advertise(name: String, port: Int, id: String, displayName: String) {
        publish(name: name, port: port, id: id, displayName: displayName)
    }

    /// No NSNetService.update() on this SDK; re-publish carries the fresh TXT.
    func updateTXTName(_ name: String) {
        guard let engine, let last = lastPublish else { return }
        publish(name: last.name, port: last.port, id: engine.identity.id, displayName: name)
    }

    func beginBrowsing() {
        let t = Timer(timeInterval: Discovery.rebrowseInterval, repeats: true) { [weak self] _ in
            self?.startBrowser()
        }
        RunLoop.main.add(t, forMode: .common)
        rebrowseTimer = t
        startBrowser()
    }

    private func startBrowser() {
        // Detach before stop: a stopping browser can deliver didRemove teardown events, and
        // those would falsely mark live peers gone on every re-browse.
        let old = browser
        browser = nil
        old?.delegate = nil
        old?.stop()
        let b = NetServiceBrowser()
        b.delegate = self
        browser = b
        b.searchForServices(ofType: Wire.serviceType, inDomain: Wire.serviceDomain)
    }

    func stopBrowsing() {
        rebrowseTimer?.invalidate()
        rebrowseTimer = nil
        browser?.stop()
        browser = nil
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    func unregister() {
        publisher?.stop()
        publisher = nil
        stopBrowsing()
    }

    // MARK: NetServiceDelegate (publish)

    func netServiceDidPublish(_ sender: NetService) {
        guard sender == publisher else { return }
        engine?.onAdvertiseStarted(name: sender.name)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender == publisher else { return }
        engine?.onAdvertiseFailed(domain: "dns_sd(NetServices \(errDomain(errorDict)))",
                                  code: errCode(errorDict), name: sender.name)
    }

    // MARK: NetServiceBrowserDelegate (browse + resolve)

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        engine?.onBrowseStarted()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        engine?.onBrowseFailed(domain: "dns_sd(NetServices \(errDomain(errorDict)))", code: errCode(errorDict))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = nameToId.removeValue(forKey: service.name)
        engine?.onServiceRemoved(id: id)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeAll { $0 === sender }
        guard let engine else { return }
        let txt = Wire.decodeTXT(sender.txtRecordData())
        guard let id = txt["id"], !id.isEmpty else {
            engine.onPeerInvalid(serviceName: sender.name, reason: "TXT missing id")
            return
        }
        guard txt["v"] == "\(Wire.protoV)" else {
            engine.onPeerInvalid(serviceName: sender.name, reason: "unsupported protocol v=\(txt["v"] ?? "-")")
            return
        }
        guard let host = sender.hostName, sender.port > 0 else {
            engine.onPeerInvalid(serviceName: sender.name, reason: "no host/port")
            return
        }
        nameToId[sender.name] = id
        let peerName = txt["name"] ?? sender.name
        engine.onPeerFound(id: id, name: peerName, hostPort: "\(host):\(sender.port)")
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
        engine?.onResolveFailed(domain: "dns_sd(NetServices \(errDomain(errorDict)))",
                                code: errCode(errorDict), serviceName: sender.name)
    }
}
