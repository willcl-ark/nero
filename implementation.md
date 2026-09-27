# Implementation Notes

## Connect Bitcoin CI containers to niks3

- Confirmed the CI runner's `/nix` store was already bind-mounted into the
  Docker container, but the host-side niks3 action's temporary Nix config and
  daemon socket were not visible there.
- Updated `/home/will/src/core/bitcoin/worktrees/pr-35877/ci/test/02_run_container.py`
  to pass `NIX_USER_CONF_FILES`/`NIX_CONFIG` through and mount the runner's
  temporary `niks3` directory at the same path inside the container.
- Committed the Bitcoin-side fix as `a772e58e416`; it must be pushed before
  rerunning the workflow.
- Follow-up failures showed container builds were attempting to create store
  paths directly in the shared store. An intermediate `NIX_REMOTE=daemon`
  experiment was superseded by the runner-side prebuild below.
- Reworked the CI path so the GitHub runner prebuilds the Windows Nix shell,
  where niks3-action can read from and upload to the cache. The Docker image
  skips its duplicate Nix build in this mode, while local Docker builds use
  the public cache temporarily and retain their BuildKit caching. The final
  commits are `c2954b691dd`, `941ec683b1f`, `83c689d4dba`,
  `3d5344a6fd5`, and `eb2edd2e257`; obsolete container-side niks3 plumbing
  was removed.

## Add niks3-backed Nix cache on nero

- Added the upstream niks3 NixOS module as a pinned flake input directly to
  this deployment.
- Configured a private Cloudflare R2 `nix-cache` bucket with niks3's read
  proxy, exposed through `https://cache.nix.fish.foo` by the existing Caddy
  instance.
- Enabled GitHub Actions OIDC uploads for `bitcoin/bitcoin` and
  `willcl-ark/bitcoin`, using the cache URL as the OIDC audience.
- Kept the niks3 API token, signing key, and R2 credentials in sops-managed
  runtime files; the R2 access and secret values still need to be added before
  deployment.
- Kept the niks3 configuration in this host repository because the upstream
  module already provides the reusable service integration; no local wrapper
  module is needed.

## Serve pruned node data from nero

- Added a `nero`-specific Caddy route on `bitcoin.fish.foo` at
  `/pruned-840k/*`.
- The route uses `handle_path` so files under `/data/pruned-840k` are served
  without exposing the local directory name as part of the filesystem root.
- Kept this on the existing `bitcoin.fish.foo` virtual host to avoid requiring
  new DNS records or a separate certificate.

## Prewarm Guix substitute cache after Bitcoin Core builds

- Added a post-build prewarm step to `guix-bitcoin-build.service`.
- The step walks the full `guix gc --requisites` closure for every default
  Bitcoin Core Guix host profile and requests each local `.narinfo` until
  `guix publish` returns success.
- The publish cache uses `--cache-bypass-threshold=0` so warmup only advances
  when the item has actually been baked into the cache, preserving cached
  responses and progress bars for later clients.
- Negative TTL advertising is disabled so a client that races a cache miss does
  not cache a transient baking 404.
- A final `guix weather` pass through the same pinned Guix time-machine
  revision checks each host before `last-built-commit` is written.

## Put Anubis in front of Forgejo

- Added a `forgejo` Anubis instance on `nero` and left Forgejo bound to its
  existing localhost HTTP port.
- Caddy now proxies `code.fish.foo` to Anubis, while Anubis forwards accepted
  requests to Forgejo.
- Enabled Open Graph passthrough so link previews can keep working through the
  Anubis challenge layer.
- Configured Caddy to trust Cloudflare proxy ranges and pass the client IP from
  `CF-Connecting-IP` to Anubis as `X-Forwarded-For` and `X-Real-IP`, preserving
  Anubis' default JWT binding to the real client IP.
- Kept this scoped to Forgejo because the seed dump and Guix substitute
  endpoints are machine-consumed services and should not receive a browser
  proof-of-work challenge.

## Use full-mirror Forgejo fork

- Added `willcl-ark/forgejo` branch `full-mirror` as a locked non-flake input
  and overrode `pkgs.forgejo` for `nero` to use it as the package source.
- The override removes the source checkout's `vendor/` directory during
  `postPatch` because Nixpkgs already builds Forgejo with a fixed Go module
  vendor derivation. Keeping the fork's stale vendor tree makes Go enter vendor
  mode against mismatched `go.mod` metadata.
- Disabled package checks for this deployment override because the fork builds
  but Forgejo's package test suite currently fails in the Nix sandbox while
  trying to execute generated repository hooks.
- Left Forgejo's `[oauth2] ENABLED` setting enabled because the fork expects
  OAuth2 signing-key settings to be initialized during startup. External OpenID
  sign-in and sign-up remain disabled separately.

## Split service modules into standalone flakes

- Created standalone module repos under `/home/will/src/nix/modules` for
  `stuntman`, `radicle-mirror`, `bitcoin-core-guix-substitutes`,
  `bitcoin-dnsseed`, and `forgejo-site`.
- Switched the deployment flake to consume those repos as pinned local
  `git+file` inputs. Plain external `path:` inputs were avoided because pure
  flake evaluation resolves relative paths from the copied store source, and
  absolute `path:` inputs remain unlocked.
- Kept deployment-owned values in this repo: domains, secret file paths, host
  sizing, and the custom Forgejo package overlay.
- Moved implementation details into module interfaces: DNS seed CoreDNS/proxy
  wiring, Guix substitute data placement, STUNTMAN ports, Radicle mirror
  `dataDir`, and Forgejo Caddy/Anubis/admin bootstrap.

## Fetch service modules from GitHub

- Switched the service module inputs from local `git+file` URLs to
  `github:willcl-ark/...` inputs so remote `/etc/nixos` evaluation does not
  require `/home/will/src/nix/modules` to exist on the target host.
- Added `just update-modules` for refreshing only the reusable service module
  inputs from GitHub.
