---
name: Build, commit, and push after meaningful changes
description: After completing a meaningful set of code changes, run xcodebuild, then git commit + push if build passes
type: feedback
---

After finishing a meaningful set of code changes, always:
1. Run `xcodebuild -project app/SFXLibrary.xcodeproj -scheme SFXLibrary -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -5` to verify the build
2. If it passes, `git add` the changed files, commit with a brief message describing what changed, and `git push`
3. Tell the user the build passed and it's been pushed (so they can pull to the test machine)

**Why:** User tests on a separate machine and wants to just `git pull` to get the latest.

**How to apply:** Do this at the end of every task, not after every individual file edit. If build fails, fix it before committing.
