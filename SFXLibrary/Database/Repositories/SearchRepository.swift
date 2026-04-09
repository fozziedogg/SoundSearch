import Foundation
import GRDB

/// Handles all search and filter queries against the database.
final class SearchRepository {
    private let db: DatabasePool

    init(db: DatabasePool) {
        self.db = db
    }

    /// Full-text search, optionally scoped to a single column.
    /// FTS5 column filter syntax: `colname:term*` restricts matches to that column.
    func search(query: String,
                scope: SearchScope = .all,
                format: String? = nil,
                minStars: Int = 0,
                limit: Int = 200,
                offset: Int = 0) throws -> [AudioFile] {
        try db.read { db in
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                var request = AudioFile.order(AudioFile.Columns.filename)
                if minStars > 0 {
                    request = request.filter(AudioFile.Columns.starRating >= minStars)
                }
                return try request.limit(limit, offset: offset).fetchAll(db)
            }

            let ftsQuery = buildFTSQuery(query: query, scope: scope)
            let starFilter = minStars > 0 ? "AND audio_files.star_rating >= \(minStars)" : ""

            let sql = """
                SELECT audio_files.*
                FROM audio_files
                JOIN audio_files_fts ON audio_files_fts.rowid = audio_files.id
                WHERE audio_files_fts MATCH ?
                \(starFilter)
                ORDER BY rank
                LIMIT \(limit) OFFSET \(offset)
            """
            return try AudioFile.fetchAll(db, sql: sql, arguments: [ftsQuery])
        }
    }

    /// Count total results for a given query (used for pagination display).
    func count(query: String, scope: SearchScope = .all) throws -> Int {
        try db.read { db in
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                return try AudioFile.fetchCount(db)
            }
            let ftsQuery = buildFTSQuery(query: query, scope: scope)
            let sql = """
                SELECT COUNT(*) FROM audio_files
                JOIN audio_files_fts ON audio_files_fts.rowid = audio_files.id
                WHERE audio_files_fts MATCH ?
            """
            return try Int.fetchOne(db, sql: sql, arguments: [ftsQuery]) ?? 0
        }
    }

    // MARK: - FTS5 query builder

    /// Builds an FTS5 MATCH expression.
    /// All fields:    `gun* shot*`
    /// Single column: `filename:gun* filename:shot*`
    private func buildFTSQuery(query: String, scope: SearchScope) -> String {
        let terms = query
            .split(separator: " ")
            .filter { !$0.isEmpty }

        if let col = scope.ftsColumn {
            // Prefix each term with the column name
            return terms.map { "\(col):\($0)*" }.joined(separator: " ")
        } else {
            return terms.map { "\($0)*" }.joined(separator: " ")
        }
    }
}
