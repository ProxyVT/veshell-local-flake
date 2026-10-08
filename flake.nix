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

      # --- zero-compilation routes ------------------------------------------
      # (1) Upstream's published 15 MB binary payload (the AUR `veshell-bin`
      #     artifact), unpacked and run through an FHS env. See binary.nix for
      #     why the FHS env is unavoidable.
      veshellBin = pkgs.callPackage ./binary.nix {
        version = "0.1.0";
        releaseTag = "v0.1.0";
        # Checked against the release's published SHA256SUMS.
        hash = "sha256-YVFYuel5Q9ndZavHvTRr0yqJL/k6VH6k/qjghax0LMw=";
      };

      # (2) Upstream's own release package (source-built engine). Building this
      #     normally means compiling LLVM + Dart + the engine; after
      #     ./import-binaries.sh has registered their attested closures it is a
      #     no-op, because every output is already in the store.
      veshellUpstream = (import "${veshell}/nix/release.nix").package;

      # winit's X11 backend dlopens libX11 / libXi / libX11-xcb / libxcb at
      # runtime (that is the `LibraryOpenError: libXi.so.6` you get from
      # `VESHELL_BACKEND=winit` under X11). Upstream's nix/package.nix lists no
      # X11 libraries. None of them are in DT_NEEDED, so stdenv's rpath
      # shrinking removes their directories from the binary's RUNPATH — what
      # actually rescues dlopen is LD_LIBRARY_PATH in the wrapper.
      # libxkbcommon-x11.so.0 needs no help: it lives next to libxkbcommon.so.0,
      # which *is* in DT_NEEDED, so that directory survives shrinking.
      x11RuntimeLibs = with pkgs; [
        libX11 # libX11.so.6 + libX11-xcb.so.1
        libXi
        libxcb
      ];

      package = (pkgs.callPackage "${veshell}/nix/package.nix" {
        flutterSdk = flutter.flutterSdk;
        flutterEngine = flutterEngine;
        inherit shellBundle;
        cargoHash = dependencies.cargoHash;
      }).overrideAttrs
        (old: {
          buildInputs = (old.buildInputs or [ ]) ++ x11RuntimeLibs;
          postFixup =
            (old.postFixup or "")
            + ''
              wrapProgram "$out/bin/veshell" \
                --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath x11RuntimeLibs}" \
                --set-default __EGL_VENDOR_LIBRARY_DIRS "/run/opengl-driver/share/glvnd/egl_vendor.d" \
                --set-default LIBGL_DRIVERS_PATH "/run/opengl-driver/lib/dri"
            '';
        });
      # Instant remedy for a package you have *already* built (or imported from
      # upstream's closure): just prepend the missing X11 libraries.
      #   nix run .#veshell-run -- ./result/bin/veshell
      veshellRun = pkgs.writeShellScriptBin "veshell-run" ''
        export LD_LIBRARY_PATH="${lib.makeLibraryPath x11RuntimeLibs}''${LD_LIBRARY_PATH:+:''${LD_LIBRARY_PATH}}"
        # glvnd ищет ICD в /run/opengl-driver/share/glvnd/egl_vendor.d (nixpkgs
        # патчит этот путь в libEGL); store-овая mesa — запасной вариант, если
        # hardware.graphics не включён.
        export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d:${pkgs.mesa}/share/glvnd/egl_vendor.d''${__EGL_VENDOR_LIBRARY_DIRS:+:''${__EGL_VENDOR_LIBRARY_DIRS}}"
        export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri:${pkgs.mesa}/lib/dri''${LIBGL_DRIVERS_PATH:+:''${LIBGL_DRIVERS_PATH}}"
        exec "$@"
      '';

    in
    {
      packages.${system} = {
        default = package;
        veshell = package;
        veshell-bin = veshellBin;
        veshell-run = veshellRun;
        veshell-upstream = veshellUpstream;
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

        # Same X11 dlopen fix, for the *session* path: the packaged user unit
        # ExecStart's the binary directly, bypassing any interactive wrapper.
        # Redundant for packages built by this flake, but it also rescues a
        # package that came from an imported upstream closure.
        systemd.user.services.veshell.serviceConfig.Environment = [
          "LD_LIBRARY_PATH=${lib.makeLibraryPath x11RuntimeLibs}"
        ];
      };
      nixosModules.veshell = self.nixosModules.default;

      # Not packages: the pinned upstream checkout, for ./import-binaries.sh.
      legacyPackages.${system} = {
        veshellSrc = veshell;
        veshellRev = veshell.sourceInfo.rev;
        # The nixpkgs revision this flake builds against (upstream's pin).
        pinnedPkgs = pkgs;
      };
    };
}
