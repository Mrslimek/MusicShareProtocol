import Foundation

struct CLIOptions {
    var identity: DeviceIdentity
    var headless = false
    var port = 0              // 0 = auto
    var connectTarget = ""
    var logDir: URL?
}

enum CLIError: Error {
    case badArg(String)
    var message: String {
        switch self {
        case .badArg(let m): return "musicshare: \(m)\n\(CLI.usage)"
        }
    }
}

enum CLI {
    static let usage = """
    usage: MusicShareMVP [--headless] [--id UUID] [--name NAME] [--port N] \
    [--connect host:port] [--log-dir DIR]
      --id/--name override this run only (persisted values untouched)
      --port 0 = dynamic; --log-dir overrides default log location
    """

    static func parse(_ argv: [String]) throws -> CLIOptions {
        var base = IdentityStore.load()
        var opts = CLIOptions(identity: base)
        var idOverride: String?
        var nameOverride: String?
        var i = 1
        func needValue(_ flag: String) throws -> String {
            guard i + 1 < argv.count else { throw CLIError.badArg("missing value for \(flag)") }
            i += 1
            return argv[i]
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--headless": opts.headless = true
            case "--id": idOverride = try needValue(a)
            case "--name": nameOverride = try needValue(a)
            case "--port":
                let v = try needValue(a)
                guard let p = Int(v), p >= 0, p <= 65535 else { throw CLIError.badArg("bad --port '\(v)'") }
                opts.port = p
            case "--connect": opts.connectTarget = try needValue(a)
            case "--log-dir":
                let v = try needValue(a)
                opts.logDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
            default:
                throw CLIError.badArg("unknown argument '\(a)'")
            }
            i += 1
        }
        if let idOverride {
            let norm = idOverride.lowercased()
            guard UUID(uuidString: norm) != nil else { throw CLIError.badArg("--id must be a UUID") }
            base.id = norm
        }
        if let nameOverride, !nameOverride.isEmpty {
            base.name = String(nameOverride.prefix(128))
        }
        opts.identity = base
        return opts
    }
}
