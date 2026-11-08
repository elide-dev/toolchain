# Security policy

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/elide-dev/toolchain/security/advisories/new).
If that route is unavailable, use the private contact details on
[the project lead's profile](https://github.com/sgammon). Do not put exploits,
credentials, private source, or sensitive crash dumps in public issues.

The latest published release is supported for security fixes. Older versions may
receive fixes at maintainer discretion; consumers should upgrade to the latest
compatible bundle and rebuild linked applications. This project does not promise
a fixed response deadline.

Include the version/commit, download source, platform/CPU, target triple, compiler
flags, minimal reproduction, and expected versus observed behavior. Identify
whether the issue affects installation, generated code, the allocator shim, a
bundled library, or CI. Reduced sanitizer reports are useful.

## Response procedure

An administrator assigns an owner, acknowledges the report, requests missing
reproduction details, and identifies severity and affected versions. Escalate
unattended reports to another administrator; prioritize confirmed critical issues.
Keep sensitive details in the private advisory while developing a fix and regression
test. Obtain independent review, run relevant native and sanitizer checks, and
publish through the normal release process. Coordinate disclosure with the reporter
and upstream component maintainers; request a CVE when appropriate. Publish affected
versions, impact, mitigation, and upgrade instructions. Credit reporters unless they
request anonymity. Record receipt, acknowledgment, confirmation, fix, and disclosure
dates so response handling can be audited.

## Security requirements and boundaries

The project protects the integrity of compiler distributions, target libraries,
installation paths, and generated build configuration. It is a local compiler and
installer, not a sandbox for hostile source code or binaries. Run untrusted builds
in an isolated, resource-limited environment.

- Source pins and SHA-256 checks constrain downloaded dependency substitution.
  A checksum fetched from the same compromised server does not authenticate a
  release; verify [signed provenance](docs/releases.md) and source identity too.
- The action/helper download and extract executable tools. Trust the chosen
  publisher, version, archive, and mirror. Local archive overrides intentionally
  trust the caller. Installation does not make third-party compiler code safe.
- Compiler drivers select sysroots and runtimes. Compatibility checks and relocation
  tests constrain accidental host-library linkage. Native programs remain responsible
  for valid pointers, ownership, lifetimes, and synchronization.
- Sanitizers detect specified classes of errors in instrumented code. Their canaries
  test detection; they do not establish absence of defects or instrument all foreign
  runtimes. See [sanitizer limitations](docs/reference.md#sanitizers).
- CI uses scoped tokens, immutable action pins, review gates, and separate cache
  scopes. Persistent runners remain a trust boundary: code executed there can modify
  the host. Cache directories do not provide security isolation between users.

Use the standard LLVM and library cryptographic implementations rather than adding
custom cryptography. TLS verification must stay enabled, credentials belong in
separate secret storage, and logs must not include tokens. Review new untrusted-input
paths for bounds, traversal, injection, and resource exhaustion. See
[architecture](docs/architecture.md) and [OpenSSF evidence](docs/openssf.md) for
validation and current assurance limits.
