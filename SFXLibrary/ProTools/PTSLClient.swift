import Foundation
import AVFoundation
import GRPC
import NIOPosix

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
struct PTSLContentSpotRequest {
    let fileURL: URL
    /// Seconds from file start to the beginning of content (0 = file start).
    let contentStartSecs: Double
    /// Seconds from file start to the end of content.
    let contentEndSecs: Double
    /// Extra audio included before and after the content (PT 2025.06+ only).
    let handles: Double
    /// Native sample rate of the audio file.
    let fileSampleRate: Int
}

// MARK: - Client

/// Handles the PTSL gRPC connection to Pro Tools.
///
/// Automatically selects the appropriate spot workflow based on the connected PT version:
///   - **PT 2025.06+**: ImportAudioToClipList → CreateAudioClips → SpotClipsByID
///     (sub-clip with handles; content trimmed to PT selection)
///   - **PT 2023.06–2025.05**: Import (ID 2) with ML_Spot / location_data
///     (no handles; whole file or trimmed export; lands on a new track — SDK limitation)
actor PTSLClient {

    static let shared = PTSLClient()

    private var sessionId:         String?
    private var ptslVersionMajor:  Int = 0
    private var ptslVersionMinor:  Int = 0

    private var isPTSL2025_06orLater: Bool {
        ptslVersionMajor > 2025 ||
        (ptslVersionMajor == 2025 && ptslVersionMinor >= 6)
    }

    // MARK: - Connection

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
        try await fetchPTSLVersion()
    }

    // MARK: - Session info

    func getSessionSampleRate() async throws -> Double {
        let response = try await sendRequest(commandId: 35, body: "{}")
        guard let data  = response.data(using: .utf8),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let srStr = json["sample_rate"] as? String
        else {
            throw PTSLError.commandFailed("GetSessionSampleRate returned unexpected response")
        }
        let digits = srStr
            .replacingOccurrences(of: "SRate_", with: "")
            .replacingOccurrences(of: "SR_",    with: "")
        guard let rate = Double(digits) else { throw PTSLError.unknownSampleRate(srStr) }
        return rate
    }

    func getTimelineSelection() async throws -> PTTimelineSelection {
        let sessionSR = try await getSessionSampleRate()
        // PT 2025.06+ uses location_type; older versions use the deprecated time_scale field.
        let body: String
        if isPTSL2025_06orLater {
            body = #"{ "location_type": "TLType_Samples" }"#
        } else {
            body = #"{ "time_scale": "Samples" }"#
        }
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

    func spotContent(_ request: PTSLContentSpotRequest) async throws {
        try await registerConnection()
        // TODO: Re-enable once PT 2025.06+ has been tested.
        // if isPTSL2025_06orLater {
        //     try await spotContentModern(request)
        // } else {
            try await spotContentLegacy(request)
        // }
    }

    // MARK: - Modern spot (PT 2025.06+)

    private func spotContentModern(_ request: PTSLContentSpotRequest) async throws {
        let sel    = try await getTimelineSelection()
        let sr     = Double(request.fileSampleRate)
        let sessSR = sel.sessionSampleRate

        let rawStart = Int64((request.contentStartSecs * sr).rounded())
        var rawEnd   = Int64((request.contentEndSecs   * sr).rounded())

        if sel.hasSelection {
            let ptDurInFileSamples = Int64((Double(sel.selectionDurationSamples) * sr / sessSR).rounded())
            rawEnd = min(rawEnd, rawStart + ptDurInFileSamples)
        }

        let handleSamples      = Int64((request.handles * sr).rounded())
        let srcStart           = max(0, rawStart - handleSamples)
        let srcEnd             = rawEnd + handleSamples
        let actualHandleBefore = rawStart - srcStart

        let ptAnchor          = sel.inSamples   // in_time = edit cursor or selection in-point
        let handleBeforeSess  = Int64((Double(actualHandleBefore) * sessSR / sr).rounded())
        let timelineStart     = ptAnchor - handleBeforeSess
        let clipDurSess       = Int64((Double(srcEnd - srcStart) * sessSR / sr).rounded())
        let timelineEnd       = timelineStart + clipDurSess

        let fileId = try await importAudioToClipList(path: request.fileURL.path)
        let clipId = try await createAudioClip(fileId:        fileId,
                                               srcStart:      srcStart,
                                               srcEnd:        srcEnd,
                                               srcSyncPoint:  rawStart,
                                               timelineStart: timelineStart,
                                               timelineEnd:   timelineEnd)
        try await spotClipByID(clipId: clipId, anchorSessionSamples: ptAnchor)
    }

    // MARK: - Legacy spot (PT 2023.06–2025.05)

    private func spotContentLegacy(_ request: PTSLContentSpotRequest) async throws {
        let sel = try await getTimelineSelection()
        let sr  = Double(request.fileSampleRate)

        // in_time is the edit cursor / selection in-point in all PT states.
        // play_start_marker_time (cursorSamples) is the transport marker and is
        // often 0 even when the edit cursor is elsewhere — don't use it.
        let ptAnchor = sel.inSamples

        // Export a segment only if the app has a waveform selection; otherwise use the file as-is.
        let fileDuration = (try? AVAudioFile(forReading: request.fileURL))
            .map { Double($0.length) / sr } ?? 0
        let isWholeFile = request.contentStartSecs <= 0 && request.contentEndSecs >= fileDuration
        let importURL: URL
        if isWholeFile {
            importURL = request.fileURL
        } else {
            importURL = try Self.exportSegment(from: request.fileURL,
                                               startSecs: request.contentStartSecs,
                                               endSecs:   request.contentEndSecs)
        }

        try await importLegacy(path: importURL.path, spotSamples: ptAnchor)
    }

    // MARK: - Legacy Import command
    // Note: PT 2024 MediaDestination has no "selected track" option — MD_NewTrack is the
    // only way to place a clip on the timeline. The clip lands at the correct position;
    // the user must move it to the target track manually in PT 2024.

    private func importLegacy(path: String, spotSamples: Int64) async throws {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body = """
        {
            "import_type": "Audio",
            "audio_data": {
                "file_list": ["\(escaped)"],
                "audio_operations": "ConvertAudio",
                "audio_destination": "MD_NewTrack",
                "audio_location": "ML_Spot",
                "location_data": {
                    "location_type": "Start",
                    "location_value": "\(spotSamples)",
                    "location_options": "Samples"
                }
            }
        }
        """
        _ = try await sendRequest(commandId: 2, body: body, streaming: true)
    }

    // MARK: - Modern PTSL steps

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

    // MARK: - Version detection

    private func fetchPTSLVersion() async throws {
        let response = try await sendRequest(commandId: 55, body: "{}")
        guard let data  = response.data(using: .utf8),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let major = json["version"] as? Int
        else { return }   // non-fatal: stay on legacy path if version unreadable
        ptslVersionMajor = major
        ptslVersionMinor = json["version_minor"] as? Int ?? 0
    }

    // MARK: - Audio export utility

    /// Exports a time range from `url` to a temp file. Used by the legacy Import path.
    private static func exportSegment(from url: URL,
                                      startSecs: Double,
                                      endSecs: Double) throws -> URL {
        let src        = try AVAudioFile(forReading: url)
        let sr         = src.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((startSecs * sr).rounded())
        let endFrame   = AVAudioFramePosition((endSecs   * sr).rounded())
        let count      = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard count > 0 else { throw PTSLError.commandFailed("Empty audio segment") }

        src.framePosition = startFrame
        guard let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: count)
        else { throw PTSLError.commandFailed("Buffer allocation failed") }
        try src.read(into: buf, frameCount: count)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibrarySpot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent
                                              + "_spot." + url.pathExtension)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        let fmt = src.fileFormat
        let settings: [String: Any] = [
            AVFormatIDKey:          kAudioFormatLinearPCM,
            AVSampleRateKey:        fmt.sampleRate,
            AVNumberOfChannelsKey:  fmt.channelCount,
            AVLinearPCMBitDepthKey: fmt.settings[AVLinearPCMBitDepthKey] ?? 24,
            AVLinearPCMIsFloatKey:  fmt.settings[AVLinearPCMIsFloatKey]  ?? false,
        ]
        let out = try AVAudioFile(forWriting: dest, settings: settings)
        try out.write(from: buf)
        return dest
    }

    // MARK: - gRPC Transport

    // Lazily created once and reused. The event loop group is intentionally
    // kept alive for the lifetime of the actor.
    private var _grpcClient: Ptsl_PTSLAsyncClient?

    private func grpcClient() -> Ptsl_PTSLAsyncClient {
        if let c = _grpcClient { return c }
        let group   = PlatformSupport.makeEventLoopGroup(loopCount: 1,
                                                          networkPreference: .best)
        let channel = ClientConnection.insecure(group: group)
            .connect(host: "localhost", port: 31416)
        let client  = Ptsl_PTSLAsyncClient(channel: channel)
        _grpcClient = client
        return client
    }

    private func sendRequest(commandId: Int, body: String, streaming: Bool = false) async throws -> String {
        var header          = Ptsl_RequestHeader()
        header.command      = Ptsl_CommandId(rawValue: commandId) ?? .cidNone
        header.version      = Int32(ptslVersionMajor > 0 ? ptslVersionMajor : 5)
        header.versionMinor = Int32(ptslVersionMinor)
        header.sessionID    = sessionId ?? ""

        var req             = Ptsl_Request()
        req.header          = header
        req.requestBodyJson = body

        let response: Ptsl_Response
        if streaming {
            response = try await grpcClient().sendGrpcStreamingRequest(req)
        } else {
            response = try await grpcClient().sendGrpcRequest(req)
        }

        // Async commands (Import) return Queued with a taskId; poll until the task finishes.
        if response.header.status == .tstatusQueued {
            let taskId = response.header.taskID
            guard !taskId.isEmpty else {
                throw PTSLError.commandFailed("Command \(commandId) returned Queued without taskId")
            }
            try await pollUntilComplete(taskId: taskId)
            return response.responseBodyJson
        }

        guard response.header.status == .tstatusCompleted else {
            let msg = response.responseErrorJson.isEmpty
                ? "Command \(commandId) failed with status \(response.header.status)"
                : response.responseErrorJson
            throw PTSLError.commandFailed(msg)
        }
        return response.responseBodyJson
    }

    // Polls GetTaskStatus until the import task finishes (mirrors C++ PingTaskStatus).
    private func pollUntilComplete(taskId: String) async throws {
        let timeout   = Date().addingTimeInterval(60)
        let pollDelay: UInt64 = 500_000_000   // 500 ms

        // Wait 1 s before first poll to give PT time to start the task.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        while Date() < timeout {
            var hdr          = Ptsl_RequestHeader()
            hdr.command      = .cidGetTaskStatus
            hdr.version      = Int32(ptslVersionMajor > 0 ? ptslVersionMajor : 5)
            hdr.versionMinor = Int32(ptslVersionMinor)
            hdr.sessionID    = sessionId ?? ""

            var req             = Ptsl_Request()
            req.header          = hdr
            req.requestBodyJson = #"{"task_id":"\#(taskId)"}"#

            let resp = try await grpcClient().sendGrpcRequest(req)

            switch resp.header.status {
            case .tstatusCompleted:
                return
            case .tstatusFailed:
                let msg = resp.responseErrorJson.isEmpty
                    ? "Async task failed (taskId: \(taskId))"
                    : resp.responseErrorJson
                throw PTSLError.commandFailed(msg)
            default:
                try await Task.sleep(nanoseconds: pollDelay)
            }
        }
        throw PTSLError.commandFailed("Timed out waiting for async task (taskId: \(taskId))")
    }
}
