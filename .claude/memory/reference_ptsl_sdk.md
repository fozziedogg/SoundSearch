---
name: PTSL SDK
description: Pro Tools Scripting Library SDK — protocol, key commands, and Swift integration approach
type: reference
---

## What It Is

PTSL (Pro Tools Scripting Library) = gRPC IPC protocol for controlling Pro Tools from external apps.
SDK located at `/Users/fozzie/developer/sfxlibrary/sdk/PTSL_SDK_CPP.2025.10.0.1267955/`

- **Version:** 2025.10.0
- **Protocol:** gRPC on `localhost:31416` (local only — no remote connections)
- **Commands:** JSON-serialized protobufs. Proto file: `Source/PTSL.proto`
- **C++ wrapper:** `CppPTSLClient` in `Source/CppPTSLClient.h/.cpp`
- **Example app:** `examples/ptslcmd/` (needs building via Conan/CMake, no prebuilt binary)

## Auth / Session Flow

1. Call `RegisterConnection` (CId_RegisterConnection=70) with `company_name` + `application_name`
2. Returns `session_id` — the C++ wrapper tracks this automatically; valid for lifetime of running PT instance

## Key Commands for SFX Library App

| Command | ID | Notes |
|---|---|---|
| `RegisterConnection` | 70 | Required first — returns session_id |
| `GetTrackList` | 3 | List session tracks |
| `GetSessionName` | 42 | |
| `GetSessionTimeCodeRate` | — | |
| `GetSessionStartTime` | — | |
| `Import` | 2 | Old: import + spot in one op (deprecated workflow) |
| `ImportAudioToClipList` | 123 | **New (PT 2025.06+):** import to clip list, returns clip IDs |
| `SpotClipsByID` | 124 | **New (PT 2025.06+):** place clips by ID on track at timecode |
| `Spot` | 29 | Old: spot currently-selected clip |

## Modern Spot Workflow (PT 2025.06+)

```
ImportAudioToClipList { file_list: ["/path/to/file.wav"] }
  → returns clip IDs

SpotClipsByID {
  src_clips: ["<clip_id>"],
  dst_track_id or dst_track_name: "...",
  dst_location_data: SpotLocationData {
    location_type: SLType_Start | SLType_SyncPoint | SLType_End,
    location: TimelineLocation {
      location: "01:00:00:00",   // timecode string
      time_type: TLType_TimeCode  // or Samples, MinSecs, etc.
    }
  }
}
```

## SpotLocationData

- `location_type`: where on clip to align (Start, SyncPoint, End)
- `location.time_type` options: `TLType_Samples`, `TLType_TimeCode`, `TLType_MinSecs`, `TLType_BarsBeats`, `TLType_FeetFrames`, `TLType_Seconds`
- `location.location`: string value (e.g. "01:00:00:00" for timecode, "48000" for samples)
- Deprecated fields `location_value` / `location_options` still work for older PT versions

## BEXT TimeReference → Timecode

The app's existing `SpotFileBuilder.swift` / `TimecodeConverter.swift` converts BEXT TimeReference (samples-since-midnight) to timecode. Can pass as `TLType_Samples` or convert to `TLType_TimeCode` string.

## Events System (PT 2025.06+)

SubscribeToEvents → SendRequest(CId_PollEvents, callback) → UnsubscribeFromEvents
- Long-polling streaming API
- EventIds include track state changes, batch job status, etc.

## Batch Jobs (PT 2025.10+)

CreateBatchJob → run commands with batch_job_header → CompleteBatchJob
- Shows a PT modal dialog with progress bar
- Useful for multi-file imports

## Swift Integration Options

The C++ wrapper can't be called directly from Swift. Options:
1. **ObjC++ bridge** — build C++ library, wrap in .mm file, expose to Swift (most control)
2. **grpc-swift + swift-protobuf** — generate Swift from PTSL.proto, talk gRPC directly
3. **Shell out to ptslcmd** — simplest but requires building the example app first; fragile

The JSON-based `SendRequest(CommandId, jsonString)` API is the modern/preferred way — all typed request structs are deprecated in favor of JSON strings.

## SendRequest API (Modern)

```cpp
CppPTSLRequest req{ CommandId::CId_ImportAudioToClipList, R"({"file_list": ["/path/file.wav"]})" };
auto future = client.SendRequest(req);
auto response = future.get();
if (response.GetStatus() == CommandStatusType::Completed) {
    auto json = response.GetResponseBodyJson();
}
```
