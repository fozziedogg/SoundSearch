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
                folderFilter: String? = nil,
                format: String? = nil,
                minStars: Int = 0,
                limit: Int = 200,
                offset: Int = 0) async throws -> [AudioFile] {
        try await db.read { db in
            let folderClause = folderFilter != nil ? "AND audio_files.file_url LIKE ?" : ""
            let folderArg: String? = folderFilter.map { "\($0)/%" }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                let sql = """
                    SELECT * FROM audio_files
                    WHERE 1=1
                    \(folderClause)
                    \(minStars > 0 ? "AND star_rating >= \(minStars)" : "")
                    ORDER BY filename
                    LIMIT \(limit) OFFSET \(offset)
                """
                var args: StatementArguments = []
                if let fa = folderArg { args += [fa] }
                return try AudioFile.fetchAll(db, sql: sql, arguments: args)
            }

            let ftsQuery = buildFTSQuery(query: query, scope: scope)
            let starClause = minStars > 0 ? "AND audio_files.star_rating >= \(minStars)" : ""
            let sql = """
                SELECT audio_files.*
                FROM audio_files
                JOIN audio_files_fts ON audio_files_fts.rowid = audio_files.id
                WHERE audio_files_fts MATCH ?
                \(folderClause)
                \(starClause)
                ORDER BY rank
                LIMIT \(limit) OFFSET \(offset)
            """
            var args: StatementArguments = [ftsQuery]
            if let fa = folderArg { args += [fa] }
            return try AudioFile.fetchAll(db, sql: sql, arguments: args)
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
    ///
    /// Implicit multi-word (no boolean keywords):
    ///   "room tone"  →  `(room* AND tone*) OR roomtone*`
    ///   Matches files containing both words separately *or* the compound "roomtone".
    ///
    /// Explicit boolean (AND / OR / NOT detected):
    ///   "gun OR shot"       →  `gun* OR shot*`
    ///   "gun AND NOT shot"  →  `gun* AND NOT shot*`
    ///
    /// Column-scoped queries apply the FTS5 column prefix to every term.
    private func buildFTSQuery(query: String, scope: SearchScope) -> String {
        let rawTokens = query
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }
        guard !rawTokens.isEmpty else { return "" }

        let boolOps: Set<String> = ["AND", "OR", "NOT"]
        let hasBooleanOps = rawTokens.contains { boolOps.contains($0.uppercased()) }

        if hasBooleanOps {
            // Pass boolean structure through; just wildcard the non-operator terms.
            return rawTokens.map { token in
                let upper = token.uppercased()
                if boolOps.contains(upper) { return upper }
                return ftsTerm(token, scope: scope)
            }.joined(separator: " ")
        } else {
            // Implicit AND, plus a concatenated-word OR alternative.
            if rawTokens.count == 1 {
                return ftsTerm(rawTokens[0], scope: scope)
            }
            let andClause = rawTokens.map { ftsTerm($0, scope: scope) }.joined(separator: " AND ")
            let compound  = ftsTerm(rawTokens.joined(), scope: scope)
            return "(\(andClause)) OR \(compound)"
        }
    }

    /// Returns a single FTS5 term with prefix wildcard, optionally column-scoped.
    /// Sanitises to characters safe in an unquoted FTS5 token.
    private func ftsTerm(_ raw: String, scope: SearchScope) -> String {
        let safe = raw.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !safe.isEmpty else { return "" }
        if let col = scope.ftsColumn {
            return "\(col):\(safe)*"
        }
        return "\(safe)*"
    }
}
