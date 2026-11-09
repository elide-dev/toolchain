# Contributing to Elide Toolchain

Start with an issue for a substantial feature or compatibility change. Small fixes
can go straight to a pull request. Explain the problem, resulting behavior,
validation, and remaining limitations; update user documentation with behavior
changes. Follow the [code of conduct](CODE_OF_CONDUCT.md) and use the
[security process](SECURITY.md) for sensitive reports.

## Contributor agreement and sign-off

Read the [contributor agreement](CONTRIBUTOR_AGREEMENT.md) and [DCO 1.1](DCO).
Submit first-party contributions under both Apache-2.0 and MIT alternatives,
retaining your copyright. Sign each new non-merge commit with `git commit -s` only
when you can certify the DCO. Repository hygiene checks author/committer trailers;
cryptographic commit signing is a separate requirement. Bot and AI-assisted
contributions follow the same provenance and certification rules. To check a local
branch, pass the full base and head commit SHAs to
`python3 scripts/check-dco.py --base BASE_SHA --head HEAD_SHA`.

## Development setup

Install Git, Python 3, Bash 4+, GNU rsync, and [mise](https://mise.jdx.dev/), then:

```sh
git clone https://github.com/elide-dev/toolchain.git
cd toolchain
mise install --locked
mise run setup
mise run test
mise run lint
```

On macOS, install Homebrew Bash and rsync (`brew install bash rsync`) and put
Homebrew's `bin` directory before `/bin` on PATH.
The fast setup fetches only `cflags`, not LLVM or every library. Without mise,
install the versions in `mise.toml`, initialize `cflags`, and run `tests/run.sh`,
`python3 -m unittest discover -s tests -p 'test_*.py'`, `actionlint`,
`python3 scripts/check-hygiene.py`, and `scripts/check-versions.sh`. In `action/`,
run `bun install --frozen-lockfile`, `bun run typecheck`, and `bun test`.

For native changes follow [building and verification](docs/building.md). A complete
LLVM build needs substantial memory, disk space, and time. Run builds sequentially
within one checkout; stages share their output directories. Focused shell tests
are available as `tests/run.sh <name-filter>`.

## Contribution requirements

Use `.editorconfig` for whitespace and indentation defaults.

- Add automated tests for major new functionality and a regression test for bug
  fixes. Document any case that cannot be reproduced in the automated suite.
- Shell code follows the Google Shell Style Guide with this repository's two-space
  indentation. Build scripts require Bash 4+; `src/elide-toolchain` and musl shims
  remain POSIX sh. Run ShellCheck and fix warnings rather than disabling it broadly.
- Python follows PEP 8; TypeScript uses strict checking and the existing two-space
  style; C/C++ follows LLVM style. Preserve upstream style in patches. Automated
  formatting coverage is still tracked in [OpenSSF work](docs/openssf.md).
- Preserve warnings and narrowly explain unavoidable suppressions. Changes to
  allocator ownership, libc compatibility, ABI, or sanitizer handling require
  native fixture execution on the affected platforms, including expected-failure
  sanitizer canaries. Shell mocks alone do not establish binary compatibility.
- Keep submodule gitlinks and `*_REV` pins in `versions.env` synchronized. Pair
  external download versions with verified checksums. Run `scripts/check-versions.sh`.
- When changing the action, use pinned Bun, rebuild with `bun run build` in
  `action/`, and commit `action/dist/main.js` together with its sources and lockfile.
- Do not commit build trees, credentials, private inputs, or unrelated edits.
  Preserve copyright, SPDX identifiers, upstream license texts, and patch attribution.

Contributions to first-party code are under `Apache-2.0 OR MIT`, at the recipient's
option. Submit only work you are authorized to contribute under these terms.
Third-party components retain their own licenses.

## Governance and continuity

Elide maintains this project. [Sam Gammon (@sgammon)](https://github.com/sgammon)
is the project lead and resolves technical direction disputes after discussion in
the issue or pull request. Repository administrators are
[@sgammon](https://github.com/sgammon), [@darvld](https://github.com/darvld), and
[@TravisCow](https://github.com/TravisCow); their admin access was verified on
2026-11-08. They handle reviews, issue triage, private security reports, CI, access
management, and [releases](docs/releases.md). CODEOWNERS routes reviews to them.
Contributors retain copyright in their contributions.

If a maintainer becomes unavailable, another administrator should take over
triage and releases within one week. Administrators must verify recovery of runner,
GitHub, and mirror credentials and record the exercise privately.
Review access whenever maintainers join or leave. Publish links to newly attained
project achievements in the README within 48 hours.

## Dependency review

Dependabot proposes Actions, Bun, and branch-tracked submodule updates. LevelDB,
Zstd, Brotli, and zlib-ng follow stable release tags through
`scripts/bump-submodules.sh`; generic submodule branch-tip updates are ignored for
these components because they can select development snapshots or omit release
security backports. Review release notes and advisories before changing those pins.
Review every submodule PR
against `versions.env`; automation does not update the corresponding pins for you.
Before releases and at least monthly, review upstream advisories for all bundled
libraries and checksum-pinned downloads, including glibc RPMs, Linux headers,
bootstrap LLVM, and Propeller dependencies. Record affected versions, advisory
links, and fixes or non-exploitability evidence in an issue or release checklist.
The dependency-review job cannot discover every native dependency from shell pins.

Fork PRs run fast tests on GitHub-hosted runners. Native changes must be reviewed
and promoted to a branch in this repository for the full build and action E2E
matrix before merge. The Gate deliberately fails for native-input fork changes;
never use `pull_request_target` to execute untrusted PR code on persistent runners.

## First-party source notices

Maintained shell, Python, TypeScript/JavaScript, C/C++, Rust and CMake sources carry
a copyright notice and `SPDX-License-Identifier: Apache-2.0 OR MIT`. Run
`python3 scripts/source-notices.py` to check, or add `--fix` to insert missing
headers. Executable shebangs stay first. Hygiene enforces this convention.
Submodules, upstream patches, generated action bundles and lockfiles retain their
upstream/generated contents; do not relicense those with this tool.

## Starter tasks

These tasks are small enough for a first contribution; each can use fast tests:

| Task | Completion check |
| --- | --- |
| Add negative tests for malformed mirror version responses in `action/lib.test.ts` | Cover empty responses, embedded whitespace, and unsupported version strings with mocked fetchers. Run the action tests and type check. |
| Add shell-quoting regression cases for paths containing apostrophes in `tests/unit/` | Exercise the installed helper's shell output and show that evaluating it round-trips the original path. |
| Add a bundle-upgrade example to `docs/releases.md` | Show separate installation directories, provenance verification, application testing, and rollback without overwriting the old bundle. |

## Review checklist

One reviewer other than the author reviews the final diff and relevant test results.
Reviewers check the problem and expected behavior, public interfaces and compatibility,
input handling and trust boundaries, error paths, dependency changes, license notices,
and test coverage. For native changes, check ABI, target floors, allocator ownership,
and sanitizer compatibility against the building guide. For workflow changes, check
runner eligibility, token permissions, pinned actions, cache isolation, and triage.

Use inline comments for concrete defects and the review summary for the overall
assessment. Approval means the change is useful, the checks appropriate to its risk
have passed, blocking findings are resolved, and the documentation describes the
resulting behavior. Re-review changed portions after a new push. Administrators may
use the documented PR bypass for exceptions; ordinary changes retain one approval.

## Account security

The elide-dev organization requires 2FA for accounts with repository access. Use a
passkey or hardware security key where possible; an authenticator app is preferable
to SMS. Keep recovery codes in protected storage separate from the primary device.
Review collaborator access when responsibilities change. Never share personal access
tokens or recovery codes in issues, pull requests, or build logs.