- Split remote deployment into a shared `sync-remote` helper, `just switch`,
  and `just build-remote`. `just build-remote` exercises the same remote flake
  path as `just switch` without activating the result.

## Consolidate service modules into a Nix collection repo

- Created `/home/will/src/nix` as the new top-level collection flake for the
  reusable service modules previously split across individual repos.
- Exposed named module outputs only, for example
  `nixosModules.bitcoin-dnsseed` and `nixosModules.stuntman`. No `default`
  module imports every service, so consumers opt into each module explicitly.
- Kept `dnsseedrs` as a collection flake input and threaded it only into the
  Bitcoin DNS seed module.
- Switched this deployment flake to a single `will-nix` local `git+file` input
  pinned to the collection repo commit. Remote build/switch recipes sync the
  collection to `/etc/nixos/nix` and override `will-nix` to that remote path so
  the workflow still works before the collection is pushed to a forge.

## Fetch Nix collection repo from GitHub

- Switched `will-nix` from the local `/home/will/src/nix` git input to
  `github:willcl-ark/nix` after the collection repo was pushed.
- Removed the extra `/home/will/src/nix` remote sync and `--override-input`
  plumbing from `just switch` and `just build-remote`; remote evaluation now
  uses the locked GitHub input directly.

## Move dnsseedrs Nix interface into the collection

- Added the `dnsseedrs` package and generic `services.dnsseedrs` NixOS module
  to `/home/will/src/nix`, while leaving the Rust source repository at
  `/home/will/src/dnsseedrs`.
- Updated the higher-level `bitcoin-dnsseed` module to import the local
  `dnsseedrs` module and pass a `package` option through to each dnsseedrs
  instance.
- Left the deployment flake pinned to the previously pushed `will-nix` GitHub
  revision until the new collection commit is pushed.

## Consume collection-owned dnsseedrs from deployment

- Updated the deployment flake after pushing `/home/will/src/nix` so it locks
  `will-nix` at the collection commit that owns `packages.dnsseedrs` and
  `nixosModules.dnsseedrs`.
- Removed the deployment's direct `dnsseedrs` input and the corresponding
  `will-nix.inputs.dnsseedrs.follows` override because the collection no
  longer exposes or needs that input.

## Use STARTTLS for Forgejo mail delivery

- Switched `nero`'s Forgejo mailer from implicit TLS on
  `smtp.mailbox.org:465` to STARTTLS on `smtp.mailbox.org:587`.
- The direct SMTP probe from `nero` timed out on port 465, while port 587
  accepted TCP connections immediately, matching mailbox.org's submission
  path.

## Enable signet DNS seed crawling

- Enabled the signet `bitcoinDnsSeed` instance on `nero` because Cloudflare
  already delegates `seed.signet.bitcoin.fish.foo` to `ns.fish.foo`.
- Added two IPv4 bootstrap peers from `seed.signet.achownodes.xyz` using the
  signet P2P port `38333`, giving `dnsseedrs-signet` initial addresses to
  crawl and avoiding an empty signed zone response.

## Restore Guix substitute public paths

- Kept `/gnu/guix-bitcoin` searchable with mode `0751` so `caddy` can serve
  public key files from `/gnu/guix-bitcoin/public` and `guix-publish` can write
  its owned publish cache.
- Re-applied that mode from both `guix-publish` and `guix-bitcoin-build`
  startup hooks because the reusable module's build startup hook recreates the
  parent data directory.
- Left build-owned subdirectories at their existing private modes.

## Run an independent GitHub metadata backup

- Imported the upstream `0xB10C/nix` GitHub metadata backup module directly
  instead of copying it into the local module collection. The flake lock pins
  the upstream revision and its `nixpkgs` input follows this deployment's pin.
- Configured a daily, persistent `bitcoin/bitcoin` backup at 06:00 UTC. The
  backup and Forgejo push credentials are separate sops secrets readable only
  by the module's `gmb-bitcoin` service user and `github-metadata` group.
- Ordered both oneshot services after sops secret installation. The backup
  pushes over HTTPS to the existing Forgejo repository as `willcl-ark`.
- The upstream module hardcodes the `master` branch and its `enable` option is
  currently ignored. The configured instance is intentionally enabled, so no
  local compatibility wrapper was added.
- Before the first run, disable Forgejo pull mirroring and seed
  `/var/lib/github-metadata-backup/bitcoin` from the existing Forgejo clone.
  This preserves `state.json` and the shared commit history, avoiding a full
  backup commit with unrelated history and a conflicting rebase.
- Keep the timer runtime-masked during activation and seeding. After one
  successful manual target run advances Forgejo with a fast-forward commit,
  unmask and start the timer.
- The production cutover preserved Forgejo `master` at
  `b976f2dddb1e2a3e8536c74ccf29225ef4afe680`, cloned that history into the
  service destination, and completed an incremental backup from the existing
  July 15 state. The first local run loaded 7 issues and 149 pull requests.
- The service pushed commit `e75344ca19b4c256b6aef98dd1edc6c430a602cc`
  as a direct child of the cutover commit. Both oneshot units exited
  successfully and the persistent timer is scheduled for 06:00 UTC daily.
- `nixos-rebuild switch` applied the configuration but returned exit 4 because
  the long-running legacy `dbus-daemon` timed out while reloading. The same
  timeout occurred on earlier June switches; D-Bus remained active and no
  units were left failed, so this was kept separate from the backup cutover.

## Diagnose Nero storage capacity

- The machine exposes two Samsung 512 GB NVMe namespaces, for about 1 TB raw
  capacity in total rather than the expected 2 TB. No additional disk or
  unallocated partition, PV, VG, or LV capacity is visible to Linux.
- The first NVMe is fully allocated through LVM to the roughly 468 GiB root
  filesystem. The second is a separate roughly 468 GiB ext4 filesystem at
  `/gnu`, so its free space cannot be used by `/` without a storage migration.
