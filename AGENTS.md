# Working on Elide Toolchain

Read README.md, CONTRIBUTING.md, and docs/building.md before changing build behavior.
Read CONTRIBUTOR_AGREEMENT.md and DCO for contribution rights and sign-offs.
Keep changes scoped; preserve unrelated working-tree edits and published artifacts.

Use Bash 4+ for build scripts and tests. Keep src/elide-toolchain and src/shims/musl-gcc
POSIX sh; macOS workflow setup runs before Homebrew Bash is available and must remain
Bash 3.2 compatible. Do not modify submodule contents as a substitute for a maintained
patch in src/patches/. Keep gitlinks and versions.env pins synchronized.

Run `mise run setup`, `mise run test`, and `mise run lint` for fast checks. Run native
fixtures for compiler, linker, ABI, allocator, sysroot, and sanitizer changes. A mock
or dry run is not a native build. Never claim a build, badge, or security property
that was not verified. Do not launch multiple builds in one checkout.

Preserve the glibc 2.17 and macOS 12 deployment floors, host ISA requirements,
relocatable paths, libc++ linkage, and Linux fat ThinLTO archives. Keep Rust bitcode
compatible with the pinned LLVM reader. Sanitizer workloads need both clean cases
and expected-failure canaries. Do not link the normal mimalloc override into a
sanitized program. Review docs/reference.md for supported sanitizer combinations.

Downloads must be checksum-verified before use. Cache keys must account for implicit
compiler configuration. Do not relax ccache validation to make PCH cacheable; disable
LLVM PCH when a compiler launcher is used. Stage stamps are local resume hints, not
content-addressed build evidence. CI starts clean and reuses only download/object caches.
Keep review, main, and release cache scopes separate. Namespace separation does not
isolate a compromised self-hosted runner; do not run fork code there.

Pin third-party Actions by full commit SHA, keep checkout credentials disabled, and
use read-only workflow permissions with writes scoped to publication jobs. Keep
CodeQL unconfigured to match the current Myna policy; use existing ShellCheck,
actionlint, and TypeScript checks and document their limits. Never broaden token
permissions or bypass review merely to improve Scorecard. Rulesets and CODEOWNERS
changes must remain reviewable. Do not rewrite released bytes or tags or manufacture
provenance for historical local builds.

First-party code is Apache-2.0 OR MIT. Preserve third-party notices and package the
first-party licenses. Rebuild action/dist/main.js with pinned Bun after action source
or dependency changes. Keep adoption instructions short and put detailed build and
optimization material in docs/. Record incomplete OpenSSF evidence in docs/openssf.md.

Run `python3 scripts/source-notices.py` for first-party license headers. Preserve
shebangs, third-party license terms, and generated artifacts. DCO trailers must
reflect an actual certification by the author or committer: do not fabricate,
auto-append, or impersonate a human sign-off. Prepare commits only with the user's
authorized identity and certification. Preserve existing author/trailer attribution.

Use scripts/ci-changes.py to verify maintenance-only changes before publication.
Never expand native-build exemptions to hide compiler/runtime changes. Exact source
notice additions are safe to triage; native behavior or file-mode changes are not.
