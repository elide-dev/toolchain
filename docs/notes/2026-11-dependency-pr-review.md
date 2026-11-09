# November dependency PR review

Checked 2026-11-09 UTC against upstream release metadata, commit comparisons,
GitHub repository security advisories, the repository's open Dependabot alerts,
and OSV queries for the currently pinned commits. No open Dependabot alerts or OSV
matches were returned; this is limited to those databases' coverage, not a claim
that the dependencies have no vulnerabilities.

| PR | Decision | Evidence |
| --- | --- | --- |
| #21 LevelDB | Retain stable 1.23 | [Latest release](https://github.com/google/leveldb/releases/tag/1.23); the proposal advances 93 commits beyond the release, with no identified advisory requiring that snapshot. |
| #22 Propeller | Validate the proposed commit | The existing policy tracks its default branch. One commit removes obsolete DenseMap sentinel interfaces; our pinned LLVM 23 implementation no longer uses them. All four local Propeller patches apply. Dependency CMake files are unchanged. |
| #23 Zstd | Retain stable 1.5.7 | [Latest release](https://github.com/facebook/zstd/releases/tag/v1.5.7); the proposal is a diverged development branch identifying itself as 1.6.0, with no identified advisory requiring it. |
| #24 Brotli | Retain fixed 1.2.1; prevent recurrence | [Security release](https://github.com/google/brotli/releases/tag/v1.2.1) fixes CVE-2026-111497. Proposed `028fb5a` is an ancestor of current `db24a98` and lacks fix `b418fa8`. |
| #25 zlib-ng | Retain stable 2.3.3 | [Latest release](https://github.com/zlib-ng/zlib-ng/releases/tag/2.3.3); the proposal is a diverged development branch identifying itself as 2.3.90, with no identified advisory requiring it. |

The proposed Brotli change would specifically revert the invalid-block-switch
handling in `c/dec/decode.c`, not merely change its version label. See the
[fix comparison](https://github.com/google/brotli/compare/028fb5a23661f123017c060daa546b55cf4bde29...db24a98aed38a16de78cc05ca15cdd8dc2a0d92d).

Keep native changes subject to full validation and one human approval on the final
revision. This dependency triage does not supply an approval or establish native
build compatibility. The stable-tag exceptions do not disable Actions/Bun updates,
Dependabot alerts, or the scheduled upstream advisory review.
