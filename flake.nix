{
  description = "Bitcoin DNS seed deployment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    dnsseedrs = {
      url = "github:willcl-ark/dnsseedrs";
      flake = false;
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    will-nix = {
      url = "github:willcl-ark/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    b10c-nix = {
      url = "github:0xB10C/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    forgejo-src = {
      url = "github:willcl-ark/forgejo/full-mirror";
      flake = false;
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niks3 = {
      url = "github:Mic92/niks3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      dnsseedrsPackageModule =
        { pkgs, ... }:
        {
          services.bitcoinDnsSeed.package = pkgs.callPackage inputs.dnsseedrs { };
        };
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { pkgs, ... }:
        {
          formatter = pkgs.nixfmt-tree;
        };

      flake = {
        nixosConfigurations.dnsseed = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            inputs.disko.nixosModules.disko
            inputs.sops-nix.nixosModules.sops
            inputs.will-nix.nixosModules.bitcoin-dnsseed
            dnsseedrsPackageModule
            ./hosts/dnsseed
          ];
        };

        nixosConfigurations.nero = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            inputs.disko.nixosModules.disko
            inputs.sops-nix.nixosModules.sops
            inputs.will-nix.nixosModules.bitcoin-dnsseed
            dnsseedrsPackageModule
            inputs.will-nix.nixosModules.radicle-mirror
            inputs.will-nix.nixosModules.bitcoin-core-guix-substitutes
            inputs.will-nix.nixosModules.stuntman
            inputs.will-nix.nixosModules.forgejo-site
            inputs.will-nix.nixosModules.forgejo-review-bot
            inputs.niks3.nixosModules.niks3
            inputs.b10c-nix.nixosModules.default.github-metadata-backup
            {
              nixpkgs.overlays = [
                (_final: prev: {
                  forgejo = prev.forgejo.overrideAttrs {
                    src = inputs.forgejo-src;
                    vendorHash = "sha256-cb6f7ZX3pG95EEZotGXn6+YUJN59SFNVHFTejFJ6y28=";
                    doCheck = false;
                    patches = (prev.forgejo.patches or []) ++ [
                      ./patches/forgejo-review-bot-comments.patch
                      ./patches/forgejo-github-metadata-sync-webhook.patch
                      ./patches/forgejo-github-metadata-comment-edits.patch
                      ./patches/forgejo-github-metadata-review-comment-map.patch
                      ./patches/forgejo-resource-index-sync.patch
                    ];
                    postPatch = ''
                      ${prev.forgejo.postPatch}
                      rm -rf vendor
                    '';
                  };
                })
              ];
            }
            ./hosts/nero
          ];
        };

        nixosConfigurations.guix-arm-builder = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            inputs.disko.nixosModules.disko
            ./hosts/guix-arm-builder
          ];
        };
      };
    };
}
