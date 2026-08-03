{
  config,
  options,
  pkgs,
  ...
}:
{
  imports = [
    ./disko.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "guix-arm-builder";
  networking.useDHCP = true;

  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # The root account is used for Guix offload because guix-daemon launches the
  # offload hook as root on Nero. Add the dedicated offload public key here
  # before enabling ARM offload on Nero.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
  ];

  networking.firewall.allowedTCPPorts = [ 22 ];

  services.guix = {
    enable = true;
    nrBuildUsers = 4;
    extraArgs = [
      "--max-jobs=4"
    ];
  };

  # Guix offload uses archive signatures in addition to SSH. Generate the
  # builder's local archive key once; Nero's public key is authorized above,
  # and the generated builder public key must later be authorized on Nero.
  systemd.services.guix-archive-key = {
    description = "Generate the Guix builder archive key";
    before = [ "guix-daemon.service" ];
    wantedBy = [ "guix-daemon.service" ];
    script = ''
      if [ ! -e /etc/guix/signing-key.sec ]; then
        ${config.services.guix.package}/bin/guix archive --generate-key
      fi
    '';
    serviceConfig.Type = "oneshot";
  };

  services.guix.substituters.authorizedKeys =
    options.services.guix.substituters.authorizedKeys.default
    ++ [ ../nero/guix-signing-key.pub ];

  services.guix.gc = {
    enable = true;
    dates = "04:00";
    extraArgs = [
      "--free-space=20G"
    ];
  };

  environment.systemPackages = [
    pkgs.git
    pkgs.htop
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "26.05";
}
