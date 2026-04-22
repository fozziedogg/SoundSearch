---
name: Spot to PT pending fixes
description: Designed but not yet implemented fixes for the PT spot workflow, ready to execute next session
type: project
---

Next session should implement these changes in order:

## 1. Fix PT 2024 legacy spot — wrong track destination
**File:** `app/SFXLibrary/ProTools/PTSLClient.swift` — `importLegacy()` method
**Problem:** `audio_destination: "MD_NewTrack"` creates a new track instead of placing on the selected track.
**Fix:** Change to `"AudioDestination_SelectedTrack"` (verify exact enum string in `sdk/PTSL_SDK_CPP.2025.10.0.1267955` first).
**Why:** Both Spot and Spot Peak land at session start on a new track in PT 2024 — this is the root cause.

## 2. Channel mismatch errors
**Approach:** Don't pre-check. PT returns an error string in `responseErrorJson` on mismatch — just make sure it surfaces to the user readably in `ProToolsSpotBar.swift`. Already captured, may just need UI wiring verified.

## 3. Stop transport on spot/drag button press
**Files:** `app/SFXLibrary/UI/Detail/ProToolsSpotBar.swift` and `app/SFXLibrary/UI/Detail/WaveformDragBar.swift`
**Fix:** Call `player.stop()` at the top of each button action before doing any spot/drag work.

## 4. Stop playback on app defocus — NEW SETTING
**Setting:** `stopOnDefocus: Bool`, default `true`, persisted in UserDefaults key `"stopOnDefocus"`
**Where to add:** `AppEnvironment.swift` alongside other UserDefaults settings (e.g. near `autoPlayOnSelect`)
**Observer:** Add `NSApplication.willResignActiveNotification` observer in `AudioPlayer` or `AppEnvironment` — check `env.stopOnDefocus` before stopping.
**Settings UI:** Add toggle in `AudioSettingsView.swift` under the Audio Output section or a new "Playback" section. Label: "Stop playback when switching apps". Default on.
