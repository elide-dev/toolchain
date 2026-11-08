# OpenSSF evidence and remaining work

Target: a high [OpenSSF Scorecard](https://github.com/ossf/scorecard) result and the
[Best Practices Silver badge](https://www.bestpractices.dev/en/criteria/1).
These are different assessments. This repository does not yet claim a Passing or
Silver badge, a particular score, or completion of all Silver requirements.

## Autofill the badge application

Run `mise run openssf` (or `python3 scripts/best-practices.py`) and open
`dist/openssf.html`. The standalone page uses OpenSSF's official proposal links;
it does not need credentials or submit answers. Register the Toolchain entry first,
then open each Passing/Silver link in sequence, review it, and save before moving
on. The repository-URL lookup avoids hard-coding another project's badge ID.

Policy and licensing answers are included by default now that the repository
changes are published. Unanswered criteria have empty notes and are omitted from
autofill links. Entered answers are passed through without additional confirmation
prompts. `.bestpractices.json` also provides repository automation proposals.
Criteria metadata follows the official `ossf/best-practices-badge` schema.

The live review policy requires **one approving reviewer**, with the extra-approval
setting disabled. Branch and version-tag protections are active. The November 8,
2026 Scorecard run after activation reported **7.1/10**.

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

## Engineering work

- Measure production statement coverage across maintained languages against the
  Silver 80% threshold.
- Enforce the documented coding styles automatically for applicable maintained
  languages and expand native static analysis.
- Compare native archive hashes from controlled repeat builds, accounting for
  timestamps, metadata, host tooling and compression settings.
- Audit compiler/linker environment-variable handling and debug-info preservation
  across the staged build.
- Complete the per-component distribution license/source-offer inventory.
- Add production allocator fuzz targets alongside the existing sanitizer canaries
  and libFuzzer smoke test.
