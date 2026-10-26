{ config, ... }:
let
  proxy = config.services.cli-proxy-api;
  readyFile = "${proxy.dataDir}/ralph-enabled";
in
{
  services.cli-proxy-api = {
    enable = true;
    configFile = config.sops.templates."cli-proxy-api.yaml".path;
  };

  environment.systemPackages = [ proxy.package ];

  sops.secrets.cli-proxy-api-key = {
    owner = "ralph";
    mode = "0400";
  };

  sops.templates."cli-proxy-api.yaml" = {
    owner = "cli-proxy-api";
    mode = "0400";
    content = ''
      config-version: 8
      server:
        host: "127.0.0.1"
        port: 8317
      management:
        secret-key: ""
        disable-control-panel: true
      access:
        api-keys:
          - "${config.sops.placeholder.cli-proxy-api-key}"
      routing:
        retry:
          request-retry: 0
      oauth:
        auth-dir: "${proxy.dataDir}/auth"
    '';
  };

  services.ralph = {
    openaiApiBase = "http://127.0.0.1:8317/v1";
    openaiKeyFile = config.sops.secrets.cli-proxy-api-key.path;
  };

  systemd.services.cli-proxy-api = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

  # Enable review requests only after the operator completes Codex login.
  systemd.services.ralph = {
    after = [ "cli-proxy-api.service" ];
    requires = [ "cli-proxy-api.service" ];
    unitConfig.ConditionPathExists = readyFile;
  };
  systemd.services.ralph-followup.unitConfig.ConditionPathExists = readyFile;
}
