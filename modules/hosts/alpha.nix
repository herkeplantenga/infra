{
  den,
  inputs,
  ...
}:
{
  den.aspects.alpha = {
    includes = [
      den.aspects.default
      den.aspects.alpha-hardware
      den.aspects.zram-swap
      den.aspects.calagopus-wings
      den.aspects.desktop
      den.aspects.t3code
    ];

    nixos =
      { pkgs, pkgs-master, ... }:
      let
        maxKHz = 4800000;

        capBoost = pkgs.writeShellScript "cap-cpu-boost" ''
          set -eu
          applied=0
          for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
            [ -w "$f" ] || continue
            echo ${toString maxKHz} > "$f"
            applied=$((applied + 1))
          done
          echo "capped scaling_max_freq to ${toString maxKHz} kHz on $applied cpus"
        '';
      in
      {
        system.stateVersion = "25.11";

        environment.systemPackages = with pkgs-master; [
          zed-editor
          nil
          nixd
          claude-code
          codex
          pi-coding-agent
          vinegar
          gh
          inputs.helium.packages.${pkgs.stdenv.hostPlatform.system}.default
        ];

        programs.direnv.enable = true;
        programs.nix-ld.enable = true;

        programs.steam = {
          enable = true;
          remotePlay.openFirewall = true;
          dedicatedServer.openFirewall = true;
          localNetworkGameTransfers.openFirewall = true;
        };

        nixpkgs.config.allowUnfree = true;

        systemd.services.cap-cpu-boost = {
          description = "Cap CPU boost clock (workaround for hard resets at stock boost)";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = capBoost.outPath;
          };
        };
      };
  };
}
