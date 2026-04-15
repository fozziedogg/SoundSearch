import Foundation

// MARK: - Errors

enum PTSLError: LocalizedError {
    case notImplemented
    case connectionFailed(String)
    case commandFailed(String)
    case importFailed(path: String)
    case unknownSampleRate(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "PTSL not yet implemented — add grpc-swift and wire sendRequest()."
        case .connectionFailed(let msg):
            return "Could not connect to Pro Tools: \(msg)"
        case .commandFailed(let msg):
            return "Pro Tools returned an error: \(msg)"
        case .importFailed(let path):
            return "Failed to import \(path) into Pro Tools."
        case .unknownSampleRate(let val):
            return "Unrecognised session sample rate: \(val)"
        }
    }
}

// MARK: - Timeline selection

struct PTTimelineSelection {
    /// Cursor / play-start position in session samples.
    let cursorSamples: Int64
    /// Selection in-point in session samples. Equals cursorSamples when no selection is active.
    let inSamples: Int64
    /// Selection out-point in session samples. Equals inSamples when no selection is active.
    let outSamples: Int64
    /// Session sample rate (Hz), as reported by GetSessionSampleRate.
    let sessionSampleRate: Double

    var hasSelection: Bool { outSamples > inSamples }
    var selectionDurationSamples: Int64 { outSamples - inSamples }
}

// MARK: - Spot requests

/// Spot a content region (SoundSearch selection or whole file) to the PT timeline.
/// If PT has a selection the content is trimmed to its duration; handles extend on both sides.
struct PTSLContentSpotRequest {
    let fileURL: URL
    /// Seconds from file start to the beginning of content (0 = file start).
    let contentStartSecs: Double
    /// Seconds from file start to the end of content.
    let contentEndSecs: Double
    /// Extra audio included before and after the content, in seconds.
    let handles: Double
    /// Native sample rate of the audio file.
    let fileSampleRate: Int
}

/// Spot a file so its loudest peak aligns with the PT cursor / in-point. Handles extend on both sides.
struct PTSLPeakSpotRequest {
    let fileURL: URL
    /// Absolute sample index (from file start) of the peak to align.
    let peakSample: Int64
    /// Seconds from file start to the beginning of the search range.
    let contentStartSecs: Double
    /// Seconds from file start to the end of the search range.
    let contentEndSecs: Double
    /// Extra audio included before and after the content, in seconds.
    let handles: Double
    /// Native sample rate of the audio file.
    let fileSampleRate: Int
}

// MARK: - Client

