{
  description = "z7z - cleanroom 7z archive format implementation in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.zig         # Zig 0.15.x compiler
            pkgs._7zz        # Official 7-Zip (oracle for testing)
            pkgs.hyperfine   # Benchmarking
          ];

          shellHook = ''
            echo "z7z dev shell"
            echo "  zig: $(zig version)"
            echo "  7zz: $(7zz 2>&1 | head -1)"
          '';
        };
      }
    );
}
