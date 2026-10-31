import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine: Engine
    private var window: NSWindow?

    init(engine: Engine) { self.engine = engine }

    func applicationDidFinishLaunching(_ note: Notification) {
        let w = NSWindow(contentRect: NSMakeRect(0, 0, 920, 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Music Share MVP"
        w.center()
        w.contentView = NSHostingView(rootView: ContentView().environmentObject(engine))
        w.minSize = NSSize(width: 640, height: 480)
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        engine.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        engine.shutdown(reason: "app_shutdown")
    }
}