- Root usage is dominated by `/var/lib/forgejo/dump`, which held 25 daily
  Forgejo ZIP dumps totaling about 263 GiB. The configured tmpfiles retention
  is four weeks, so this is expected to approach roughly 28 daily dumps before
  pruning begins.
- Other notable root consumers were the live Forgejo data (about 15 GiB
  excluding dumps), `/root/.bitcoin/signet` (about 23 GiB), `/data` (about
  13 GiB), the Nix store (about 14 GiB), logs (about 4 GiB), and the new
  metadata backup checkout (about 5 GiB).
- Reduced the local Forgejo dump retention from the NixOS default of four
  weeks to seven days. This keeps a recent local recovery window while
  reducing steady-state dump usage from roughly 300 GiB to about 80 GiB;
  off-host backups remain a separate requirement for machine-loss recovery.
- After deploying the new rule, verified the tmpfiles dry-run and pruned 18
  expired archives. Seven dumps from July 11 through July 17 remain, dump
  usage fell from 263 GiB to 75 GiB, and root free space increased from
  108 GiB to 290 GiB.

## Build native Guix substitute profiles

- Replaced the deployment's full Bitcoin Core build with a local service
  override that only materializes Guix profiles. Bitcoin build artifacts live
  outside `/gnu/store` and cannot be served by `guix publish`.
- Discover every `contrib/guix/manifest_*.scm` entry point so later manifest
  splits are cached without another deployment change. Each manifest is built
  for every supported Bitcoin target host.
- Keep profiles as GC roots below
  `/gnu/guix-bitcoin/profiles/<system>/<commit>/<host>/<manifest>` and clean
  commit directories using the module's existing retention period.
- Source Bitcoin Core's `contrib/guix/libexec/prelude.bash` and use its
  `time-machine` helper rather than duplicating the pinned Guix revision. A
  Bitcoin commit that updates the pin is therefore handled automatically.
- Materialize the full manifest matrix for both `x86_64-linux` and native
  `aarch64-linux`. The latter uses NixOS static QEMU binfmt registration so
  Guix can run AArch64 builders inside isolated build environments.
- Prewarm every rooted closure through the local `guix publish` endpoint and
  require `guix weather --system=<system>` to report complete coverage before
  recording that system's completion marker.
- Added Nero's public substitute signing key to Guix's declarative authorized
  key list. The key is committed in plaintext because it is public, while the
  private signing key remains SOPS-encrypted.
- Preserve the NixOS Guix module's official authorized keys when extending the
  list. This generates `/etc/guix/acl` at build time and removes the need for a
  manual `guix archive --authorize` command after deployment.
- Generate wrapper manifests for each Guix system rather than modifying the
  Bitcoin checkout. The wrapper parameterizes `%current-system` before loading
  the original manifest, so AArch64 derivations use the same build triplet as
  native ARM builders.
- Keep Nero's scheduled service x86_64-only until a native ARM remote builder is
  available. Removed local AArch64 binfmt emulation so QEMU cannot turn the
  substitute job into an hours-long ARM toolchain build.

## Prepare native AWS ARM builder

- Added an `aarch64-linux` NixOS host for an EBS-backed Graviton builder with a
  native Guix daemon, four build users, and conservative garbage collection.
- Added declarative Guix offload configuration on Nero, gated until the ARM
  host key and private builder address are supplied. The existing profile job
  remains x86-only until that gate is enabled, preventing accidental QEMU
  fallback.
- Made the native Guix system list configurable and added Just recipes for ARM
  deployment/status plus manual substitute-job control.
- Added mutual Guix archive-key bootstrap: the ARM builder authorizes Nero's
  public key, while Nero accepts the builder public key once it is added as a
  public file. The offload SSH private key is declared as a gated sops-nix
  secret and is not stored in the repository.
- Added a preflight `guix offload test` whenever `aarch64-linux` is enabled;
  NixOS evaluation asserts that ARM profiles cannot be enabled without the
  declared offload configuration.
- Install Nero's existing SOPS-managed Guix archive key at
  `/etc/guix/signing-key.sec` before `guix-daemon`; `guix offload test` uses
  this conventional daemon key path. The daemon must be restarted after the
  key pair is first provisioned so it does not retain a missing-key state.
- Automatic ARM-builder poweroff is currently disabled while native offload is
  being diagnosed; keeping the host online preserves logs from both machines.
- Nero's Guix profile timer is explicitly daily at 06:00 UTC with no random
  delay; AWS should start the ARM instance before that time.
- Removed `--keep-failed` from profile materialization so Guix can offload
  `aarch64-linux` derivations to the native ARM builder. Keeping failed build
  directories forces those derivations to run locally on Nero, where ARM
  builder executables cannot run.
- Restored explicit `%current-system` parameterization in generated wrapper
  manifests. Bitcoin's manifest derives a `building-on` configure flag from
  this parameter; without it, ARM evaluation inherited Nero's x86_64 value and
  emitted duplicate, conflicting `--build` flags for GCC.
- Restored the successful-build-only AWS shutdown hook. It runs after the
  profile script exits successfully, so the ARM instance remains online for
  failures and powers off only after all profiles have been prewarmed and
  substitute coverage checks pass.

## Allow Cygwin and Sourceware migrations in Forgejo

- Made the Forgejo site's migration allow-list configurable by the deployment
  instead of keeping it hard-coded in the reusable module.
- Added `cygwin.com`, `sourceware.org`, and `gitlab.com` (including subdomains)
  to Nero's existing GitHub migration allow-list. The setting will be rendered
  into Forgejo's `[migrations]` `ALLOWED_DOMAINS` configuration during the next
  NixOS deployment.

## Retry rate-limited Git mirror cloning conservatively

- Added `scripts/git-clone-with-backoff` for a one-time mirror bootstrap when
  the upstream Git server returns transient 429, 5xx, or network errors.
