import AppKit

let options: CLIOptions
do {
    options = try CLI.parse(CommandLine.arguments)
} catch let e as CLIError {
    FileHandle.standardError.write(Data(e.message.utf8))
    exit(2)
}

let engine = Engine(cli: options)

/// One-shot gate so SIGINT+SIGTERM (or a repeated signal) run graceful shutdown exactly once.
final class ShutdownOnce {
    private var begun = false
    private let lock = NSLock()
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if begun { return false }
        begun = true; return true
    }
}

if options.headless {
    let shutdownOnce = ShutdownOnce()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        // shutdown() hops its final unregister + `sem.signal()` onto DispatchQueue.main and then
        // blocks on that semaphore. Running it *on* .main deadlocks: the main queue is busy with
        // this handler so the enqueued hop can never execute, `exit(0)` stays unreachable, and the
        // process zombies. Run it on a background queue instead — the main RunLoop stays free to
        // service the hop, so shutdown completes (goodbye + app_stop + discovery_stop all log) and
        // the process exits.
        src.setEventHandler {
            guard shutdownOnce.begin() else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                engine.shutdown(reason: "app_shutdown")
                exit(0)
            }
        }
        src.resume()
        sources.append(src)
    }
    engine.onReady = { id, port in
        FileHandle.standardOutput.write(Data("READY id=\(id) port=\(port)\n".utf8))
    }
    engine.start()
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(engine: engine)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
