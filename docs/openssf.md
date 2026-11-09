# OpenSSF evidence and remaining work

Toolchain holds the [OpenSSF Best Practices Silver badge](https://www.bestpractices.dev/en/projects/16468).
[OpenSSF Scorecard](https://github.com/ossf/scorecard) separately measures repository
security practices.

## Autofill the badge application

Run `mise run openssf` (or `python3 scripts/best-practices.py`) and open
`dist/openssf.html`. The standalone page uses OpenSSF's official proposal links;
it does not need credentials or submit answers. The page opens Toolchain project 16468. Open each Passing/Silver link in sequence
and save before moving on.

Answers reflect the saved Silver application as of November 8, 2026. Unanswered criteria have empty notes and are omitted from
autofill links. Entered answers are passed through without additional confirmation
prompts. `.bestpractices.json` also provides repository automation proposals.
Criteria metadata follows the official `ossf/best-practices-badge` schema.

The live review policy requires **one approving reviewer**, with the extra-approval
setting disabled. Branch and version-tag protections are active. The November 8,
2026 Scorecard run after Silver recognition reported **7.2/10**.

The standalone page also provides targeted cleanup links for older generated
notes. They override only the listed justification fields, preserving saved status
answers. Open each link and choose Save and exit.

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
- Extend allocator fuzzing to the mimalloc backend and persist a shared corpus.

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