- The script waits a randomized 15–60 seconds between attempts, keeps failed
  clones in disposable temporary directories, and moves a completed mirror into
  place only after success.
- Matched Git's actual `returned error: 429` wording and added cleanup traps
  for interrupted or non-transient failures.
- Extended the script to sequentially bootstrap `newlib-cygwin`, `binutils-gdb`,
  and `glibc`, deduplicating the repeated `binutils-gdb` URL.

## Submit Guix builds for exact Bitcoin commits

- Added `just guix-build-commit <commit-hash>` to queue a hexadecimal Bitcoin
  Core commit on Nero and start the existing Guix profile service.
- The service consumes the request once, fetches that commit from its configured
  Bitcoin remote (GitHub), and removes the request only after all profiles and
  substitute checks succeed. Scheduled builds continue following the branch.

## Start the ARM Guix builder on demand

- Added Nero's SOPS-managed AWS access key pair to the Guix build service's
  environment without placing either value in the Nix configuration.
- Before an AArch64 profile build, the service starts EC2 instance
  `i-033b747d5599f78b9` in `eu-central-1`, waits for it to enter the running
  state, and retries `guix offload test` until the builder is reachable.
- The existing successful-build shutdown hook remains responsible for powering
  off the ARM instance; failed builds leave it running for diagnosis.
- Verified both modified Nix files with `nix-instantiate --parse` and the
  Justfile with `just --list`. Full Nix evaluation was unavailable because the
  local Nix daemon socket is permission-restricted.

## Use the official Codeberg Guix repository

- Updated the locked `will-nix` input to the pushed module revision whose
  default is `https://codeberg.org/guix/guix.git`, then removed Nero's temporary
  host-level override.
- Changed `just guix-build-commit` to start the systemd job with `--no-block`,
  returning after queueing rather than waiting for the build result.

## Run native Guix system builds in parallel

- Changed the Guix build service to launch each configured native system's
  `materialize_system` phase concurrently, so x86_64 and AArch64 work can
  overlap.
- The service still waits for every phase and returns failure if any phase
  fails; the ARM builder shutdown hook therefore remains after both phases.

## Log expanded Guix build commands

- Added shell tracing around each profile materialization so the systemd
  journal records the expanded `guix time-machine` command, including the
  native system, target host, manifest wrapper, profile root, and flags.
- Prefix each trace line with its system and target host so concurrent x86_64
  and AArch64 jobs remain distinguishable in the interleaved journal output.

## Build requested commits from arbitrary Bitcoin repositories

- Kept `https://github.com/bitcoin/bitcoin` as the default repository for
  `just guix-build-commit`.
- Added an optional `repo=` argument and queue file so a requested commit is
  fetched directly from a fork or other Git repository, even when it is not
  present in the existing checkout.
- Consume the repository request only after all native-system builds succeed,
  matching the existing requested-commit cleanup behavior.

## Power off the ARM builder after failed builds

- Moved the ARM builder shutdown command from `ExecStartPost` to
  `ExecStopPost`, so systemd powers down the EC2 runner after both successful
  and failed Guix build services.
- This prevents failed nightly builds from leaving the ARM instance running
  and incurring unnecessary cost.

## Begin manifest-first Guix builder cutover

- Replaced the commit-file build path with immutable jobs under
  `/gnu/guix-bitcoin/jobs/{queued,running,succeeded,failed}`. Submission copies
  manifests and optional context into a temporary directory and atomically
  renames it into `queued`, so the worker never observes a partial job.
- Split the old build unit into `guix-bitcoin-nightly.service`, which only
  updates the managed Bitcoin checkout and submits one bundle of discovered
  manifests, and `guix-manifest-worker.service`, which claims jobs serially and
  records logs/results before atomically moving them to a terminal state.
- Made profile roots job-oriented at
  `profiles/<native-system>/<job-id>/<target-host>/<manifest>`, removing the
  commit and `last-built-manifests-*` identity optimization from this path.
- Kept the worker independent of Bitcoin by evaluating manifests from the job
  bundle. A Bitcoin context is stored below `context/contrib/guix` so manifests
  that use `current-filename` for patches retain their expected relative files.
- Added an AWS stop fallback in both the worker cleanup trap and systemd
  `ExecStopPost`. The active-job marker lets the post-stop helper shut down the
  ARM instance even if the worker is terminated before its shell trap runs.
- Removed `requested-commit`, `requested-repository`, and
  `just guix-build-commit` rather than adding compatibility interpretation.
- Confirmed the current Bitcoin manifests are standalone Scheme entry points;
  the nightly context remains necessary for `manifest_build.scm` patch files
  resolved relative to `current-filename`, not for manifest imports.
- Verified Bash syntax, Just parsing/dry-run expansion, atomic submission and
  validation behavior, worker recovery and terminal transitions with a fake
  Guix command, NixOS option evaluation, and a complete `nero` system build.

## Keep cross-system profile probes on the host

- The manifest worker originally ran `guix shell --system=aarch64-linux ... --
  true`. Guix resolved `true` from the target profile, so Nero's x86_64 host
  attempted to execute an AArch64 binary after the offloaded build succeeded.
- Injected an absolute Nero-side Coreutils `true` into the worker environment
  and use it as the shell probe, allowing target profiles to be materialized
  without executing target-architecture binaries locally.

## Follow an activating oneshot worker without a false recipe failure

- `systemctl status` returns a nonzero status while the oneshot worker is still
  `activating`, even though its process is healthy and progressing.
- Made `guix-manifest-logs` tolerate that transitional status before starting
  `journalctl -fu`, so the recipe now behaves as a long-running log follower.

## Build the ARM NixOS deployment on the ARM host

- `nixos-rebuild --build-host` still evaluates locally and transfers the
  resulting derivation closure to the remote host. This is unsuitable for a
  bandwidth-limited ARM deployment because it transfers many `.drv` paths.
