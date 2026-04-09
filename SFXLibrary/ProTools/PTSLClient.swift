import Foundation

// MARK: - Errors

enum PTSLError: LocalizedError {
    /// Thrown by every method until grpc-swift is wired up.
    case notImplemented
    /// Pro Tools is not running or PTSL server is not reachable.
    case connectionFailed(String)
    /// A PTSL command completed with an error status.
    case commandFailed(String)
    /// The file could not be imported.
    case importFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "PTSL not yet implemented — upgrade Pro Tools to 2025.06+ and add grpc-swift."
        case .connectionFailed(let msg):
            return "Could not connect to Pro Tools: \(msg)"
        case .commandFailed(let msg):
            return "Pro Tools returned an error: \(msg)"
        case .importFailed(let path):
            return "Failed to import \(path) into Pro Tools."
        }
    }
}

// MARK: - Spot request

/// Everything PTSLClient needs to import and spot a clip.
struct PTSLSpotRequest {
    /// Absolute path to the audio file on disk.
    let fileURL: URL
    /// Start of the region within the file, in seconds. nil = start of file.
    let selectionStart: TimeInterval?
    /// End of the region within the file, in seconds. nil = end of file.
    let selectionEnd: TimeInterval?
    /// Audio to include before selectionStart, in seconds.
    let preHandle: TimeInterval
    /// Audio to include after selectionEnd, in seconds.
    let postHandle: TimeInterval
    /// Target timecode string in PT's current frame rate format, e.g. "01:00:10:00".
    let timecode: String
    /// Frame rate of the timecode string.
    let frameRate: FrameRate
    /// Name of the Pro Tools track to place the clip on. Empty = PT chooses.
    let trackName: String
    /// File sample rate (needed to convert selection seconds → samples).
    let sampleRate: Int
}

// MARK: - Client

/// Handles the PTSL gRPC connection to Pro Tools.
///
/// The 3-step spot workflow (PT 2025.06+):
///   1. ImportAudioToClipList  → file_id
///   2. CreateAudioClips       → clip_id  (with src_start/end/sync in samples)
///   3. SpotClipsByID          → done
///
/// **Not yet wired to gRPC.** Every method throws `PTSLError.notImplemented` until
/// grpc-swift is added and `sendRequest(_:streaming:)` is implemented.
/// See the MARK: - gRPC Transport section below.
actor PTSLClient {

    static let shared = PTSLClient()

    // Set by registerConnection() and reused for all subsequent calls.
    private var sessionId: String?

    // MARK: - Public API

    /// Registers the app with Pro Tools. Must succeed before any other call.
    /// Safe to call multiple times — no-ops if already registered.
    func registerConnection() async throws {
        guard sessionId == nil else { return }
        let body = """
        { "company_name": "Personal", "application_name": "SFXLibrary" }
        """
        let response = try await sendRequest(commandId: 70, body: body)
        // response_body_json contains { "session_id": "..." }
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = json["session_id"] as? String
        else {
            throw PTSLError.commandFailed("RegisterConnection returned unexpected response: \(response)")
        }
        sessionId = sid
    }

    /// Full spot workflow: import file → create sub-clip → spot on timeline.
    func spot(_ request: PTSLSpotRequest) async throws {
        try await registerConnection()

        // Step 1 — import the source file, get file_id
        let fileId = try await importAudioToClipList(path: request.fileURL.path)

        // Step 2 — create a sub-clip with the selection + handles
        let clipId = try await createAudioClip(
            fileId: fileId,
            request: request
        )

        // Step 3 — spot it at the target timecode
        try await spotClipByID(
            clipId: clipId,
            timecode: request.timecode,
            trackName: request.trackName
        )
    }

    // MARK: - Private steps

    private func importAudioToClipList(path: String) async throws -> String {
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
        let body = """
        { "file_list": ["\(escapedPath)"] }
        """
        let response = try await sendRequest(commandId: 123, body: body)
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileList = json["file_list"] as? [[String: Any]],
              let first = fileList.first,
              let destList = first["destination_file_list"] as? [[String: Any]],
              let firstDest = destList.first,
              let fileId = firstDest["file_id"] as? String
        else {
            throw PTSLError.importFailed(path: path)
        }
        return fileId
    }

    private func createAudioClip(fileId: String, request: PTSLSpotRequest) async throws -> String {
        let sr = Double(request.sampleRate)

        // Clamp handles to file boundaries
        let rawStart = request.selectionStart ?? 0.0
        let rawEnd   = request.selectionEnd   // nil = end of file

        let clippedStart = max(0.0, rawStart - request.preHandle)
        let clippedEnd: Double? = rawEnd.map { $0 + request.postHandle }

        let startSample = Int64((clippedStart * sr).rounded())
        // syncPoint = where the original BEXT timecode falls inside the sub-clip
        let syncOffsetSec = rawStart - clippedStart   // = min(preHandle, rawStart)
        let syncSample    = Int64((syncOffsetSec * sr).rounded())

        var clipInfoJson = """
            {
                "file_id": "\(fileId)",
                "src_start_point": { "position": \(startSample), "time_type": "BTType_Samples" },
                "src_sync_point":  { "position": \(syncSample),  "time_type": "BTType_Samples" }
        """
        if let end = clippedEnd {
            let endSample = Int64((end * sr).rounded())
            clipInfoJson += """
            ,   "src_end_point": { "position": \(endSample), "time_type": "BTType_Samples" }
            """
        }
        clipInfoJson += "\n}"

        let body = """
        {
            "clip_list": [{
                "clip_info": [\(clipInfoJson)]
            }]
        }
        """
        let response = try await sendRequest(commandId: 127, body: body)
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clipList = json["clip_list"] as? [[String: Any]],
              let first = clipList.first,
              let clipIds = first["clip_ids"] as? [String],
              let clipId = clipIds.first
        else {
            throw PTSLError.commandFailed("CreateAudioClips returned unexpected response: \(response)")
        }
        return clipId
    }

    private func spotClipByID(clipId: String, timecode: String, trackName: String) async throws {
        let trackField = trackName.isEmpty ? "" : """
        "dst_track_name": "\(trackName)",
        """
        let body = """
        {
            "src_clips": ["\(clipId)"],
            \(trackField)
            "dst_location_data": {
                "location_type": "SLType_SyncPoint",
                "location": {
                    "location": "\(timecode)",
                    "time_type": "TLType_TimeCode"
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
    //   2. Create a minimal proto file with just the service + Request/Response messages
    //      (see sdk/PTSL_SDK_CPP.2025.10.0.1267955/Source/PTSL.proto lines 175–189, 5713–5830)
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
    //        var header = Ptsl_RequestHeader()
    //        header.command    = Ptsl_CommandId(rawValue: commandId) ?? .cidNone
    //        header.version    = 2025
    //        header.versionMinor = 10
    //        if let sid = sessionId { header.sessionID = sid }
    //        var request = Ptsl_Request()
    //        request.header          = header
    //        request.requestBodyJson = body
    //        let response = try await client.sendGrpcRequest(request)
    //        if response.header.status == .completed {
    //            return response.responseBodyJson
    //        } else {
    //            throw PTSLError.commandFailed(response.responseErrorJson)
    //        }

    private func sendRequest(commandId: Int, body: String) async throws -> String {
        throw PTSLError.notImplemented
    }
}
