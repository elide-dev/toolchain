# CI and build caching

PR, main, and merge-queue workflows share fast tests, change classification, the
three-platform native build, action E2E tests, and an always-running `Gate`.
The classifier compares the complete Git diff with renames disabled. Documentation,
legal/governance files, workflow maintenance, action code (covered by its fast tests),
unit tests and repository tooling use fast validation. Native source, stage logic,
compiler flags, fixtures, pins and gitlinks require the native matrix. A source edit
that only adds/removes the exact first-party notice header does not rebuild native
code; mode changes, additions/deletions and any other code edits still do.

The license-packaging changes in this initial hygiene migration have explicit
old/new Git blob pairs in `.github/native-build-exemptions.json`. Those reviewed
metadata-only edits skip native compilation; changing either file again cannot
reuse that exemption unless the exact blob pair matches. Do not add compiler or
runtime changes to this manifest. All fast checks and the Gate still run.
Empty diffs, new branches and manual runs require full validation. Failed diff
detection fails the gate. There are no workflow-level path filters that could leave
required checks pending. Native build/E2E jobs are skipped for maintenance-only
changes, including the main push after merge. Release tags always build normally.


Fast shell/Python/action checks run on GitHub-hosted Ubuntu. Native Linux amd64,
Linux arm64, and macOS arm64 jobs use the existing `*-cipool` runners. Fork code
never executes on that pool. A non-Markdown fork PR's Gate fails until maintainers
review and promote it to a branch in this repository for native validation.
Do not change this to `pull_request_target` plus a PR checkout. Same-repository
write access is therefore a trust boundary; persistent runners need operational
isolation and routine rebuilding, especially for releases.

Main and release builds include sanitizer add-ons; PR builds omit them. Releases
also run fast checks before building, and require action E2E success before
publication. Superseded PR runs are cancelled; main runs are not.

## Cache policy

`actions/checkout` cleans workspace output; `build.sh --clean` additionally clears
stage output explicitly. Local stage stamps are resume hints, not build cache keys.
CI never restores a stamped stage tree or a packaged bundle as evidence of a build.

Downloads and ccache live outside the workspace under
`$HOME/.cache/elide-toolchain/v2/<scope>/<os>-<arch>/`. Scope is `main`, `release`,
or `review-<PR number or run ID>`. Main and release builds do not consume review
object caches. These directory names prevent accidental cross-use, but they are
not a security boundary against code with access to the runner's filesystem.
Administrators should expire inactive review directories on idle runners according
to available disk capacity; jobs must not delete caches that another build uses.

Downloads are checked against pinned SHA-256 values on every use. ccache checks
compiler content, source/header inputs, and frontend/sanitizer generators. LLVM
PCH is disabled when using a compiler launcher, avoiding relaxed PCH validation.
The default object-cache limit is 50 GiB per scope; `CCACHE_MAXSIZE` overrides it.
No shared writable remote cache or permissive restore prefix is introduced.

After a build, inspect verbose ccache statistics for direct/preprocessed hits,
misses, and uncacheable reasons. Full stage logs are retained for 14 days even on
failure. [Recorded build timings](notes/build-timings.md) explain the measured PCH
fix. Keep timing comparisons tied to source revision, platform, and warm/cold state.
For unexplained stale results, rerun with `USE_CCACHE=no` and clean stage output;
never mask a correctness issue by weakening validation.

## Repository checks and protection

`Repository hygiene` checks local documentation links, root license metadata,
immutable workflow action pins, first-party SPDX notices, actionlint, and
synchronized submodule pins. On pull requests and merge groups it checks each new
non-merge commit for a DCO trailer matching its author or committer. Historical
commits outside that range are not retroactively certified.
Unit tests run ShellCheck and TypeScript checking, test the CLI/build helpers and
setup action, and rebuild the committed action bundle to detect stale output.
The Bun build resolves `__dirname` at runtime through Node's `import.meta.dirname`
instead of embedding the builder's absolute dependency path.
Dependency review rejects newly introduced high/critical known vulnerabilities;
Dependabot checks Actions daily and Bun/submodules weekly. Native shell-managed
inputs still require manual advisory review.

Scorecard runs on main, weekly, and manually. It publishes results and retains JSON
for 90 days with job-scoped OIDC permission. CodeQL is not configured, matching
Myna's current policy. These checks are not comprehensive C/C++ static analysis.

`.github/rulesets/main.json` and `tags.json` are proposed settings, not proof that
GitHub has applied them. The main rules require signed commits, linear history,
one independent approval of the final push, CODEOWNERS review, resolved threads, and
`Gate`, `Repository hygiene`, and `Dependency review` on up-to-date branches.
Version tags cannot be updated or deleted. Multiple-reviewer requirements are
intentionally omitted. Apply the rules only after these check
names have been emitted successfully, so required checks cannot deadlock adoption.
No workflow receives an administrator token. After reviewing these definitions and
confirming the required checks exist, administrators can create them using:

```sh
gh api --method POST repos/elide-dev/toolchain/rulesets --input .github/rulesets/main.json
gh api --method POST repos/elide-dev/toolchain/rulesets --input .github/rulesets/tags.json
gh api repos/elide-dev/toolchain/rulesets
```

These commands create new rulesets; inspect existing rules first and use `PUT` with
the existing ID when updating. Read back each ruleset and verify its enforcement,
required check names, and lack of bypass actors. See [OpenSSF evidence](openssf.md).
