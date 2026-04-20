# PTSL — Pro Tools Scripting Library Reference

Use this command to recall everything about the PTSL SDK when working on Pro Tools integration in this project.

## SDK Location
`/Users/fozzie/developer/sfxlibrary/sdk/PTSL_SDK_CPP.2025.10.0.1267955/`
- Proto definition: `Source/PTSL.proto`
- C++ client: `Source/CppPTSLClient.h`
- All command implementations: `Source/Commands/CppPTSLC_*.cpp`
- Example app: `examples/ptslcmd/`

## Protocol
- **Transport:** gRPC on `localhost:31416` (local only)
- **Format:** Commands are JSON-serialized protobuf messages
- **SDK version:** 2025.10.0 (PT 2025.10)
- **Modern API:** All typed C++ request structs are deprecated — use JSON strings with `SendRequest(CommandId, jsonString)`

## Auth Flow
Every client must call `RegisterConnection` first. The C++ wrapper stores the returned `session_id` automatically and attaches it to all subsequent requests.

```json
// RegisterConnection request body
{ "company_name": "YourCo", "application_name": "SFXLibrary" }
// Returns session_id — valid for life of running PT instance
```

## Key Commands for SFX Library

| Command | CId | PT Version | Purpose |
|---|---|---|---|
| `RegisterConnection` | 70 | All | Must call first |
| `GetTrackList` | 3 | All | List session tracks |
| `GetSessionName` | 42 | All | Current session name |
| `GetSessionTimeCodeRate` | — | All | Session frame rate |
| `GetSessionStartTime` | — | All | Session start timecode |
| `ImportAudioToClipList` | 123 | 2025.06+ | Import files → get clip IDs |
| `SpotClipsByID` | 124 | 2025.06+ | Place clips on track at timecode |
| `Import` | 2 | All | Legacy: import+spot in one op |
| `Spot` | 29 | All | Legacy: spot selected clip |
| `HostReadyCheck` | — | All | Ping to confirm PT is responsive |

## Modern Spot Workflow (PT 2025.06+)

**Step 1 — Import to clip list:**
```json
// CId_ImportAudioToClipList (123)
{ "file_list": ["/absolute/path/to/file.wav"] }

// Response:
{
  "file_list": [
    {
      "file_path": "/absolute/path/to/file.wav",
      "destination_file_list": [
        { "clip_id": "<uuid>", "clip_name": "file" }
      ]
    }
  ]
}
```

**Step 2 — Spot by clip ID:**
```json
// CId_SpotClipsByID (124)
{
  "src_clips": ["<clip_id_from_step_1>"],
  "dst_track_name": "SFX",
  "dst_location_data": {
    "location_type": "SLType_Start",
    "location": {
      "location": "01:00:00:00",
      "time_type": "TLType_TimeCode"
    }
  }
}
```

## SpotLocationData

**location_type** — which point of the clip to align to the target timecode:
- `SLType_Start` — clip start aligns to timecode
- `SLType_SyncPoint` — clip's inline sync point aligns to timecode
- `SLType_End` — clip end aligns to timecode

**time_type** values (TimelineLocationType):
- `TLType_TimeCode` — `"HH:MM:SS:FF"` (e.g. `"01:00:00:00"`)
- `TLType_Samples` — integer sample count from session start (e.g. `"0"`)
- `TLType_MinSecs` — `"MM:SS.mmm"` (e.g. `"00:00.000"`)
- `TLType_FeetFrames` — `"FEET+FF"`
- `TLType_BarsBeats` — `"BARS|BEATS"`
- `TLType_Seconds` — floating point seconds

## BEXT TimeReference → PT Timecode

The app's `TimecodeConverter.swift` converts BEXT `TimeReference` (samples since midnight at session sample rate) to timecode strings. Pass result as `TLType_TimeCode`, or pass `TimeReference` directly as sample count with `TLType_Samples` after subtracting session start sample offset.

## Legacy Import+Spot (all PT versions)

```json
// CId_Import (2) — imports and spots in one command
{
  "audio_data": {
    "file_list": ["/path/to/file.wav"],
    "audio_operations": { "copy_option": "AOCopy_None" },
    "audio_location": "MLocation_Spot",
    "location_data": {
      "location_type": "SLType_Start",
      "location": { "location": "01:00:00:00", "time_type": "TLType_TimeCode" }
    }
  }
}
```

## Events System (PT 2025.06+)

Subscribe → PollEvents (long-poll streaming) → Unsubscribe

```json
// CId_SubscribeToEvents
{ "events": [{ "event_id": "EId_TrackRecordEnabledStateChanged", "event_data_json": "{\"track_id\": \"...\"}" }] }

// CId_PollEvents — blocks/streams indefinitely, use responseCallback
// CId_UnsubscribeFromEvents — same body as Subscribe
```

Available event IDs include track state changes, transport state, batch job status, etc. See `Source/PTSL.proto` for `enum EventId`.

## Batch Jobs (PT 2025.10+)

Wraps a multi-step operation in a PT modal dialog with a progress bar.

```
CId_CreateBatchJob { name, description, timeout_ms, is_cancelable, cancel_on_failure }
  → returns batch_job_id

Include in subsequent command headers:
  versioned_request_header_json: '{ "batch_job_header": { "id": "<id>", "progress": 0..100 } }'

CId_CompleteBatchJob { id: "<batch_job_id>" }
CId_CancelBatchJob   { id: "<batch_job_id>" }
CId_GetBatchJobStatus { id: "<batch_job_id>" }
```

## Swift Integration

The C++ wrapper cannot be called directly from Swift. Three approaches:

### Option A: ObjC++ Bridge (use the C++ SDK directly)
Build `ptsl.client.cpp` dylib via `python3 setup/build_cpp_ptsl_sdk.py`, add to Xcode, write `.mm` bridge file.
Best if you want full SDK coverage and type safety from the C++ layer.

### Option B: grpc-swift (pure Swift, recommended)
Add `grpc-swift` + `swift-protobuf` via SPM. Run `protoc` with Swift plugin on `Source/PTSL.proto` to generate Swift types. Write a `PTSLClient.swift` that calls gRPC directly.
Best fit: already using SPM, keeps codebase pure Swift, no C++ build step.

### Option C: Shell out to ptslcmd
Build the ptslcmd example binary, bundle with app, call via `Process()` with JSON args.
Simplest to prototype, but process overhead and no async streaming.

## Error Handling

Always check `response.GetStatus()`:
- `CommandStatusType::Completed` — success, read `GetResponseBodyJson()`
- `CommandStatusType::Failed` — read `GetResponseErrorJson()` or iterate `GetResponseErrorList()`
- `CommandErrorType::SDK_VersionMismatch` — client SDK version incompatible with running PT version

## Notes
- Session must have a Pro Tools session open for most commands to work
- `HostReadyCheck` can be used to confirm PT is running and PTSL is ready before sending commands
- gRPC is HTTP/2 — not compatible with plain URLSession; need a proper gRPC client
