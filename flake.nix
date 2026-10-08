{
  description = ''
    Veshell for local use: upstream's own Nix packaging (free-explorers/veshell nix/),
    with the source-built Flutter engine swapped for a prebuilt one so a local
    build takes minutes instead of hours.
  '';

  inputs = {
    # Pinned to the commit the upstream release v0.1.0 was built from, so the
    # attested closures published by free-explorers/veshell-packaging match this
    # checkout exactly (see README, "Option A").
    veshell = {
      url = "github:free-explorers/veshell/e954bb7ebcdfab7892249005c64ff7ba740930d3";
      flake = false;
    };
  };

  outputs =
    { self, veshell }:
    let
      # Upstream only supports native x86_64-linux.
      system = "x86_64-linux";

      # The exact nixpkgs revision upstream tests against (nix/release.nix).
      # nix/flutter.nix reaches into nixpkgs' internal Flutter API
      # (mkFlutter/wrapFlutter/useNixpkgsEngine), so moving this pin can break
      # evaluation — bump it together with upstream, not independently.
      nixpkgsRev = "774debe7a0d1b496e35677ad955a1011c6ff74f3";
      nixpkgsSrc = builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz";
        sha256 = "1japvhk1jlgc8sihm9gczwnv6fjanqsr1ji57vx67wbvqj88a34x";
      };
      pkgs = import nixpkgsSrc { inherit system; };
      inherit (pkgs) lib;

      # --- upstream's own building blocks -----------------------------------
      # flutter.nix reads the Flutter pin from Cargo.toml and the verified
      # SDK/artifact metadata from nix/flutter-sdk.json.
      flutter = pkgs.callPackage "${veshell}/nix/flutter.nix" { };
      dependencies = pkgs.callPackage "${veshell}/nix/dependencies.nix" { };

      # --- the one piece we replace -----------------------------------------
      # Engine revision that upstream pins for Flutter 3.47.2. If upstream
      # moves the Flutter pin, this assert fires instead of silently producing
      # an engine/AOT pair that cannot load each other.
      pinnedEngineVersion = "a804b261645ef8c13eb3d5c44a5c2fb0340c5539";
      engineProfile = "release";
      # Resolved against the published .sha256 asset of the same release.
      engineHash = "sha256-dk4FumEqr5Q1I8dqh92JlS9EmEo+wbSMA6qLIn2vtWw=";

      flutterEngine =
        assert lib.assertMsg (flutter.engineVersion == pinnedEngineVersion) ''
          Upstream moved the Flutter engine pin to ${flutter.engineVersion},
          but prebuilt-engine hash in flake.nix is for ${pinnedEngineVersion}.
          Re-resolve engineHash (see README) or use upstream's source engine.
        '';
        pkgs.callPackage ./prebuilt-engine.nix {
          engineVersion = flutter.engineVersion;
          inherit engineHash engineProfile;
        };

      polkitHelperPath = "/run/wrappers/bin/polkit-agent-helper-1";

      # Upstream's shell derivation, minus the --local-engine-* flags: without a
      # source-built engine we let the pinned SDK's own gen_snapshot/frontend
      # server produce the AOT snapshot (same engine revision).
      shellBundle =
        (pkgs.callPackage "${veshell}/nix/shell.nix" {
          flutterSdk = flutter.flutterSdk;
          flutterEngine = flutterEngine;
          inherit (dependencies) pubspecLock gitHashes;
          inherit polkitHelperPath;
        }).overrideAttrs
          (_old: {
            flutterBuildFlags = [
              "--no-pub"
              "--dart-define=VESHELL_POLKIT_HELPER_PATH=${polkitHelperPath}"
            ];
          });

      # Upstream's nix/engine-aot-test.nix has a loader-only mode (when
      # appLibrary is given it skips compilation): it links a tiny C program
      # against the engine and calls FlutterEngineCreateAOTData() on the real
      # libapp.so. That is exactly the assumption this flake makes — an AOT
      # snapshot produced by the pinned SDK's official gen_snapshot must load
      # in the prebuilt engine of the same revision. `nix build .#aotCheck`
      # verifies it headlessly, without starting a session.
      engineRuntime = pkgs.runCommand "veshell-flutter-engine-runtime-prebuilt" { } ''
        mkdir -p "$out/include" "$out/lib"
        ln -s "${flutterEngine}/flutter_embedder.h" "$out/include/flutter_embedder.h"
        ln -s "${flutterEngine}/${engineProfile}/libflutter_engine.so" "$out/lib/libflutter_engine.so"
      '';

      aotCheck = pkgs.callPackage "${veshell}/nix/engine-aot-test.nix" {
        engine = flutterEngine;
        runtime = engineRuntime;
        appLibrary = "${shellBundle}/lib/libapp.so";
      };

      package = pkgs.callPackage "${veshell}/nix/package.nix" {
        flutterSdk = flutter.flutterSdk;
        flutterEngine = flutterEngine;
        inherit shellBundle;
        cargoHash = dependencies.cargoHash;
      };
    in
    {
      packages.${system} = {
        default = package;
        veshell = package;
        # Exposed so each stage can be built/inspected on its own:
        #   nix build .#flutterEngine   (~98 MB download, no compilation)
        #   nix build .#flutterSdk      (official Flutter 3.47.2 + artifacts)
        #   nix build .#veshell-shell   (pub deps, build_runner codegen, AOT)
        inherit flutterEngine shellBundle aotCheck;
        flutterSdk = flutter.flutterSdk;
      };

      # Convenience overlay: makes `pkgs.veshell` available in any nixpkgs.
      # Note the package itself is built against the pinned nixpkgs above.
      overlays.default = final: prev: lib.optionalAttrs (prev.system == system) {
        veshell = self.packages.${system}.veshell;
      };
      overlays.veshell = self.overlays.default;

      # programs.veshell.enable = true;
      # Upstream's module wires the session, user units, portals, polkit setuid
      # helper, graphics, D-Bus, UPower and PipeWire; we only point it at the
      # prebuilt-engine package instead of upstream's source-engine default.
      nixosModules.default = { lib, ... }: {
        imports = [ "${veshell}/nix/module.nix" ];
        programs.veshell.package = lib.mkDefault self.packages.${system}.veshell;
      };
      nixosModules.veshell = self.nixosModules.default;
    };
}
