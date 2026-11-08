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

The page withholds answers backed by unpublished local changes until you confirm
those changes are on main. Unknown criteria are omitted; explicit maintainer
answers can be added with their evidence. `.bestpractices.json` also provides
repository automation proposals once published. Criteria metadata was checked
against the official `ossf/best-practices-badge` criteria on 2026-11-08.

The review policy intentionally requires **one approving reviewer**, never two or
more. Keep the other proposed protections; accept any Scorecard ceiling associated
with omitting multiple reviewers. There was no public Toolchain Scorecard report
at the API endpoint when checked on 2026-11-08, so no numeric score is claimed.

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
explicit. First-party source notices are automatically checked. The DCO badge
answer remains unanswered until historical contributor certifications are audited;
new policy does not establish that every earlier contributor has certified it.

## Evidence still needed

- Apply and read back repository rules after the new required checks have run.
  No rulesets were configured at inspection on 2026-11-08. Verify dependency alerts, token defaults, and runner access policies in GitHub settings.
  Private vulnerability reporting was confirmed enabled.
  Security updates, secret scanning, and push protection were already enabled.
- Register or locate the project's Best Practices entry; complete Passing before
  Silver. Answer every criterion with evidence and justification. Do not copy
  Myna's badge ID, review history, personnel assertions, or certification answers.
- Verify that another administrator can recover every release credential and
  operate runners/mirror publication within a week. Admin access for sgammon,
  darvld, and TravisCow was verified, but credential recovery was not.
- Measure production statement coverage across maintained languages against the
  Silver 80% threshold. Test counts and fixture success are not coverage evidence.
  Audit regression-test additions over the required six-month period.
- Enforce the documented coding styles automatically for all applicable maintained
  languages; ShellCheck and TypeScript typechecking alone are insufficient.
  Audit strict warning flags and native static/dynamic analysis evidence.
- Demonstrate repeatable outputs from controlled independent builds and compare
  hashes. Current archive timestamps, generated metadata, host tool versions,
  compression settings, and build paths require investigation. Do not claim that
  deterministic source pins alone imply reproducible artifacts.
- Audit standard compiler/linker environment-variable handling and debugging-info
  preservation in all stages against the Silver build criteria; the toolchain's
  fixed target profiles and release stripping require explicit assessment.
- Complete bundled license/source-offer inventory, including glibc RPMs, Linux UAPI
  headers, optional libraries, transitive sources, and setup-action dependencies.
- Record secure-development expertise, threat/design review, advisory dispositions,
  vulnerability response/credit history, accessibility and localization assessment,
  and evidence supporting every remaining Passing/Silver answer.

Use the Scorecard JSON to prioritize actual gaps. Review history, maintainer
activity, external badge certification, and historical unsigned releases cannot
be fixed by adding a workflow file. Never fabricate reviews or attestations,
weaken protections, or rewrite releases to increase the score. Once an achievement
is actually attained, link it from the README within 48 hours.
