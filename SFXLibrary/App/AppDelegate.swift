import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // DEBUG: mirror all print() output to ~/Desktop/sfxaudio.log
        // Remove before release.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/sfxaudio.log")
        freopen(logURL.path, "w", stdout)
        freopen(logURL.path, "a", stderr)

        // Clean up any leftover ProTools spot temp files from previous sessions
        let spotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibrarySpot")
        try? FileManager.default.removeItem(at: spotDir)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
