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

        z7z = pkgs.stdenv.mkDerivation {
          pname = "z7z";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            zig build --prefix $out -Doptimize=ReleaseFast
          '';

          dontInstall = true;
        };
      in {
        packages.default = z7z;

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "z7z-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            zig build test
          '';

          installPhase = ''
            touch $out
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.zig
            pkgs._7zz
            pkgs.hyperfine
            pkgs.luajit
            pkgs.jq
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
