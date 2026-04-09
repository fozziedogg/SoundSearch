import SwiftUI
import GRDB
import Observation

/// Root object that wires all services together and is injected into the SwiftUI environment.
@Observable
final class AppEnvironment {
    let libraryService: LibraryService
    let folderScanner: FolderScanner
    let audioPlayer: AudioPlayer
    let searchRepository: SearchRepository
    let ptslClient = PTSLClient.shared

    /// Reactively updated list of all audio files, sorted by filename.
    var audioFiles: [AudioFile] = []

    /// Reactively updated list of watched folders.
    var watchedFolders: [WatchedFolder] = []

    @ObservationIgnored private let db: DatabasePool
    @ObservationIgnored private var filesObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var foldersObservation: AnyDatabaseCancellable?

    init() {
        let db = try! DatabasePool.setupShared()
        self.db = db
        self.searchRepository = SearchRepository(db: db)
        let ls = LibraryService(db: db)
        self.libraryService = ls
        let scanner = FolderScanner(libraryService: ls)
        self.folderScanner  = scanner
        self.audioPlayer    = AudioPlayer()

        // Observe audio_files table
        let filesObs = ValueObservation.tracking { db in
            try AudioFile.order(AudioFile.Columns.filename).fetchAll(db)
        }
        filesObservation = filesObs.start(
            in: db,
            scheduling: .async(onQueue: .main),
            onError: { error in print("[AppEnv] files observation error: \(error)") },
            onChange: { [weak self] files in self?.audioFiles = files }
        )

        // Observe watched_folders table
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
