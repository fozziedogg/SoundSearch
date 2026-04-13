import SwiftUI
import AppKit

struct MainWindowView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selectedFile: AudioFile?
    @State private var showFileInfo: Bool = true

    private var windowTitle: String {
        let dbName = env.currentDatabaseURL.deletingPathExtension().lastPathComponent
        return "SoundSearch — \(dbName)"
    }

    private func applyWindowTitle(_ title: String) {
        NSApplication.shared.windows
            .filter { $0.isVisible && !($0 is NSPanel) }
            .forEach { $0.title = title }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VSplitView {
                // Top pane: Preview above File Info (File Info collapsible)
                Group {
                    if let file = selectedFile {
                        VStack(spacing: 0) {
                            PreviewView(file: file)
                            Divider()
                            FileInfoView(file: file, isExpanded: $showFileInfo)
                                .frame(minHeight: showFileInfo ? 120 : 0)
                        }
                    } else {
                        Text("Select a file")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 200)

                // Bottom pane: Browser
                FileListView(selectedFile: $selectedFile)
                    .frame(minHeight: 160)
            }
        }
        // Force full rebuild of all child @State when the database changes.
        // This resets sidebar selection, search text, expanded folders, etc.
        .id(env.databaseEpoch)
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(windowTitle)
        .onAppear { applyWindowTitle(windowTitle) }
        .onChange(of: env.currentDatabaseURL) { _, _ in
            applyWindowTitle(windowTitle)
            selectedFile = nil
        }
        .onChange(of: env.audioFiles) { _, newFiles in
            if let sel = selectedFile, !newFiles.contains(where: { $0.id == sel.id }) {
                selectedFile = nil
            }
        }
    }
}
