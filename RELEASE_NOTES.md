# SoundSearch — Update Notes

## The problem you reported

SoundSearch was remembering where each sound effect lived by its **exact full location** — something like `/Volumes/SFX_01/Library/door.wav`. That works fine until the drive shows up somewhere slightly different, which macOS does more often than you'd think:

- If a drive wasn't cleanly ejected, macOS mounts it the next time as `SFX_01-1` instead of `SFX_01`
- A network share can mount under a different name depending on who connected to it
- On a different machine, the same drive often lands somewhere else entirely

The moment that happened, every single file in the database looked like a *new* file the app had never seen — and a few thousand "missing" ones. So it started indexing the whole library from scratch. Hence your four hours.

Your metadata was never actually lost. The app just couldn't find its way back to the files.

## What's fixed

**The app now identifies drives, not paths.** SoundSearch stores each drive's own identity alongside a location that's relative to that drive. Every time you open a library, it checks where your drives are mounted *right now* and quietly corrects itself. `SFX_01` becoming `SFX_01-1` overnight is now a non-event — no warning, no reindex, nothing to click. Your ratings, notes, tags, and projects all come along.

For a large library this takes about a second. Normal launches, where nothing moved, add about 30 milliseconds.

**New "Relocate Library" command.** For the one case the automatic fix can't cover (more on that below), there's now **Library > Relocate Library…**. You point it at where the folder actually is, it shows you how many files it's about to repoint, and it rewrites them in a few seconds. It does *not* re-read your files, so nothing is re-indexed and no metadata is touched.

If SoundSearch notices a folder is missing when you open it, it now offers this automatically instead of flagging the folder as "changed" and steering you toward a rescan — which was the trap that cost you the four hours.

**The app no longer refuses to start after a bad database copy.** Previously, if a database file was damaged or copied while the app was still running, SoundSearch would crash on launch — and because it remembers the last database you opened, it would crash again every time you tried. There was no way out from inside the app. Now it tells you what went wrong and opens a working library so you can carry on. **It never deletes or alters the file that failed** — if that's your only copy of a big library, it's still there to recover.

**Better diagnostics.** Every session writes a log recording which database was opened, where each of your folders is, which drive each one is on, and where that drive is currently mounted. If a scan ever starts re-reading everything again, the log now says so explicitly, in plain terms, within the first few seconds — instead of you finding out four hours later.

You can get to these with **Library > Show Debug Logs in Finder**. If anything looks off, send us that folder.

## What you need to do

**Nothing, in most cases.** Open the updated app on the machine where your library already works. It'll quietly record your drives' identities while everything is still pointing to the right place, and you'll never see a prompt.

**One exception:** a database you *already* moved to another machine before this update has no drive information recorded yet, and its stored paths describe a machine that isn't the one it's on. That one needs **Library > Relocate Library…** once — you'll be prompted automatically. After that, it's permanent; that library is portable from then on.

Also worth knowing: a drive that gets **reformatted** counts as a brand-new drive as far as any computer is concerned, so that needs one Relocate too.

## One habit worth changing

When you copy a database to another system, **quit SoundSearch first**, or use **Library > Save Database As…**.

A live SQLite database keeps recent changes in a companion `.sqlite-wal` file next to it. Copying just the `.sqlite` in the Finder while the app is open silently leaves those changes behind. "Save Database As…" folds everything into one file before copying, so it's always safe.

---

## Technical appendix

**New files**

- `Services/VolumeIndex.swift` — drive identity (`uuid:<UUID>` for local disks, `name:<volume>` for network shares that report no UUID), mount enumeration, path↔relative arithmetic, and a lock-guarded cache so a large scan does one volume lookup per drive rather than one per file.
- `Services/VolumeResolver.swift` — runs on every database open. Backfill derives `(volume_uuid, volume_relative_path)` for pre-v6 rows while their paths are still valid; repoint regenerates `file_url` from that pair for every mounted volume.
- `Services/LibraryRelocator.swift` — manual prefix rewrite across the library and projects databases, and captures drive identity afterwards so a relocation only ever has to happen once.
- `Services/LibraryDiagnostics.swift` — path and volume logging into the existing per-session log file.
- `UI/Settings/RelocateLibrarySheet.swift` — preview and confirm UI.
- Migration `v6_volume_identity` — adds `volume_uuid` and `volume_relative_path` to `audio_files` and `watched_folders`, plus an index on `volume_uuid`. Backfill happens at runtime, not in SQL: deriving identity needs the volume mounted, which SQL cannot see.

