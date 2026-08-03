{
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
