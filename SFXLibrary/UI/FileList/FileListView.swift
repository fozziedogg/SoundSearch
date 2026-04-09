import SwiftUI

struct FileListView: View {
    @Environment(AppEnvironment.self) var env
    @StateObject private var vm = FileListViewModel()
    @Binding var selectedFile: AudioFile?

    @State private var selectedID: Int64? = nil
    @State private var columnCustomization = TableColumnCustomization<AudioFileRow>()
    @State private var sortOrder: [KeyPathComparator<AudioFileRow>] = []

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
            ForEach(sortedRows) { TableRow($0) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchBar(text: $vm.searchQuery, scope: $vm.searchScope)
                .padding(8)
                .background(.bar)
        }
        .overlay {
            if sortedRows.isEmpty {
                Text(vm.searchQuery.isEmpty ? "Add a folder to get started" : "No results")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Library")
        .onChange(of: selectedID) { _, newID in
            selectedFile = newID.flatMap { id in env.audioFiles.first { $0.id == id } }
        }
        .onChange(of: vm.searchQuery) { _, _ in
            Task { await vm.search(repo: env.searchRepository) }
        }
        .onChange(of: vm.searchScope) { _, _ in
            Task { await vm.search(repo: env.searchRepository) }
        }
    }

    // MARK: - Column group A  (name, description, duration, SR, bit, ch, format)

    @TableColumnBuilder<AudioFileRow, KeyPathComparator<AudioFileRow>>
    private var columnsA: some TableColumnContent<AudioFileRow, KeyPathComparator<AudioFileRow>> {
        TableColumn("Name", value: \.file.displayName) { row in
            Text(row.file.displayName).font(.system(size: 12)).lineLimit(1)
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

        TableColumn("Library", value: \.file.libraryName) { row in
            label11(row.file.libraryName)
        }
        .width(min: 60, ideal: 90).customizationID("library")
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
