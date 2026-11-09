# Releases and verification

Releases use CalVer tags `vYYYY.M.N` (month not zero-padded). Review the source
revision and compatibility changes before creating a new version tag. Never move
a published tag or overwrite an existing artifact to improve metadata or a score.

## Maintainer checklist

1. Update `TOOLCHAIN_VERSION`, dependency pins/gitlinks and checksums as needed;
   run `mise run test` and `mise run lint`. Review upstream security advisories and
   third-party notices. Describe compatibility changes and upgrade steps.
2. Obtain independent review of the final revision. Require full native CI for
   compiler, sysroot, allocator, action, and build changes; unit tests alone are
   insufficient. Confirm runner integrity and available disk space before release.
3. Complete the [isolated release runner setup](slsa.md#enable-and-qualify) before
   tagging: the new release workflow requires `RELEASE_ISOLATION_READY=true`.
   Tag the reviewed main revision. The release workflow runs fast checks, builds
   all platforms including Linux amd64 sanitizer add-ons, verifies the bundles,
   and runs action E2E tests. Do not bypass a failing check.
4. The reusable release builder signs the actual archives on a fresh GitHub-hosted
   job after native build and E2E success. The publish job verifies checksums,
   expected add-ons, and source/signer-bound provenance before uploading archives,
   checksums, and SBOMs to GitHub.
   The same run's signed Sigstore bundle (`toolchain-provenance.sigstore.json`) and
   discoverable in-toto envelope (`toolchain-provenance.intoto.jsonl`) are attached
   alongside the archives and copied to the mirror. Only publication has
   contents writes; only the hosted provenance job has attestation/OIDC writes. Mirror publication runs after
   GitHub publication and updates the version directory and latest pointer.
5. Check the GitHub assets, attestations, and mirror bytes; retain links to the
   build and evidence in release notes. Document supported targets and known issues.
   For a partial mirror failure, repair the mirror using the already published
   bytes; do not rebuild and replace the GitHub release.

The attestation identifies the signing workflow and artifact digests. The
[Build L3 rollout](slsa.md) defines the new runner and signer boundaries.
Attestations are not an independent hermetic-build guarantee. Historical local builds must not be given retroactive
CI build provenance. No bit-for-bit repeatability claim is currently established.

## Consumer verification

Download the archive and its `.sha256`, then check both the digest and provenance
before extraction (substitute your actual asset path):

```sh
shasum -a 256 -c elide-toolchain-2026.11.5-linux-amd64.tar.xz.sha256
gh attestation verify elide-toolchain-2026.11.5-linux-amd64.tar.xz \
  --repo elide-dev/toolchain \
  --signer-workflow elide-dev/toolchain/.github/workflows/on.release.yml
```

Inspect the verification result for the intended source tag/commit and workflow;
repository identity alone does not identify your intended release. GitHub CLI uses
the trusted Sigstore/GitHub attestation roots; there is no project signing key to
fetch from the mirror. See [GitHub's artifact verification documentation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/verifying-the-provenance-of-binaries).
A historical asset without provenance cannot pass this check; do not silently
treat a checksum as equivalent evidence. Mirrored bytes must verify against the
same digest and provenance as the GitHub asset.

Extract into a new directory, run `elide-toolchain doctor`, and run your application's
tests before switching versions. Install sanitizer add-ons of exactly the same
version. Rebuild static consumers after library security updates; replacing the
compiler bundle does not patch already-linked executables.

For historical releases produced after the provenance-download change, you can also verify
using the downloaded full bundle (the bare in-toto envelope lacks the complete
certificate/verification material):

```sh
gh attestation verify "$asset" --bundle toolchain-provenance.sigstore.json \
  --repo elide-dev/toolchain \
  --signer-workflow elide-dev/toolchain/.github/workflows/on.release.yml
```

`$asset` is the archive you downloaded. Inspect the source revision and subject
digest as with API-based verification. Historical releases are not rewritten.

## Isolated release verification

For releases built by `job.release-build.yml`, use its signer identity rather than
`on.release.yml`. Resolve the intended release tag and commit before verification:

```sh
gh attestation verify "$asset" --bundle toolchain-provenance.sigstore.json \
  --repo elide-dev/toolchain \
  --signer-workflow elide-dev/toolchain/.github/workflows/job.release-build.yml \
  --signer-digest "$commit" --source-digest "$commit" \
  --source-ref "refs/tags/$tag" --deny-self-hosted-runners
```

`$commit` is the full reviewed source commit and `$tag` includes the `v` prefix.
The hosted-runner check applies to signing; build isolation is provided by the
single-job native guests. Historical releases continue to use the original
verification commands above. The Sigstore badge links to these verification
instructions; it does not imply that historical builds used the new isolated pool.