/// Handles the PTSL gRPC connection to Pro Tools.
///
/// Spot workflow (PT 2025.06+):
///   1. GetSessionSampleRate   → session sample rate for timeline math
///   2. GetTimelineSelection   → cursor position / selection in session samples
///   3. ImportAudioToClipList  → file_id
///   4. CreateAudioClips       → clip_id  (sub-clip with src in/out and sync point)
///   5. SpotClipsByID          → places clip at sync-point aligned to PT anchor
///
/// **Not yet wired to gRPC.** Every call throws `PTSLError.notImplemented` until
/// grpc-swift is added and `sendRequest(commandId:body:)` is implemented.
/// See the MARK: - gRPC Transport section below for the implementation guide.
actor PTSLClient {

    static let shared = PTSLClient()

    private var sessionId: String?

    // MARK: - Connection

    /// Registers the app with Pro Tools. Safe to call multiple times — no-ops when already registered.
    func registerConnection() async throws {
        guard sessionId == nil else { return }
        let body = """
        { "company_name": "Personal", "application_name": "SFXLibrary" }
        """
        let response = try await sendRequest(commandId: 70, body: body)
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid  = json["session_id"] as? String
        else {
            throw PTSLError.commandFailed("RegisterConnection returned unexpected response: \(response)")
        }
        sessionId = sid
    }

    // MARK: - Session info

    /// Returns the session's sample rate in Hz (e.g. 48000.0).
    func getSessionSampleRate() async throws -> Double {
        let response = try await sendRequest(commandId: 35, body: "{}")
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let srStr = json["sample_rate"] as? String
        else {
            throw PTSLError.commandFailed("GetSessionSampleRate returned unexpected response")
        }
        // Handle both old (SR_48000) and new (SRate_48000) enum value formats.
        let digits = srStr
            .replacingOccurrences(of: "SRate_", with: "")
            .replacingOccurrences(of: "SR_",    with: "")
        guard let rate = Double(digits) else { throw PTSLError.unknownSampleRate(srStr) }
        return rate
    }

    /// Returns the current timeline selection (or cursor position) in session samples.
    func getTimelineSelection() async throws -> PTTimelineSelection {
        let sessionSR = try await getSessionSampleRate()
        // Request times as session samples so we can do direct arithmetic below.
        let body = """
        { "location_type": "TLType_Samples" }
        """
        let response = try await sendRequest(commandId: 82, body: body)
        guard let data      = response.data(using: .utf8),
              let json      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cursorStr = json["play_start_marker_time"] as? String,
              let inStr     = json["in_time"]  as? String,
              let outStr    = json["out_time"] as? String,
              let cursor    = Int64(cursorStr),
              let inTime    = Int64(inStr),
              let outTime   = Int64(outStr)
        else {
            throw PTSLError.commandFailed("GetTimelineSelection returned unexpected response")
        }
        return PTTimelineSelection(cursorSamples:    cursor,
                                   inSamples:         inTime,
                                   outSamples:        outTime,
                                   sessionSampleRate: sessionSR)
    }

    // MARK: - Public spot API

    /// Spots the content region to the PT timeline.
    ///
    /// - If PT has a selection the content is trimmed to fit it and spotted to the in-point.
    /// - If PT has no selection the content is spotted at the cursor, full duration.
    /// - Handles (extra audio) extend on both sides; the content start acts as the sync point.
    func spotContent(_ request: PTSLContentSpotRequest) async throws {
        try await registerConnection()
        let sel   = try await getTimelineSelection()
        let sr    = Double(request.fileSampleRate)
        let sessSR = sel.sessionSampleRate

        // Content boundaries in file samples
        let rawStart = Int64((request.contentStartSecs * sr).rounded())
        var rawEnd   = Int64((request.contentEndSecs   * sr).rounded())

        // Trim content to fit PT selection when one is active
        if sel.hasSelection {
            let ptDurInFileSamples = Int64((Double(sel.selectionDurationSamples) * sr / sessSR).rounded())
            rawEnd = min(rawEnd, rawStart + ptDurInFileSamples)
        }

        // Handle boundaries clamped to file start (upper bound handled by PT)
        let handleSamples     = Int64((request.handles * sr).rounded())
        let srcStart          = max(0, rawStart - handleSamples)
        let srcEnd            = rawEnd + handleSamples
        let actualHandleBefore = rawStart - srcStart   // ≤ handleSamples

        // Timeline anchor: PT in-point when there's a selection, else cursor
        let ptAnchor = sel.hasSelection ? sel.inSamples : sel.cursorSamples
        // Clip starts (actualHandleBefore) before the anchor in session-sample space
        let handleBeforeSess = Int64((Double(actualHandleBefore) * sessSR / sr).rounded())
        let timelineStart    = ptAnchor - handleBeforeSess
        let clipDurSess      = Int64((Double(srcEnd - srcStart) * sessSR / sr).rounded())
        let timelineEnd      = timelineStart + clipDurSess

        let fileId = try await importAudioToClipList(path: request.fileURL.path)
        let clipId = try await createAudioClip(fileId:       fileId,
                                               srcStart:     srcStart,
                                               srcEnd:       srcEnd,
                                               srcSyncPoint: rawStart,     // content start → sync point
                                               timelineStart: timelineStart,
                                               timelineEnd:   timelineEnd)
        try await spotClipByID(clipId: clipId, anchorSessionSamples: ptAnchor)
    }

    /// Spots the file so its loudest peak aligns with the PT cursor / in-point.
    ///
    /// - Handles extend on both sides of the content range.
    /// - The peak sample is embedded as the clip's sync point and aligned to the PT anchor.
    func spotPeak(_ request: PTSLPeakSpotRequest) async throws {
        try await registerConnection()
        let sel    = try await getTimelineSelection()
        let sr     = Double(request.fileSampleRate)
        let sessSR = sel.sessionSampleRate

        let handleSamples = Int64((request.handles * sr).rounded())
        let contentStart  = Int64((request.contentStartSecs * sr).rounded())
        let contentEnd    = Int64((request.contentEndSecs   * sr).rounded())
        let srcStart      = max(0, contentStart - handleSamples)
        let srcEnd        = contentEnd + handleSamples

        // Peak is the sync point — it aligns to the PT anchor on the timeline
        let syncPoint  = request.peakSample
        let ptAnchor   = sel.hasSelection ? sel.inSamples : sel.cursorSamples

        // Offset from clip start to peak, converted to session samples
        let peakOffsetInClip  = syncPoint - srcStart
        let peakOffsetSess    = Int64((Double(peakOffsetInClip) * sessSR / sr).rounded())
        let timelineStart     = ptAnchor - peakOffsetSess
        let clipDurSess       = Int64((Double(srcEnd - srcStart) * sessSR / sr).rounded())
        let timelineEnd       = timelineStart + clipDurSess

        let fileId = try await importAudioToClipList(path: request.fileURL.path)
        let clipId = try await createAudioClip(fileId:        fileId,
                                               srcStart:      srcStart,
                                               srcEnd:        srcEnd,
                                               srcSyncPoint:  syncPoint,   // peak → sync point
                                               timelineStart: timelineStart,
                                               timelineEnd:   timelineEnd)
        try await spotClipByID(clipId: clipId, anchorSessionSamples: ptAnchor)
    }

    // MARK: - Private PTSL steps

    private func importAudioToClipList(path: String) async throws -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body = """
        { "file_list": ["\(escaped)"] }
        """
        let response = try await sendRequest(commandId: 123, body: body)
        guard let data     = response.data(using: .utf8),
              let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileList = json["file_list"] as? [[String: Any]],
              let first    = fileList.first,
              let destList = first["destination_file_list"] as? [[String: Any]],
              let dest     = destList.first,
              let fileId   = dest["file_id"] as? String
        else { throw PTSLError.importFailed(path: path) }
        return fileId
    }

    /// Creates a sub-clip in the PT clip list.
    /// src positions are in file-native samples; timeline positions are in session samples.
    private func createAudioClip(fileId: String,
                                  srcStart: Int64, srcEnd: Int64, srcSyncPoint: Int64,
                                  timelineStart: Int64, timelineEnd: Int64) async throws -> String {
        let body = """
        {
            "clip_list": [{
                "clip_info": [{
                    "file_id": "\(fileId)",
                    "src_start_point": { "position": \(srcStart),      "time_type": "BTType_Samples" },
                    "src_end_point":   { "position": \(srcEnd),        "time_type": "BTType_Samples" },
                    "src_sync_point":  { "position": \(srcSyncPoint),  "time_type": "BTType_Samples" },
                    "start_point":     { "position": \(timelineStart), "time_type": "BTType_Samples" },
                    "end_point":       { "position": \(timelineEnd),   "time_type": "BTType_Samples" }
                }]
            }]
        }
        """
        let response = try await sendRequest(commandId: 127, body: body)
        guard let data    = response.data(using: .utf8),
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list    = json["clip_list"] as? [[String: Any]],
              let first   = list.first,
              let clipIds = first["clip_ids"] as? [String],
              let clipId  = clipIds.first
        else {
            throw PTSLError.commandFailed("CreateAudioClips returned unexpected response: \(response)")
        }
        return clipId
    }

    /// Places `clipId` on the PT timeline with its sync point aligned to `anchorSessionSamples`.
    private func spotClipByID(clipId: String, anchorSessionSamples: Int64) async throws {
        let body = """
        {
            "src_clips": ["\(clipId)"],
            "dst_location_data": {
                "location_type": "SLType_SyncPoint",
                "location": {
                    "location": "\(anchorSessionSamples)",
                    "time_type": "TLType_Samples"
                }
            }
        }
        """
        _ = try await sendRequest(commandId: 124, body: body)
    }

    // MARK: - gRPC Transport
    //
    // TODO: Replace this stub with grpc-swift when upgrading to PT 2025.06+.
    //
    // Steps to implement:
    //   1. Add to Package.resolved:
    //        grpc-swift      https://github.com/grpc/grpc-swift  (v2.x)
    //        swift-protobuf  https://github.com/apple/swift-protobuf
    //
    //   2. Create a minimal proto with just the service + Request/Response messages
    //      (see sdk/PTSL_SDK_CPP.2025.10.0.1267955/Source/PTSL.proto lines ~175–189)
    //      and run protoc to generate Swift types.
    //
    //   3. Replace the throw below with:
    //
    //        let channel = try GRPCChannelPool.with(
    //            target: .host("localhost", port: 31416),
    //            transportSecurity: .plaintext,
    //            eventLoopGroup: PlatformSupport.makeEventLoopGroup(loopCount: 1)
    //        )
    //        let client = Ptsl_PTSLNIOClient(channel: channel)
    //        var req = Ptsl_Request()
    //        req.header.command        = Ptsl_CommandId(rawValue: commandId) ?? .cidNone
    //        req.header.sessionID      = sessionId ?? ""
    //        req.requestBodyJson       = body
    //        let response = try await client.sendGrpcRequest(req)
    //        guard response.header.status == .completed else {
    //            throw PTSLError.commandFailed(response.responseErrorJson)
    //        }
    //        return response.responseBodyJson

    private func sendRequest(commandId: Int, body: String) async throws -> String {
        throw PTSLError.notImplemented
    }
}
