## ADR-IOS-102: Every Package Version Is Pinned by a Tracked Package.resolved

**Status:** Active (2026-11-06; owner ruling, relayed by the coordinating session). Reverses the 2026-08-09 "closed as a decision" of IOS-BUILD-002 for the part that could be fixed without tracking anything inside the generated project.

**Context:** `project.yml` pins SwiftMail by `revision:` but declares every other package with `from:`. The resolved versions lived only in `TabMail.xcodeproj/.../Package.resolved`, which is generated and ignored, so each clone and worktree resolved on its own: the primary checkout's file had SwiftNIO SSL 2.37.2 (release builds come from there), most worktree caches 2.37.5, a fresh resolution 2.37.6. They vendor different BoringSSL revisions (2.37.5 and before: OpenSSL-lineage license; 2.37.6 and later: Apache 2.0), so the Acknowledgments screen could not state the license of the BoringSSL that shipped (#405), and a field bug could not be tied to the dependency versions of a build.

**Decision:**
1. **`Package.resolved` at the repository root is tracked** (the `.gitignore` entry for it is removed). It holds the versions of every package, direct and transitive. It starts as the primary checkout's file with SwiftNIO SSL moved to 2.37.6 (the owner agreed to that move).
2. **`Scripts/xcodegen.sh` copies it** into `TabMail.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` after generating, so Xcode, `xcodebuild` and the release lanes (which all go through that script) resolve exactly those versions. Nothing inside the generated project is tracked, which keeps the invariant the old known issue protected.
3. **Moving a package** means editing the root file (resolve in a scratch clone, copy the result back, commit it with a reason); the SwiftMail re-pin keeps editing `project.yml`'s `revision:` and the SwiftMail entry of the root file together. The generated copy is never edited.
4. **A test fences it** (`PackagePinTests`): the file exists and parses, every package `project.yml` names is pinned, SwiftMail's pin equals `project.yml`'s revision, the ignore file does not hide it, and the generator script copies it.

**Rejected:** tracking the file inside the generated `.xcodeproj` (rewritten on every generation); `exact:` versions in `project.yml` (one place per package, and no record of transitive versions).

**Consequence:** a package update is now a commit; supply-chain and "which versions did this build use" questions are answered by the release tag. Dependabot-style drift no longer arrives silently on a fresh clone.
