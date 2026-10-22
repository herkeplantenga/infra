{ den, inputs, ... }:
let
  net = inputs.infra-private.hostNetworking.beta;
in
{
  den.aspects.beta = {
    includes = [
      den.aspects.default
      den.aspects.beta-hardware
      den.aspects.website
      den.aspects.starlight-web
      den.aspects.muzionnaire
      den.aspects.calagopus-panel
      den.aspects.calagopus-wings
      den.aspects.smokeping
    ];
    nixos =
      let
        grokbotKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsbsGrkT0zrAUTcjWoQTeIru8OUoIuAmO2sfQl18kgV";
      in
      {
        users.users.rooq = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          openssh.authorizedKeys.keys = [ grokbotKey ];
        };
        users.users.root.openssh.authorizedKeys.keys = [ grokbotKey ];

        # No DHCP on this network
        networking.useDHCP = false;
        systemd.network = {
          enable = true;
          networks."10-wan" = {
            matchConfig.MACAddress = net.mac;
            address = [ "${net.address}/${toString net.prefixLength}" ];
            routes = [
              {
                Gateway = net.gateway;
                GatewayOnLink = true;
              }
            ];
            networkConfig.DNS = [
              "1.1.1.1"
              "8.8.8.8"
            ];
            linkConfig.RequiredForOnline = "routable";
          };
        };
        networking.nameservers = [
          "1.1.1.1"
          "8.8.8.8"
        ];

        # Offer beta as a Tailscale exit node. "server" turns on IPv4/IPv6
        # forwarding; extraSetFlags is re-applied by tailscaled-set on every
        # boot, so it also works on an already-authenticated node.
        # The route still has to be approved in the admin console.
        services.tailscale = {
          useRoutingFeatures = "server";
          extraSetFlags = [ "--advertise-exit-node" ];
        };

        system.stateVersion = "26.05";
      };
  };
}