- Changed `just arm-switch` to rsync the repository source to `/etc/nixos` and
  invoke `nixos-rebuild switch` there, matching Nero's remote deployment
  pattern. The ARM host now performs evaluation and closure construction.

## Check pinned Guix substitutes for aarch64

- The completed job captured the same `prelude.bash` as the current Bitcoin
  checkout, including the Guix time-machine commit
  `c5eee3336cc1d10a3cc1c97fde2809c3451624d3`.
- Generated job wrappers retain a `jobs/running/<job-id>` manifest path after
  the job moves to `jobs/succeeded`; use the captured context manifest directly
  for post-build weather checks.
- With the pinned Guix revision and `HOST=aarch64-linux-gnu`, the remote
  `guix.fish.foo` endpoint supplied 18 of 24 aarch64 items (75.0%); six
  cross-toolchain items were missing.
- Locally, invoke `guix time-machine ... -- weather ...` and set `HOST` to
  `aarch64-linux-gnu` when checking aarch64 cross-toolchain substitutes.
- The worker's ARM-native weather check wraps the manifest in a `parameterize`
  for `%current-system` before `primitive-load`ing it. A regular x86_64
  `guix-build` evaluates the raw manifest on its native x86_64 system, so its
  matching weather check must use `--system=x86_64-linux`; using
  `--system=aarch64-linux` checks a different derivation set.
- The historical Aug 13 `guix-bitcoin-build.service` still used the older
  time-machine commit `3b98aa3889888dd1a69d30bed2a5f1a8519fd06c` and failed
  while building `gcc-cross-sans-libc-aarch64-linux-gnu-14.3.0`.
- The deployed manifest worker contains the `c5eee3336cc1d10a3cc1c97fde2809c3451624d3`
  pin. Its wrapper-style weather check reports 24/24 substitutes available
  from `https://guix.fish.foo`, including the six expensive toolchain items.
- `contrib/guix/guix-build` forwards `SUBSTITUTE_URLS` only when the regular
  user sets it; the cache URL is not hard-coded in the Bitcoin Core script.

## Prime substitutes for regular Guix builders

- The worker's manifest wrapper is intentional: it parameterizes
  `%current-system` so each native build system gets its own correct
  derivations. The raw manifest is correct for regular `guix-build` because
  that command evaluates it on the builder's actual native system.
- Nero is configured to build both `x86_64-linux` and `aarch64-linux` native
  profiles, across the Bitcoin target-host matrix. It prewarms every profile
  requisite and waits for the local publisher to expose each `.narinfo`.
- A regular user must set `SUBSTITUTE_URLS` and authorize Nero's signing key;
  `guix-build` does not hard-code the substitute URL.
- Generated wrappers currently retain `jobs/running/<job-id>` source paths
  after a job moves to `jobs/succeeded`. This is a post-hoc inspection bug,
  not a build/cache derivation bug; use the captured context manifest with the
  correct native system until the wrapper path is made stable.

## Retain and publish Guix build-input closures

- A final manifest profile exposes only its direct/runtime package closure. A
  top-level toolchain derivation can reference the complete bootstrap and
  compiler closure through its `.drv`; the aarch64 cross-toolchain graph
  currently has 743 requisites, including mesboot GCC, bootstrapped binutils,
  headers, glibc, and final GCC stages.
- To serve these inputs, the worker now obtains the top-level `.drv` paths for
  each system/host/manifest using the same pinned time-machine and wrapper,
  roots those `.drv` paths, and prewarms `guix gc --requisites` on the `.drv`
  roots. `guix publish` already serves any valid rooted store path; no
  manifest-specific publisher allowlist is needed.
- This is optional for normal users once final outputs are cached, but it is
  required if the goal is to retain and serve the complete no-substitute build
  closure. It will substantially increase store/cache usage across both
  native systems and the target-host matrix.

## Parallelize publisher cache baking

- The first closure prewarm was serial: it waited for one NAR to finish baking
  before requesting the next one, despite Nero's publisher having 16 workers.
- The worker now maintains 16 concurrent prewarm requests, allowing
  `guix publish` to use its configured baking workers while retaining the
  existing retry behavior for paths whose NARs are still being generated.
- Derivation rooting is idempotent so an interrupted job can be requeued and
  resumed without treating its existing correct GC-root symlinks as errors.

## Materialize derivation-closure outputs

- Rooting top-level `.drv` paths keeps derivation metadata and allows the
  worker to prewarm builder scripts and other non-derivation store references,
  but it does not itself realize the output paths of source and build-input
  derivations.
- The manifest worker now walks `guix gc --requisites` for each top-level
  derivation, filters that closure to `.drv` paths, runs a normal concrete
  `guix build` for every derivation in that closure, and roots the realized
  outputs under `<profile>.derivation-outputs`.
- The output-root check follows Guix's `--root` layout: one output uses the
  requested root path directly, while multi-output derivations use suffixed
  roots beginning at `-0`. Existing correct roots are accepted so requeued jobs
  remain resumable.
- Prewarming still includes the profile runtime closure and top-level `.drv`
  requisites, and now also includes the requisites of every rooted
  derivation-closure output. This is what exposes source/check-out outputs such
  as LLVM and glibc archives through `guix publish`.

## Submit Bitcoin source revisions

- Guix jobs now contain a small source descriptor instead of uploaded
  manifests or a `contrib/guix` snapshot. The module fetches the named
  repository, pins the accepted commit in its bare Git repository, and builds
  from a server-owned detached worktree.
- The normal nightly producer resolves the configured `bitcoin/bitcoin`
  `master` branch. Manual jobs name an exact 40-character commit and may also
  name an arbitrary fork repository; this is intentionally a trusted-operator
  interface and does not have a repository allowlist.
- Nero's Just recipes only invoke the installed module commands. No source
  archive crosses SSH, and the obsolete Nero-local copies of the submitter,
  nightly producer, and worker were removed.
