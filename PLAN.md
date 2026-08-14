# On-demand native ARM Guix substitute builder

This plan adds native `aarch64-linux` Guix builds without running ARM builds
under QEMU on Nero. Nero remains the coordinator and public substitute server;
an AWS Graviton instance is started only for the build window and stopped when
the build finishes.

## Current state

- Nero is an `x86_64-linux` NixOS host.
- `guix-bitcoin-build.service` materializes profile closures and
  `guix-publish` serves them through Caddy.
- The local profile service currently enables only `x86_64-linux` in its
  `guixSystems` list. Its Bitcoin host list includes cross-compilation targets
  such as `aarch64-linux-gnu` and `arm64-apple-darwin`; these are not native
  `aarch64-linux` substitutes.
- Local AArch64 binfmt/QEMU was deliberately removed because bootstrapping the
  ARM toolchain under emulation was too slow and failed in practice.
- The existing wrapper-manifest and per-system profile layout are intended to
  support additional native systems.

## Target topology

```text
AWS EventBridge Scheduler
        │ starts instance
        ▼
ARM64 EC2 NixOS host
  native Guix daemon / offload builder
        ▲
        │ SSH Guix offload
        │
Nero x86_64 NixOS
  evaluates profile matrix
  publishes signed substitutes
  powers ARM host off after the job
```

The ARM host does not need the private substitute signing key and does not
serve public substitutes. Build outputs are returned to Nero, where the
existing signing and publishing flow remains authoritative.

## AWS instance and storage

Create an EBS-backed Graviton instance with:

- `t4g.xlarge` initially (4 vCPU, 16 GiB RAM);
- 128 GiB encrypted `gp3` root volume;
- default gp3 IOPS/throughput initially;
- no EFS, FSx, or S3 filesystem attachment;
- instance-initiated shutdown behavior set to `Stop`;
- root EBS `DeleteOnTermination` set to `false`;
- a security group allowing SSH only from Nero or the private administration
  path, with outbound HTTPS/Git access;
- no public HTTP/HTTPS listener.

The EBS root volume contains NixOS, `/gnu/store`, Guix profiles, source
caches, and build state. A normal stop/start preserves those volumes. Do not
use termination as the normal lifecycle operation; termination normally deletes
the root volume unless `DeleteOnTermination` is disabled.

The T4g instance is a cost-conscious starting point, not a permanent
performance guarantee. Set Guix build jobs to four. Monitor CPU credit metrics;
if sustained builds incur substantial surplus-credit charges, evaluate a
non-burstable Graviton instance.

## Initial AWS networking and installation

`nixos-anywhere` requires an SSH path during installation. For a private
subnet, use one of:

1. a bastion or existing VPC SSH path;
2. a temporary public IPv4 address restricted to the administrator's IP;
3. an equivalent provisioning path that provides SSH access.

After installation, remove any temporary public access. The steady-state path
should be Nero-to-ARM over the VPC/private network (or controlled IPv6), with
the ARM host's security group allowing SSH only from Nero.

## NixOS configuration

Add a dedicated flake host, for example
`nixosConfigurations.guix-arm-builder`, with `system = "aarch64-linux"` and a
new `hosts/guix-arm-builder/` directory. The host configuration should contain:

- generated hardware configuration;
- disk layout for the 128 GiB EBS root volume;
- hostname and SSH configuration;
- Guix and `guix-daemon`;
- four local build jobs;
- the SSH account/key used by Nero for Guix offload;
- no QEMU/binfmt registration;
- conservative Guix GC after the first successful build and verification;
- a persistent state path for `/gnu/store` and Guix caches.

Only public configuration belongs in the repository. Builder private keys and
any deploy credentials must be provisioned through the existing secret-management
workflow or an equivalent host bootstrap mechanism.

## Guix offload configuration

Configure Nero's Guix daemon to recognize the ARM host as a native builder.
The configuration must specify:

- the ARM host's stable private address or DNS name;
- the offload SSH key and authorized public key;
- `aarch64-linux` as the builder's supported system;
- four builder jobs (matching the instance size);
- a hard failure when no suitable ARM builder is available.

Before enabling ARM in the profile matrix, verify a small native build through
offload. The test must demonstrate that the builder executes on the ARM host,
not through local binfmt/QEMU. The production service must never silently fall
back to emulation.

## Profile service changes

