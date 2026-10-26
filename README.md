# nix-dnsseed

NixOS host aggregator for the `dnsseed` and `nero` machines.

## Overview

This flake composes reusable service modules from
`github:willcl-ark/nix`.

Modules currently consumed by this repo:

- **bitcoin-dnsseed** -- `dnsseedrs`, CoreDNS, DNSSEC secrets, seed dumps, Tor/I2P
- **bitcoin-core-guix-substitutes** -- Guix publish and Bitcoin Core build profiles
- **stuntman** -- STUNTMAN STUN server and btcpunch rendezvous helper
- **forgejo-site** -- Forgejo, Anubis, Caddy route, secrets, admin bootstrap
- **ralph** -- first-pass pull request reviews

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
    ralph/
    stuntman/
```

This flake pins that collection as the `will-nix` input. The modules
expose the service interfaces; this repo supplies site-local values such as
domains, secret paths, and data placement.

Bitcoin Core review prompts and model assignments live in the shared
[will-nix ralph package](https://github.com/willcl-ark/nix/tree/master/pkgs/ralph).
Nero uses the package defaults through its pinned `will-nix` input.

For unpublished module changes, `just switch-local-nix` copies the local
`/home/will/src/nix` checkout to Nero and switches with a temporary input
override. After publishing, run `just update-modules` and then `just switch`.

## Ralph Codex subscription trial

`will-nix` follows `ralph-codex-proxy`. OpenAI review stages and follow-up
assessments use CLIProxyAPI on `127.0.0.1:8317`; PPQ keeps its own endpoint and
credential. The encrypted `cli-proxy-api-key` secret authenticates Ralph to the
proxy. Only the proxy user can read the upstream OAuth files.

Apply this configuration from the local checkout after active reviews finish:

```sh
cd /home/will/src/nero
just switch
```

The proxy starts, but Ralph and follow-up assessments skip startup until the
operator enables them. Telegram and statistics remain available. Old queued
engine configurations need requeuing after the endpoint cutover.

SSH to Nero and log in as the proxy service user:

```sh
ssh -p 2222 root@nero
cd /var/lib/cli-proxy-api
runuser -u cli-proxy-api -- env HOME=/var/lib/cli-proxy-api \
  /run/current-system/sw/bin/cli-proxy-api \
  --config /run/secrets/rendered/cli-proxy-api.yaml \
  --codex-device-login --no-browser
```

Open the displayed device-login URL on your own computer and enter the code.
No port forwarding is needed. Authenticate with the ChatGPT account whose
subscription should pay for Ralph. This installs no coding CLI agent and makes
no review request. Credentials persist under `/var/lib/cli-proxy-api/auth`.

Restart the proxy, then inspect the authenticated model list without printing
the client key or passing it in curl's process arguments:

```sh
systemctl restart cli-proxy-api
{
  printf 'header = "Authorization: Bearer '
  tr -d '\n' < /run/secrets/cli-proxy-api-key
  printf '"\n'
} | curl --fail --silent --show-error --config - http://127.0.0.1:8317/v1/models
```

Check that the list includes the configured OpenAI model IDs, currently
`gpt-6-luna` and `gpt-6.1-sol`. A model list is not an inference entitlement
test; the first Ralph review on Nero should verify tool calls and structured
results after the queue is enabled. Subscription dollar totals remain API-equivalent
usage estimates. The proxy removes the Codex output-token cap, so local
reservations do not bound each response. No paid OpenAI credentials are
configured in the proxy.

Enable Ralph and follow-up checks after verifying login and model access:

```sh
touch /var/lib/cli-proxy-api/ralph-enabled
systemctl start ralph
systemctl start ralph-followup
```

The marker survives reboot. To pause review requests again, remove it and stop
both units; the proxy and Telegram monitor can remain running.

### Log out or switch subscription accounts

CLIProxyAPI retains separate credential files for different accounts. Another
login adds an account; it does not replace the old one. For a single-account
cutover, SSH to Nero and pause requests before removing the old credentials:

```sh
ssh -p 2222 root@nero
rm -f /var/lib/cli-proxy-api/ralph-enabled
systemctl stop ralph-followup.timer ralph-stats.timer
systemctl stop ralph-followup.service ralph-stats.service ralph.service cli-proxy-api.service
find /var/lib/cli-proxy-api/auth -type f -name 'codex-*.json' -delete
```

This removes all saved Codex accounts from this proxy. The proxy is stopped so
it cannot keep using tokens in memory or refresh and rewrite deleted files.
Stop here to remain logged out. This is local credential removal, not upstream
OAuth revocation or a logout of your other devices. The SOPS client key is
independent of the subscription account and does not need changing.

To use a different account, run the same device-login flow with the proxy
service still stopped:

```sh
cd /var/lib/cli-proxy-api
runuser -u cli-proxy-api -- env HOME=/var/lib/cli-proxy-api \
  /run/current-system/sw/bin/cli-proxy-api \
  --config /run/secrets/rendered/cli-proxy-api.yaml \
  --codex-device-login --no-browser
```

Approve the device code using the replacement ChatGPT account. A private browser
window can help keep it separate from your usual browser login. If login fails,
leave Ralph paused and retry the login command.

After successful login, start the proxy and use the authenticated model-list
check above. Then enable Ralph and restore both timers:

```sh
systemctl start cli-proxy-api
# Check the authenticated model list before enabling requests.
touch /var/lib/cli-proxy-api/ralph-enabled
systemctl start ralph.service ralph-stats.timer ralph-followup.timer
```

No Nix rebuild is needed when changing subscription accounts.

## Secrets

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix) and encrypted with age + PGP keys. The server decrypts at boot using an age key at `/var/lib/sops-nix/key.txt`.

Managed secrets:
- Cloudflare API token (for Caddy ACME DNS challenges)
- DNSSEC keys (ZSK + KSK per network, deployed as binary files)
- Forgejo secrets and mailer password
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
# (returns immediately; submit job handling continues on the host)
just guix-submit-master

# Follow or start the Bitcoin source-job worker
just guix-worker-logs
just guix-worker-start

# Show the worker state and queued/running jobs
just guix-queue

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
