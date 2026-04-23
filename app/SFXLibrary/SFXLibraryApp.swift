import SwiftUI
import AppKit

@main
struct SFXLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var env = AppEnvironment()
    @State private var showDeleteConfirmation = false
    @State private var addFolderAfterDelete = false
    @State private var showRenameDialog = false
    @State private var pendingDatabaseName: String = ""
    /// Mirrors env.currentDatabaseURL.lastPathComponent — updated via .onChange so commands can read it.
    @State private var currentDBName: String = ""

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(env)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    currentDBName = env.currentDatabaseURL.lastPathComponent
                }
                .background(WindowFrameSaver())
                .onChange(of: env.currentDatabaseURL) { _, url in
                    currentDBName = url.lastPathComponent
                }
                .alert("Delete Database?", isPresented: $showDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        env.deleteDatabase()
                        if addFolderAfterDelete {
                            env.addWatchedFolder()
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete the current library database. All file records, tags, and metadata will be lost. This cannot be undone.")
                }
                .alert("Rename Database", isPresented: $showRenameDialog) {
                    TextField("Name", text: $pendingDatabaseName)
                    Button("Rename") {
                        let name = pendingDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        env.renameDatabase(to: name)
                    }
                    .disabled(env.isScanning)
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(env.isScanning
                         ? "A scan is in progress — please wait for it to finish before renaming."
                         : "Enter a new name for the database file. The .sqlite extension will be added automatically if omitted.")
                }
        }
        .windowStyle(.titleBar)

        Settings {
            AudioSettingsView()
                .environment(env)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Appearance") {
                Picker("", selection: Binding(
                    get: { env.appearanceMode },
                    set: { env.appearanceMode = $0 }
                )) {
                    Text("Dark").tag("dark")
                    Text("Warm").tag("warm")
                    Text("Light").tag("light")
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Toggle("GRM", isOn: Binding(
                    get: { env.grahamRogersMode },
                    set: { env.grahamRogersMode = $0 }
                ))
            }

            CommandMenu("Library") {
                // Current database indicator
                Button(currentDBName.isEmpty ? "No Database" : currentDBName) { }
                    .disabled(true)

                Divider()

                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([env.currentDatabaseURL])
                }

                Button("Rename Database…") {
                    pendingDatabaseName = env.currentDatabaseURL
                        .deletingPathExtension().lastPathComponent
                    showRenameDialog = true
                }

                Button("Open Database…") {
                    env.openDatabase()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Save Database As…") {
                    env.saveDatabase()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Delete Database…") {
                    addFolderAfterDelete = false
                    showDeleteConfirmation = true
                }

                Button("New Database…") {
                    env.newDatabase()
                }
            }
        }
    }
}

// MARK: - Window frame persistence

/// Wraps a custom NSView subclass that overrides viewDidMoveToWindow().
/// AppKit guarantees self.window is non-nil inside that callback, unlike
/// DispatchQueue.main.async approaches where the view may not be in the
/// hierarchy yet. The deferred setFrameUsingName re-applies the saved frame
/// after SwiftUI's own layout pass, which otherwise overrides the restored position.
private struct WindowFrameSaver: NSViewRepresentable {
    func makeNSView(context: Context) -> FrameSaverView { FrameSaverView() }
    func updateNSView(_ nsView: FrameSaverView, context: Context) {}
}

final class FrameSaverView: NSView {
    private static let frameKey = "MainWindowFrame"
    private var applied = false

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !applied else { return }
        applied = true

        // Observe move/resize to manually persist the frame.
        // setFrameAutosaveName does not save in this SwiftUI context.
        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame(_:)),
            name: NSWindow.didMoveNotification,   object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame(_:)),
            name: NSWindow.didResizeNotification, object: window)

        let saved = UserDefaults.standard.string(forKey: Self.frameKey)
        SFXAudioLog.write("[Window] viewDidMoveToWindow | saved=\(saved ?? "NONE") | current=\(NSStringFromRect(window.frame)) | screen=\(window.screen?.localizedName ?? "nil")")

        guard let saved, !saved.isEmpty else { return }
        let frame = NSRectFromString(saved)
        guard frame != .zero else { return }

        // Deferred: SwiftUI repositions the window after viewDidMoveToWindow.
        // Apply saved frame on the next run loop to win that race.
        DispatchQueue.main.async { [weak window] in
            SFXAudioLog.write("[Window] restoring frame=\(saved) | before=\(NSStringFromRect(window?.frame ?? .zero))")
            window?.setFrame(frame, display: true, animate: false)
            SFXAudioLog.write("[Window] after restore=\(NSStringFromRect(window?.frame ?? .zero)) | screen=\(window?.screen?.localizedName ?? "nil")")
        }
    }

    @objc private func saveFrame(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        let str = NSStringFromRect(window.frame)
        UserDefaults.standard.set(str, forKey: Self.frameKey)
        SFXAudioLog.write("[Window] saved frame=\(str) | screen=\(window.screen?.localizedName ?? "nil")")
    }
}