Refactor the local profile service's system list so it can be configured per
host, then enable the following on Nero once offload is proven:

```nix
guixSystems = [
  "x86_64-linux"
  "aarch64-linux"
];
```

Keep the existing Bitcoin target-host list. It describes the six/eight Bitcoin
cross-platform targets and is independent of the native Guix system list.

The service should continue to:

1. update the managed Bitcoin checkout;
2. discover every `manifest_*.scm` file;
3. materialize each manifest for each native Guix system and Bitcoin target;
4. retain profile roots by system, commit, host, and manifest;
5. prewarm closures through Nero's local publisher;
6. verify complete substitute coverage before recording completion.

The ARM derivations will be offloaded to the native ARM host while profile
roots and public publishing remain on Nero.

## Automatic start and shutdown

Use two schedules with a boot buffer:

1. EventBridge Scheduler calls `ec2:StartInstances` for the ARM instance.
2. After the expected boot interval, Nero's build timer starts
   `guix-bitcoin-build.service`.
3. The service verifies that the ARM builder is reachable before evaluating
   `aarch64-linux` profiles.
4. The service runs the complete x86 and ARM matrix.
5. On success or failure, a `finally`/cleanup path asks the dedicated ARM host
   to run `systemctl poweroff`.
6. EC2 interprets that shutdown as `Stop`, leaving the EBS volume available for
   the next run.

The shutdown path must run on both success and failure, but must not terminate
the instance or delete its root volume. If a build exceeds the nominal window,
the instance should remain running until completion rather than being forcibly
stopped by a timer.

The EventBridge Scheduler role needs only the required `ec2:StartInstances`
permission for this instance. No AWS credentials should be placed on the ARM
builder merely to stop itself; the normal Linux shutdown path is sufficient.

## Failure handling and safety

- If the ARM host is unavailable, fail the ARM portion instead of enabling
  QEMU fallback.
- Keep the existing x86 build result and ARM result independently marked, so a
  failed ARM run does not falsely claim complete coverage.
- Do not run public publishing on the ARM host.
- Keep signing exclusively on Nero.
- Preserve profile roots until the corresponding closure has been published
  and verified.
- Enable GC only after confirming that profile roots and publisher cache
  retention are correct; retain a substantial free-space floor.
- Take an initial EBS snapshot after the first successful NixOS deployment.

## Implementation sequence

1. Add the ARM NixOS host configuration and hardware/disk files.
2. Install it with `nixos-anywhere` over a controlled SSH path.
3. Verify persistent EBS storage, Guix daemon startup, and native ARM builds.
4. Configure and test Nero-to-ARM Guix offload with a small derivation.
5. Add explicit builder reachability checks and disable any QEMU fallback.
6. Make `guixSystems` configurable and enable `aarch64-linux` on Nero.
7. Add the coordinated EventBridge start schedule and Nero build timer.
8. Add success/failure shutdown handling for the ARM instance.
9. Run one complete manual x86+ARM build and verify public substitutes with
   `guix weather` from both architectures.
10. Enable the nightly schedule, monitor build duration, disk usage, and CPU
    credits, then tune instance size or build parallelism if necessary.

## Verification checklist

- `nixos-rebuild` succeeds for the ARM host configuration.
- `guix-daemon` is active on the ARM host without binfmt/QEMU.
- Nero can offload a test `aarch64-linux` derivation to the ARM host.
- The service logs both `x86_64-linux` and `aarch64-linux` profile work.
- ARM store paths are present on Nero after offload and are published by
  `guix publish`.
- `guix weather --system=aarch64-linux --substitute-urls=https://guix.fish.foo`
  reports complete coverage for a representative manifest.
- A failed build still stops the ARM instance and leaves diagnostics on EBS.
- A stopped instance starts with the previous Guix store and checkout intact.
- No QEMU/binfmt process or emulated builder is involved.

## Operational commands to add

The repository should eventually provide Just recipes for:

- deploying/switching the ARM host;
- checking ARM host and Guix daemon status;
- testing Nero-to-ARM offload;
- starting the AWS instance manually;
- starting/following the Nero build job;
- checking the last ARM build and substitute coverage;
- stopping the ARM instance manually after an aborted run.

This plan intentionally does not commit AWS account identifiers, private IPs,
SSH keys, IAM role identifiers, or other environment-specific secrets.
