import SwiftUI
import AppKit

struct FileListView: View {
    @Environment(AppEnvironment.self) var env
    @StateObject private var vm = FileListViewModel()
    @Binding var selectedFile: AudioFile?
    var showHeader: Bool = true

    @State private var selectedID: Int64? = nil
    @State private var columnCustomization = TableColumnCustomization<AudioFileRow>()
    @State private var sortOrder: [KeyPathComparator<AudioFileRow>] = []
    @FocusState private var searchFocused: Bool
    @State private var showChangesSheet = false

    private var displayedRows: [AudioFileRow] {
        let files = vm.searchQuery.isEmpty ? env.audioFiles : vm.searchResults
        return files.map { AudioFileRow(file: $0) }
    }

    private var sortedRows: [AudioFileRow] {
        sortOrder.isEmpty ? displayedRows : displayedRows.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: AudioFileRow.self,
              selection: $selectedID,
              sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            columnsA
            columnsB
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
                    let capped = env.totalAudioFileCount > AppEnvironment.browseLimit
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

    // MARK: - Column group A  (name, description, duration, SR, bit, ch, format)

    @TableColumnBuilder<AudioFileRow, KeyPathComparator<AudioFileRow>>
    private var columnsA: some TableColumnContent<AudioFileRow, KeyPathComparator<AudioFileRow>> {
        TableColumn("Name", value: \.displayName) { row in
            Text(row.displayName).font(.system(size: 12)).lineLimit(1)
        }
        .customizationID("name")

        TableColumn("Description", value: \.file.bwfDescription) { row in
            Text(row.file.bwfDescription)
                .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
        }
        .customizationID("description")

        TableColumn("Dur", value: \.durationSort) { row in
            mono11(row.file.duration.map { formatDuration($0) } ?? "—")
        }
        .width(min: 40, ideal: 46).customizationID("duration")

        TableColumn("SR", value: \.sampleRateSort) { row in
            mono11(row.file.sampleRateLabel)
        }
        .width(min: 34, ideal: 44).customizationID("sampleRate")

        TableColumn("Bit", value: \.bitDepthSort) { row in
            mono11(row.file.bitDepthLabel)
        }
        .width(min: 26, ideal: 34).customizationID("bitDepth")

        TableColumn("Ch", value: \.channelSort) { row in
            label11(row.file.channelLabel)
        }
        .width(min: 44, ideal: 52).customizationID("channels")

        TableColumn("Format", value: \.file.format) { row in
            label11(row.file.format)
        }
        .width(min: 36, ideal: 44).customizationID("format")
    }

    // MARK: - Column group B  (date, tape, UCS cat, UCS sub, note, library)

    @TableColumnBuilder<AudioFileRow, KeyPathComparator<AudioFileRow>>
    private var columnsB: some TableColumnContent<AudioFileRow, KeyPathComparator<AudioFileRow>> {
        TableColumn("Date", value: \.file.originationDate) { row in
            mono11(row.file.originationDate.isEmpty ? "—" : row.file.originationDate)
        }
        .width(min: 68, ideal: 82).customizationID("originationDate")

        TableColumn("Tape", value: \.file.tapeName) { row in
            label11(row.file.tapeName.isEmpty ? "—" : row.file.tapeName)
        }
        .width(min: 40, ideal: 70).customizationID("tapeName")

        TableColumn("UCS Cat", value: \.file.ucsCategory) { row in
            label11(row.file.ucsCategory.isEmpty ? "—" : row.file.ucsCategory)
        }
        .width(min: 50, ideal: 90).customizationID("ucsCategory")

        TableColumn("UCS Sub", value: \.file.ucsSubCategory) { row in
            label11(row.file.ucsSubCategory.isEmpty ? "—" : row.file.ucsSubCategory)
        }
        .width(min: 50, ideal: 90).customizationID("ucsSubCategory")

        TableColumn("Note", value: \.file.ixmlNote) { row in
            label11(row.file.ixmlNote.isEmpty ? "—" : row.file.ixmlNote)
        }
        .width(min: 40, ideal: 80).customizationID("ixmlNote")

        TableColumn("Library", value: \.libraryName) { row in
            label11(row.libraryName)
        }
        .width(min: 60, ideal: 90).customizationID("library")

        TableColumn("Filename", value: \.file.filename) { row in
            Text(row.file.filename)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .customizationID("filename")
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
