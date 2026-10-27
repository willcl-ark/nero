{ config, lib, ... }:
let
  tailscale = lib.getExe config.services.tailscale.package;
in
{
  sops.secrets.tailscale-auth-key.mode = "0400";

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.sops.secrets.tailscale-auth-key.path;
    extraUpFlags = [ "--accept-dns=false" ];
  };

  systemd.services.tailscaled-autoconnect = {
    after = [ "sops-install-secrets.service" ];
    requires = [ "sops-install-secrets.service" ];
  };

  systemd.services.tailscale-serve-cliproxy = {
    description = "Serve CLIProxyAPI privately over Tailscale HTTPS";
    wantedBy = [ "multi-user.target" ];
    after = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
      "cli-proxy-api.service"
    ];
    requires = [ "tailscaled-autoconnect.service" ];
    wants = [ "cli-proxy-api.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${tailscale} serve --bg --yes --https=443 http://127.0.0.1:8317";
      ExecStop = "${tailscale} serve --yes --https=443 off";
    };
  };
}
