{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.bitcoinDnsSeed;
  ip = "${pkgs.iproute2}/bin/ip";

  namespace = "dnsseedrs";
  namespaceVeth = "dnsseedrs-ns";
  hostVeth = "dnsseedrs-host";
  namespaceAddress = "10.200.1.1";
  hostAddress = "10.200.1.0";

  wireguardInterface = "wg-dnsseedrs";
  wireguardAddress = "10.200.0.1/32";
  wireguardAddress6 = "fd42:200:200::1/128";
  wireguardEndpoint = "45.133.119.39:51820";
  wireguardEndpointAddress = "45.133.119.39";
  wireguardPeerPublicKey = "jOFSDXK6vPG5xc1+Xg/qqvVUeoq6BODt+LnqIhX+NFA=";
in
{
  sops.useSystemdActivation = true;

  sops.secrets.wireguard-nero-private-key = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  environment.etc."netns/${namespace}/resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 8.8.8.8
  '';

  # Keep the public DNS listener in the root namespace, while forwarding its
  # seed-zone queries across the veth to dnsseedrs in its private namespace.
  services.coredns.config = lib.mkForce ''
    ${cfg.mainnet.seedDomain}:53 {
      bind ${lib.concatStringsSep " " cfg.coredns.bindAddresses}
      forward . ${namespaceAddress}:${toString cfg.mainnet.dnsPort}
      any
      log
    }

    ${cfg.signet.seedDomain}:53 {
      bind ${lib.concatStringsSep " " cfg.coredns.bindAddresses}
      forward . ${namespaceAddress}:${toString cfg.signet.dnsPort}
      any
      log
    }

    .:53 {
      bind ${lib.concatStringsSep " " cfg.coredns.bindAddresses}
      template ANY ANY {
        rcode REFUSED
      }
      log
    }
  '';

  services.bitcoinDnsSeed.proxies = {
    onionProxy = "${hostAddress}:9050";
    i2pProxy = "${hostAddress}:4447";
  };

  services.tor.client.socksListenAddress = {
    addr = hostAddress;
    port = 9050;
    IsolateDestAddr = true;
  };
  services.i2pd.proto.socksProxy.address = hostAddress;

  # A separate namespace gives only dnsseedrs access to the WireGuard default
  # routes. The root-side veth address is also trusted by the host firewall so
  # CoreDNS can receive replies from the namespace.
  networking.firewall.trustedInterfaces = [ hostVeth ];

  networking.nat = {
    enable = true;
    enableIPv6 = true;
    externalInterface = "enp6s0";
    internalInterfaces = [ hostVeth ];
  };

  networking.wireguard.interfaces.${wireguardInterface} = {
    interfaceNamespace = namespace;
    privateKeyFile = config.sops.secrets.wireguard-nero-private-key.path;
    ips = [
      wireguardAddress
      wireguardAddress6
    ];
    peers = [
      {
        publicKey = wireguardPeerPublicKey;
        endpoint = wireguardEndpoint;
        allowedIPs = [
          "0.0.0.0/0"
          "::/0"
        ];
        persistentKeepalive = 25;
      }
    ];
  };

  systemd.services.dnsseedrs-netns = {
    description = "Network namespace for dnsseedrs and WireGuard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-pre.target" ];
    wants = [ "network-pre.target" ];
    unitConfig.Before = [
      "wireguard-${wireguardInterface}.service"
      "dnsseedrs-mainnet.service"
      "dnsseedrs-signet.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${ip} netns del ${namespace}";
    };
    script = ''
      ${ip} netns add ${namespace}
      ${ip} link add ${hostVeth} type veth peer name ${namespaceVeth} netns ${namespace}
      ${ip} address add ${hostAddress}/31 dev ${hostVeth}
      ${ip} link set ${hostVeth} up
      ${ip} -n ${namespace} address add ${namespaceAddress}/31 dev ${namespaceVeth}
      ${ip} -n ${namespace} link set ${namespaceVeth} up
      ${ip} -n ${namespace} link set lo up
    '';
  };

  systemd.services.tor = {
    requires = [ "dnsseedrs-netns.service" ];
    after = [ "dnsseedrs-netns.service" ];
  };

  systemd.services.i2pd = {
    requires = [ "dnsseedrs-netns.service" ];
    after = [ "dnsseedrs-netns.service" ];
  };

  systemd.services."wireguard-${wireguardInterface}" = {
    requires = [
      "dnsseedrs-netns.service"
      "sops-install-secrets.service"
    ];
    after = [
      "dnsseedrs-netns.service"
      "sops-install-secrets.service"
    ];
  };

  systemd.services.dnsseedrs-routing = {
    description = "Routes for dnsseedrs WireGuard egress";
    requires = [ "wireguard-${wireguardInterface}.target" ];
    after = [ "wireguard-${wireguardInterface}.target" ];
    unitConfig.Before = [
      "dnsseedrs-mainnet.service"
      "dnsseedrs-signet.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${ip} -n ${namespace} route replace ${wireguardEndpointAddress}/32 via ${hostAddress} dev ${namespaceVeth}
      ${ip} -n ${namespace} route replace default dev ${wireguardInterface}
      ${ip} -n ${namespace} -6 route replace default dev ${wireguardInterface}
    '';
  };

  services.dnsseedrs.mainnet.bind = lib.mkForce [
    "udp://${namespaceAddress}:${toString cfg.mainnet.dnsPort}"
    "tcp://${namespaceAddress}:${toString cfg.mainnet.dnsPort}"
  ];
  services.dnsseedrs.signet.bind = lib.mkForce [
    "udp://${namespaceAddress}:${toString cfg.signet.dnsPort}"
    "tcp://${namespaceAddress}:${toString cfg.signet.dnsPort}"
  ];

  systemd.services.dnsseedrs-mainnet = {
    requires = [
      "dnsseedrs-netns.service"
      "dnsseedrs-routing.service"
    ];
    after = [
      "dnsseedrs-netns.service"
      "dnsseedrs-routing.service"
    ];
    serviceConfig = {
      NetworkNamespacePath = "/run/netns/${namespace}";
      BindReadOnlyPaths = [
        "/etc/netns/${namespace}/resolv.conf:/etc/resolv.conf"
      ];
    };
  };

  systemd.services.dnsseedrs-signet = {
    requires = [
      "dnsseedrs-netns.service"
      "dnsseedrs-routing.service"
    ];
    after = [
      "dnsseedrs-netns.service"
      "dnsseedrs-routing.service"
    ];
    serviceConfig = {
      NetworkNamespacePath = "/run/netns/${namespace}";
      BindReadOnlyPaths = [
        "/etc/netns/${namespace}/resolv.conf:/etc/resolv.conf"
      ];
    };
  };
}
