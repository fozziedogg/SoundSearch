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
