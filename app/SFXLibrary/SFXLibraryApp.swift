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
                .background(WindowFrameSaver(autosaveName: "MainWindow"))
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

/// Injects itself into the view hierarchy to reliably obtain the NSWindow reference,
/// then sets the autosave name so AppKit persists frame + screen across launches.
private struct WindowFrameSaver: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName(autosaveName)
            // Second pass: SwiftUI may relayout after setFrameAutosaveName fires,
            // overriding the restored frame. Explicitly re-apply the saved frame
            // after SwiftUI's layout settles.
            DispatchQueue.main.async {
                window.setFrameUsingName(autosaveName)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
