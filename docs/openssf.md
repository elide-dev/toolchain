# OpenSSF evidence

Toolchain holds the [OpenSSF Best Practices Gold badge](https://www.bestpractices.dev/en/projects/16468).
[OpenSSF Scorecard](https://github.com/ossf/scorecard) separately measures repository
security practices.

## Autofill the badge application

Run `mise run openssf` (or `python3 scripts/best-practices.py`) and open
`dist/openssf.html`. The standalone page uses OpenSSF's official proposal links;
it does not need credentials or submit answers. The page opens Toolchain project 16468. Open each Passing/Silver/Gold link in sequence
and save before moving on.

Answers reflect the saved Gold application as of November 8, 2026. Unanswered criteria have empty notes and are omitted from
autofill links. Entered answers are passed through without additional confirmation
prompts. `.bestpractices.json` also provides repository automation proposals.
Criteria metadata follows the official `ossf/best-practices-badge` schema.

The live review policy requires **one approving reviewer**, with the extra-approval
setting disabled. Branch and version-tag protections are active. The November 8,
2026 Scorecard run after Hadolint integration reported **9.0/10**, including
10/10 for SAST, fuzzing, licensing, and signed releases.

Saved-note cleanup is complete. Autofill proposals preserve existing saved answers.

## Repository evidence

| Area | Evidence |
| --- | --- |
| Adoption and design | [Quick start](../README.md), [reference](reference.md), [architecture](architecture.md), [roadmap](roadmap.md) |
| Governance and contribution policy | [Contributor agreement](../CONTRIBUTOR_AGREEMENT.md), [DCO](../DCO), [contributing](../CONTRIBUTING.md), [conduct](../CODE_OF_CONDUCT.md), CODEOWNERS |
| Reporting and security boundaries | [Security policy](../SECURITY.md), GitHub issues and private advisory route |
| Licensing | Apache-2.0 OR MIT first-party grant and [third-party inventory](../THIRD_PARTY.md) |
| Automated validation | [CI](ci.md), shell/Python/action tests, native fixtures, sanitizer canaries |
| Supply chain | SHA-pinned Actions, scoped permissions, version/hash pins, dependency review, Dependabot |
| Publication | Checksums, SBOMs, and [release provenance](releases.md) |
| Continuous assessment | `.github/workflows/scorecard.yml` retains published JSON results |

DCO 1.1 is enforced for new non-merge PR/merge-queue commits through the required
hygiene check. The contributor agreement makes inbound Apache-2.0 OR MIT terms
explicit. First-party source notices are automatically checked.

## Further improvements

- Measure production statement coverage across maintained languages.
- Enforce the documented coding styles automatically for applicable maintained
  languages and expand native static analysis.
- Compare native archive hashes from controlled repeat builds, accounting for
  timestamps, metadata, host tooling and compression settings.
- Audit compiler/linker environment-variable handling and debug-info preservation
  across the staged build.
- Complete the per-component distribution license/source-offer inventory.
- Extend allocator fuzzing to the mimalloc backend.

## Static analysis and fuzzing

ShellCheck analyzes first-party shell scripts on each PR and main push. Its SARIF
results are uploaded to GitHub code scanning. Actionlint and TypeScript checks
remain in the fast gates; CodeQL analysis is not configured.

ClusterFuzzLite runs the production allocator shim with its forward (libc) backend
under AddressSanitizer on PRs, main pushes, and a daily schedule. The target varies
configuration thresholds, disabled mode, allocation sizes, alignments, C allocation
APIs, and all eight hinted C++ allocation overloads. It checks hint classification,
alignment, partition reporting, writable allocations, and matching deallocation.
Only the shim and harness are compiled with the supplied fuzzing compiler; the
native toolchain pipeline is not invoked. Mimalloc partition heaps are outside
this target's coverage. See [.clusterfuzzlite](../.clusterfuzzlite).

The fuzz workflow uses the pinned ClusterFuzzLite builder directly with a sparse
checkout, avoiding recursive LLVM submodule downloads. Corpus caches are isolated
by Git ref; failures retain crash reproducers as workflow artifacts.

Original GitHub attestation bundles for v2026.11.0, v2026.11.1, v2026.11.2,
v2026.11.4, and v2026.11.5 are attached to their releases. All 30 archive digests
match the existing signed provenance. No binaries or tags were changed.
Signed-Releases scores 10/10 in the November 8 assessment.

## Gold achievement

Project 16468 achieved Gold on November 8, 2026, with Passing, Silver, and Gold
all at 100%. The standalone page includes all 23 official Gold criteria and the
saved application answers. Existing saved answers are preserved by default.

References include [starter tasks and review guidance](../CONTRIBUTING.md),
organization 2FA, source-notice checks, the
[November security review](security-review-2026-11.md), and the enforced Content
Security Policy on [elide.dev](https://elide.dev/).
The review policy remains one reviewer; Gold's two-person criterion means the
author and a separate reviewer, not two reviewers.

### Coverage reports

The `Coverage` workflow retains action LCOV and LLVM line/branch reports as the
`first-party-coverage` artifact. It compiles only the small allocator shim using the
hosted runner's compiler, without building LLVM or fetching its submodules.

The November 8 local baseline reports 70/70 instrumented lines for `action/lib.ts`;
`action/main.ts` is not imported by that unit suite. The allocator forwarding target
reports 138/167 lines (82.63%) and 58/92 branches (63.04%) across `core.cc`,
`hotcold.cc`, and `backend-forward.cc`. Line coverage is reported as line coverage,
not relabeled as statement coverage. These historical, scoped measurements are not whole-project totals.
