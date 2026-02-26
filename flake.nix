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

        # Pre-fetch libmagic Zig wrapper tarball (runs during Nix fetch phase, has network)
        libmagic-tarball = pkgs.fetchurl {
          url = "https://github.com/pmarreck/libmagic/archive/refs/tags/zig-0.15.0.tar.gz";
          hash = "sha256-lEySLP0ththmbc/zRhbGlKcPk5H0jvGzDMohOYGmJqg=";
        };

        # Unpack into the directory structure Zig expects for --system
        zigDeps = pkgs.runCommandLocal "zig-deps" {} ''
          hash="libmagic-5.46.0-RysxHD9fCACu5caBjXS-x3qQnQM3nRfosCyktdVRzv-R"
          mkdir -p "$out/$hash"
          tar xzf ${libmagic-tarball} --strip-components=1 -C "$out/$hash"
        '';

        z7z = pkgs.stdenv.mkDerivation {
          pname = "z7z";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build --system ${zigDeps} --prefix $out -Doptimize=ReleaseFast
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
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build --system ${zigDeps} test
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
            pkgs.file
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
