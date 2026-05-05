---
name: Studio handover prep steps
description: Steps to prep SoundSearch for sending to studio engineers — do on dev machine
type: project
---

Ready to do on dev machine, in this order:

1. **Bundle ID** — open Xcode, click SFXLibrary target → Signing & Capabilities → change `com.mattchan.SFXLibrary` to `com.mattchan.SoundSearch`. Commit and push.

2. **Rename GitHub repo** — go to github.com/fozziedogg/SFXLibraryB → Settings → rename to `SoundSearch`. Then update local remote: `git remote set-url origin https://github.com/fozziedogg/SoundSearch.git`

3. **CLAUDE.md** — decide whether to clean it up or leave internal dev notes visible to engineers.

4. **Share repo** — make public or add engineers as collaborators in GitHub Settings → Collaborators.

5. **Fresh install note for engineers** — default DB is `~/Documents/SoundSearchDB/`, add a watched folder on first launch.

**Why:** App is called SoundSearch but bundle ID still says SFXLibrary. Engineers need clean repo access. All changes committed from dev and pulled on test as usual.
