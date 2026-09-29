{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  guixSubstitutesBuilder = config.services.bitcoinCoreGuixSubstitutes.builder;
  guixPublish2KnownHost = lib.removeSuffix "\n" (builtins.readFile ./guix-publish-2-known-host);
in
{
  imports = [
    ../common.nix
    ./disko.nix
    ./guix-arm-lifecycle.nix
    ./guix-offload.nix
    ./hardware-configuration.nix
    ./dnsseedrs-wireguard.nix
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

  services.journald.extraConfig = ''
    SystemMaxUse=12G
    MaxRetentionSec=30day
  '';

  services.bitcoinDnsSeed.mainnet = {
    enable = true;
    threads = 200;
    crawlRate = 40;
  };
  services.bitcoinDnsSeed.signet = {
    enable = true;
    seedNodes = [
      "5.78.116.35:38333"
      "34.254.97.244:38333"
    ];
    threads = 8;
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

  sops.secrets.openai-api-key = {
    owner = "forgejo-review-bot";
    mode = "0400";
  };

  sops.secrets.forgejo-review-bot-webhook-secret = {
    owner = "forgejo-review-bot";
    mode = "0400";
  };

  sops.secrets.forgejo-review-bot-token = {
    owner = "forgejo-review-bot";
    mode = "0400";
  };

  sops.secrets.niks3-api-token = {
    owner = "niks3";
    group = "niks3";
    mode = "0400";
  };

  sops.secrets.niks3-signing-key = {
    owner = "niks3";
    group = "niks3";
    mode = "0400";
  };

  sops.secrets.niks3-r2-access-key = {
    owner = "niks3";
    group = "niks3";
    mode = "0400";
  };

  sops.secrets.niks3-r2-secret-key = {
    owner = "niks3";
    group = "niks3";
    mode = "0400";
  };

  sops.secrets.guix-publish-2-ssh-key = {
    sopsFile = ../../secrets/guix/nero-to-guix-publish-2;
    format = "binary";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  environment.etc."ssh/guix-publish-2.conf".text = ''
    Host guix-publish-2
      HostName guix2.fish.foo
      User root
      Port 22
      IdentityFile ${config.sops.secrets.guix-publish-2-ssh-key.path}
      IdentitiesOnly yes
  '';

  systemd.tmpfiles.rules = [
    "d /root/.ssh 0700 root root -"
    "L+ /root/.ssh/config - - - - /etc/ssh/guix-publish-2.conf"
  ];

  system.activationScripts.guix-publish-2-known-host.text = ''
    known_host=${lib.escapeShellArg guixPublish2KnownHost}
    install -d -m 0700 /root/.ssh
    touch /root/.ssh/known_hosts
    chmod 600 /root/.ssh/known_hosts
    grep -qxF "$known_host" /root/.ssh/known_hosts || printf '%s\n' "$known_host" >> /root/.ssh/known_hosts
  '';

  services.niks3 = {
    enable = true;
    httpAddr = "127.0.0.1:5751";

    apiTokenFile = config.sops.secrets.niks3-api-token.path;
    signKeyFiles = [ config.sops.secrets.niks3-signing-key.path ];

    s3 = {
      endpoint = "edfc2e5212d83182dfa64fa22e3899ec.r2.cloudflarestorage.com";
      bucket = "nix-cache";
      region = "auto";
      useSSL = true;
      accessKeyFile = config.sops.secrets.niks3-r2-access-key.path;
      secretKeyFile = config.sops.secrets.niks3-r2-secret-key.path;
    };

    readProxy.enable = true;
    cacheUrl = "https://cache.nix.fish.foo";
    serverUrl = "https://cache.nix.fish.foo";

    oidc.providers.github = {
      issuer = "https://token.actions.githubusercontent.com";
      audience = "https://cache.nix.fish.foo";
      boundClaims.repository = [
        "bitcoin/bitcoin"
        "willcl-ark/bitcoin"
      ];
    };

    gc = {
      enable = true;
      olderThan = "720h";
      failedUploadsOlderThan = "6h";
      schedule = "*-*-* 03:30:00 UTC";
      randomizedDelaySec = 1800;
    };
  };

  services.caddy.virtualHosts."cache.nix.fish.foo".extraConfig = ''
    reverse_proxy 127.0.0.1:5751
  '';

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

    builder = {
      enable = true;
      nativeSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      publisherHosts = [ "guix-publish-2" ];
    };
  };

  # Add guix-arm-offload-private-key to secrets/secrets.yaml before enabling
  # services.neroGuixOffload. Keeping this declaration gated lets the current
  # x86-only deployment continue to build before the AWS host exists.
  sops.secrets.guix-arm-offload-private-key = lib.mkIf config.services.neroGuixOffload.enable {
    owner = guixSubstitutesBuilder.buildUser;
    group = guixSubstitutesBuilder.buildGroup;
    mode = "0400";
  };

  sops.secrets.aws-nero-access-key = {
    owner = guixSubstitutesBuilder.buildUser;
    group = guixSubstitutesBuilder.buildGroup;
    mode = "0400";
  };

  sops.secrets.aws-nero-secret-key = {
    owner = guixSubstitutesBuilder.buildUser;
    group = guixSubstitutesBuilder.buildGroup;
    mode = "0400";
  };

  sops.templates."guix-bitcoin-build-aws-env".content = ''
    AWS_ACCESS_KEY_ID=${config.sops.placeholder."aws-nero-access-key"}
    AWS_SECRET_ACCESS_KEY=${config.sops.placeholder."aws-nero-secret-key"}
    AWS_DEFAULT_REGION=eu-central-1
  '';

  services.neroGuixOffload.hostKey = builtins.readFile ./guix-arm-builder-host-key.pub;
  services.neroGuixOffload.builderArchiveKeyFile = ./guix-arm-builder-archive-key.pub;
  services.neroGuixOffload = {
    enable = true;
    host = "52.59.139.152";
  };

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

  services.forgejo.settings.migrations.ALLOWED_DOMAINS = lib.mkForce
    "github.com,*.github.com,github-production-user-asset-*.s3.amazonaws.com,cygwin.com,sourceware.org,gitlab.com,*.gitlab.com";
  services.forgejo.settings.migrations.ALLOW_LOCALNETWORKS = lib.mkForce true;
  services.forgejo.settings.mirror.MIN_INTERVAL = "2m";
  services.forgejo.settings."cron.update_mirrors".SCHEDULE = "@every 1m";
  services.forgejo.settings."cron.update_github_metadata_mirrors".SCHEDULE = "@every 1m";
  services.forgejo.settings.service.DISABLE_REGISTRATION = lib.mkForce false;

  services.forgejo.dump.age = "7d";

  systemd.services.forgejo.preStart = lib.mkAfter ''
    install -D -m 0644 ${./forgejo-custom/footer.tmpl} \
      ${lib.escapeShellArg config.services.forgejo.customDir}/templates/custom/footer.tmpl
    install -D -m 0644 ${./forgejo-custom/ralph-anchor.js} \
      ${lib.escapeShellArg config.services.forgejo.customDir}/public/assets/ralph-anchor.js
  '';

  services.github-metadata-backup.bitcoin = {
    enable = true;
    owner = "bitcoin";
    repository = "bitcoin";
    personalAccessTokenFile = config.sops.secrets.github-metadata-backup-github-token.path;
    timerOnCalendar = "*-*-* *:00/2:00 UTC";

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

  services.caddy.virtualHosts."review.fish.foo".extraConfig = ''
    log {
      output file /var/log/caddy/access-review.fish.foo.log
      format filter {
        request>headers delete
      }
    }

    reverse_proxy 127.0.0.1:8765
  '';

  services.forgejoReviewBot = {
    enable = true;
    origin = "https://git.fish.foo/bitcoin/bitcoin.git";
    repository = "bitcoin/bitcoin";
    forgejoApi = "https://git.fish.foo/api/v1/repos/bitcoin/bitcoin";
    promptFile = ../../review-bot-prompt.md;
    auditPromptDir = ../../review-bot-audits;
    openaiKeyFile = config.sops.secrets.openai-api-key.path;
    webhookSecretFile = config.sops.secrets.forgejo-review-bot-webhook-secret.path;
    forgejoTokenFile = config.sops.secrets.forgejo-review-bot-token.path;
    botLogin = "ralph";
  };

  systemd.services.forgejo-review-bot = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

  systemd.services.radicle-node = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

  systemd.timers.github-metadata-backup-bitcoin.timerConfig.Persistent = true;

  systemd.services.github-metadata-backup-bitcoin = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
    script = lib.mkForce ''
      ${config.services.github-metadata-backup.bitcoin.package}/bin/github-metadata-backup \
        --owner=bitcoin \
        --repo=bitcoin \
        --destination=/var/lib/github-metadata-backup/bitcoin/ \
        --personal-access-token-file=${config.sops.secrets.github-metadata-backup-github-token.path}

      ${pkgs.git}/bin/git -C /var/lib/github-metadata-backup/bitcoin/ init
      ${pkgs.git}/bin/git -C /var/lib/github-metadata-backup/bitcoin/ add state.json issues pulls
      if ! ${pkgs.git}/bin/git -C /var/lib/github-metadata-backup/bitcoin/ diff --cached --quiet; then
        ${pkgs.git}/bin/git -C /var/lib/github-metadata-backup/bitcoin/ config user.name "bitcoin:bitcoin"
        ${pkgs.git}/bin/git -C /var/lib/github-metadata-backup/bitcoin/ config user.email "bitcoin-bitcoin@github-metadata-backup"
        ${pkgs.git}/bin/git -C /var/lib/github-metadata-backup/bitcoin/ commit -m "bitcoin:bitcoin GitHub backup from $(date)"
      fi
    '';
  };

  systemd.services.github-metadata-backup-git-pusher-bitcoin = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

}
