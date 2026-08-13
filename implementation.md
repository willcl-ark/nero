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

## Build the ARM NixOS deployment on the ARM host

- `nixos-rebuild --build-host` still evaluates locally and transfers the
  resulting derivation closure to the remote host. This is unsuitable for a
  bandwidth-limited ARM deployment because it transfers many `.drv` paths.
- Changed `just arm-switch` to rsync the repository source to `/etc/nixos` and
  invoke `nixos-rebuild switch` there, matching Nero's remote deployment
  pattern. The ARM host now performs evaluation and closure construction.