- The current module-level Guix time-machine URL and commit remain authoritative
  for builds made today. If Bitcoin Core exposes those values in its own tree,
  this interface should be replaced in one hard cutover rather than retaining
  support for older Bitcoin commits.
- Nero's `will-nix` lock remains unchanged until the local module commit is
  pushed. The consumer changes are validated with a local input override and
  must not be activated before the lock is advanced.
- `just guix-queue` reports the worker state and the source repository, commit,
  and submission time for queued and running jobs without evaluating descriptor
  contents as shell code.
- `just guix-worker-start` uses systemd's non-blocking start mode because the
  worker is a long-running `Type=oneshot` build. This returns after the start is
  queued while systemd continues to supervise the build.

## Simplify Nero operator workflow and remove ARM maintenance lock

- Kept `guix-submit-master` non-blocking by switching to
  `systemctl start --no-block` in the Just recipe.
- Removed ARM maintenance-lock handling from both lifecycle Nix wiring and the
  ARM stop helper; the stop helper now gates shutdown only on the active-job
  marker for safety.
- Updated `just guix-queue` output to match current job metadata shape by
  reporting only `source_repository` and `source_commit`.
- Preserved ARM startup/shutdown safety checks: pre-flight job-name validation,
  `guix offload test` readiness loop, active-file stop guard, and builder state
  assertions.

## Reproducible Guix publisher SSH identity

- Nero's dedicated `guix copy` SSH identity is stored as a binary SOPS secret
  and restored by sops-nix as root-owned, mode `0400` key material.
- A Nix-managed root SSH configuration selects that identity for
  `guix-publish-2`; this will be restored when Nero is reprovisioned.
- The publisher's SSH host key must be pinned in the same configuration after
  its fresh installation, because that key is generated during deployment.
- The fresh publisher's Ed25519 host key is now pinned under both the Guix
  copy alias and its DNS name. An activation script adds that one entry to
  root's existing `known_hosts` without discarding unrelated host keys.

## Isolate Nero dnsseedrs egress through WireGuard

- The public DNS listener remains in Nero's root network namespace. CoreDNS
  forwards the seed zones over a veth pair to dnsseedrs listeners in a
  dedicated `dnsseedrs` namespace, so public DNS service is not interrupted.
- NixOS creates the WireGuard interface in the root namespace and moves it
  into the dnsseedrs namespace. The WireGuard peer's IPv4 and IPv6 catch-all
  routes therefore apply only to the two dnsseedrs services.
- A dedicated veth route and narrowly scoped IPv4/IPv6 NAT let the namespace
  reach both the WireGuard endpoint and the tunnel without changing Nero's
  ordinary default routes.
- Tor and I2P SOCKS endpoints are exposed only on the veth address so the
  isolated dnsseedrs processes retain their existing proxy transports; those
  proxy daemons remain outside the WireGuard namespace.
- sops-nix systemd activation provisions the WireGuard private key before the
  tunnel starts, including after a reboot. The Ubuntu egress VPS masquerades
  only the WireGuard tunnel addresses on `eth0`; Nero's other services
  continue to use their existing routes.

## Update dnsseedrs mainnet capacity

- Advanced the `will-nix` flake input to `willcl-ark/nix` commit `20e5c52`.
- Set Nero's mainnet dnsseedrs crawler to 400 threads and a crawl rate of 40
  starts per second. The upstream module calls the latter `crawlRate` and
  emits dnsseedrs's `--crawl-rate=40` argument.

## Pin the deployment to current dnsseedrs

- Added `willcl-ark/dnsseedrs` as a non-flake source input pinned to commit
  `791fb2e`. This lets the deployment build the upstream `default.nix` with its
  existing nixpkgs input, without adding dnsseedrs's flake dependencies.
- Both DNS seed hosts override the reusable module's package option with that
  source build. The reusable `will-nix` service module remains responsible for
  the service interface and runtime configuration.

## Pass the selected repository to Guix submission

- Resolve the recipe's omitted repository argument to the upstream Bitcoin Core
  URL and set `GUIX_BITCOIN_REPOSITORY` in the remote command. This satisfies
  the locked submission wrapper's required default while keeping explicit
  `--repository` submissions working.

## Enable Forgejo webhooks

- Removed the shared `forgejo-site` module's `DISABLE_WEBHOOKS = true` setting.
  Forgejo defaults this option to `false`, so a host-specific override is not
  needed.
- Pinned Nero's `will-nix` input to `051f3c9` and switched the host to that
  revision. The resulting configuration omits `DISABLE_WEBHOOKS`; Forgejo
  restarted successfully and answered HTTP requests on its local listener.

## Add a Forgejo review bot

- Added a Python service on Nero behind `review.fish.foo`. It accepts only signed
  pull request webhooks for `bitcoin/bitcoin` and keeps its checkout under
  `/var/lib/forgejo-review-bot`.
- The bot fetches the target branch and `refs/pull/<number>/head` from the fixed
  Forgejo origin, checks the webhook head SHA, and reviews the merge-base diff
  plus commit messages. The fetch requests a blob filter because the mirrored
  Bitcoin repository has a large history. It skips oversized review inputs
  rather than sending an incomplete patch to the model.
- The OpenAI key, a separate generated webhook secret, and the dedicated
  `review-bot` account token are SOPS secrets owned by the service user. The
  model request uses `gpt-6-sol` with `store: false`.
- The bot posts one issue comment per PR, identified by bot author and a hidden
  marker. Later reviews edit that comment only when its body changes. It checks
  the current Git PR head before posting so stale webhooks cannot publish.
- A live mirror webhook and model request remain to be tested after deployment.
  The issue comment API and Git PR ref work with the bot token. The PR API is
  unavailable with the token's issue-only scope, so the bot does not use it.
