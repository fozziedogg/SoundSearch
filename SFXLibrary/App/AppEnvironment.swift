import SwiftUI
import AppKit
import GRDB
import Observation
import UniformTypeIdentifiers

enum SpotFeedback {
    case success
    case failure(String)
}

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

    var metadataEditingEnabled: Bool = UserDefaults.standard.bool(forKey: "metadataEditingEnabled") {
        didSet { UserDefaults.standard.set(metadataEditingEnabled, forKey: "metadataEditingEnabled") }
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

    /// Paths of watched folders where the disk file count differs from the DB count.
    var foldersWithChanges: [String] = []

    // MARK: - Projects (global, stored in Application Support/SoundSearch)

    var projects: [Project] = []

    /// The currently active project. Mutually exclusive with folderFilter.
    var activeProjectID: Int64? = nil {
        didSet {
            guard activeProjectID != oldValue else { return }
            projectTask?.cancel()
            if let id = activeProjectID {
                let pDB = projectsDB
                let gen = observationGeneration
                projectTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let urls = (try? await pDB.read { db in
                        try String.fetchAll(db,
                            sql: "SELECT file_url FROM project_files WHERE project_id = ? ORDER BY date_added",
                            arguments: [id])
                    }) ?? []
                    guard !Task.isCancelled, self.observationGeneration == gen else { return }
                    self.activeProjectFileURLs = urls
                    self.startFilesObservation(db: self.db)
                }
            } else {
                activeProjectFileURLs = []
                startFilesObservation(db: db)
            }
        }
    }

    /// The last project the user explicitly selected — used as the add target even when
    /// browsing All Files or a folder (persists until the project is deleted or a
    /// different project is selected). Persisted across launches.
    var trackedProjectID: Int64? = nil {
        didSet {
            if let id = trackedProjectID {
                UserDefaults.standard.set(Int(id), forKey: "trackedProjectID")
            } else {
                UserDefaults.standard.removeObject(forKey: "trackedProjectID")
            }
        }
    }

    /// Drives the sidebar List selection. Stored here so launch code can restore it
    /// before the first render.
    var sidebarSelection: SidebarItem? = .allFiles

    /// When true, files dragged to PT or sent via PTSL are added to the active project.
    var autoAddToProject: Bool = {
        guard UserDefaults.standard.object(forKey: "autoAddToProject") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "autoAddToProject")
    }() {
        didSet { UserDefaults.standard.set(autoAddToProject, forKey: "autoAddToProject") }
    }

    /// Seconds of extra audio included before and after content when spotting via PTSL (PT 2025.06+).
    var spotHandles: Double = {
        let v = UserDefaults.standard.double(forKey: "spotHandles")
        return v > 0 ? v : 0.5
    }() {
        didSet { UserDefaults.standard.set(spotHandles, forKey: "spotHandles") }
    }

    /// When true, the volume slider resets to 100% when loading a new file.
    var resetVolumeOnLoad: Bool = {
        return UserDefaults.standard.bool(forKey: "resetVolumeOnLoad")   // default false
    }() {
        didSet { UserDefaults.standard.set(resetVolumeOnLoad, forKey: "resetVolumeOnLoad") }
    }

    var stopOnDefocus: Bool = {
        guard UserDefaults.standard.object(forKey: "stopOnDefocus") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "stopOnDefocus")
    }() {
        didSet { UserDefaults.standard.set(stopOnDefocus, forKey: "stopOnDefocus") }
    }

    /// Uses a blue/orange palette instead of green/red — safe for red-green colour blindness.
    var grahamRogersMode: Bool = {
        return UserDefaults.standard.bool(forKey: "grahamRogersMode")   // default false
    }() {
        didSet { UserDefaults.standard.set(grahamRogersMode, forKey: "grahamRogersMode") }
    }

    /// Transient spot result shown in the player controls row. Cleared on new file selection.
    var spotFeedback: SpotFeedback? = nil

    /// When true, Pro Tools is brought to the foreground after a successful Spot to PT.
    var focusProToolsOnSpot: Bool = {
        guard UserDefaults.standard.object(forKey: "focusProToolsOnSpot") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "focusProToolsOnSpot")
    }() {
        didSet { UserDefaults.standard.set(focusProToolsOnSpot, forKey: "focusProToolsOnSpot") }
    }

    /// When true, the current preview volume is baked into audio delivered via drag or Spot to PT.
    var commitVolumeOnExport: Bool = {
        guard UserDefaults.standard.object(forKey: "commitVolumeOnExport") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "commitVolumeOnExport")
    }() {
        didSet { UserDefaults.standard.set(commitVolumeOnExport, forKey: "commitVolumeOnExport") }
    }

    @ObservationIgnored private var sessionRestored = false
    @ObservationIgnored private var db: DatabasePool
    @ObservationIgnored private var projectsDB: DatabasePool
    @ObservationIgnored private var projectRepository: ProjectRepository
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var foldersObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var projectsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var projectTask: Task<Void, Never>?
    @ObservationIgnored private var observationGeneration: Int = 0
    @ObservationIgnored private var launchCheckDone: Bool = false
    @ObservationIgnored private var activeProjectFileURLs: [String] = []

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

        let pDB = try! DatabasePool.setupProjectsDatabase()
        self.projectsDB         = pDB
        self.projectRepository  = ProjectRepository(db: pDB)

        startObservations(db: db, ls: ls, scanner: scanner)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.stopOnDefocus else { return }
            self.audioPlayer.stop()
        }
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
        foldersWithChanges = []
        launchCheckDone = false
        projectTask?.cancel()
        projectTask = nil
        activeProjectFileURLs = []
        activeProjectID = nil

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

    // MARK: - Project management

    @discardableResult
    func createProject(name: String) -> Project? {
        try? projectRepository.createProject(name: name)
    }

    func renameProject(_ id: Int64, to name: String) {
        try? projectRepository.renameProject(id, to: name)
    }

    func deleteProject(_ id: Int64) {
        try? projectRepository.deleteProject(id)
        if activeProjectID  == id { activeProjectID  = nil }
        if trackedProjectID == id { trackedProjectID = nil }
    }

    /// Adds `fileURL` to the tracked project if auto-add is enabled.
    /// Uses `trackedProjectID` so it works even when browsing All Files.
    func addToActiveProject(fileURL: String) {
        guard autoAddToProject, let projectId = trackedProjectID else { return }
        try? projectRepository.addFile(fileURL: fileURL, toProject: projectId)
        // If we're currently filtering by this project, update the live list too.
        if activeProjectID == projectId, !activeProjectFileURLs.contains(fileURL) {
            activeProjectFileURLs.append(fileURL)
            startFilesObservation(db: db)
        }
    }

    /// Adds a file to a specific project by ID (used for sidebar drag-and-drop).
    func addFile(_ fileURL: String, toProject projectId: Int64) {
        try? projectRepository.addFile(fileURL: fileURL, toProject: projectId)
        if activeProjectID == projectId, !activeProjectFileURLs.contains(fileURL) {
            activeProjectFileURLs.append(fileURL)
            startFilesObservation(db: db)
        }
    }

    /// Removes `fileURL` from the active project and refreshes the browse list.
    func removeFromActiveProject(fileURL: String) {
        guard let projectId = activeProjectID else { return }
        try? projectRepository.removeFile(fileURL: fileURL, fromProject: projectId)
        activeProjectFileURLs.removeAll { $0 == fileURL }
        startFilesObservation(db: db)
    }

    // MARK: - Folder change detection

    /// Rescans all folders that were flagged as changed.
    func rescanChangedFolders() {
        let paths = foldersWithChanges
        foldersWithChanges = []
        for path in paths { folderScanner.scan(path: path) }
    }

    /// Rescans a single folder and removes it from the changed list.
    func rescanFolder(path: String) {
        foldersWithChanges.removeAll { $0 == path }
        folderScanner.scan(path: path)
    }

    /// Counts audio files on disk per folder and compares to the count stored after
    /// the last scan. Folders that have never been scanned (scannedFileCount == nil)
    /// are skipped — no spurious warning on first launch.
    private func checkForFolderChanges(folders: [WatchedFolder]) {
        Task.detached(priority: .background) { [weak self] in
            var changed: [String] = []
            for folder in folders {
                guard let stored = folder.scannedFileCount else { continue }
                let diskCount = Self.countAudioFiles(in: folder.path)
                if diskCount != stored { changed.append(folder.path) }
            }
            if !changed.isEmpty {
                await MainActor.run { self?.foldersWithChanges = changed }
            }
        }
    }

    /// Fast recursive count of WAV/AIFF files — reads only filenames, no file content.
    private static func countAudioFiles(in path: String) -> Int {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "wav" || ext == "aif" || ext == "aiff" { count += 1 }
        }
        return count
    }

    // MARK: - Private

    private func startProjectsObservation() {
        let obs = ValueObservation.tracking { db in
            try Project.order(Column("sort_order"), Column("name")).fetchAll(db)
        }
        projectsObservation = obs.start(
            in: projectsDB,
            scheduling: .async(onQueue: .main),
            onError: { _ in },
            onChange: { [weak self] projects in
                self?.projects = projects
                self?.restoreOrCreateProjectIfNeeded(projects)
            }
        )
    }

    /// Called on first projects observation delivery. Restores the last active project
    /// from UserDefaults, or creates "NEW PROJECT" if no projects exist yet.
    private func restoreOrCreateProjectIfNeeded(_ projects: [Project]) {
        guard !sessionRestored else { return }
        sessionRestored = true

        if projects.isEmpty {
            if let created = createProject(name: "NEW PROJECT"), let id = created.id {
                trackedProjectID = id
                activeProjectID  = id
                sidebarSelection = .project(id)
            }
        } else {
            let storedID = Int64(UserDefaults.standard.integer(forKey: "trackedProjectID"))
            let target   = projects.first(where: { $0.id == storedID }) ?? projects.first
            if let proj = target, let id = proj.id {
                trackedProjectID = id
                activeProjectID  = id
                sidebarSelection = .project(id)
            }
        }
    }

    private func startObservations(db: DatabasePool, ls: LibraryService, scanner: FolderScanner) {
        startFilesObservation(db: db)
        startProjectsObservation()

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
                if !self.launchCheckDone && !folders.isEmpty {
                    self.launchCheckDone = true
                    self.checkForFolderChanges(folders: folders)
                }
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

    /// Builds the WHERE clause and arguments for the current browse filter state.
    /// Project filter takes priority over folder filter; they are mutually exclusive in practice.
    private func buildBrowseWhereClause() -> (String, StatementArguments) {
        if activeProjectID != nil {
            let urls = activeProjectFileURLs
            guard !urls.isEmpty else { return ("WHERE 1=0", []) }
            let placeholders = urls.map { _ in "?" }.joined(separator: ",")
            var args: StatementArguments = []
            urls.forEach { args += [$0] }
            return ("WHERE file_url IN (\(placeholders))", args)
        } else if let filter = folderFilter {
            return ("WHERE file_url LIKE ?", ["\(filter)/%"])
        }
        return ("", [])
    }

    /// Fetches the browse list in the background and delivers results to the main actor.
    /// Replaces any in-flight fetch. Capped at browseLimit rows.
    private func startFilesObservation(db: DatabasePool) {
        browseTask?.cancel()

        let gen   = observationGeneration
        let limit = AppEnvironment.browseLimit
        let (whereClause, queryArgs) = buildBrowseWhereClause()

        let sql = """
            SELECT id, file_url, bookmark_data, filename, file_size, mtime, format,
                   duration, sample_rate, bit_depth, channels, lufs,
                   bwf_description, bwf_originator, bwf_scene, bwf_take,
                   bwf_time_ref_low, bwf_time_ref_high, origination_date,
                   tape_name, ixml_note, ucs_category, ucs_sub_category,
                   notes, star_rating, date_added, last_modified
            FROM audio_files \(whereClause) ORDER BY filename
            LIMIT \(limit)
            """
        let countSQL = "SELECT COUNT(*) FROM audio_files \(whereClause)"

        browseTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let result = try? await db.read({ db -> ([AudioFile], Int) in
                let files = try AudioFile.fetchAll(db, sql: sql, arguments: queryArgs)
                let count = try Int.fetchOne(db, sql: countSQL, arguments: queryArgs) ?? 0
                return (files, count)
            }) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.observationGeneration == gen else { return }
                self.audioFiles          = result.0
                self.totalAudioFileCount = result.1
            }
        }
    }
}
