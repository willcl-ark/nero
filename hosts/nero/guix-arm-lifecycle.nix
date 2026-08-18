{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.bitcoinCoreGuixSubstitutes;
  builder = cfg.builder;
  armEnabled = lib.elem "aarch64-linux" builder.nativeSystems;

  jobsRoot = "${cfg.dataDir}/jobs";
  runtimeDirectory = "guix-bitcoin-arm-lifecycle";
  runtimePath = "/run/${runtimeDirectory}";
  activeFile = "${runtimePath}/active";
  region = "eu-central-1";
  instanceId = "i-033b747d5599f78b9";

  aws = "${pkgs.awscli2}/bin/aws";
  guix = "${config.services.guix.package}/bin/guix";
  armPrepare = pkgs.writeShellScript "guix-bitcoin-arm-prepare" ''
    set -euo pipefail

    jobs_dir=${lib.escapeShellArg jobsRoot}
    active_file=${lib.escapeShellArg activeFile}
    region=${lib.escapeShellArg region}
    instance_id=${lib.escapeShellArg instanceId}

    has_job=false
    shopt -s nullglob
    for job in "$jobs_dir"/queued/* "$jobs_dir"/running/*; do
      [[ -d $job ]] || continue
      job_id=$(basename "$job")
      if [[ $job_id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]; then
        has_job=true
        break
      fi
      echo "Skipping unsafe queued or running job name: $job_id" >&2
    done
    shopt -u nullglob
    [[ $has_job == true ]] || exit 0

    touch "$active_file"
    state=$(${aws} ec2 describe-instances \
      --region="$region" \
      --instance-ids="$instance_id" \
      --query='Reservations[0].Instances[0].State.Name' \
      --output=text)
    case $state in
      stopped)
        ${aws} ec2 start-instances --region="$region" --instance-ids="$instance_id" >/dev/null
        ;;
      stopping)
        ${aws} ec2 wait instance-stopped --region="$region" --instance-ids="$instance_id"
        ${aws} ec2 start-instances --region="$region" --instance-ids="$instance_id" >/dev/null
        ;;
      pending|running)
        ;;
      *)
        echo "ERR: ARM Guix builder is in unexpected state: $state" >&2
        exit 1
        ;;
    esac

    ${aws} ec2 wait instance-running --region="$region" --instance-ids="$instance_id"
    until ${guix} offload test; do
      echo "Waiting for ARM Guix builder offload readiness..."
      sleep 10
    done
  '';

  armStopSource = pkgs.writeText "guix-bitcoin-arm-stop" (
    builtins.readFile ../../scripts/guix-bitcoin-arm-stop
  );
  armStop = pkgs.writeShellScript "guix-bitcoin-arm-stop" ''
    export GUIX_BITCOIN_DATA_DIR=${lib.escapeShellArg cfg.dataDir}
    export GUIX_BITCOIN_ARM_ACTIVE_FILE=${lib.escapeShellArg activeFile}
    export GUIX_BITCOIN_ARM_REGION=${lib.escapeShellArg region}
    export GUIX_BITCOIN_ARM_INSTANCE_ID=${lib.escapeShellArg instanceId}
    export PATH=${
      lib.makeBinPath [
        pkgs.awscli2
        pkgs.coreutils
      ]
    }
    exec ${pkgs.bash}/bin/bash ${armStopSource} "$@"
  '';
in
{
  config = lib.mkIf (cfg.enable && builder.enable && armEnabled) {
    assertions = [
      {
        assertion = config.services.neroGuixOffload.enable;
        message =
          "aarch64-linux profile builds require services.neroGuixOffload.enable.\n"
          + "This prevents an accidental local QEMU fallback.";
      }
    ];

    systemd.services.guix-bitcoin-worker = {
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      serviceConfig = {
        EnvironmentFile = config.sops.templates."guix-bitcoin-build-aws-env".path;
        ExecStartPre = lib.mkAfter [ "+${armPrepare}" ];
        ExecStopPost = lib.mkAfter [ "+${armStop}" ];
        RuntimeDirectory = runtimeDirectory;
        RuntimeDirectoryMode = "0750";
      };
    };
  };
}
