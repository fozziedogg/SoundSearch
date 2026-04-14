import Foundation
import Combine

enum SearchScope: String, CaseIterable, Identifiable {
    case all           = "All"
    case name          = "Name"
    case description   = "Description"
    case ucsCategory   = "UCS Cat"
    case ucsSubCategory = "UCS Sub"
    case tape          = "Tape"
    case note          = "Note"

    var id: String { rawValue }

    /// FTS5 column name(s) for a scoped query, nil means search all columns.
    var ftsColumn: String? {
        switch self {
        case .all:           return nil
        case .name:          return "filename"
        case .description:   return "bwf_description"
        case .ucsCategory:   return "ucs_category"
        case .ucsSubCategory: return "ucs_sub_category"
        case .tape:          return "tape_name"
        case .note:          return "ixml_note"
        }
    }
}

@MainActor
final class FileListViewModel: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var searchScope: SearchScope = .all
    @Published var searchResults: [AudioFile] = []
    @Published var isSearching: Bool = false

    private var debounceTask: Task<Void, Never>?

    func search(repo: SearchRepository, folderFilter: String? = nil) async {
        debounceTask?.cancel()
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isSearching = true
            searchResults = (try? await repo.search(query: searchQuery,
                                                    scope: searchScope,
                                                    folderFilter: folderFilter,
                                                    limit: 200, offset: 0)) ?? []
            isSearching = false
        }
    }
}
