# mise `github:` backend asset matching

Inspected: mise 2026.9.12 (installed locally), source tag `v2026.9.12`
(commit 1698dd8ff8308b6e39fee8ce1537ddf93f246a2a), cloned to a scratch dir.
Paths below are relative to the mise repo root.

Assets published: `elide-toolchain-<version>-<os>-<arch>.tar.xz`
(os = linux|darwin, arch = amd64|arm64; darwin is arm64 only), each with one top-level dir
`elide-toolchain/` containing `bin/`.

## Findings

- OS: `darwin` is recognised as macOS. Target match `src/backend/asset_matcher.rs:59`;
  asset-name regex `src/backend/asset_matcher.rs:131` (`darwin|mac(os)?|osx`);
  linux regex at `:126`.
- Arch: `amd64` is x64 and `arm64` is arm64. Target match
  `src/backend/asset_matcher.rs:69-70`; asset-name regex `:148`
  (`x86[_-]64|x64|amd64`).
- Format: `.tar.xz` is a recognised archive (`ExtractionFormat::TarXz`), scored 11
  at `src/backend/asset_matcher.rs:604-609`. A test with Elide-style names
  (`elide.linux-amd64.txz`) is at `:1800-1812`.
- Autodetect is the default when no `asset_pattern` is set:
  `docs/dev-tools/backends/github.md:70-86`.
- Single top-level dir: when `strip_components` and `bin_path` are both unset,
  mise auto-applies `strip_components = 1` if the archive has exactly one
  top-level entry and it is a directory. Docs: `docs/dev-tools/backends/github.md:354`;
  code: `src/backend/static_helpers.rs:757-765`, detection in
  `src/file.rs:2650-2664` (`./` prefixes skipped, `src/file.rs:2577`).
- `bin_path` is relative to the install dir after stripping, and setting it
  disables auto-strip (`docs/dev-tools/backends/github.md:419-425`). Without
  `bin_path`, mise looks for `bin/` in the install path
  (`docs/dev-tools/backends/github.md:461-462`).

## Decision

Autodetection picks the right asset on all three platforms; no `asset_pattern`
or `platforms` table is needed. Because mise auto-strips the single
`elide-toolchain/` directory, `bin/` lands at the install root and is found by
default, so `bin_path` is dropped (brief rule 3).

## README snippet

```toml
[tools]
"github:elide-dev/toolchain" = "2026.10.0"
```

Equivalent explicit form (no reliance on auto-strip; keeps the outer dir):

```toml
[tools]
"github:elide-dev/toolchain" = { version = "2026.10.0", bin_path = "elide-toolchain/bin" }
```

## Caveats

- Not tested against a live release (repo not yet published under this name).
  Once a release exists, verify with `mise install` and `mise which <tool>` on
  linux and macOS.
- Auto-strip requires the archive to have exactly one top-level directory and
  no sibling files; keep it that way (Task 18 packaging). If a stray top-level
  file is added, switch to the explicit `bin_path` form.
- If the release also ships other assets (checksums, `.tar.gz`), autodetect
  still prefers the matching platform archive; keep names strictly
  `elide-toolchain-<version>-<os>-<arch>.tar.xz`.

## Sanitizer add-on assets (2026-10-05)

Releases now also carry `elide-toolchain-<version>-<os>-<arch>-sanitizer-<san>.tar.xz` (Linux;
`san` = asan, tsan, msan). Checked against mise `v2026.9.12` `src/backend/asset_matcher.rs`
(fetched from GitHub raw):

- `pick_best_asset` (`:329-357`) keeps assets with a positive score and picks the highest score,
  tie-broken by **shorter name** (`then_with(|| name_a.len().cmp(&name_b.len()))`, `:353`).
- `score_asset` (`:443-457`) = OS (+100, `:488`) + arch (+50, `:515`) + libc (`:551`; neither
  name has a gnu/musl token) + format (`.tar.xz` +11, `:589-611`) + preferred name + build
  penalties (`:632`: `debug`/`test`/checksum suffixes; `sanitizer-asan` matches none of them).
- The OS/arch/libc regexes (`:126-181`) match nothing in `-sanitizer-<san>`.

So the main bundle and an add-on score identically, and the main bundle wins because its name
is shorter. The plain `"github:elide-dev/toolchain" = "<ver>"` snippet keeps installing the main
bundle. `action/lib.test.ts` pins the naming invariant (each add-on name extends the main
bundle's name). If a later mise changes the tie-break, the fallback is an explicit
`asset_pattern` in the README snippet.
