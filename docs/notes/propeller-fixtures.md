# Propeller verification fixtures (no branch sampling in CI)

The CI runners cannot record branch samples. GCE c4d (AMD Turin) exposes no PMU to the guest;
c4a (Axion, arm64) offers PMU STANDARD only via delete+recreate (local SSDs), and SPE is
unconfirmed. We are not changing the runners. Stage 95 therefore verifies Propeller from checked-in
perf data (spec §3.3a):

| Check | Fixture | What it proves |
|---|---|---|
| `check_propeller_golden` | `llvm-propeller/propeller/testdata/sample_with_bb_hash.{bin,perfdata}` + `sample_with_bb_hash_cc_directives.golden.txt` | the shipped `generate_propeller_profiles` reproduces upstream's golden cc profile (ignoring the optional `h` hash lines) |
| `check_propeller_relink` | `.../testdata/bimodal_sample_v2.{c,bin,perfdata.1,perfdata.2}` | profile → tool → relink of `bimodal_sample_v2.c` with the bundle's clang/lld (non-LTO `-fbasic-block-sections=list=`, ThinLTO `--lto-basic-block-sections=`) → functions in ld-profile order, `.text.hot` + `.text.split`, every `*.cold` symbol inside `.text.split`, program runs |
| `check_propeller_live` | the DeduBB fixture, recorded live | only on LBR (x86) or SPE (arm64) capable hosts; otherwise `WARN … skipped`. `REQUIRE_LBR=yes` turns the skip into a failure |

The fixtures ship inside the pinned `llvm-propeller` submodule, so the repository checks in no
binaries. Upstream regenerates them together with the tool.

## If `check_propeller_relink` breaks after an LLVM bump

The relink step compiles `bimodal_sample_v2.c` with *our* clang and applies a cc profile whose
basic-block IDs came from upstream's compiler. That works because the source is tiny and BB
numbering agrees (E26 in `memprof-dedubb-research.md`). If a new LLVM numbers blocks differently,
the layout evidence fails. Then record our own fixture **once** on an LBR-capable host and switch
the check to it:

1. Host: bare-metal x86-64 with LBR (Intel Skylake or newer, or AMD Zen 4+ with LBRv2), and
   `perf_event_paranoid ≤ 2`. Confirm with `perf record -b -e cycles:u -o /tmp/p -- true`.
2. Build `tests/fixtures/propeller/prog.c` (copy `bimodal_sample_v2.c`) with the **bundle** of the
   new LLVM: `x86_64-unknown-linux-gnu-clang -O2 -funique-internal-linkage-names -fbasic-block-address-map -fuse-ld=lld -Wl,--build-id prog.c -o prog.labelled`.
3. Record briefly: `perf record -e cycles:u -j any,u -c 100003 -o prog.perfdata -- ./prog.labelled`
   (a few seconds; keep the file ≤ 2 MB).
4. Check in `prog.c`, `prog.labelled`, `prog.perfdata`, and a `README` naming the bundle version.
   Point `check_propeller_relink` at them.

## Live collection is a consumer-side step

Profile collection (`perf record` with LBR or SPE) happens on the **consumer's own perf-capable
hosts** (bare metal or PMU-passthrough VMs), running their real workloads. The bundle ships the
tool and the compiler/linker support; it never collects profiles itself, and CI doesn't need to.
DeduBB is static: `--dedubb_profile` needs only the binary and its `.llvm_bb_addr_map`, so CI
verifies it end to end (`check_propeller_tool`, `check_dedubb_codegen`).

## Future option (not planned)

The self-hosted runner `sandbox-ci-x86` (labels `linux-amd64-bench`, `cloud-latitude`; likely
bare-metal Latitude.sh, AMD) may support AMD LBRv2/BRS. Once SSH access exists, probe it with the
commands in `perf_branch_capable` (`scripts/verify/checks-pgo.sh`). If it can sample branches, a
`REQUIRE_LBR=yes` job there would cover live collection.
