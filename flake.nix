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
        isDarwin = pkgs.stdenv.isDarwin;

        # Pre-fetched Zig dependencies (fixed-output derivation)
        # Update this hash when build.zig.zon changes:
        #   1. Set zigDepsHash = "";
        #   2. Run `nix build` — it fails and prints the correct hash
        #   3. Replace zigDepsHash with the printed hash
        zigDepsHash = "sha256-gAStXNdjSeXASQc/z9Z8xwB8gts4Ww3P7NdUTbeNBO8=";

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "z7z-zig-deps";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = with pkgs; [ zig git cacert ];

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;

          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$out
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';

          dontInstall = true;
          dontFixup = true;
        };

        z7z = pkgs.stdenv.mkDerivation {
          pname = "z7z";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            zig build --prefix $out -Doptimize=ReleaseFast
          '';

          dontInstall = true;
          dontFixup = true;
        };
      in {
        packages.default = z7z;

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "z7z-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            timeout 600 zig build test || {
              echo "Tests timed out or failed after 10 minutes"
              exit 1
            }
          '';

          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
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
