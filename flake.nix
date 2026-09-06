{
  description = "z7z - cleanroom 7z archive format implementation in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
        isDarwin = pkgs.stdenv.isDarwin;
        isLinux = pkgs.stdenv.isLinux;

        # Pre-fetched Zig dependencies (fixed-output derivation)
        # Update this hash when build.zig.zon changes:
        #   1. Set zigDepsHash = "";
        #   2. Run `nix build` — it fails and prints the correct hash
        #   3. Replace zigDepsHash with the printed hash
        zigDepsHash = "sha256-c8QpZA9KFPIQ52gNIiLClfxTmP8B4SzHoieQCnKMLgg=";

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

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ]
            ++ pkgs.lib.optionals isLinux [ pkgs.patchelf ];

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
            ${pkgs.lib.optionalString isLinux ''
              DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
              for f in "$out"/bin/*; do
                [ -f "$f" ] || continue
                patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
              done
            ''}
          '';

          dontInstall = true;
          dontFixup = true;
        };

        mkCrossPackage = target: pkgs.stdenvNoCC.mkDerivation {
          pname = "z7z-${target}";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ];
          strictDeps = true;
          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
            chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
            zig build --prefix "$out" -Doptimize=ReleaseFast -Dtarget=${target}
          '';

          dontInstall = true;
          dontFixup = true;
        };
      in {
        packages = {
          default = z7z;
        } // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          aarch64-macos = mkCrossPackage "aarch64-macos";
          aarch64-linux-musl = mkCrossPackage "aarch64-linux-musl";
          x86_64-linux-musl = mkCrossPackage "x86_64-linux-musl";
          aarch64-windows-gnu = mkCrossPackage "aarch64-windows-gnu";
          x86_64-windows-gnu = mkCrossPackage "x86_64-windows-gnu";
        };

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "z7z-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig pkgs.bash pkgs.jq pkgs.coreutils pkgs.findutils ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ]
            ++ pkgs.lib.optionals isLinux [ pkgs.patchelf ];

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
            # On Linux, Zig with link_libc bakes the FHS dynamic-linker path
            # into binaries, which does not exist in the Nix sandbox. Compile
            # the test binaries first, patchelf them, then run the test step
            # which reuses the cached (now patched) artifacts.
            ${pkgs.lib.optionalString isLinux ''
            zig build test-compile
            DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
            # Patch every executable under .zig-cache and zig-out; non-ELF
            # files (scripts, json) silently fail patchelf which is fine.
            for d in .zig-cache zig-out; do
              [ -d "$d" ] || continue
              for f in $(find "$d" -type f -perm -u+x); do
                patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
              done
            done
            ''}
            timeout 600 zig build test || {
              echo "Tests timed out or failed after 10 minutes"
              exit 1
            }
            bash tests/cli/codec-fixtures
            bash tests/integration/bzip-module-identity ${pkgs.lib.optionalString isLinux "-Dtarget=${system}-musl"}
          '';

          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };

        checks.coverage = pkgs.stdenvNoCC.mkDerivation {
          pname = "z7z-coverage-check";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.ripgrep ];
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            patchShebangs coverage tests/unit/feature-matrix
            bash tests/unit/feature-matrix
            runHook postBuild
          '';
          installPhase = ''
            mkdir -p "$out"
            printf 'matrix consistency passed; feature completeness is a separate gate\n' > "$out/result"
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            pkgs._7zz
            pkgs.hyperfine
            pkgs.luajit
            pkgs.jq
            pkgs.ripgrep
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