**Modified**

- `App/AppEnvironment.swift` — fault-tolerant database open (default → recovery file → temp, never deleting a file that failed), resolver wiring, missing-folder detection routed to relocation instead of rescan, `switchToDatabase` now opens before tearing down and returns success.
- `FolderWatcher/FolderScanner.swift` — logs mtime-cache hit rate and prints an explicit path-mismatch warning after 200 files with zero hits.
- `Services/LibraryService.swift` — captures drive identity on ingest and on adding a watched folder.
- `Database/Models/AudioFile.swift`, `WatchedFolder.swift` — new columns.
- `UI/MainWindowView.swift`, `SFXLibraryApp.swift` — relocation sheet, database-error alert, `Relocate Library…` and `Show Debug Logs in Finder` menu items.
- `app/SFXLibrary.xcodeproj/project.pbxproj` — `TEST_HOST` pointed at `SFXLibrary.app` but the product is `SoundSearch.app`, stale from a rename; this is why the unit-test target never built or ran.

**Design note.** `file_url` remains the absolute path that every existing query uses, but it is now derived data, regenerated from the durable identity pair on each open. That kept the change contained while still making the database portable — rewriting every query onto a composite key would have been far larger for no additional user-visible benefit.

**Traps worth remembering** (also recorded in `CLAUDE.md`)

- Path prefix matching must use `substr()`, never `LIKE`: `_` and `%` are LIKE wildcards and library paths contain them, so `/Volumes/SFX_01` would also match `/Volumes/SFXX01`. Measure lengths with SQLite `length()`, not Swift `String.count` — macOS filenames are NFD, so one Swift grapheme can be several SQLite characters.
- Never resolve a `file_url` UNIQUE conflict with `UPDATE OR REPLACE`. SQLite fires delete triggers during REPLACE only when `recursive_triggers` is on, which it is not, so the FTS index keeps the deleted row permanently. Delete the loser explicitly first, then plain UPDATE.
- `INSERT INTO audio_files_fts(audio_files_fts) VALUES('rebuild')` cannot work here: the FTS5 table is external-content and declares a `tags_denorm` column that `audio_files` lacks, so rebuild — and any unconstrained scan of the view — fails with `no such column: T.tags_denorm`. Inspect rows via `audio_files_fts_docsize` instead.
- `VolumeIndex.currentMounts()` must not pass `.skipHiddenVolumes`; that drops `nobrowse` mounts, which is how many studio SMB/NFS automounts appear.
- Database open must never use `try!` — the path is persisted in UserDefaults, so a throw crash-loops the app with no in-app escape.

**Verification**

- 20 unit tests passing in `SFXLibraryTests` (8 relocator, 12 volume/resolver), covering backfill, files with no watched-folder row, remount repoint, project membership, no-op launches, unmounted drives, duplicate handling, FTS orphans, two-drive isolation, path arithmetic, mount-suffix stripping, real boot-volume UUID, and identity capture on fresh ingest.
- End-to-end against a real 20 MB APFS disk image: indexed at one mount point, detached, remounted at a second mount point. Paths repointed automatically, ratings intact, no rescan triggered.
- Performance on 100,000 rows: backfill 1.12 s (one-time), repoint 1.29 s, unchanged-mount launch 0.029 s, zero FTS orphans.
- Three defects were found by that testing and fixed: `.skipHiddenVolumes` hiding `nobrowse` mounts, backfill granting identity to duplicate rows left by a partial rescan, and a UNIQUE collision aborting the entire repoint pass.

**Known gap.** `SFXLibraryTests` is not in the scheme's test action, so `xcodebuild test` runs only the UI tests. Add it in Edit Scheme > Test. The unit tests above were run through a temporary scheme.
