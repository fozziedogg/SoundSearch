import SwiftUI

struct SidebarView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selection: SidebarItem? = .allFiles
    @State private var expandedFolders: Set<String> = []
    @State private var isRescanning: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Files", systemImage: "waveform")
                    .tag(SidebarItem.allFiles)
            }

            Section("Folders") {
                ForEach(env.watchedFolders) { folder in
                    FolderTreeRow(
                        path: folder.path,
                        canRemove: true,
                        expandedFolders: $expandedFolders,
                        isRescanning: $isRescanning,
                        onRescan: rescan,
                        onRemove: removeFolder
                    )
                }
            }

        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { env.addWatchedFolder() }) {
                    Label("Add Folder", systemImage: "plus")
                }
                .help("Add a folder to the library")
                .disabled(env.isScanning)
            }
        }
        .onChange(of: selection) { _, newSel in
            switch newSel {
            case .folder(let path): env.folderFilter = path
            default:                env.folderFilter = nil
            }
        }
    }

    // MARK: - Actions

    private func rescan(path: String) {
        isRescanning.insert(path)
        Task.detached(priority: .utility) {
            await env.folderScanner.rescan(path: path)
            await MainActor.run { isRescanning.remove(path) }
        }
    }

    private func removeFolder(path: String) {
        try? env.libraryService.removeWatchedFolder(path: path, scanner: env.folderScanner)
        if case .folder(let sel) = selection, sel.hasPrefix(path) {
            selection = .allFiles
        }
    }
}

// MARK: - Recursive folder tree row

struct FolderTreeRow: View {
    let path: String
    let canRemove: Bool
    @Binding var expandedFolders: Set<String>
    @Binding var isRescanning: Set<String>
    let onRescan: (String) -> Void
    let onRemove: (String) -> Void

    /// Cached subdirectories — nil until first appear, then set once.
    @State private var children: [String]? = nil

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        Group {
            if let kids = children, !kids.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedFolders.contains(path) },
                        set: { if $0 { expandedFolders.insert(path) }
                               else  { expandedFolders.remove(path) } }
                    )
                ) {
                    ForEach(kids, id: \.self) { child in
                        FolderTreeRow(
                            path: child,
                            canRemove: false,
                            expandedFolders: $expandedFolders,
                            isRescanning: $isRescanning,
                            onRescan: onRescan,
                            onRemove: onRemove
                        )
                    }
                } label: {
                    rowLabel
                }
            } else {
                rowLabel
            }
        }
        .task {
            guard children == nil else { return }
            let p = path
            let subs = await Task.detached(priority: .userInitiated) {
                Self.subfolders(of: p)
            }.value
            children = subs
        }
    }

    private var rowLabel: some View {
        let scanning = isRescanning.contains(path)
        return HStack(spacing: 6) {
            Image(systemName: canRemove ? "folder" : "folder.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if scanning {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
            }
        }
        .tag(SidebarItem.folder(path))
        .contextMenu {
            Button { onRescan(path) } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(scanning)

            if canRemove {
                Divider()
                Button(role: .destructive) { onRemove(path) } label: {
                    Label("Remove Folder", systemImage: "trash")
                }
            }
        }
    }

    nonisolated private static func subfolders(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map    { $0.path }
            .sorted()
    }
}

enum SidebarItem: Hashable {
    case allFiles
    case folder(String)
    case tag(String)
    case category(Int64)
}