- Extended the review with Responses API function tools for reading numbered
  chunks of tracked regular files and literal searches at the checked-out PR
  head. The model chooses its own reads to follow definitions and callers.
  Tool results and model output are replayed for each request with `store: false`.
  Reads are bounded to 1 MB files, 12 KB outputs, 12 calls, and eight model
  turns. No model tool executes PR code; the only subprocesses are fixed Git
  commands. CI remains responsible for builds and tests.
- Caddy obtained a certificate for `review.fish.foo`, and an unsigned HTTPS
  webhook request returned 401 through the live service. We will wait for an
  organic PR event rather than send a synthetic one.
- Synced the contextual reviewer to Nero and switched the system configuration.
  The service and Caddy are active; systemd has `Restart=on-failure`. The public
  endpoint still rejects unsigned POST requests with 401. No PR review or
  OpenAI model call was triggered during deployment.
- Removed the bot's special `@` mention scan and comment section, leaving that
  static check to other tools. Added a short writing guide distilled from the
  local unslop skill to the model prompt: plain, specific, active prose without
  stock praise, filler, inflated phrasing, decorative formatting, or em dashes.
- Deployed the style change on Nero after all 14 local tests passed. The new
  `forgejo-review-bot` service is active with zero restarts, and an unsigned
  HTTPS webhook still returns 401. The first organic review remains pending.
- Added a collapsed public debug section to new bot comments for development.
  It records the review input size and hash, exact bot instructions, each API
  turn's request and response hashes, status, model, latency, token counts,
  chosen tool calls, and an estimated USD cost. It omits credentials, patch
  text, and retrieved file contents. Forgejo's Markdown renderer preserved a
  trial `<details>` block. The estimate uses published `gpt-6-sol` Standard
  rates, including cached and cache-write tokens when usage reports them.
- Deployed the debug comment change on Nero. All 15 local tests passed, the
  NixOS build and switch succeeded, and the bot is active with zero restarts.
  The public endpoint rejects an unsigned POST with 401. The first organic PR
  webhook will validate the full model and comment path.
- A manual signed webhook for open PR #36321 reached the bot, and its model
  requests completed, but Forgejo rejected the comment POST with 403. The
  custom Forgejo fork intentionally makes GitHub metadata mirrors read-only for
  issues and pulls. Added a deployment patch that allows only `review-bot` to
  use the canonical issue-comment POST and PATCH API routes on `bitcoin/bitcoin`;
  other mirror mutations remain blocked. The importer only inserts source-mapped
  upstream comments, so local bot comments should survive metadata sync.
- Added an ignored local `scripts/review-pr-local` helper and `just review-pr`
  recipe. It takes one PR number, checks the upstream PR and mirrored head,
  reads the webhook secret from SOPS at run time, and sends a signed event.
- Built and switched Nero with the Forgejo patch. A `just review-pr 36321`
  trigger created comment 607583 from `review-bot` on the existing PR, with
  the expected head and collapsed debug details. The model used 10 repository
  tools across seven API turns and reported no actionable issue; the trace's
  cost estimate was $0.037451. Repeating the command logged "head already
  reviewed" and did not create another comment. Forgejo, Caddy, and the bot
  remain active with zero restarts.

## Improve review context and judgment

- The first two comments were technically plausible but too checklist-like.
  In particular, the comment on PR #36321 claimed existing checkpoint tests
  covered the change, although the observed requests do not reach the empty
  vector condition that triggered the sanitizer warning.
- Fetch the latest PR title and description from Forgejo's issue API and
  confirm its `pull_request` field. The mirror's pull request API returns 404
  even with a token that can read the repository. Git still checks the head
  SHA against the webhook before review. The comment does not repeat the title
  or description by default. The existing 200 KB input cap includes this text.
- The prompt now asks for a short judgment of the problem, root cause, code
  placement, and material tradeoffs before implementation details. It requires
  evidence for test-coverage claims and avoids routine checklist reassurance.
  It still forbids running PR code and giving a human-style ACK.
- A replacement token scoped to `bitcoin/bitcoin` with `write:issue` and
  `read:repository` was installed in SOPS. This implementation needs only
  `write:issue`; the additional read scope is not used by the review path.
- The mirror ignores `page` and `limit` for issue comments: PR #25665 returned
  the same 65 comments for pages 1, 2, 3, and 10. The old lookup looped over
  thousands of identical pages and eventually got HTTP 401 after the previous
  token was rotated. Stop when a page repeats, while preserving normal
  pagination. A regression test fails before the fix and passes afterward.
- Deployed the context prompt, encrypted token rotation, and pagination fix
  with NixOS switches. The bot service is active with zero restarts, and an
  unsigned webhook still returns 401. Re-triggering open PR #25665 created
  exactly one bot comment, ID 607585. It identified a real caller error in
  `src/kernel/bitcoinkernel.cpp`: the verify-failure log reads `load_result`
  instead of `verify_result`. The PR diff confirms the cited line.
- Added a short simplicity check distilled from the local ponytail skill to the
  existing model pass. The bot may suggest removing unnecessary helpers, types,
  state, or layers only when it can give a concrete alternative and account for
  behavior, errors, locking, consensus, and API contracts. It stays silent when
  it has no supported simplification. This keeps one model pass and one comment.
- Expanded the simplicity pass after feedback: it now asks the reviewer to
  trace the problem and callers, look for project or standard-library reuse,
  identify narrow abstractions and unused options, and prefer root-cause fixes
  at shared boundaries. It explicitly guards consensus, locking, serialization,
  errors, public contracts, and regression tests, and requires a concrete
  replacement before suggesting simplification.
- Committed as `2378e78` and switched Nero. All 17 local tests passed; the
  review service is active with zero restarts, and an unsigned webhook still
  returns 401. Existing reviews on unchanged heads are not rerun; the next
  new or updated PR will use the expanded prompt.
- Compared the live simplicity prompt with the upstream Ponytail skill. Added
  its useful checks for speculative behavior, native platform features,
  installed dependencies, and deleting redundant code. Kept the requirement
  for a concrete, behavior-preserving suggestion and the Bitcoin Core safety
  constraints. This remains one review pass and one editable PR comment.

