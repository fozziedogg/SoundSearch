import Foundation
import Combine

/// Search scope: All, filename (Name), or a specific metadata field. The field
/// cases are driven by the active metadata profile (see `available(for:)`).
enum SearchScope: Hashable, Identifiable {
    case all
    case name
    case field(BWFFieldKey)

    var id: String {
        switch self {
        case .all:            return "__all__"
        case .name:           return "__name__"
        case .field(let key): return key.rawValue
        }
    }

    var label: String {
        switch self {
        case .all:            return "All"
        case .name:           return "Name"
        case .field(let key): return key.label
        }
    }

    /// FTS5 column for a fast scoped match. nil for `.all` (match all columns)
    /// or for fields that aren't FTS-indexed (those use `likeColumn` instead).
    var ftsColumn: String? {
        switch self {
        case .all:            return nil
        case .name:           return "filename"
        case .field(let key): return key.isFTSColumn ? key.searchColumn : nil
        }
    }

    /// Column for a LIKE fallback when the field isn't in the FTS index.
    var likeColumn: String? {
        switch self {
        case .all, .name:     return nil
        case .field(let key): return key.isFTSColumn ? nil : key.searchColumn
        }
    }

    /// Scopes offered for a profile: All, Name, then the profile's searchable fields.
    static func available(for profile: MetadataProfile) -> [SearchScope] {
        [.all, .name] + profile.fields
            .filter { $0.searchColumn != nil }
            .map { SearchScope.field($0) }
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
