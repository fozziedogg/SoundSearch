import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Clean up any leftover ProTools spot temp files from previous sessions
        let spotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibrarySpot")
        try? FileManager.default.removeItem(at: spotDir)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
