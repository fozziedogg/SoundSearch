# SoundSearch

Native macOS app for sound effects library management, built for Re-Recording Mixer / Sound Supervisor workflows.

**Stack:** Swift/SwiftUI + AppKit, GRDB.swift (SQLite + FTS5), AVFoundation, FSEvents

**Key features:** BWF/iXML metadata search & edit, live folder watching, waveform display + scrubbing, pitch shifting, drag-to-ProTools with timecode spotting (BEXT TimeReference)

**Architecture notes:**
- AppEnvironment must NOT be @MainActor — causes ObservableObject synthesis failure
- LibraryService and AudioPlayer must NOT be @MainActor classes — prevents instantiation from AppEnvironment.init()
- objectWillChange must be declared explicitly on AppEnvironment (synthesis unreliable here)
- AVAudioUnitTimePitch has no .algorithm property — spectral is the default, just set .pitch in cents
- kFSEventsCurrentEventId not available in Swift — use FSEventStreamEventId(UInt64.max)
- NSFilePromiseProvider init requires non-nil delegate — ProToolsDragProvider is a separate NSObject delegate that calls makePromiseProvider() to create the provider
- Data.loadLE/storeLE must use Swift.withUnsafeBytes(of:_:) explicitly to avoid ambiguity with Data.withUnsafeBytes

**File identity / portable databases:**
- `audio_files.file_url` is an absolute path and is the join key everywhere (mtime skip-cache, folder GLOB, projects DB), but it is *derived data*. The durable identity is `(volume_uuid, volume_relative_path)`; `VolumeResolver` regenerates file_url from it on every database open. Never treat file_url as stable across mounts.
- `volume_uuid` is prefixed: `uuid:<UUID>` for local disks, `name:<volume name>` for network shares, which usually report no UUID. Names have mount-collision suffixes stripped, so `/Volumes/SFX-1` and `/Volumes/SFX` are one volume.
- `VolumeIndex.currentMounts()` must NOT pass `.skipHiddenVolumes` — that drops `nobrowse` mounts, which is how many studio SMB/NFS automounts appear.
- Prefix matching on paths must use `substr()`, never `LIKE` — `_` and `%` are LIKE wildcards and library paths contain them (`/Volumes/SFX_01` would match `/Volumes/SFXX01`). Measure lengths with SQLite `length()`, not Swift `String.count`: macOS filenames are NFD, so one Swift grapheme can be several SQLite characters.
- Never resolve a `file_url` UNIQUE conflict with `UPDATE OR REPLACE`. SQLite fires delete triggers during REPLACE only when `recursive_triggers` is on (it isn't), so the FTS index keeps the deleted row forever. DELETE the loser explicitly first, then plain UPDATE.
- `INSERT INTO audio_files_fts(audio_files_fts) VALUES('rebuild')` cannot work: the FTS5 table is external-content and declares a `tags_denorm` column that `audio_files` lacks, so rebuild (and any unconstrained scan of the view) fails with `no such column: T.tags_denorm`. Count/inspect rows via `audio_files_fts_docsize` instead.
- Database open must never use `try!` — the path is persisted in UserDefaults, so a throw crash-loops the app with no in-app escape. `AppEnvironment.openDatabaseWithFallback` degrades through default → recovery file → temp, and never deletes a file that failed to open.
- SFXLibraryTests is not in the scheme's test action, so `xcodebuild test` runs only the UI tests. Add it in Edit Scheme > Test to run the unit tests.
