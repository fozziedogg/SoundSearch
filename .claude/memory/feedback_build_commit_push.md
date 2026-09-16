---
name: build-commit-and-push-after-meaningful-changes
description: "After completing a meaningful set of code changes, run xcodebuild, then git commit + push if build passes"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9ee2661b-1758-44f5-80e4-6320f090e8c8
  modified: 2026-09-16T00:23:26.719Z
---

After finishing a meaningful set of code changes, always:
1. Run `xcodebuild -project app/SFXLibrary.xcodeproj -scheme SFXLibrary -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -5` to verify the build
2. Check for deployment-target regression: `git diff -- app/SFXLibrary.xcodeproj/project.pbxproj | grep MACOSX_DEPLOYMENT_TARGET`. If any line raises it above the current floor (14.4, Sonoma, as of the 2026-09-15 merge with streamlandmedia/soundsearch — see [[project_studio_prep]] and check the live pbxproj for the current value if this memory is stale), revert that hunk before committing.
3. If build passes and the deployment target is unchanged (or intentionally bumped by the user), `git add` the changed files, commit with a brief message describing what changed, and `git push`
4. Tell the user the build passed and it's been pushed (so they can pull to the test machine)

**Why:** User tests on a separate machine and wants to just `git pull` to get the latest. Separately, Xcode has silently bumped `MACOSX_DEPLOYMENT_TARGET` on its own before (commit `509a26b` had to walk it back from `26.3` Tahoe-beta to `15.0` after Xcode raised it unprompted) — this happens through certain GUI interactions (e.g. "Update to recommended settings"), not through opening the project. A colleague's fork later lowered it further to 14.4 (Sonoma) for wider compatibility, and that's now the floor to protect.

**How to apply:** Do this at the end of every task, not after every individual file edit. If build fails, fix it before committing. If the deployment target check flags an unintended raise, fix it and re-verify the build still passes at the lower target before committing.
