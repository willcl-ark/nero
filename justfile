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

# Show and follow the Guix manifest worker.
guix-manifest-logs:
    ssh -p {{ssh_port}} {{target}} "systemctl status guix-manifest-worker.service --no-pager || true; journalctl -fu guix-manifest-worker.service"

# Start the Guix manifest worker immediately.
guix-manifest-start:
    ssh -p {{ssh_port}} {{target}} "sudo systemctl start guix-manifest-worker.service"

# Submit one or more immutable manifest files. Use context=PATH for SCM files.
guix-submit-manifests +args:
    #!/usr/bin/env bash
    set -euo pipefail
    manifests=()
    declare -A seen_manifests=()
    context=
    for arg in {{args}}; do
        case "$arg" in
            context=*) context=${arg#context=} ;;
            *.scm) manifests+=("$arg") ;;
            *) echo "expected manifest path or context=PATH: $arg" >&2; exit 2 ;;
        esac
    done
    if (("${#manifests[@]}" == 0)); then
        echo "submit at least one manifest_*.scm file" >&2
        exit 2
    fi
    stage=$(mktemp -d)
    trap 'rm -rf -- "$stage"' EXIT
    mkdir -p "$stage/manifests"
    for manifest in "${manifests[@]}"; do
        name=$(basename -- "$manifest")
        if [[ ! "$name" =~ ^manifest_[A-Za-z0-9._-]+\.scm$ || ! -f "$manifest" || -L "$manifest" ]]; then
            echo "invalid manifest: $manifest" >&2
            exit 2
        fi
        if [[ -n ${seen_manifests[$name]+x} ]]; then
            echo "duplicate manifest basename: $name" >&2
            exit 2
        fi
        seen_manifests[$name]=1
        cp -- "$manifest" "$stage/manifests/$name"
    done
    if [[ -n "$context" ]]; then
        mkdir -p "$stage/context/contrib/guix"
        cp -a -- "$context/." "$stage/context/contrib/guix/"
    fi
    remote_stage=$(ssh -p {{ssh_port}} {{target}} "sudo mktemp -d {{guix_data_dir}}/jobs/.tmp/manual.XXXXXX")
    remote_stage_q=$(printf '%q' "$remote_stage")
    trap 'ssh -p {{ssh_port}} {{target}} "sudo rm -rf -- $remote_stage_q"' EXIT
    tar -C "$stage" -cf - . | ssh -p {{ssh_port}} {{target}} "sudo tar -C $remote_stage_q -xf -"
    job_id=$(ssh -p {{ssh_port}} {{target}} "sudo /run/current-system/sw/bin/guix-bitcoin-submit --staged $remote_stage_q --method manual")
    ssh -p {{ssh_port}} {{target}} "sudo rm -rf -- $remote_stage_q; sudo systemctl start --no-block guix-manifest-worker.service"
    trap - EXIT
    rm -rf -- "$stage"
    echo "submitted job $job_id"

# Report total node count in the dnsseedrs sqlite db
@db-stats network="mainnet":
    ssh -p {{ssh_port}} {{target}} "nix shell --quiet nixpkgs#sqlite -c sqlite3 /var/lib/dnsseedrs/{{network}}/sqlite.db 'SELECT COUNT(*) FROM nodes;'"

ssh:
    ssh -p {{ssh_port}} {{target}}
