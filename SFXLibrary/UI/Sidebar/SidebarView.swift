import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppEnvironment.self) var env
    @State private var expandedFolders: Set<String> = []
    @State private var isRescanning: Set<String> = []
    @State private var renamingProjectID: Int64? = nil

    var body: some View {
        @Bindable var bEnv = env
        List(selection: $bEnv.sidebarSelection) {
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

            Section {
                ForEach(env.projects) { project in
                    ProjectRow(
                        project: project,
                        isRenaming: Binding(
                            get: { renamingProjectID == project.id },
                            set: { renamingProjectID = $0 ? project.id : nil }
                        )
                    )
                    .tag(SidebarItem.project(project.id ?? 0))
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button {
                        if let created = env.createProject(name: "New Project") {
                            renamingProjectID = created.id
                            env.sidebarSelection = .project(created.id ?? 0)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
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
        .onChange(of: env.sidebarSelection) { _, newSel in
            switch newSel {
            case .folder(let path):
                env.activeProjectID = nil
                env.folderFilter = path
            case .project(let id):
                env.folderFilter     = nil
                env.activeProjectID  = id
                env.trackedProjectID = id
            default:
                env.activeProjectID = nil
                env.folderFilter = nil
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
        if case .folder(let sel) = env.sidebarSelection, sel.hasPrefix(path) {
            env.sidebarSelection = .allFiles
        }
    }
}

// MARK: - Project row

private struct ProjectRow: View {
    let project: Project
    @Binding var isRenaming: Bool
    @Environment(AppEnvironment.self) var env

    @State private var editName: String = ""
    @State private var isDropTargeted = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        // Evaluate at top level so @Observable always tracks this dependency.
        let isTracked = env.trackedProjectID == project.id

        Group {
            if isRenaming {
                TextField("", text: $editName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commit() }
                    .onExitCommand { isRenaming = false }
                    .onAppear {
                        editName = project.name
                        DispatchQueue.main.async { renameFocused = true }
                    }
            } else {
                HStack(spacing: 0) {
                    Text(project.name)
                        .fontWeight(isTracked ? .semibold : .regular)
                    Spacer(minLength: 6)
                    if isTracked {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .padding(.trailing, 2)
                    }
                }
                .onTapGesture(count: 2) {
                    editName = project.name
                    isRenaming = true
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let id = project.id else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { env.addFile(url.path, toProject: id) }
                }
            }
            return !providers.isEmpty
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isDropTargeted
                        ? Color.accentColor.opacity(0.30)
                        : isTracked
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                )
        )
        .contextMenu {
            Button("Rename") {
                editName = project.name
                isRenaming = true
            }
            Divider()
            Button(role: .destructive) {
                if let id = project.id { env.deleteProject(id) }
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
        }
    }

    private func commit() {
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let id = project.id {
            env.renameProject(id, to: trimmed)
        }
        isRenaming = false
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
    case project(Int64)
}
