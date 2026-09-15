---
name: project-audio-export
description: "Audio export/convert feature — formats, tech, and the MP3/SwiftLAME caveat"
metadata: 
  node_type: memory
  type: project
  originSessionId: 073976a9-6288-4268-8284-3a0c7bf94946
---

Multi-format audio export lives on branch `feature/audio-export` (built on top of v1.1,
started 2026-07-16). Entry points: file-list right-click **Export…** (multi-select), and
sidebar **Export Project…** on a project row. All funnel into `ExportSheet`.

Core: `Audio/Export/AudioExportService.swift` uses `AVAudioConverter`
(`AVSampleRateConverterAlgorithm_Mastering`, quality `.max`, `dither = true` on 16-bit
reduction) + `AVAudioFile` writers. Formats: WAV/BWF, AIFF, FLAC, Apple Lossless, AAC — all
native AVFoundation and **verified working** (FLAC write on macOS 15 confirmed via spike).
`ExportMetadataWriter` re-injects bext/iXML/LIST-INFO into WAV exports (scales BEXT
TimeReference on sample-rate change).

**MP3** uses the **SwiftLAME** SPM package (hidden-spectrum/SwiftLAME @ 0.1.0, LGPL) — added
to `project.pbxproj` mirroring the GRDB package entry. Path: mastering-convert → temp WAV →
`SwiftLameEncoder` at matching rate. **SwiftLAME is early-alpha and the MP3 path was NOT
runtime-tested** (the standalone test was blocked; app builds+links fine). Needs a real-file
export test on the studio machine; fallback if it misbehaves is BB9z/LAME-xcframework.

Gotcha learned: an `AVAudioFile(forWriting:)` stays open/unflushed until it deallocates —
re-reading the same URL before it goes out of scope yields 0 frames. The service writes via a
helper that returns (deallocating the file) before any metadata patching.
