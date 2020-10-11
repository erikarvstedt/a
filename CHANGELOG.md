# 0.5 (unreleased)
- Enhancements
  - Add generic support for systemd-based Linux distros.
  - Add command `shell`.
  - Add extra container options:  
    `extra.enableWAN`  
    `extra.exposeLocalhost`  
    `extra.firewallAllowHost`  
    See [eval-config.nix](eval-config.nix) for descriptions.
  - Add option `--ssh`.
  - Add option `--expr|-E`.
  - Append `pwd` to `NIX_PATH` to allow accessing the working dir in non-file configs.
  - Support nixpkgs versions > 20.03.
- Fixes
  - Don't copy local nixpkgs sources provided via `--nixpkgs` to the nix store.

# 0.4 (2020-09-25)
- Enhancements
  - Significantly speed up container evaluation.  
    Use a reduced module set for evaluating the container host system derivation.
  - Speed up container destruction.  
    Kill the container process instead of a clean shutdown.
