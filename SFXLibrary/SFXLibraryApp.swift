import SwiftUI
import AppKit

@main
struct SFXLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var env = AppEnvironment()
    @State private var showDeleteConfirmation = false
    @State private var addFolderAfterDelete = false
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
        }
        .windowStyle(.titleBar)

        Settings {
            AudioSettingsView()
                .environment(env)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Library") {
                // Current database indicator
                Button(currentDBName.isEmpty ? "No Database" : currentDBName) { }
                    .disabled(true)

                Divider()

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
                    addFolderAfterDelete = true
                    showDeleteConfirmation = true
                }
            }
        }
    }
}
