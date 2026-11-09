# Repository security review — November 2026

Review date: November 8, 2026. Source baseline: `ece5391812c89027fcb42e3d1831cac12796c0ae`.
Method: source and workflow inspection, automated test results, sanitizer-backed
allocator fuzzing, and inspection of published provenance and access configuration.
This is a repository-focused review, not a third-party audit of LLVM or bundled libraries.

## Requirements and boundaries

The requirements in [SECURITY.md](../SECURITY.md) protect distribution integrity,
installation paths, compiler configuration, repository access, and release credentials.
The [architecture](architecture.md) separates dependency acquisition, staged native
builds, packaging, release publication, and consumer installation. Compiler inputs,
executables, local archives, and explicitly selected publishers are trusted inputs;
the toolchain is not a sandbox for malicious programs.

## Reviewed paths

| Boundary | Checks and result |
| --- | --- |
| Source acquisition | `scripts/lib/common.sh` checks cached and downloaded bytes against version-pinned SHA-256 values before promoting temporary files. `scripts/check-versions.sh` checks gitlink/pin consistency. |
| Action installation | `action/lib.ts` constrains version syntax, platform combinations, sanitizer names, digest syntax, and helper JSON value types. `action/main.ts` checks remote archive digests before extraction and checks installed add-on versions. External commands use argument arrays. |
| CLI installation | `src/elide-toolchain` verifies the checksum by default, extracts and compares add-on metadata before installation, and constrains add-on names. `--from` and `--no-verify` are explicit caller-controlled trust overrides. |
| Allocator | The C API, hint thresholds, backend dispatch, aligned allocation, and matching deletion paths were inspected. The forwarding backend is exercised under ASan and UBSan locally and ASan in hosted continuous fuzzing. Mimalloc partition heaps require the native fixtures. |
| PR and cache isolation | Fast checks run on hosted runners. Fork and Dependabot native changes cannot allocate the persistent runner pool. Cache scopes distinguish main, release, and review workloads. Version-pin checks precede native build allocation. |
| Release identity | The release workflow creates GitHub build attestations. Original signed bundles attached to the five recent releases cover all 30 archive digests. Tags and released binary bytes are preserved. |
| Repository access | Organization 2FA is enabled. PRs normally require one codeowner approval and passing gates. The explicitly configured repository-admin bypass is limited to pull requests. Tokens in workflows are scoped to their jobs. |

## Follow-up work

- Verify provenance automatically in consumer installation, in addition to the
  documented `gh attestation verify` command. Downloaded checksums detect corruption
  but do not independently authenticate a compromised publisher or mirror.
- Add archive member/path validation before extraction. Current installation trusts
  the selected publisher and explicit local archive overrides; checksums do not make
  a hostile archive safe.
- Validate numeric allocator environment settings with end-pointer and range checks.
  They currently use `strtoul` and are treated as trusted process configuration.
- Expand allocator tests to partition creation, allocation failure, configuration
  concurrency, and the mimalloc backend. The forwarding target cannot cover those
  backend-dependent paths.
- Add action entry-point integration coverage and whole-project coverage collection;
  library-only coverage does not measure the installer orchestration.
- Exercise credential recovery and persistent-runner rebuild procedures periodically.
  Cache namespaces do not isolate a compromised runner host.

Private reports continue through [the security reporting process](../SECURITY.md).

## Validation

The merged baseline passed repository hygiene, ShellCheck with GitHub code-scanning
publication, action and shell/Python tests, and a two-minute hosted allocator fuzz run.
Local allocator fuzzing also passed 100,000 inputs with AddressSanitizer and UBSan.
Release sanitizer fixtures include clean runs and expected-failure canaries. No new
native toolchain build was run for this review.
