set shell := ["bash", "-uc"]
hostname := "nero"
target := "root@nero"
guix_data_dir := "/gnu/guix-bitcoin"
ssh_port := env_var_or_default("SSH_PORT", "2222")
arm_target := env_var_or_default("ARM_TARGET", "root@arm-guix-builder")
arm_ssh_port := env_var_or_default("ARM_SSH_PORT", "22")
arm_ssh_key := env_var_or_default(
    "ARM_SSH_KEY",
    env_var_or_default("HOME", "/home/will") + "/.ssh/guix-builder-aarch64.pem",
)
module_inputs := "will-nix"

[private]
default:
    just --list

# Deploy NixOS via nixos-anywhere (first install)
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    key="keys/{{hostname}}.txt"
    if [[ ! -f "$key" ]]; then
        echo "Missing $key — run: just gen-key {{hostname}}" >&2
        exit 1
    fi
    pub=$(nix-shell -p age --run "age-keygen -y $key")
    if ! grep -qF "$pub" .sops.yaml; then
        echo "Pubkey $pub not in .sops.yaml — add it and run: just rekey" >&2
        exit 1
    fi
    stage=$(mktemp -d)
    trap "rm -rf $stage" EXIT
    install -D -m 400 "$key" "$stage/var/lib/sops-nix/key.txt"
    nix run github:nix-community/nixos-anywhere -- \
        --generate-hardware-config nixos-generate-config ./hosts/{{hostname}}/hardware-configuration.nix \
        --extra-files "$stage" \
        --flake .#{{hostname}} {{target}}

# Generate an age key for a host at keys/<host>.txt and print the pubkey.
gen-key host=hostname:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p keys
    key="keys/{{host}}.txt"
    if [[ -e "$key" ]]; then
        echo "Refusing to overwrite existing $key" >&2
        exit 1
    fi
    nix-shell -p age --run "age-keygen -o $key"
    chmod 400 "$key"
    pub=$(nix-shell -p age --run "age-keygen -y $key")
    echo
    echo "Add to .sops.yaml under 'keys:':"
    echo "  - &{{host}} $pub"
    echo "Reference *{{host}} in each creation_rules.age list, then run: just rekey"

# Re-encrypt every tracked secret to the recipients in .sops.yaml.
rekey:
    nix-shell -p sops --run "git ls-files secrets | xargs -n1 sops updatekeys -y"

[private]
sync-remote:
    rsync -avz -e 'ssh -p {{ssh_port}}' --delete --exclude='.git' --filter=':- .gitignore' ./ {{target}}:/etc/nixos/
    ssh -p {{ssh_port}} {{target}} "git config --global --add safe.directory /etc/nixos && cd /etc/nixos && git init -q && git add -A"

# Sync repo to remote and switch configuration.
# Reusable service modules are fetched through flake.lock.
switch: sync-remote
    ssh -p {{ssh_port}} {{target}} "cd /etc/nixos && nixos-rebuild switch --flake /etc/nixos#{{hostname}}"

# Sync repo to remote and build there without switching.
# This verifies the same remote flake path used by `just switch`.
build-remote: sync-remote
    ssh -p {{ssh_port}} {{target}} "cd /etc/nixos && nixos-rebuild build --flake /etc/nixos#{{hostname}} --no-link"

# Build locally and switch remote configuration
push:
    NIX_SSHOPTS='-p {{ssh_port}}' nixos-rebuild switch --flake .#{{hostname}} --target-host {{target}}

# Build configuration locally
build:
    nix build .#nixosConfigurations.{{hostname}}.config.system.build.toplevel --show-trace

# Install the native ARM builder through nixos-anywhere.
arm-deploy:
    nix run github:nix-community/nixos-anywhere -- --ssh-option "IdentityFile={{arm_ssh_key}}" --flake .#guix-arm-builder {{arm_target}}

# Sync the repository to the ARM builder for remote evaluation and builds.
[private]
sync-arm-remote:
    rsync -avz -e 'ssh -i {{arm_ssh_key}} -p {{arm_ssh_port}}' --delete --exclude='.git' --filter=':- .gitignore' ./ {{arm_target}}:/etc/nixos/
    ssh -i {{arm_ssh_key}} -p {{arm_ssh_port}} {{arm_target}} "git config --global --add safe.directory /etc/nixos && cd /etc/nixos && git init -q && git add -A"

