import SwiftUI

struct SidebarView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selection: SidebarItem? = .allFiles
    @State private var isRescanning: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Files", systemImage: "waveform")
                    .tag(SidebarItem.allFiles)
            }

            Section("Watched Folders") {
                ForEach(env.watchedFolders) { folder in
                    folderRow(folder)
                }

                Label("Add Folder…", systemImage: "plus.circle")
                    .foregroundColor(.accentColor)
                    .onTapGesture { addFolder() }
            }

            Section("Tags") {
                // TODO: populate from TagRepository
            }

            Section("Categories") {
                // TODO: populate from CategoryRepository
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    // MARK: - Folder row

    @ViewBuilder
    private func folderRow(_ folder: WatchedFolder) -> some View {
        let scanning = isRescanning.contains(folder.path)
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
            Text(folderDisplayName(folder.path))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if scanning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
            }
        }
        .tag(SidebarItem.folder(folder.path))
        .contextMenu {
            Button {
                rescan(folder)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(scanning)

            Divider()

            Button(role: .destructive) {
                remove(folder)
            } label: {
                Label("Remove Folder", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func addFolder() {
        env.addWatchedFolder()
    }

    private func rescan(_ folder: WatchedFolder) {
        let path = folder.path
        isRescanning.insert(path)
        Task.detached(priority: .utility) {
            await env.folderScanner.rescan(path: path)
            await MainActor.run { isRescanning.remove(path) }
        }
    }

    private func remove(_ folder: WatchedFolder) {
        try? env.libraryService.removeWatchedFolder(path: folder.path,
                                                     scanner: env.folderScanner)
    }

    // MARK: - Helpers

    private func folderDisplayName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

enum SidebarItem: Hashable {
    case allFiles
    case folder(String)
    case tag(String)
    case category(Int64)
}
