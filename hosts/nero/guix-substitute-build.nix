{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.bitcoinCoreGuixSubstitutes;
  nativeSystems = config.services.neroGuixBuild.nativeSystems;
  profilesRoot = "${cfg.dataDir}/profiles";
  bitcoinGuixHosts = [
    "x86_64-linux-gnu"
    "arm-linux-gnueabihf"
    "aarch64-linux-gnu"
    "riscv64-linux-gnu"
    "powerpc64-linux-gnu"
    "x86_64-w64-mingw32"
    "x86_64-apple-darwin"
    "arm64-apple-darwin"
  ];
in
{
  options.services.neroGuixBuild.nativeSystems = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "x86_64-linux" ];
    description = "Native Guix systems whose Bitcoin profiles Nero materializes.";
  };

  config = {
    assertions = [
      {
        assertion =
          !(lib.elem "aarch64-linux" nativeSystems)
          || config.services.neroGuixOffload.enable;
        message =
          "aarch64-linux profile builds require services.neroGuixOffload.enable.\n"
          + "This prevents an accidental local QEMU fallback.";
      }
    ];

    systemd.services.guix-bitcoin-build = {
    description = lib.mkForce "Build Bitcoin Core Guix substitute profiles";
    serviceConfig.ExecStartPost = lib.mkIf (lib.elem "aarch64-linux" nativeSystems) [
      "+${pkgs.openssh}/bin/ssh -i ${config.services.neroGuixOffload.privateKeyFile} -o BatchMode=yes -o UserKnownHostsFile=/etc/ssh/guix-arm-builder_known_hosts ${config.services.neroGuixOffload.user}@${config.services.neroGuixOffload.host} systemctl poweroff"
    ];
    script = lib.mkForce ''
      set -euo pipefail

      if [ ! -d ${cfg.dataDir}/bitcoin/.git ]; then
        git clone ${cfg.bitcoinRepository} ${cfg.dataDir}/bitcoin
      fi

      cd ${cfg.dataDir}/bitcoin
      git fetch ${cfg.bitcoinRemote} ${cfg.bitcoinBranch}
      commit="$(git rev-parse ${cfg.bitcoinRemote}/${cfg.bitcoinBranch})"
      git reset --hard ${cfg.bitcoinRemote}/${cfg.bitcoinBranch}

      mapfile -t manifests < <(
        find contrib/guix \
          -maxdepth 1 \
          -type f \
          -name 'manifest_*.scm' \
          -print \
          | sort
      )
      if [ "''${#manifests[@]}" -eq 0 ]; then
        echo "ERR: no contrib/guix/manifest_*.scm files found"
        exit 1
      fi

      JOBS=${toString cfg.buildJobs}
      ADDITIONAL_GUIX_COMMON_FLAGS=
      ADDITIONAL_GUIX_TIMEMACHINE_FLAGS="${cfg.additionalGuixTimemachineFlags}"
      SUBSTITUTE_URLS=
      source contrib/guix/libexec/prelude.bash

      if ${lib.boolToString (lib.elem "aarch64-linux" nativeSystems)}; then
        echo "Checking native AArch64 Guix offload before building..."
        guix offload test
      fi

      manifest_wrapper() {
        local guix_system="$1"
        local manifest="$2"
        local wrapper_dir=${cfg.dataDir}/manifest-wrappers/"$guix_system"
        local wrapper="$wrapper_dir/$(basename "$manifest")"
        manifest="$(realpath "$manifest")"

        mkdir -p "$wrapper_dir"
        cat > "$wrapper" <<EOF
(use-modules (guix))

(parameterize
  ((%current-system "$guix_system"))
  (primitive-load "$manifest"))
EOF
        printf '%s\n' "$wrapper"
      }

      materialize_profile() {
        local guix_system="$1"
        local host="$2"
        local manifest="$3"
        local manifest_file="$4"
        local profile="$5"

        if [ -e "$profile" ]; then
          return
        fi

        echo "Building $manifest profile for $host on $guix_system..."
        HOST="$host" time-machine shell \
          --system="$guix_system" \
          --manifest="$manifest_file" \
          --cores=${toString cfg.buildJobs} \
          --root="$profile" \
          -- ${pkgs.coreutils}/bin/true
      }

      prewarm_url=http://${cfg.publishAddress}:${toString cfg.publishPort}

      prewarm_store_path() {
        local path="$1"
        local hash
        hash="$(basename "$path" | cut -d- -f1)"
        until curl -fsS -o /dev/null "$prewarm_url/$hash.narinfo"; do
          sleep 10
        done
      }

      check_manifest() {
        local guix_system="$1"
        local host="$2"
        local manifest="$3"
        local manifest_file
        manifest_file="$(manifest_wrapper "$guix_system" "$manifest")"

        echo "Checking $manifest substitutes for $host on $guix_system..."
        until HOST="$host" \
          time-machine weather \
            --system="$guix_system" \
            --substitute-urls="$prewarm_url" \
            --manifest="$manifest_file" \
          | grep -q '100.0% substitutes available'; do
          sleep 10
        done
      }

      materialize_system() {
        local guix_system="$1"
        local profiles_dir=${profilesRoot}/"$guix_system"/"$commit"
        local last_built=${cfg.dataDir}/last-built-manifests-"$guix_system"
        local profiles_complete=true
        local host manifest manifest_name wrapper

        for host in ${lib.escapeShellArgs bitcoinGuixHosts}; do
          for manifest in "''${manifests[@]}"; do
            manifest_name="$(basename "$manifest" .scm)"
            if [ ! -e "$profiles_dir/$host/$manifest_name" ]; then
              profiles_complete=false
            fi
          done
        done

        if [ -f "$last_built" ] \
          && [ "$(cat "$last_built")" = "$commit" ] \
          && "$profiles_complete"; then
          echo "Guix manifests for $guix_system are already built at $commit; skipping."
          return
        fi

        mkdir -p "$profiles_dir"
        for host in ${lib.escapeShellArgs bitcoinGuixHosts}; do
          mkdir -p "$profiles_dir/$host"
          for manifest in "''${manifests[@]}"; do
            manifest_name="$(basename "$manifest" .scm)"
            wrapper="$(manifest_wrapper "$guix_system" "$manifest")"
            materialize_profile \
              "$guix_system" \
              "$host" \
              "$manifest" \
              "$wrapper" \
              "$profiles_dir/$host/$manifest_name"
          done
        done

        echo "Prewarming Guix substitute closure for $guix_system..."
        for host in ${lib.escapeShellArgs bitcoinGuixHosts}; do
          for manifest in "''${manifests[@]}"; do
            manifest_name="$(basename "$manifest" .scm)"
            guix gc --requisites \
              "$(readlink -f "$profiles_dir/$host/$manifest_name")"
          done
        done | sort -u | while IFS= read -r path; do
          prewarm_store_path "$path"
        done

        for host in ${lib.escapeShellArgs bitcoinGuixHosts}; do
          for manifest in "''${manifests[@]}"; do
            check_manifest "$guix_system" "$host" "$manifest"
          done
        done

        printf '%s\n' "$commit" > "$last_built"
      }

      for guix_system in ${lib.escapeShellArgs nativeSystems}; do
        materialize_system "$guix_system"
      done
    '';
    };

    systemd.services.guix-bitcoin-build-cleanup.script = lib.mkForce ''
    for guix_system in ${lib.escapeShellArgs nativeSystems}; do
      profiles_dir=${profilesRoot}/"$guix_system"
      if [ -d "$profiles_dir" ]; then
        find "$profiles_dir" \
          -mindepth 1 \
          -maxdepth 1 \
          -type d \
          -mtime +${toString cfg.cleanup.maxAgeDays} \
          -exec rm -rf {} +
      fi
    done

    find ${cfg.dataDir}/bitcoin \
      -maxdepth 1 \
      -type d \
      -name 'guix-build-*' \
      -mtime +${toString cfg.cleanup.maxAgeDays} \
      -exec rm -rf {} +
    '';
  };
}
