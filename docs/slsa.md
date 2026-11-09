# SLSA v1.2 Build Level 3

Toolchain targets [SLSA v1.2 Build L3](https://slsa.dev/spec/v1.2/build-requirements)
using disposable native build guests and GitHub-hosted Sigstore signing. The
repository implements the release workflow, Linux/macOS guest lifecycle controllers,
and a supervisor for explicitly selected Actions runs. The first qualifying native
release is planned as `2026.11.6`, after the dependency updates and additional fixes;
existing release archives retain their original provenance and build properties.

## Release boundary

`on.release.yml` calls the input-free `job.release-build.yml`. That reusable workflow
requires a tag push and `RELEASE_ISOLATION_READY=true`, builds the tag's source,
runs the installer and sanitizer checks, and signs the resulting archive digests.
The version comes from the tag; sanitizer add-ons are always enabled. Callers cannot
supply a shell command, source revision, artifact path, or alternate builder.

Native build and test jobs have read-only repository permissions, with no OIDC or
attestation permission. They use these dedicated runner labels:

| Platform | Runner label |
| --- | --- |
| Linux amd64 | `linux-amd64-toolchain-release` |
| Linux arm64 | `linux-arm64-toolchain-release` |
| macOS arm64 | `darwin-arm64-toolchain-release` |

Each label must resolve exclusively to a newly provisioned, single-job guest.
A label or the readiness variable alone is not an isolation mechanism. Ordinary
CI continues to use the existing `*-cipool` runners and persistent caches.
Release builds get empty, job-private download and compiler caches; remote ccache
storage and sccache are disabled. Nothing is restored from another job's cache.

A fresh GitHub-hosted job inside the reusable release workflow downloads the
archives and signs them without checking out or executing repository code or
archive contents. Publication has no signing permission. It verifies each archive
against the downloaded Sigstore bundle, the exact source tag and commit, and the
reusable signer workflow and commit before uploading release assets.

`--deny-self-hosted-runners` in verification checks the **signing** runner. The
native guest lifecycle provides the separate build-isolation guarantee.
No additional approving reviewer is required by this Build L3 design.

## Provision one Linux guest

The controller `.github/scripts/release-runner.py` runs outside the build guest.
It uses existing `gcloud` and `gh` authentication; the guest receives only a
single-job JIT configuration. It creates a unique GCE VM with a Hyperdisk Balanced boot disk, waits for SSH through
IAP, starts one runner, and deletes the VM and its boot disk when the runner exits.
GCE also deletes the VM after a maximum 13-hour running lifetime if the controller
is lost. A running controller limits the runner session to 12.5 hours.

First create an approved image for each Linux architecture with:

- A clean, patched OS, build prerequisites, Docker, and a checksum-verified, pinned
  GitHub Actions runner at `/opt/actions-runner`, owned by `ci-agent`.
- No registered runner, credentials, workspaces, compiler caches, background
  build services, or shared writable mounts. Do not snapshot a used CI worker.
- A `ci-agent` account able to run the existing package setup and Docker checks.
  OS Login administrators must be able to invoke commands as this account.
- A protected image name with deletion/replacement restricted to image maintainers.
  Retain its image ID and provisioning revision with release infrastructure records.

Provide a private subnet with Cloud NAT for required outbound access, IAP SSH
access, and firewall rules that prevent cross-worker and private-service access.
There is no public IP or VM service account. Keep the controller outside that
subnet's build trust boundary. Its identity needs narrowly scoped instance/image,
OS Login and IAP permissions, plus GitHub permission to create/delete repository
JIT runners. Use workload identity and a GitHub App for an automated controller;
do not put controller credentials in images, instance metadata, or build secrets.

This command prints a plan and does not create resources:

```sh
python3 .github/scripts/release-runner.py \
  --project elide-cloud-sandbox --zone us-east1-b \
  --image projects/elide-cloud-sandbox/global/images/APPROVED_IMAGE \
  --arch amd64 --machine-type c4d-highmem-8 --subnet release-builders
```

Replace `APPROVED_IMAGE` with the actual lowercase image name. Add `--execute` to
create a billable guest and wait for one job. For arm64 use its approved image and
machine type. The controller never restarts or reuses an old VM. It is a single-job
primitive, not an autoscaler; the infrastructure controller must supply one guest
for every queued build or test job, and retain runner/VM lifecycle logs externally.
Use a dedicated repository runner group where available and restrict admission to
the reviewed reusable release workflows. Do not reuse an organization-wide runner
registration credential inside guests.

macOS uses `.github/scripts/release-macos-runner.py` on the arm64 host
`elide@10.5.0.15`. Each job receives an APFS clone of the sealed macOS image, with
no mounted host folders, clipboard, audio, or USB access. Softnet blocks guest
connections to the host, peers, and private networks; only DNS to the gateway is
allowed. Commands and JIT configuration travel over Tart's guest-agent channel,
not guest SSH. A separate launchd watchdog deletes job VMs after 13 hours, including
controller-loss cases. The previous persistent host runner has been uninstalled.

## Enable and qualify

1. Deploy both Linux images, the controller/network policy, and the macOS guest
   lifecycle. Exercise success, failure, cancellation and controller-loss cleanup.
   Confirm boot disks disappear and no guest can access another guest or controller.
2. Confirm only the dedicated release workflows can schedule these guests, and that
   build/test jobs cannot obtain cloud control-plane or signing credentials.
3. Set repository variable `RELEASE_ISOLATION_READY=true` only after all three
   platforms are available. Until then, tag-triggered releases fail the readiness
   check before allocating native runners. Normal CI and existing releases work
   as before.
4. Build the next reviewed release through the new workflow and verify all archive
   digests, source identity and signer identity. Retain that run and the runner
   lifecycle records as the first qualifying release. Then add the achieved SLSA
   Build L3 README badge linking to this evidence.

The `Provenance verification` workflow signs a small test fixture through a
separate reusable workflow. It verifies the expected identity and rejects a wrong
signer, wrong source revision, and modified bytes. It never builds LLVM and does
not produce release provenance. Fast tests also exercise readiness failures,
cache separation, publication rejection, and VM cleanup after failures.

See [GitHub's reusable-workflow guidance](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/increase-security-rating)
and [release verification](releases.md). SLSA levels describe artifact build
processes; adding a signature to an old archive does not change its build level.

## Deployed pool and qualification

The checked-in [pool configuration](../.github/release-runners/pool.json) records
Linux image names and numeric IDs, the immutable macOS base-image digest, the
controller host, and organization runner group 18 (`Toolchain Releases`). The
GCP network is `toolchain-release` in `us-east1`, with no peering, IAP-only SSH,
private-range egress denial, and NAT. Image-builder VMs are deleted after sealing.
Provisioning and installation scripts live in `.github/release-runners/`.

The runner group is restricted to this repository and explicitly selected workflow
references. GitHub requires those references to exist. Before `v2026.11.6` runs,
add its exact `job.build.yml` and `job.action-e2e.yml` workflow references to the
group; qualification uses only `release-runner-qualification.yml@refs/heads/main`.
Never add wildcard repository access or remove the workflow restriction.

Dispatch **Release runner qualification** once per platform. Each run creates two
sequential guests: the first writes an isolation sentinel and the second must have
a new runner identity and no sentinel. Both lack signing credentials. Supply their
run IDs to the supervisor from a trusted controller with `gh`, `gcloud`, Python,
and SSH access to the Mac:

```sh
python3 .github/scripts/release-pool.py \
  --run-id "$linux_amd64_run" --run-id "$linux_arm64_run" --run-id "$macos_run" \
  --logs "$HOME/toolchain-release-logs"
```

The supervisor starts at most one worker per platform, only for queued jobs in the
explicitly selected qualification or `v2026.11.6` release runs. It stops allocating
when those runs finish, retains controller logs, cleans up guests, and stops after
three worker failures on a platform. Run it on the trusted controller throughout a
release; no controller credentials are copied into guests. The GCE lifetime limit
and macOS watchdog remain active independently of the supervisor.

The qualification workflow does not build native toolchains or publish a release.
Keep `RELEASE_ISOLATION_READY` unset until the lifecycle qualification passes on
all three platforms. The achieved SLSA badge follows the verified `2026.11.6`
release; dependency PRs remain a separate integration step.


## Lifecycle evidence (2026-11-09 UTC)

The deployed images pin GitHub Actions runner 2.338.2 and its published SHA-256
checksums. The initial 2.336.0 image was rejected by GitHub as deprecated; its guests
were removed and the image references were replaced before release enablement.

The macOS [qualification run](https://github.com/elide-dev/toolchain/actions/runs/42554544027)
passed on two different arm64 guests. The successor had no predecessor sentinel,
shared toolchain cache, or signing credentials. A separate registered idle guest
was cancelled through the controller; the guest and GitHub registration disappeared.
The host watchdog also removed an expired job clone without a controller present.

A GCE guest configured with a 60-second maximum running lifetime and `DELETE`
termination action disappeared with its boot disk without controller cleanup.
The production controllers use the same provider lifetime mechanism with a
13-hour limit. Cancelling the initial Linux controllers removed their guests and
boot disks. Rejected runner registrations were removed as well. Image-builder
VMs and their disks were deleted after sealing the replacement images.


The arm64 pool uses `c4a-standard-16` (64 GiB RAM). During qualification,
`c4a-highmem-8` hit a zonal capacity shortage after its first successful job;
three bounded retries stopped allocation, and the standard shape started
successfully with the same sealed image and isolation policy.
