---
name: spot-to-pt-appleevent-spottoregion-working
description: Spot-to-Pro-Tools now uses the Avid RegionSpotter AppleEvent; PTSL removed; old PTSL fixes obsolete
metadata: 
  node_type: memory
  type: project
  originSessionId: 073976a9-6288-4268-8284-3a0c7bf94946
---

Spot to Pro Tools now uses the classic Avid RegionSpotter AppleEvent (`Sd2a`/`SRgn`), NOT PTSL/gRPC. Implemented in `app/SFXLibrary/ProTools/ProToolsSpotter.swift` (commit b0a926d on branch `feature/ptpeep-spotting-and-profiles`). The whole PTSL gRPC stack (PTSLClient + PTSL_minimal.* + grpc-swift/swift-protobuf/NIO deps) was deleted — so the 4 older PTSL spot fixes that used to be listed here are obsolete (item 3, `player.stop()` on spot, is already in ProToolsSpotBar).

Key behavior (from the Avid SDK source at `~/developer/docs/SpotToRegion/`): `Trak=-99` spots into the **first edit-selected track**; `SMSt` is the sample offset from the selection start; `Star`/`Stop` are the source in/out within the file. It is **selection-based** — there is no "track under the playhead." If no track is edit-selected, or the file's channel width doesn't match the selected track, Pro Tools creates a NEW track (inherent PT behavior, not a bug).

Confirmed working: stereo file → stereo edit-selected track lands correctly. FILE is sent as `typeFileURL`; the Avid SDK uses classic `typeAlias` — if some PT version ever routes a fileURL spot to a new track, switching to `typeAlias` is the fix to try. Drag-to-PT (file promise + BEXT timeReference patching via SpotFileBuilder) is unchanged and independent.

See [[reference_ptsl_sdk]] only for unrelated PTSL work; for spotting, edit ProToolsSpotter.swift.
