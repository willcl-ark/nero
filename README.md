# nix-dnsseed

NixOS host aggregator for the `dnsseed` and `nero` machines.

## Overview

This flake composes reusable service modules from
`github:willcl-ark/nix`.

Modules currently consumed by this repo:

- **bitcoin-dnsseed** -- `dnsseedrs`, CoreDNS, DNSSEC secrets, seed dumps, Tor/I2P
- **bitcoin-core-guix-substitutes** -- Guix publish and Bitcoin Core build profiles
- **radicle-mirror** -- public Radicle seed, explorer frontend, Bitcoin Core mirror
- **stuntman** -- STUNTMAN STUN server and btcpunch rendezvous helper
- **forgejo-site** -- Forgejo, Anubis, Caddy route, secrets, admin bootstrap

Host-local configuration stays here: hardware/disko config, domains, encrypted
secret file paths, host sizing, and deployment commands.

## Module Layout

Reusable modules live under a single top-level Nix collection repo:

```text
github.com/willcl-ark/nix
  flake.nix
  modules/
    bitcoin-dnsseed/
    bitcoin-core-guix-substitutes/
    forgejo-site/
    radicle-mirror/
    stuntman/
```

This flake pins that collection as the `will-nix` input. The modules
expose the service interfaces; this repo supplies site-local values such as
domains, secret paths, and data placement.

## Secrets

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix) and encrypted with age + PGP keys. The server decrypts at boot using an age key at `/var/lib/sops-nix/key.txt`.

Managed secrets:
- Cloudflare API token (for Caddy ACME DNS challenges)
- DNSSEC keys (ZSK + KSK per network, deployed as binary files)
- Forgejo secrets and mailer password
- Radicle private key
- Guix substitute signing keys

## Usage

Requires [just](https://github.com/casey/just) and [nix](https://nixos.org/download/) with flakes enabled.

```bash
# First-time deploy via nixos-anywhere (wipes target disk)
just deploy

# Sync config and rebuild on the remote
just switch

# Sync config and build on the remote without switching
just build-remote

# Build locally to check for errors
just build

# Tail service logs (defaults to mainnet)
just logs
just logs signet

# Submit an exact Bitcoin Core commit, from upstream or a fork
just guix-submit 0123456789abcdef0123456789abcdef01234567
just guix-submit 0123456789abcdef0123456789abcdef01234567 \
    https://github.com/example/bitcoin

# Fetch and submit the configured bitcoin/bitcoin master branch now
just guix-submit-master

# Follow or start the Bitcoin source-job worker
just guix-worker-logs
just guix-worker-start

# Update flake inputs
just update
```

### Initial setup

1. Deploy with `just deploy` (generates `hardware-configuration.nix` from the target)
2. Generate an age key on the server: `ssh root@dnsseed "mkdir -p /var/lib/sops-nix && age-keygen -o /var/lib/sops-nix/key.txt"`
3. Add the server's public key to `.sops.yaml` and re-encrypt all secrets:
   ```bash
   # The age-keygen output from step 2 prints the public key (age1...).
   # Add it as &server in .sops.yaml under the keys: section, and include
   # *server in each creation rule's age list.

   # Re-encrypt the YAML secrets
   sops updatekeys secrets/secrets.yaml

   # Re-encrypt the binary DNSSEC keys
   for f in secrets/dnssec/mainnet/K* secrets/dnssec/signet/K*; do
     sops updatekeys --input-type binary -y "$f"
   done
   ```
4. Apply with `just switch`
