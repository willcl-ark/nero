{
  config,
  pkgs,
  ...
}:
let
  caddyWithCloudflare = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.3" ];
    hash = "sha256-8KwWkxhCyz7cxRFjm47tUS/veVH7cVzv/+FQ16ri3jE=";
  };

in
{
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
  ];

  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets.cloudflare-api-token = { };

    # Caddy needs the Cloudflare token as an env var for ACME DNS challenges.
    # sops.templates creates a KEY=VALUE file that systemd reads via EnvironmentFile.
    templates."caddy-env".content = ''
      CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare-api-token"}
    '';
  };

  services.caddy = {
    enable = true;
    package = caddyWithCloudflare;
    globalConfig = ''
      acme_dns cloudflare {$CLOUDFLARE_API_TOKEN}
      servers {
        trusted_proxies static 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
        client_ip_headers CF-Connecting-IP
      }
    '';
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile = config.sops.templates."caddy-env".path;

  services.bitcoinDnsSeed = {
    enable = true;
    serverName = "ns.fish.foo";
    soaRname = "will.256k1.dev";

    mainnet.dnssecKeyFiles = [
      ../secrets/dnssec/mainnet/Kseed.bitcoin.fish.foo.+013+00562.key
      ../secrets/dnssec/mainnet/Kseed.bitcoin.fish.foo.+013+00562.private
      ../secrets/dnssec/mainnet/Kseed.bitcoin.fish.foo.+013+42136.key
      ../secrets/dnssec/mainnet/Kseed.bitcoin.fish.foo.+013+42136.private
    ];

    signet.dnssecKeyFiles = [
      ../secrets/dnssec/signet/Kseed.signet.bitcoin.fish.foo.+013+15250.key
      ../secrets/dnssec/signet/Kseed.signet.bitcoin.fish.foo.+013+15250.private
      ../secrets/dnssec/signet/Kseed.signet.bitcoin.fish.foo.+013+32912.key
      ../secrets/dnssec/signet/Kseed.signet.bitcoin.fish.foo.+013+32912.private
    ];
  };

  # Required for remote nixos-rebuild switch via justfile.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  environment.systemPackages = [
    pkgs.git
    pkgs.ghostty.terminfo
    pkgs.htop
  ];

  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "25.11";
}
