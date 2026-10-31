import Foundation

struct DeviceIdentity {
    var id: String
    var name: String
}

enum IdentityStore {
    static let appDirName = "MusicShareMVP"

    static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appDirName)
    }

    private static var fileURL: URL { appSupportDir().appendingPathComponent("device.json") }

    static func load() -> DeviceIdentity {
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let id = obj["id"], id.count >= 32 {
            let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            return DeviceIdentity(id: id.lowercased(), name: obj["name"] ?? host)
        }
        let fresh = DeviceIdentity(id: UUID().uuidString.lowercased(),
                                  name: ProcessInfo.processInfo.hostName)
        save(fresh)
        return fresh
    }

    static func save(_ identity: DeviceIdentity) {
        try? FileManager.default.createDirectory(at: appSupportDir(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: ["id": identity.id, "name": identity.name],
                                               options: [.prettyPrinted, .sortedKeys])
        if let data { try? data.write(to: fileURL) }
    }

    /// Persist a UI name edit while leaving the on-disk id untouched (a --id override for this
    /// run must not overwrite the persisted id).
    static func updateName(_ name: String) {
        save(DeviceIdentity(id: load().id, name: name))
    }
}