## Move the review bot into the shared Nix flake

- The shared `/home/will/src/nix` flake now owns the bot source, tests, package,
  and `services.forgejoReviewBot` module. Nero keeps only its repository URL,
  reverse proxy, SOPS secret paths, and service ordering for decrypted secrets.
- The module preserves the `forgejo-review-bot` system user and the private
  `/var/lib/forgejo-review-bot` StateDirectory, so the existing checkout and
  comment state survive the service cutover. The runtime API URL and marker are
  derived from Nero's repository configuration; the marker remains unchanged.
- `just switch-local-nix` syncs the local shared flake to Nero and passes a
  temporary `will-nix` override. This avoids pushing development changes and
  does not rewrite `flake.lock`. A normal switch requires the shared module to
  be published and the `will-nix` input pin updated first.
- The unrelated DNS seed edits in `flake.lock` and the top of
  `hosts/nero/default.nix` remain outside the review bot commits.
- Shared module committed as `1c2fcd4`; Nero cutover committed as `fd38d56`.
  All 19 bot unit tests pass, the shared Nix package builds, and local Nero
  evaluation succeeds with `--override-input will-nix path:/home/will/src/nix`.
- The first `just switch-local-nix` attempt stopped before sync because the
  system SSH drop-in is rejected for its permissions. Updated the relevant
  switch recipes to use `/home/will/.ssh/config` and committed as `05d3f5b`.
  The retry switched Nero successfully. The service runs the package binary,
  is active with zero restarts, retains its 0700 checkout state directory, and
  returns 401 for an unsigned webhook. The shared input remains an unpublished
  local override; a normal pinned switch needs the shared module published and
  `nix flake update will-nix` first.

## Improve review logs and make the prompt editable here

- The shared bot now logs validated PR number, action, and short head on
  enqueue and start. One terminal line records outcome, elapsed time, model
  turns, tool calls, token totals, and estimated cost when available. Failures
  add a fixed stage, exception type, and HTTP status/host without exception
  messages or PR content. Browser GET request lines are DEBUG rather than INFO.
- The worker catches ordinary unexpected job exceptions and continues to later
  jobs. The cost total uses the same calculation as the per-comment debug
  section. Shared commit `d9f2c57` passed bot tests and package checks and was
  switched on Nero. A same-head manual webhook for PR #36328 logged enqueue,
  start, and `already-reviewed` with zero model turns and zero tools; no new
  review was generated.
- The prompt was formerly embedded in the shared Python file. Shared commit
  `2599f50` ships that exact text as the package default and adds the module's
  `promptFile` option. Nero commit `24f24ef` supplies an identical
  `review-bot-prompt.md` so Bitcoin Core wording can be edited here. The host
  evaluates with the override and was switched using `just switch-local-nix`.
  All 25 bot tests pass; the service is active with zero restarts and reads
  Nero's prompt from a Nix store path. An unsigned webhook still returns 401.

## Shorten the Bitcoin Core review prompt

- The host override prompt now keeps the bot's read-only context inspection,
  conceptual and correctness review, deliberate simplicity pass, and concise
  comment style in 318 words instead of 495.
- Nero now uses the revised prompt. The shared module commits through
  `2599f50` were published, the `will-nix` pin was updated in `4df097b`,
  and `just switch` deployed the current working tree. The active unit points
  to a Nix store prompt whose hash matches the local file.
- A follow-up sentence limits findings to changes introduced by the PR while
  allowing unchanged files as context. This came from the public Codex Action
  example and does not change the bot's checkout behavior.
- The service restarted with zero restarts and reviewed PR #36358 after the
  switch: 4 model turns, 15 tool calls, and a created comment. Both DNS seed
  services also remained active after deploying the uncommitted seed edits.

## Label review findings by severity

- The prompt now groups findings under Critical, Major, Minor, or Suggestion
  headings with a single matching emoji. Only levels with findings appear.
  Reviews without findings remain brief prose without a severity label.
- The model still produces one editable PR comment, and the application still
  supplies the base/head header and debug section. No bot code changed.
- This prompt edit is local and has not been switched on Nero.

## Reduce review banner and increase inspection budget

- The shared bot comment wrapper now starts with Base and Head commit IDs,
  followed by the model's concise review. It keeps the hidden ownership marker
  and the requested collapsible debug trace.
- The model remains gpt-6-sol at default medium reasoning. The tool limit rises
  from 12 to 24 calls, model turns from 8 to 10, and the per-response generated
  token cap from 3,000 to 6,000. The larger cap gives reasoning and tool calls
  room; it does not request a longer public comment or set a fixed spend. This
  setting aims for roughly $1-$2 on demanding reviews, but an exact dollar
  ceiling would require metered stopping.
- The new comment-format regression test failed before the edit, then all 26
  bot unit tests passed. These shared changes have not been published or
  switched on Nero.

## Add bounded inspection tools and forced reruns

- The bot can now find tracked paths, read regular files at the PR merge base,
  and page through a changed file's diff. For patches over 200 KB, it sends a
  changed-file list and lets the model select diffs instead of skipping the PR.
- The signed `review_bot_force` webhook field bypasses only the same-head
  precheck. The existing stale-head check and single-comment edit path remain.
  The ignored local helper accepts `just review-pr NUMBER --force` and signs
  that field into its synthetic webhook request.
- The shared changes were split into commits `73ba907` and `054d2fa`. Bot
  tests, package build, flake evaluation, and a mocked helper call passed.
- The first forced PR #36182 run passed model review but failed publication
  because the token and old marked comment belong to renamed account `ralph`,
  while the bot expected `review-bot`. After updating that setting, Forgejo
  still returned 403: the site patch also hardcoded the old login. Account ID
  4 owns both the token and comment, so the patch now checks that stable ID.
