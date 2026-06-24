import SwiftUI
import AppKit

struct FileListView: View {
    @Environment(AppEnvironment.self) var env
    @StateObject private var vm = FileListViewModel()
    @Binding var selectedFile: AudioFile?
    var showHeader: Bool = true

    @State private var selectedID: Int64? = nil
    @State private var columnCustomization = TableColumnCustomization<AudioFileRow>()
    @State private var sortOrder: [AudioFileSort] = [AudioFileSort(field: .name)]
    @State private var sortedRows: [AudioFileRow] = []
    @State private var sortTask: Task<Void, Never>? = nil
    @FocusState private var searchFocused: Bool
    @State private var showChangesSheet = false

    // Active metadata profile drives the dynamic columns.
    @AppStorage(MetadataProfileKeys.profiles) private var profilesJSON: String = ""
    @AppStorage(MetadataProfileKeys.activeID) private var activeProfileID: String = ""

    private var activeProfile: MetadataProfile {
        MetadataProfileStore.activeProfile(profilesJSON: profilesJSON, activeID: activeProfileID)
    }

    private var allProfiles: [MetadataProfile] {
        MetadataProfileStore.loaded(from: profilesJSON).profiles
    }

    private var profileBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "tablecells")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Menu {
                ForEach(allProfiles) { profile in
                    Button {
                        activeProfileID = profile.id.uuidString
                    } label: {
                        if profile.id.uuidString == activeProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                SettingsLink { Text("Manage Profiles…") }
            } label: {
                HStack(spacing: 3) {
                    Text(activeProfile.name).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func applySort() {
        sortTask?.cancel()
        let files = vm.searchQuery.isEmpty ? env.audioFiles : vm.searchResults
        let order = sortOrder
        sortTask = Task {
            let rows = await Task.detached(priority: .userInitiated) {
                files.map { AudioFileRow(file: $0) }
            }.value
            guard !Task.isCancelled else { return }
            let sorted: [AudioFileRow]
            if order.isEmpty {
                sorted = rows
            } else {
                sorted = await Task.detached(priority: .userInitiated) {
                    rows.sorted(using: order)
                }.value
            }
            guard !Task.isCancelled else { return }
            sortedRows = sorted
        }
    }

    var body: some View {
        Table(of: AudioFileRow.self,
              selection: $selectedID,
              sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            fixedColumns
            TableColumnForEach(activeProfile.fields) { key in
                TableColumn(key.label, sortUsing: AudioFileSort(field: .bwf(key))) { row in
                    let v = row.file.displayValue(for: key)
                    Text(v ?? "—")
                        .font(.system(size: 11))
                        .foregroundColor(v != nil ? .secondary : Color.secondary.opacity(0.4))
                        .lineLimit(1)
                }
                .width(min: 50, ideal: 110)
                .customizationID(key.rawValue)
            }
        } rows: {
            ForEach(sortedRows) { row in
                TableRow(row)
                    .itemProvider {
                        NSItemProvider(object: URL(fileURLWithPath: row.file.fileURL) as NSURL)
                    }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: row.file.fileURL)])
                        }
                        if env.activeProjectID != nil {
                            Divider()
                            Button(role: .destructive) {
                                env.removeFromActiveProject(fileURL: row.file.fileURL)
                            } label: {
                                Label("Remove from Project", systemImage: "minus.circle")
                            }
                        }
                    }
            }
        }
        .scrollIndicators(.visible)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if showHeader { PanelHeader(title: "Browser") }
                if !env.foldersWithChanges.isEmpty && !env.isScanning {
                    Button { showChangesSheet = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 10))
                            Text("Folder changes detected — click for details")
                                .font(.system(size: 10))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.yellow.opacity(0.08))
                    }
                    .buttonStyle(.plain)
                } else if env.isScanning {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                            Text("\(env.scannedFileCount) files scanned…")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        if !env.currentScanFile.isEmpty {
                            Text(env.currentScanFile)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.07))
                } else {
                    let capped = env.totalAudioFileCount > env.browseLimit
                    HStack(spacing: 4) {
                        Text(capped
                             ? "Showing \(env.audioFiles.count) of \(env.totalAudioFileCount) records — search to find others"
                             : "Showing \(env.audioFiles.count) of \(env.totalAudioFileCount) records")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(capped ? Color.yellow.opacity(0.08) : Color.clear)
                }
                profileBar
                SearchBar(text: $vm.searchQuery, scope: $vm.searchScope, isFocused: $searchFocused)
                    .padding(8)
                    .background(.bar)
            }
        }
        .overlay {
            if sortedRows.isEmpty {
                Text(vm.searchQuery.isEmpty ? "Add a folder to get started" : "No results")
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: "fileListColumnCustomization"),
               let decoded = try? JSONDecoder().decode(TableColumnCustomization<AudioFileRow>.self, from: data) {
                columnCustomization = decoded
            }
            applySort()
        }
        .onChange(of: columnCustomization) { _, new in
            if let data = try? JSONEncoder().encode(new) {
                UserDefaults.standard.set(data, forKey: "fileListColumnCustomization")
            }
        }
        .onChange(of: sortOrder)              { _, _ in applySort() }
        .onChange(of: env.audioFiles.count)   { _, _ in applySort() }
        .onChange(of: vm.searchResults.count) { _, _ in applySort() }
        .onChange(of: vm.searchQuery)         { _, _ in applySort() }
        .onChange(of: selectedID) { _, newID in
            guard let id = newID else { selectedFile = nil; return }
            selectedFile = env.audioFiles.first { $0.id == id }
                        ?? vm.searchResults.first { $0.id == id }
        }
        .onChange(of: vm.searchQuery) { _, _ in
            Task { await vm.search(repo: env.searchRepository, folderFilter: env.folderFilter) }
        }
        .onChange(of: vm.searchScope) { _, _ in
            Task { await vm.search(repo: env.searchRepository, folderFilter: env.folderFilter) }
        }
        .onChange(of: env.folderFilter) { _, _ in
            vm.searchQuery = ""
            Task { await vm.search(repo: env.searchRepository, folderFilter: env.folderFilter) }
        }
        .onChange(of: env.activeProjectID) { _, _ in
            vm.searchQuery = ""
        }
        .background {
            Button("") {
                searchFocused = true
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .sheet(isPresented: $showChangesSheet) {
            FolderChangesSheet(isPresented: $showChangesSheet)
                .environment(env)
        }
    }

    // MARK: - Fixed columns (technical identity — always shown)

    @TableColumnBuilder<AudioFileRow, AudioFileSort>
    private var fixedColumns: some TableColumnContent<AudioFileRow, AudioFileSort> {
        TableColumn("Name", sortUsing: AudioFileSort(field: .name)) { row in
            Text(row.displayName).font(.system(size: 12)).lineLimit(1)
        }
        .customizationID("name")

        TableColumn("Dur", sortUsing: AudioFileSort(field: .duration)) { row in
            mono11(row.file.duration.map { formatDuration($0) } ?? "—")
        }
        .width(min: 40, ideal: 46).customizationID("duration")

        TableColumn("SR", sortUsing: AudioFileSort(field: .sampleRate)) { row in
            mono11(row.file.sampleRateLabel)
        }
        .width(min: 34, ideal: 44).customizationID("sampleRate")

        TableColumn("Bit", sortUsing: AudioFileSort(field: .bitDepth)) { row in
            mono11(row.file.bitDepthLabel)
        }
        .width(min: 26, ideal: 34).customizationID("bitDepth")

        TableColumn("Ch", sortUsing: AudioFileSort(field: .channels)) { row in
            label11(row.file.channelLabel)
        }
        .width(min: 44, ideal: 52).customizationID("channels")

        TableColumn("Format", sortUsing: AudioFileSort(field: .format)) { row in
            label11(row.file.format)
        }
        .width(min: 36, ideal: 44).customizationID("format")
    }

    // MARK: - Helpers

    private func mono11(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    private func label11(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s.rounded())
        let m     = total / 60
        let sec   = total % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Unified sort comparator
//
// One comparator type for the whole Table so fixed (technical) columns and
// dynamic profile (metadata) columns can share a single `sortOrder` binding.

struct AudioFileSort: SortComparator, Hashable {
    enum Field: Hashable {
        case name, duration, sampleRate, bitDepth, channels, format
        case bwf(BWFFieldKey)
    }

    var field: Field
    var order: SortOrder = .forward

    func compare(_ a: AudioFileRow, _ b: AudioFileRow) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .name:       result = str(a.displayName, b.displayName)
        case .format:     result = str(a.file.format, b.file.format)
        case .duration:   result = num(a.durationSort, b.durationSort)
        case .sampleRate: result = num(Double(a.sampleRateSort), Double(b.sampleRateSort))
        case .bitDepth:   result = num(Double(a.bitDepthSort), Double(b.bitDepthSort))
        case .channels:   result = num(Double(a.channelSort), Double(b.channelSort))
        case .bwf(let k): result = str(a.file.displayValue(for: k) ?? "", b.file.displayValue(for: k) ?? "")
        }
        switch order {
        case .forward:  return result
        case .reverse:
            switch result {
            case .orderedAscending:  return .orderedDescending
            case .orderedDescending: return .orderedAscending
            case .orderedSame:       return .orderedSame
            }
        }
    }

    private func str(_ a: String, _ b: String) -> ComparisonResult {
        a.localizedCaseInsensitiveCompare(b)
    }
    private func num(_ a: Double, _ b: Double) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

// MARK: - Folder changes sheet

private struct FolderChangesSheet: View {
    @Environment(AppEnvironment.self) var env
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("Folder Changes Detected")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            Text("The following folders have a different number of audio files on disk than in the library. Rescan to update.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Per-folder rows
            List(env.foldersWithChanges, id: \.self) { path in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 13))
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Rescan Folder") {
                        env.rescanFolder(path: path)
                        if env.foldersWithChanges.isEmpty { isPresented = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)

            Divider()

            // Footer
            HStack {
                Button("Continue without Rescanning") {
                    env.foldersWithChanges = []
                    isPresented = false
                }
                Spacer()
                Button("Rescan All") {
                    env.rescanChangedFolders()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 460, height: 320)
    }
}
