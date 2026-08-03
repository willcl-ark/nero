{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  guixSubstitutesDataDir = config.services.bitcoinCoreGuixSubstitutes.dataDir;
in
{
  imports = [
    ../common.nix
    ./disko.nix
    ./guix-offload.nix
    ./guix-substitute-build.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "nero";
  networking.useDHCP = true;
  networking.interfaces.enp6s0.ipv6.addresses = [
    {
      address = "2a01:4f9:3100:441f::1";
      prefixLength = 64;
    }
  ];
  networking.defaultGateway6 = {
    address = "fe80::1";
    interface = "enp6s0";
  };

  services.bitcoinDnsSeed.mainnet = {
    enable = true;
    threads = 40;
  };
  services.bitcoinDnsSeed.signet = {
    enable = true;
    seedNodes = [
      "5.78.116.35:38333"
      "34.254.97.244:38333"
    ];
    threads = 10;
  };

  services.stuntman.enable = true;

  services.openssh.ports = [
    22
    2222
  ];
  services.openssh.extraConfig = ''
    Match LocalPort 22
      DenyUsers root
  '';
  networking.firewall.allowedTCPPorts = [ 2222 ];

  sops.secrets.radicle-private-key = {
    owner = "radicle";
    group = "radicle";
    mode = "0400";
  };

  sops.secrets.github-metadata-backup-github-token = {
    owner = "gmb-bitcoin";
    group = "github-metadata";
    mode = "0400";
  };

  sops.secrets.github-metadata-backup-forgejo-token = {
    owner = "gmb-bitcoin";
    group = "github-metadata";
    mode = "0400";
  };

  services.radicleMirror = {
    enable = true;
    domain = "radicle.fish.foo";

    seed = {
      enable = true;
      privateKeyFile = config.sops.secrets.radicle-private-key.path;
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKPDAHBnAYYRqKFeDBC7VhYa4e6KbIV0VXdW6Bk1QMxZ radicle";
      nodeId = "z6MkqUWxg7edhgBufSVEb39cEmndNEg8FuMhqCKaMB85UXDJ";
    };

    frontend.enable = true;

    bitcoinMirror = {
      enable = true;
      delegateDids = [ "did:key:z6MkminBAVqNKgPS7bT6HqDqbXaE31jqZ8p3eXMAC2czwHJn" ];
    };
  };

  services.bitcoinCoreGuixSubstitutes = {
    enable = true;
    domain = "guix.fish.foo";
    dataDir = "/gnu/guix-bitcoin";

    signingKey = {
      publicFile = ../../secrets/guix/signing-key.pub;
      privateFile = ../../secrets/guix/signing-key.sec;
      signatureFile = ../../secrets/guix/signing-key.pub.asc;
    };
  };

  # Add guix-arm-offload-private-key to secrets/secrets.yaml before enabling
  # services.neroGuixOffload. Keeping this declaration gated lets the current
  # x86-only deployment continue to build before the AWS host exists.
  sops.secrets.guix-arm-offload-private-key = lib.mkIf config.services.neroGuixOffload.enable {
    owner = "guix-bitcoin-build";
    group = "guix-bitcoin-build";
    mode = "0400";
  };

  services.neroGuixOffload.hostKey = builtins.readFile ./guix-arm-builder-host-key.pub;
  services.neroGuixOffload.builderArchiveKeyFile = ./guix-arm-builder-archive-key.pub;
  services.neroGuixOffload = {
    enable = true;
    host = "52.59.139.152";
  };

  services.neroGuixBuild.nativeSystems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  services.guix.substituters.authorizedKeys =
    options.services.guix.substituters.authorizedKeys.default
    ++ [ ./guix-signing-key.pub ];

  services.forgejoSite = {
    enable = true;
    domain = "git.fish.foo";

    admin = {
      user = "willcl-ark";
      email = "will@256k1.dev";
    };

    mailer = {
      enable = true;
      from = "Forgejo <forgejo@fish.foo>";
      protocol = "smtp+starttls";
      smtpAddress = "smtp.mailbox.org";
      smtpPort = 587;
      user = "will@256k1.dev";
    };
  };

  services.forgejo.dump.age = "7d";

  services.github-metadata-backup.bitcoin = {
    enable = true;
    owner = "bitcoin";
    repository = "bitcoin";
    personalAccessTokenFile = config.sops.secrets.github-metadata-backup-github-token.path;
    timerOnCalendar = "*-*-* 06:00:00 UTC";

    pushToRemotes = [
      {
        name = "forgejo";
        remote = "https://git.fish.foo/willcl-ark/github-metadata-backup-bitcoin-bitcoin.git";
        user = "willcl-ark";
        tokenFile = config.sops.secrets.github-metadata-backup-forgejo-token.path;
      }
    ];
  };

  services.caddy.virtualHosts."bitcoin.fish.foo".extraConfig = ''
    redir /pruned-840k /pruned-840k/
    handle_path /pruned-840k/* {
      root * /data/pruned-840k
      file_server browse
    }
  '';

  systemd.services.radicle-node = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

  systemd.timers.github-metadata-backup-bitcoin.timerConfig.Persistent = true;

  systemd.services.github-metadata-backup-bitcoin = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

  systemd.services.github-metadata-backup-git-pusher-bitcoin = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

  systemd.tmpfiles.rules = lib.mkAfter [
    "z ${guixSubstitutesDataDir} 0751 guix-bitcoin-build guix-bitcoin-build -"
  ];

  systemd.services.guix-publish.serviceConfig.ExecStartPre = lib.mkAfter [
    "+${pkgs.coreutils}/bin/chmod 0751 ${guixSubstitutesDataDir}"
  ];

  systemd.services.guix-bitcoin-build.serviceConfig.ExecStartPre = lib.mkAfter [
    "+${pkgs.coreutils}/bin/chmod 0751 ${guixSubstitutesDataDir}"
  ];

  systemd.timers.guix-bitcoin-build.timerConfig = {
    OnBootSec = lib.mkForce [ ];
    OnCalendar = "*-*-* 06:00:00 UTC";
    OnUnitActiveSec = lib.mkForce [ ];
    Persistent = true;
    RandomizedDelaySec = lib.mkForce "0";
  };
}
