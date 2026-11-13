# Third-party components

The root Apache-2.0 OR MIT license covers first-party code only. Source submodules,
patch context, dependencies of the setup action, and bundled libraries retain
their upstream copyrights, notices, and licenses.

The machine-readable source inventory is `.gitmodules` plus gitlinks and
`versions.env`. Downloaded inputs have URL/version/hash declarations in
`versions.env` and the consuming stages. `action/package.json` and `action/bun.lock`
record the setup action's dependencies. Every bundle includes `manifest.json` and
`sbom.cdx.json` under `share/elide-toolchain/`; releases also carry an external SBOM.
These inventories are not a license-compliance certification.

Major sources include LLVM/Clang (Apache-2.0 with LLVM exceptions), musl (MIT),
the official Rust toolchain binaries (Apache-2.0 OR MIT, with the third-party
notices shipped under `share/elide-toolchain/licenses/rust/`),
glibc (LGPL and associated notices), Linux UAPI headers (file-specific syscall
exceptions), and the libraries selected in `versions.env`. Consult each pinned
upstream source for the authoritative terms, including optional components and
transitive dependencies. The macOS SDK is supplied by the user's Xcode installation
and is not redistributed as part of this project's license grant.

Package metadata preserves first-party license texts and the LLVM notices already
collected by stage 90. A complete per-component distribution notice and source-offer
audit remains required before claiming license completeness for all bundled static
libraries and downloaded RPM contents. See [OpenSSF remaining work](docs/openssf.md).
Do not remove upstream notices or assume the root license relicenses a binary bundle.
