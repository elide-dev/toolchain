# Roadmap: November 2026–November 2027

This is the intended direction, not a release-date guarantee. Propose changes in
GitHub Issues; the project lead prioritizes them with maintainers.

1. Make releases easier to adopt: concise installation instructions, explicit
   compatibility and sanitizer matrices, verified provenance, and complete license
   inventories for each distributed bundle.
2. Maintain LLVM, Rust compatibility, native libraries, and upstream security fixes
   while preserving the documented glibc/macOS and CPU baselines. Explain any future
   baseline change in release notes and migration instructions.
3. Keep fast PR triage and reliable full native validation; measure cache hit rates
   and build times without weakening cache correctness or runner trust boundaries.
4. Close the [OpenSSF evidence gaps](openssf.md): production coverage, automated style
   checks, repeatable artifact experiments, secure-development review, and demonstrated
   release continuity. Pursue Passing and then Silver with auditable evidence.
5. Expand regression cases for fat/distributed ThinLTO, clangd, allocator ownership,
   and sanitizer add-ons as adopter reports expose gaps.

Windows, cross-OS/cross-architecture bundles, arbitrary CPU baselines, and sandboxing
hostile compiled programs are outside this roadmap. A higher Scorecard score alone
is not a reason to weaken review or rewrite historical releases.
