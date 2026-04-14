import Foundation
import GRDB

final class ProjectRepository {
    private let db: DatabasePool

    init(db: DatabasePool) { self.db = db }

    // MARK: - Project CRUD

    @discardableResult
    func createProject(name: String) throws -> Project {
        try db.write { db in
            let maxOrder = (try? Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM projects")) ?? 0
            var project = Project(id: nil, name: name, sortOrder: maxOrder + 1)
            try project.insert(db)
            return project
        }
    }

    func renameProject(_ id: Int64, to name: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    func deleteProject(_ id: Int64) throws {
        try db.write { db in try Project.deleteOne(db, key: id) }
    }

    // MARK: - File membership

    func addFile(fileURL: String, toProject projectId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO project_files (project_id, file_url, date_added) VALUES (?, ?, ?)",
                arguments: [projectId, fileURL, Date()])
        }
    }

    func removeFile(fileURL: String, fromProject projectId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM project_files WHERE project_id = ? AND file_url = ?",
                arguments: [projectId, fileURL])
        }
    }

    func fileURLs(forProject projectId: Int64) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(db,
                sql: "SELECT file_url FROM project_files WHERE project_id = ? ORDER BY date_added",
                arguments: [projectId])
        }
    }
}
