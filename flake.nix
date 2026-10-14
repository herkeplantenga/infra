{
  description = "yanpla infra";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-master.url = "github:nixos/nixpkgs/master";

    colmena.url = "github:zhaofengli/colmena";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    website.url = "git+ssh://git@github.com/yanpla/website";
    website.inputs.nixpkgs.follows = "nixpkgs";

    starlight-web.url = "git+ssh://git@github.com/All-Of-Us-Mods/Starlight-Web?ref=original";
    starlight-web.inputs.nixpkgs.follows = "nixpkgs";

    muzionnaire.url = "git+ssh://git@github.com/yanpla/muzionnaire";
    muzionnaire.inputs.nixpkgs.follows = "nixpkgs";

    infra-private.url = "git+ssh://git@github.com/yanpla/infra-private";

    den.url = "github:denful/den";
    import-tree.url = "github:denful/import-tree";

    # No nixpkgs follows: keeps hashes matching upstream CI, so cachix hits.
    calagopus-nix.url = "github:calagopus/nix";

    helium.url = "github:AlvaroParker/helium-nix";
    helium.inputs.nixpkgs.follows = "nixpkgs";

    t3-code-nix.url = "github:LisaScheers/t3-code-nix";
    t3-code-nix.inputs.nixpkgs.follows = "nixpkgs-master";
  };

  outputs =
    { self, ... }@inputs:
    let
      inherit (inputs) nixpkgs;
      inherit (nixpkgs) lib;

      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pkgs-master = import inputs.nixpkgs-master {
        inherit system;
        config.allowUnfree = true;
      };

      # Hosts/aspects are declared in modules/den.nix; each host exposes a mainModule pulling in its aspects.
      den =
        (lib.evalModules {
          modules = [ (inputs.import-tree ./modules) ];
          specialArgs.inputs = inputs;
        }).config;

      denHosts = den.den.hosts.x86_64-linux;
      servers = builtins.attrNames denHosts;

      serverModules = host: [ denHosts.${host}.mainModule ];
    in
    {
      nixosConfigurations = lib.genAttrs servers (
        host:
        lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs self pkgs-master; };
          modules = serverModules host;
        }
      );

      colmenaHive = inputs.colmena.lib.makeHive (
        {
          meta = {
            nixpkgs = pkgs;
            specialArgs = { inherit inputs self pkgs-master; };
          };
        }
        // lib.genAttrs servers (host: {
          imports = serverModules host;
          deployment.targetHost = host;
          deployment.targetUser = if host == "tunneler" then "root" else "yanpla";
          deployment.privilegeEscalationCommand = [
            "sudo"
            "-n"
          ];
        })
      );
    };
}
