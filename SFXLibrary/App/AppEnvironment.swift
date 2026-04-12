import SwiftUI
import AppKit
import GRDB
import Observation
import UniformTypeIdentifiers

/// Root object that wires all services together and is injected into the SwiftUI environment.
@Observable
final class AppEnvironment {
    var libraryService: LibraryService
    var folderScanner: FolderScanner
    let audioPlayer: AudioPlayer
    var searchRepository: SearchRepository
    let ptslClient = PTSLClient.shared

    /// Reactively updated list of all audio files, sorted by filename.
    var audioFiles: [AudioFile] = []

    /// Reactively updated list of watched folders.
    var watchedFolders: [WatchedFolder] = []

    /// URL of the currently open database file.
    var currentDatabaseURL: URL = DatabasePool.databaseURL

    // MARK: - Playback preferences (persisted)

    var autoPlayOnSelect: Bool = UserDefaults.standard.bool(forKey: "autoPlayOnSelect") {
        didSet { UserDefaults.standard.set(autoPlayOnSelect, forKey: "autoPlayOnSelect") }
    }
    var playOnWaveformClick: Bool = UserDefaults.standard.bool(forKey: "playOnWaveformClick") {
        didSet { UserDefaults.standard.set(playOnWaveformClick, forKey: "playOnWaveformClick") }
    }

    var dragExportMode: DragExportMode = DragExportMode(rawValue: UserDefaults.standard.integer(forKey: "dragExportMode")) ?? .selectionOnly {
        didSet { UserDefaults.standard.set(dragExportMode.rawValue, forKey: "dragExportMode") }
    }

    @ObservationIgnored private var db: DatabasePool
    @ObservationIgnored private var filesObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var foldersObservation: AnyDatabaseCancellable?

    private static let lastDBPathKey = "lastDatabasePath"

    init() {
        // Restore the last-used database path (fall back to default if missing/gone).
        let restoredURL: URL = {
            if let path = UserDefaults.standard.string(forKey: AppEnvironment.lastDBPathKey) {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return DatabasePool.databaseURL
        }()

        let db = try! DatabasePool.setup(at: restoredURL)
        self.db = db
        self.currentDatabaseURL = restoredURL
        self.searchRepository = SearchRepository(db: db)
        let ls = LibraryService(db: db)
        self.libraryService = ls
        let scanner = FolderScanner(libraryService: ls)
        self.folderScanner  = scanner
        self.audioPlayer    = AudioPlayer()

        startObservations(db: db, ls: ls, scanner: scanner)
    }

    // MARK: - Library Management

    /// Opens a folder picker and adds the chosen folder as a watched folder.
    func addWatchedFolder() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles          = false
            panel.canChooseDirectories    = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose a folder to scan for audio files"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? self.libraryService.addWatchedFolder(url: url, scanner: self.folderScanner)
        }
    }

    // MARK: - Database Management

    /// Exports the current database to a user-chosen location.
    func saveDatabase() {
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "sqlite")!]
            panel.nameFieldStringValue = "library_backup.sqlite"
            panel.title = "Save Database Backup"
            panel.message = "Choose where to save a copy of the current library database."
            guard panel.runModal() == .OK, let dest = panel.url else { return }

            // Checkpoint WAL so the main file is fully up to date before copying.
            try? self.db.write { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: self.currentDatabaseURL, to: dest)
            } catch {
                print("[AppEnv] saveDatabase error: \(error)")
            }
        }
    }

    /// Opens an existing `.sqlite` database chosen by the user and switches to it.
    func openDatabase() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles          = true
            panel.canChooseDirectories    = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes     = [.init(filenameExtension: "sqlite")!]
            panel.title   = "Open Database"
            panel.message = "Choose an SFXLibrary database file to open."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self.switchToDatabase(at: url)
        }
    }

    /// Tears down the current database, deletes it from disk, and starts fresh at the default path.
    func deleteDatabase() {
        let urlToDelete = currentDatabaseURL

        // Checkpoint WAL so SQLite is in a clean state before we unlink the files.
        try? db.write { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }

        // Stop observations and watchers before touching the pool.
        filesObservation  = nil
        foldersObservation = nil
        folderScanner.stopAll()

        // Delete the old files (the open pool still holds its fd — safe on Unix).
        let base = urlToDelete.path
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }

        // Switch to a fresh default database (creates new files, replaces pool).
        switchToDatabase(at: DatabasePool.databaseURL, persist: true)
    }

    /// Tears down the current setup and opens a database at `url`, running migrations.
    /// Persists the choice to UserDefaults so it's restored on next launch.
    func switchToDatabase(at url: URL, persist: Bool = true) {
        filesObservation  = nil
        foldersObservation = nil
        folderScanner.stopAll()

        let newDB = try! DatabasePool.setup(at: url)
        self.db               = newDB
        self.currentDatabaseURL = url
        let ls = LibraryService(db: newDB)
        self.libraryService   = ls
        let scanner = FolderScanner(libraryService: ls)
        self.folderScanner    = scanner
        self.searchRepository = SearchRepository(db: newDB)

        audioFiles    = []
        watchedFolders = []

        if persist {
            UserDefaults.standard.set(url.path, forKey: AppEnvironment.lastDBPathKey)
        }

        startObservations(db: newDB, ls: ls, scanner: scanner)
    }

    // MARK: - Private

    private func startObservations(db: DatabasePool, ls: LibraryService, scanner: FolderScanner) {
        let filesObs = ValueObservation.tracking { db in
            try AudioFile.order(AudioFile.Columns.filename).fetchAll(db)
        }
        filesObservation = filesObs.start(
            in: db,
            scheduling: .async(onQueue: .main),
            onError: { error in print("[AppEnv] files observation error: \(error)") },
            onChange: { [weak self] files in self?.audioFiles = files }
        )

        let foldersObs = ValueObservation.tracking { db in
            try WatchedFolder.fetchAll(db)
        }
        foldersObservation = foldersObs.start(
            in: db,
            scheduling: .async(onQueue: .main),
            onError: { error in print("[AppEnv] folders observation error: \(error)") },
            onChange: { [weak self] folders in self?.watchedFolders = folders }
        )

        // Resume watching any folders that were added in a previous session
        let existing = (try? ls.fetchWatchedFolders()) ?? []
        for folder in existing {
            scanner.startWatching(path: folder.path)
        }
    }
}
