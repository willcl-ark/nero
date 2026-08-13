{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.bitcoinCoreGuixSubstitutes;
  nativeSystems = config.services.neroGuixBuild.nativeSystems;
  armEnabled = lib.elem "aarch64-linux" nativeSystems;
  profilesRoot = "${cfg.dataDir}/profiles";
  jobsRoot = "${cfg.dataDir}/jobs";
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
  nativeSystemsText = lib.concatStringsSep " " nativeSystems;
  bitcoinGuixHostsText = lib.concatStringsSep " " bitcoinGuixHosts;
  submitSource = pkgs.writeText "guix-bitcoin-submit" (
    builtins.readFile ../../scripts/guix-bitcoin-submit
  );
  nightlySource = pkgs.writeText "guix-bitcoin-nightly" (
    builtins.readFile ../../scripts/guix-bitcoin-nightly
  );
  armStopSource = pkgs.writeText "guix-bitcoin-arm-stop" (
    builtins.readFile ../../scripts/guix-bitcoin-arm-stop
  );
  workerSource = pkgs.writeText "guix-manifest-worker" (
    builtins.readFile ../../scripts/guix-manifest-worker
  );
  tool =
    name: source:
    pkgs.writeShellScriptBin name ''
      export GUIX_BITCOIN_DATA_DIR=${lib.escapeShellArg cfg.dataDir}
      export GUIX_BITCOIN_BUILD_USER=${lib.escapeShellArg cfg.buildUser}
      export GUIX_BITCOIN_BUILD_GROUP=${lib.escapeShellArg cfg.buildGroup}
      export GUIX_BITCOIN_BUILD_JOBS=${toString cfg.buildJobs}
      export GUIX_BITCOIN_HOST_TRUE=${pkgs.coreutils}/bin/true
      export GUIX_BITCOIN_PREWARM_URL=http://${cfg.publishAddress}:${toString cfg.publishPort}
      export GUIX_BITCOIN_NATIVE_SYSTEMS=${lib.escapeShellArg nativeSystemsText}
      export GUIX_BITCOIN_TARGET_HOSTS=${lib.escapeShellArg bitcoinGuixHostsText}
      export GUIX_BITCOIN_TIMEMACHINE_FLAGS=${lib.escapeShellArg cfg.additionalGuixTimemachineFlags}
      export GUIX_BITCOIN_ARM_ENABLED=${lib.boolToString armEnabled}
      export GUIX_BITCOIN_ARM_REGION=eu-central-1
      export GUIX_BITCOIN_ARM_INSTANCE_ID=i-033b747d5599f78b9
      export GUIX_BITCOIN_ARM_MAINTENANCE_LOCK=${lib.escapeShellArg "${jobsRoot}/arm-maintenance.lock"}
      exec ${pkgs.bash}/bin/bash ${source} "$@"
    '';
  submitTool = tool "guix-bitcoin-submit" submitSource;
  nightlyTool = tool "guix-bitcoin-nightly" nightlySource;
  armStopTool = tool "guix-bitcoin-arm-stop" armStopSource;
  workerTool = tool "guix-manifest-worker" workerSource;
  servicePath = [
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.git
    pkgs.systemd
    pkgs.awscli2
    config.services.guix.package
    submitTool
    armStopTool
  ];
  jobDirectories = [
    cfg.dataDir
    jobsRoot
    "${jobsRoot}/.tmp"
    "${jobsRoot}/queued"
    "${jobsRoot}/running"
    "${jobsRoot}/succeeded"
    "${jobsRoot}/failed"
    profilesRoot
  ];
  prepareDirectories = map (
    directory:
    "+${pkgs.coreutils}/bin/install -d -m 0750 -o ${cfg.buildUser} -g ${cfg.buildGroup} ${directory}"
  ) jobDirectories;
in
{
  options.services.neroGuixBuild = {
    nativeSystems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "x86_64-linux" ];
      description = "Native Guix systems whose manifest profiles Nero materializes.";
    };

    failedJobMaxAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Retention period for failed manifest jobs.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !armEnabled || config.services.neroGuixOffload.enable;
        message =
          "aarch64-linux profile builds require services.neroGuixOffload.enable.\n"
          + "This prevents an accidental local QEMU fallback.";
      }
    ];

    environment.systemPackages = [
      submitTool
    ];

    systemd.tmpfiles.rules = map (
      directory:
      "d ${directory} 0750 ${cfg.buildUser} ${cfg.buildGroup} -"
    ) jobDirectories;

    systemd.services.guix-bitcoin-build.enable = false;
    systemd.timers.guix-bitcoin-build.enable = false;

    systemd.services.guix-bitcoin-nightly = {
      description = "Submit the nightly Bitcoin Core Guix manifest job";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = servicePath;
      script = "${nightlyTool}/bin/guix-bitcoin-nightly";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.buildUser;
        Group = cfg.buildGroup;
        ExecStartPre = prepareDirectories;
        ExecStartPost = "+${pkgs.systemd}/bin/systemctl start --no-block guix-manifest-worker.service";
      };
      environment = {
        GUIX_BITCOIN_REPOSITORY = cfg.bitcoinRepository;
        GUIX_BITCOIN_REMOTE = cfg.bitcoinRemote;
        GUIX_BITCOIN_BRANCH = cfg.bitcoinBranch;
      };
    };

    systemd.timers.guix-bitcoin-nightly = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 06:00:00 UTC";
        Persistent = true;
        RandomizedDelaySec = "0";
      };
    };

    systemd.services.guix-manifest-worker = {
      description = "Build queued immutable Guix manifest jobs";
      after = [
        "network-online.target"
        "guix-daemon.service"
        "guix-publish.service"
      ];
      wants = [
        "network-online.target"
        "guix-daemon.service"
        "guix-publish.service"
      ];
      path = servicePath ++ [ workerTool ];
      script = "${workerTool}/bin/guix-manifest-worker";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.buildUser;
        Group = cfg.buildGroup;
        ExecStartPre = prepareDirectories;
        ExecStopPost = lib.mkIf armEnabled [
          "+${armStopTool}/bin/guix-bitcoin-arm-stop"
        ];
      };
    };

    systemd.services.guix-bitcoin-build-cleanup.script = lib.mkForce ''
      set -euo pipefail

      find ${jobsRoot}/succeeded \
        -mindepth 1 -maxdepth 1 -type d \
        -mtime +${toString cfg.cleanup.maxAgeDays} -exec rm -rf {} +
      find ${jobsRoot}/failed \
        -mindepth 1 -maxdepth 1 -type d \
        -mtime +${toString config.services.neroGuixBuild.failedJobMaxAgeDays} \
        -exec rm -rf {} +
      find ${profilesRoot} \
        -mindepth 2 -maxdepth 2 -type d \
        -mtime +${toString cfg.cleanup.maxAgeDays} -exec rm -rf {} +
      find ${cfg.dataDir}/bitcoin \
        -maxdepth 1 -type d -name 'guix-build-*' \
        -mtime +${toString cfg.cleanup.maxAgeDays} -exec rm -rf {} +
    '';
  };
}