# Switch an already-installed ARM builder to the current configuration.
arm-switch: sync-arm-remote
    ssh -i {{arm_ssh_key}} -p {{arm_ssh_port}} {{arm_target}} "cd /etc/nixos && nixos-rebuild switch --flake /etc/nixos#guix-arm-builder"

# Check the native ARM builder's Guix daemon and SSH service.
arm-status:
    ssh -i {{arm_ssh_key}} -p {{arm_ssh_port}} {{arm_target}} "systemctl status guix-daemon.service sshd.service --no-pager"

# Test Nero's configured Guix offload machines.
guix-offload-test:
    ssh -p {{ssh_port}} {{target}} "guix offload test"

# Stop the ARM builder after an aborted or manual build.
arm-poweroff:
    ssh -i {{arm_ssh_key}} -p {{arm_ssh_port}} {{arm_target}} "systemctl poweroff"

# Update flake inputs
update:
    nix flake update

# Update reusable service modules from GitHub
update-modules:
    nix flake update {{module_inputs}}

logs network="mainnet":
    ssh -p {{ssh_port}} {{target}} "systemctl status dnsseedrs-{{network}} && journalctl -f -u dnsseedrs-{{network}}"

# Show and follow the Guix Bitcoin worker.
guix-worker-logs:
    ssh -p {{ssh_port}} {{target}} "systemctl status guix-bitcoin-worker.service --no-pager || true; journalctl -fu guix-bitcoin-worker.service"

# Start the Guix Bitcoin worker immediately.
guix-worker-start:
    ssh -p {{ssh_port}} {{target}} "systemctl start --no-block guix-bitcoin-worker.service"

# Show the worker state and queued or running source jobs.
guix-queue:
    #!/usr/bin/env bash
    set -euo pipefail
    ssh -p {{ssh_port}} {{target}} '
        jobs_root={{guix_data_dir}}/jobs
        worker_state=$(systemctl is-active guix-bitcoin-worker.service 2>/dev/null || true)
        printf "worker: %s\n" "${worker_state:-unknown}"
        for state in queued running; do
            printf "\n%s:\n" "$state"
            found=false
            for job in "$jobs_root/$state"/*; do
                [ -d "$job" ] || continue
                found=true
                printf "  %s\n" "${job##*/}"
                if [ -f "$job/source_repository" ] && [ -f "$job/source_commit" ]; then
                    printf "    source_repository=%s\n" "$(cat "$job/source_repository")"
                    printf "    source_commit=%s\n" "$(cat "$job/source_commit")"
                else
                    printf "    (missing source descriptor)\n"
                fi
            done
            [ "$found" = true ] || printf "  (empty)\n"
        done
    '

# Submit an exact Bitcoin Core commit, optionally from a fork repository.
guix-submit commit repository="":
    #!/usr/bin/env bash
    set -euo pipefail
    commit={{quote(commit)}}
    repository={{quote(repository)}}
    repository=${repository:-https://github.com/bitcoin/bitcoin}
    if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
        echo "commit must be a full lowercase 40-character hash" >&2
        exit 2
    fi
    submit=(GUIX_BITCOIN_REPOSITORY="$repository" /run/current-system/sw/bin/guix-bitcoin-submit)
    [[ -z $repository ]] || submit+=(--repository "$repository")
    submit+=("$commit")
    remote_command=$(printf '%q ' "${submit[@]}")
    job_id=$(ssh -p {{ssh_port}} {{target}} "$remote_command")
    ssh -p {{ssh_port}} {{target}} "systemctl start --no-block guix-bitcoin-worker.service"
    echo "submitted job $job_id"

# Fetch and submit the configured Bitcoin Core master branch now.
guix-submit-master:
    ssh -p {{ssh_port}} {{target}} "systemctl start --no-block guix-bitcoin-nightly.service"

# Report total node count in the dnsseedrs sqlite db
@db-stats network="mainnet":
    ssh -p {{ssh_port}} {{target}} "nix shell --quiet nixpkgs#sqlite -c sqlite3 /var/lib/dnsseedrs/{{network}}/sqlite.db 'SELECT COUNT(*) FROM nodes;'"

ssh:
    ssh -p {{ssh_port}} {{target}}
