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

    /// Reactively updated list of audio files (capped at browseLimit for UI safety).
    var audioFiles: [AudioFile] = []

    /// Total number of audio files in the database (may exceed audioFiles.count).
    var totalAudioFileCount: Int = 0

    /// Maximum rows loaded into the browse list. Search results are separate and always <= 200.
    static let browseLimit = 1_000

    /// When set, the browse list and search are limited to files under this path prefix.
    var folderFilter: String? = nil {
        didSet {
            guard folderFilter != oldValue else { return }
            // Debounce: let GRDB finish any in-flight read before restarting
            // the observation, and coalesce rapid sidebar clicks into one reload.
            filterTask?.cancel()
            filterTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self else { return }
                self.startFilesObservation(db: self.db)
            }
        }
    }

    /// Reactively updated list of watched folders.
    var watchedFolders: [WatchedFolder] = []

    /// URL of the currently open database file.
    var currentDatabaseURL: URL = DatabasePool.databaseURL

    /// True while one or more folder scans are in progress.
    var isScanning: Bool = false
    /// Filename most recently processed by the scanner (updates every 25 files).
    var currentScanFile: String = ""
    /// Running count of audio files processed by the scanner this session.
    var scannedFileCount: Int = 0
    private var activeScanCount: Int = 0

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

    var waveformColor: Color = {
        let r = UserDefaults.standard.object(forKey: "wfColorR") as? Double
        let g = UserDefaults.standard.object(forKey: "wfColorG") as? Double
        let b = UserDefaults.standard.object(forKey: "wfColorB") as? Double
        if let r, let g, let b { return Color(red: r, green: g, blue: b) }
        return Color.accentColor
    }() {
        didSet {
            if let c = NSColor(waveformColor).usingColorSpace(.sRGB) {
                UserDefaults.standard.set(Double(c.redComponent),   forKey: "wfColorR")
                UserDefaults.standard.set(Double(c.greenComponent), forKey: "wfColorG")
                UserDefaults.standard.set(Double(c.blueComponent),  forKey: "wfColorB")
            }
        }
    }

    /// Increments on every database switch — used as a SwiftUI `.id` to force full UI rebuild.
    var databaseEpoch: Int = 0

    @ObservationIgnored private var db: DatabasePool
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var foldersObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var observationGeneration: Int = 0

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

    /// Renames the current database file in-place (same directory, new filename).
    func renameDatabase(to newName: String) {
        guard !isScanning else {
            print("[AppEnv] renameDatabase: ignored — scan in progress")
            return
        }
        let safeName = newName.hasSuffix(".sqlite") ? newName : newName + ".sqlite"
        let dir    = currentDatabaseURL.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent(safeName)
        guard newURL.path != currentDatabaseURL.path else { return }

        let oldURL = currentDatabaseURL

        // Fold WAL back into the main file so only one file needs renaming.
        try? db.write { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }

        // Stop observations and watchers so nothing holds GRDB write locks.
        browseTask?.cancel()
        browseTask         = nil
        foldersObservation = nil

        // Release every strong reference to the original pool before touching files.
        // self.db, libraryService, and searchRepository all hold the pool — all three
        // must be replaced or the WAL shared-memory file stays locked and the rename
        // races with an open connection, causing a disk I/O error on reopen.
        let tempURL = dir.appendingPathComponent(".sfxlib_rename_\(UUID().uuidString).sqlite")
        if let tempPool = try? DatabasePool(path: tempURL.path) {
            self.db             = tempPool
            self.libraryService   = LibraryService(db: tempPool)
            self.searchRepository = SearchRepository(db: tempPool)
        }

        // Rename the real files now that no pool holds them open.
        for suffix in ["", "-wal", "-shm"] {
            let old = oldURL.path + suffix
            let new = newURL.path + suffix
            if FileManager.default.fileExists(atPath: old) {
                try? FileManager.default.moveItem(atPath: old, toPath: new)
            }
        }

        // Open the renamed database (releases the temp pool) and restart everything.
        switchToDatabase(at: newURL)

        // Temp pool is now closed — clean up its files.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempURL.path + suffix)
        }
    }

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

    /// Shows a save panel and creates a fresh blank database at the chosen location.
    func newDatabase() {
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "sqlite")!]
            panel.nameFieldStringValue = "library.sqlite"
            panel.title = "Create New Database"
            panel.message = "Choose a location and name for the new library database."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let dest = url.pathExtension.lowercased() == "sqlite" ? url : url.appendingPathExtension("sqlite")
            self.switchToDatabase(at: dest)
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
        guard !isScanning else {
            print("[AppEnv] deleteDatabase: ignored — scan in progress")
            return
        }
        let urlToDelete = currentDatabaseURL

        // Checkpoint WAL so SQLite is in a clean state before we unlink the files.
        try? db.write { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }

        // Stop observations and watchers before touching the pool.
        browseTask?.cancel()
        browseTask         = nil
        foldersObservation = nil

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
        filterTask?.cancel()
        filterTask = nil
        folderFilter = nil      // clear stale filter; didSet may create a new filterTask
        filterTask?.cancel()    // cancel any task just created by the folderFilter reset
        filterTask = nil
        browseTask?.cancel()
        browseTask         = nil
        foldersObservation = nil
        observationGeneration += 1
        databaseEpoch += 1

        // Update URL and persist immediately — title bar and menu reflect the new
        // name regardless of whether the pool setup below succeeds.
        self.currentDatabaseURL = url
        if persist {
            UserDefaults.standard.set(url.path, forKey: AppEnvironment.lastDBPathKey)
        }

        guard let newDB = try? DatabasePool.setup(at: url) else {
            print("[AppEnv] switchToDatabase: failed to open \(url.lastPathComponent)")
            return
        }
        self.db             = newDB
        let ls              = LibraryService(db: newDB)
        self.libraryService = ls
        let scanner         = FolderScanner(libraryService: ls)
        self.folderScanner  = scanner
        self.searchRepository = SearchRepository(db: newDB)

        audioFiles     = []
        watchedFolders = []

        startObservations(db: newDB, ls: ls, scanner: scanner)
    }

    // MARK: - Private

    private func startObservations(db: DatabasePool, ls: LibraryService, scanner: FolderScanner) {
        startFilesObservation(db: db)

        let gen = observationGeneration
        let foldersObs = ValueObservation.tracking { db in
            try WatchedFolder.fetchAll(db)
        }
        foldersObservation = foldersObs.start(
            in: db,
            scheduling: .async(onQueue: .main),
            onError: { error in print("[AppEnv] folders observation error: \(error)") },
            onChange: { [weak self] folders in
                guard let self, self.observationGeneration == gen else { return }
                self.watchedFolders = folders
            }
        )

        // Point the scanner's error log at the current database directory.
        scanner.logFileURL = currentDatabaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("scan_errors.txt")

        // Wire scan progress callbacks before starting watchers.
        // Pause the files observation while scanning so 50k individual upserts
        // don't each trigger a full table re-fetch (O(n²) rebuilds).
        // One reload fires when all scans finish.
        scanner.onScanStarted = { [weak self] _ in
            guard let self else { return }
            if self.activeScanCount == 0 {
                self.browseTask?.cancel()     // pause — avoids O(n²) table rebuilds
                self.browseTask = nil
                self.currentScanFile  = ""
                self.scannedFileCount = 0
            }
            self.activeScanCount += 1
            self.isScanning = true
        }
        scanner.onScanFinished = { [weak self] _ in
            guard let self else { return }
            self.activeScanCount = max(0, self.activeScanCount - 1)
            if self.activeScanCount == 0 {
                self.isScanning = false
                self.currentScanFile = ""
                self.startFilesObservation(db: self.db)   // one reload, then resume watching
            }
        }
        scanner.onScanProgress = { [weak self] filename, count in
            self?.currentScanFile  = filename
            self?.scannedFileCount = count
        }

        // No auto-scan on open — use Rescan to pick up changes manually.
    }

    /// Fetches the browse list in the background and delivers results to the main actor.
    /// Replaces any in-flight fetch. Capped at browseLimit rows.
    /// Filtered to folderFilter path prefix when set.
    private func startFilesObservation(db: DatabasePool) {
        browseTask?.cancel()

        let gen    = observationGeneration
        let limit  = AppEnvironment.browseLimit
        let filter = folderFilter

        let whereClause = filter != nil ? "WHERE file_url LIKE ?" : ""
        let fileArgs: StatementArguments = filter != nil ? ["\(filter!)/%"] : []

        let sql = """
            SELECT id, file_url, bookmark_data, filename, file_size, mtime, format,
                   duration, sample_rate, bit_depth, channels, lufs,
                   bwf_description, bwf_originator, bwf_scene, bwf_take,
                   bwf_time_ref_low, bwf_time_ref_high, origination_date,
                   tape_name, ixml_note, ucs_category, ucs_sub_category,
                   NULL as ixml_raw,
                   notes, star_rating,
                   NULL as waveform_peaks,
                   date_added, last_modified
            FROM audio_files \(whereClause) ORDER BY filename
            LIMIT \(limit)
            """

        let countSQL = filter != nil
            ? "SELECT COUNT(*) FROM audio_files WHERE file_url LIKE ?"
            : "SELECT COUNT(*) FROM audio_files"
        let countArgs: StatementArguments = filter != nil ? ["\(filter!)/%"] : []

        browseTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let files = (try? await db.read { db in
                try AudioFile.fetchAll(db, sql: sql, arguments: fileArgs)
            }) ?? []
            let count = (try? await db.read { db in
                try Int.fetchOne(db, sql: countSQL, arguments: countArgs) ?? 0
            }) ?? 0
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.observationGeneration == gen else { return }
                self.audioFiles          = files
                self.totalAudioFileCount = count
            }
        }
    }
}
