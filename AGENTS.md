# Working rules

- Think before coding. State assumptions and resolve material ambiguity.
- Make the smallest focused change that meets the request. Reuse existing code
  and conventions; avoid speculative abstractions and unrelated cleanup.
- Define a verifiable result. Reproduce fixes before changing code, then check
  the result. Review the diff before presenting it.
- Keep commits small and atomic. Use concise titles and rationale in prose,
  wrapping commit bodies at 80 columns.
- Use a hard cutover rather than adding backward compatibility.
- Never write to GitHub without permission. Push only feature branches; never
  push to main or master without explicit human override.
- Record noteworthy implementation decisions in `implementation.md` without
  committing that file unless asked.
- Use the `grant-log` skill for substantive work before the final response.
- Delegate independent work to subagents when it can run in parallel.

# Shared Nix modules

Reusable NixOS modules and packages live in `/home/will/src/nix`. This repo
consumes that flake as the `will-nix` input in `flake.nix`; host domains,
secrets, and deployment choices stay here. The Forgejo review bot follows
that split. Its shared module and package are edited in the Nix repo, while
Nero supplies its site-specific configuration.

The Bitcoin Core review prompts and model assignments live only in the shared
Nix package at `/home/will/src/nix/pkgs/forgejo-review-bot/` (`prompt.md` and
`audits/`). Nero uses the module defaults. Edit those files in the Nix repo,
then publish the change and update Nero's `will-nix` pin before `just switch`.
For an unpublished shared change, use `just switch-local-nix` instead.

For development before publishing the Nix repo, build against the local
checkout without changing `flake.lock`:

```sh
nix build .#nixosConfigurations.nero.config.system.build.toplevel \
  --override-input will-nix path:/home/will/src/nix
```

Use `just switch-local-nix` to copy both checkouts to Nero and switch with a
local `will-nix` override. The normal `just switch` uses the pinned GitHub
input. If this repo imports an unpublished module, a normal switch cannot
evaluate until that module is published and the pin is updated.

After the shared Nix change is published, update only its pin from this repo:

```sh
nix flake update will-nix
just switch
```

`just update-modules` runs the same input update command.

The input is named `will-nix`, not `review-bot`. Review the `flake.lock` diff
before committing it. Do not replace the committed GitHub input with a
machine-specific absolute path.
