---
name: streamlandmedia-merge
description: "Merged colleague's fork (streamlandmedia/soundsearch, unrelated git history) into main — library relocation feature, Sonoma deployment target"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9ee2661b-1758-44f5-80e4-6320f090e8c8
  modified: 2026-09-16T00:23:49.453Z
---

On 2026-09-15, user gained ownership of `github.com/streamlandmedia/soundsearch`, a fork
colleagues at Streamland Media had modified after being handed the app. That repo had **no
shared git history** with this repo's `main` (single `init commit`, no common ancestor) —
merged via `git merge --allow-unrelated-histories` on a throwaway branch
(`merge-streamlandmedia`) first, verified (declaration-diffed every conflicting file to
confirm their side was a strict superset, then built) before touching `main`.

**What their fork added** (now merged in): fault-tolerant database opening (no more
`try!` crash-loops), volume/UUID-based file identity so libraries survive a drive
remounting at a different path (`VolumeResolver`, `VolumeIndex`, `LibraryRelocator`,
`RelocateLibrarySheet` — see [[project_studio_prep]] and the "File identity / portable
databases" section of CLAUDE.md), a `LibraryDiagnostics` logger, and an expanded
`.gitignore` that dropped ~2277 vendored PTSL SDK doxygen doc files + `.DS_Store` from
tracking.

**Deployment target**: their fork set `MACOSX_DEPLOYMENT_TARGET = 14.4` (Sonoma) — lower
than main's prior `15.0` (Sequoia), which itself was a fix for Xcode silently bumping it to
`26.3`/Tahoe-beta (commit `509a26b`). 14.4 is now the floor to protect going forward — see
[[feedback_build_commit_push]] for the regression check added to the build workflow.

**Why:** Colleagues extended the app independently after receiving a copy; user wants their
work folded back in without losing anything built here (audio export, AppleEvent spotting,
browser features, etc.) or there (relocation feature, Sonoma compatibility).

**How to apply:** If asked about the relocation feature, volume identity, or why the
deployment target is 14.4, this is the origin. If streamlandmedia's repo gets more commits
later, it now shares history with this repo's `main` post-merge, so a normal `git fetch` +
merge/rebase will work — no more unrelated-histories dance needed.
