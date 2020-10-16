nixosPath: systemConfig:

let
  nixos = toString nixosPath;

  baseModules = if builtins.pathExists "${nixos}/modules/virtualisation/nixos-containers.nix"
                then baseModulesLatest
                else baseModules_20_03;

  # Minimal module sets for evaluating container configs.
  # They significantly reduce extra-container evaluation overhead (total eval time - container eval time)

  # Compatible with nixpkgs 16.09-20.03 (inclusive)
  baseModules_20_03 = [
    "${nixos}/modules/misc/assertions.nix"
    "${nixos}/modules/misc/nixpkgs.nix"
    "${nixos}/modules/system/activation/top-level.nix"
    "${nixos}/modules/system/etc/etc.nix"
    "${nixos}/modules/system/boot/systemd.nix"
    "${nixos}/modules/virtualisation/containers.nix"
    ({ lib, ... }: let
      optionValue = default: lib.mkOption { inherit default; };
    in {
      # Top-level config attrs need corresponding option definitions
      # even if they are unused.
      # Add dummy definitions instead of costly module imports.
      options = {
        boot.kernel = {};
        boot.kernelModules = {};
        environment.profiles = {};
        environment.systemPackages = {};
        networking = {};
        nix = {};
        security = {};
        services = {
          dbus = {};
          udev = {};
          rsyslogd.enable = optionValue false;
          syslog-ng.enable = optionValue false;
        };
        system.activationScripts = optionValue "";
        system.path = optionValue "";
        system.requiredKernelConfig = {};
        users = {};
     };
    })
  ];

  # Compatible with nixpkgs > 20.03
  baseModulesLatest = [
    "${nixos}/modules/misc/assertions.nix"
    "${nixos}/modules/misc/nixpkgs.nix"
    "${nixos}/modules/system/activation/top-level.nix"
    "${nixos}/modules/system/etc/etc.nix"
    "${nixos}/modules/system/boot/systemd.nix"
    "${nixos}/modules/virtualisation/nixos-containers.nix"
    ({ lib, ... }: let
      optionValue = default: lib.mkOption { inherit default; };
      dummy = optionValue [];
    in {
      options = {
        boot.kernel.sysctl = dummy;
        boot.kernelModules = dummy;
        environment.systemPackages = dummy;
        networking.dhcpcd.denyInterfaces = dummy;
        networking.extraHosts = dummy;
        networking.proxy.envVars = optionValue {};
        security = dummy;
        services = {
          dbus = dummy;
          udev = dummy;
          rsyslogd.enable = optionValue false;
          syslog-ng.enable = optionValue false;
        };
        system.activationScripts = dummy;
        system.path = optionValue "";
        system.nssDatabases = dummy;
        system.nssModules = dummy;
        system.requiredKernelConfig = dummy;
        ids.gids.keys = dummy;
        ids.gids.systemd-journal = dummy;
        ids.gids.systemd-journal-gateway = dummy;
        ids.uids.systemd-journal-gateway = dummy;
        ids.gids.systemd-network = dummy;
        ids.uids.systemd-network = dummy;
        ids.uids.systemd-resolve = dummy;
        ids.gids.systemd-resolve = dummy;
        users.users.systemd-network.uid = dummy;
        users.users.systemd-resolve.uid = dummy;
        users.users.systemd-journal-gateway.uid = dummy;
        users.groups.systemd-network.gid = dummy;
        users.groups.systemd-resolve.gid = dummy;
        users.groups.keys.gid = dummy;
        users.groups.systemd-journal.gid = dummy;
        users.groups.systemd-journal-gateway.gid = dummy;
     };
    })
  ];

  containerAssert = cond: name: msg: value:
    if cond then value
    else throw "container '${name}': ${msg}'";

  assertNonNull = var:
    containerAssert (var != null);

  extraModule = { config, pkgs, lib, ... }: with lib; {
    options = {
      containers = mkOption {
        type = types.attrsOf (types.submodule (
          { config, name, ... }: {
            options = {
              extra = {
                addressPrefix = mkOption {
                  type = with types; nullOr str;
                  default = null;
                  description = ''
                    Enable privateNetwork and set
                    hostAddress = ${addressPrefix}.1
                    localAddress = ${addressPrefix}.2
                  '';
                };
                enableWAN = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Enable WAN access inside the container by rewriting container traffic
                    to use the host's address (NAT).

                    Only active when privateNetwork == true.
                  '';
                };
                exposeLocalhost = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Forward requests from the container's external interface
                    to the container's localhost.
                    Useful to test internal services from outside the container.

                    WARNING: This exposes the container's localhost to all users.
                    Only use in a trusted environment.

                    Only active when privateNetwork == true.
                  '';
                };
                firewallAllowHost = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Always allow connections from the container host.

                    Only active when privateNetwork == true.
                  '';
                };
              };
            };

            config = mkMerge [
              (
                let
                  prefix = config.extra.addressPrefix;
                in mkIf (prefix != null) {
                  privateNetwork = true;
                  hostAddress = "${prefix}.1";
                  localAddress = "${prefix}.2";
                }
              )
              {
                config = ({ pkgs, ... }: mkMerge [
                  {
                    systemd.services.forward-to-localhost = mkIf (config.extra.exposeLocalhost && config.privateNetwork) {
                      wantedBy = [ "network.target" ];
                      script = assertNonNull config.localAddress name
                        ''
                          option extra.exposeLocalhost requires localAddress to be non-null.
                        ''
                        ''
                          ${pkgs.procps}/bin/sysctl -w net.ipv4.conf.all.route_localnet=1
                          ${pkgs.iptables}/bin/iptables -t nat -I PREROUTING -p tcp \
                            -d ${config.localAddress} ! --dport 80 -j DNAT --to-destination 127.0.0.1
                        '';
                    };
                    networking.firewall.extraCommands = mkIf (config.extra.firewallAllowHost && config.privateNetwork) (
                      assertNonNull config.hostAddress name
                        ''
                          option extra.exposeLocalhost requires hostAddress to be non-null.
                        ''
                        ''
                          iptables -w -A nixos-fw -s ${config.hostAddress} -j ACCEPT
                        ''
                    );
                  }
                ]);
              }
            ];
          }
        ));
      };
    };

    config = {
      systemd.services = let
        WANContainers = builtins.filter (c:
                          let cfg = config.containers.${c};
                          in cfg.privateNetwork && cfg.extra.enableWAN
                        ) (builtins.attrNames config.containers);
        iptables = "${pkgs.iptables}/bin/iptables";
        serviceCfg = c: let
          containerAddress = config.containers.${c}.localAddress;
        in
          assertNonNull containerAddress c
          ''
            option extra.enableWAN requires localAddress to be non-null
          ''
          {
            preStart = "${iptables} -w -t nat -A POSTROUTING -s ${containerAddress} -j MASQUERADE";
            postStop = "${iptables} -w -t nat -D POSTROUTING -s ${containerAddress} -j MASQUERADE || true";
          };
      in
        listToAttrs (map (c: nameValuePair "container@${c}" (serviceCfg c)) WANContainers);
    };
  };
in
import "${nixos}/lib/eval-config.nix" {
  inherit baseModules;
  modules = [ extraModule systemConfig ];
}
