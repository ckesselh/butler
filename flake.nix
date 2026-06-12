{
  description = "butler — command-line client for the BuchhaltungsButler (BHB) accounting API";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        butler = pkgs.callPackage ./package.nix { };
        default = butler;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_16
            pkgs.zls
            pkgs.go-task
            pkgs.zig-zlint
          ];
        };
      });

      overlays.default = final: _prev: {
        butler = final.callPackage ./package.nix { };
      };
    };
}
