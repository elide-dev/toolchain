# Toolchain debug artifacts

The existing Release optimization levels and hardening remain in place. Debug
generation is enabled alongside them for shipped LLVM tools, target components,
musl, LLVM runtimes and sanitizer variants. Static libraries retain their debug
information for downstream final links; archive DWARF does not prove final-address
contributions in any consuming executable.

Stage 90 runs after final linking and before its existing tool stripping step.
It retains ELF peers or Mach-O dSYMs for tools and debug-bearing shared libraries
in `dist/<bundle>-symbols/`. Tools are then stripped; shared libraries keep their
existing stripping behavior. Exact code addresses and bytes must remain equal.
The directory is read by `<bundle>.symbol-coverage.json` and uploaded separately
as `native-debug-toolchain-<platform>` for 90 days. The public bundle artifact
excludes it, and release consumers' existing artifact pattern does not match it.
Mach-O shared libraries use dSYM extraction even when they contain only a debug
map, because their DWARF still lives in link inputs at this point.

A preservation generation marker invalidates earlier stripped or incomplete
cached stage outputs. An ordinary rebuild regenerates the final links before
packaging; explicit operator `--from`/`--only` choices remain explicit.

The record binds binary/debug hashes, identity, architecture, debuglink CRCs and
DWARF inspection diagnostics. DWO references must resolve by identifier and are
packed for retention. Copied/prebuilt modules without DWARF are listed in
`preservation-gaps.json`; they are not silently certified by another module's
symbols. LLVM verifier failures remain explicit producer quality gaps. No
debug-information upload destination, source publication or release action is
added by preservation.


## Qualification workflow cleanup

The obsolete `diagnose-symbol-upload`, `qualify-live-symbols`,
`symbol-coverage-qualification`, and `symbol-ingestion-qualification` workflow
entrypoints are retired. For a native packaging check, manually dispatch
`job.build.yml` with one platform selected; ordinary PR/release matrices and
permanent symbol ingestion/gates retain their existing behavior.

The artifact lifecycle policy in `.github/qualification/artifact-lifecycle.json`
reserves seven days for future disposable task diagnostics and records how to
preserve required recovery evidence before expiry. It does not change existing
artifact expiry or the retention of permanent product evidence. The separate
`debug-quality-qualification` branch and its unfinished producer work are not
prerequisites of this cleanup and are not imported here.
