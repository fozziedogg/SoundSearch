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

            CommandMenu("Debug") {
                Button("Copy Audio Log to Clipboard") {
                    let logURL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop/sfxaudio.log")
                    if let text = try? String(contentsOf: logURL, encoding: .utf8) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
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
