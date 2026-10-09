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

      # --- EGL vendor discovery -------------------------------------------
      # nixpkgs patches libEGL to search three directories for vendor ICDs:
      # /etc/glvnd/egl_vendor.d, /run/opengl-driver/share/glvnd/egl_vendor.d and
      # /usr/share/glvnd/egl_vendor.d. On NixOS only the second one can exist,
      # and it appears solely because of `hardware.graphics.enable` — which is
      # false by default and is turned on by neither services.xserver nor the
      # Xfce module. No directory => no ICD => Mesa never gets asked, so the
      # client extension list lacks EGL_KHR_platform_x11 and smithay's winit
      # backend dies with Egl(DisplayNotSupported).
      # /run/opengl-driver stays first (system drivers, incl. NVIDIA win);
      # store Mesa is the fallback. It costs ~250 MB of closure, so it is a
      # switch: set mesaFallback = false if your system has graphics enabled.
      mesaFallback = true;

      # --- Mesa's two search paths -------------------------------------------
      # src/loader/loader.c: loader_open_driver_lib() walks every colon-separated
      # entry and only gives up when *all* dlopens fail, so the system directory
      # goes first: a matching system driver wins, a glibc-skewed one is skipped
      # in favour of the Mesa from this flake's own nixpkgs pin. Both variables
      # are ignored for root (the `__normal_user()` gate in mesa).
      #
      #   LIBGL_DRIVERS_PATH  -> <dir>/dri/*_dri.so        (DRI drivers)
      #   GBM_BACKENDS_PATH   -> <dir>/gbm/*_gbm.so        (GBM backends)
      #
      # GBM_BACKENDS_PATH is the one that bites: nixpkgs builds mesa-libgbm with
      # -Dgbm-backends-path=${libglvnd.driverLink}/lib/gbm, i.e. the compiled-in
      # default is a *single* path /run/opengl-driver/lib/gbm. With no fallback
      # entry, a system Mesa built against a newer glibc than this package kills
      # GBM outright and the error masquerades as a missing device:
      #   MESA-LOADER: failed to open dri: .../glibc-2.42-84/lib/libm.so.6:
      #     version `GLIBC_2.43' not found (required by
      #     /run/opengl-driver/lib/libgallium-26.1.2.so)
      #     (search paths /run/opengl-driver/lib/gbm, suffix _gbm)
      #   Error: "failed to open GBM device /dev/dri/renderD128: No such file or
      #     directory (os error 2)"
      # glvnd walks every vendor ICD and skips the ones that fail to load
      # (verified experimentally), so a broken or glibc-skewed system ICD is not
      # fatal: the store Mesa below is still tried, and a system NVIDIA ICD keeps
      # priority when it works.
      eglVendorDirs = lib.concatStringsSep ":" (
        [ "/run/opengl-driver/share/glvnd/egl_vendor.d" ]
        ++ lib.optional mesaFallback "${pkgs.mesa}/share/glvnd/egl_vendor.d"
      );
      driDriverDirs = lib.concatStringsSep ":" (
        [ "/run/opengl-driver/lib/dri" ]
        ++ lib.optional mesaFallback "${pkgs.mesa}/lib/dri"
      );
      gbmBackendDirs = lib.concatStringsSep ":" (
        [ "/run/opengl-driver/lib/gbm" ]
        ++ lib.optional mesaFallback "${pkgs.mesa}/lib/gbm"
      );

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
                --set-default __EGL_VENDOR_LIBRARY_DIRS "${eglVendorDirs}" \
                --set-default LIBGL_DRIVERS_PATH "${driDriverDirs}" \
                --set-default GBM_BACKENDS_PATH "${gbmBackendDirs}"
            '';
        });
      # Instant remedy for a package you have *already* built (or imported from
      # upstream's closure): just prepend the missing X11 libraries.
      #   nix run .#veshell-run -- ./result/bin/veshell
      veshellRun = pkgs.writeShellScriptBin "veshell-run" ''
        if [ "$#" -eq 0 ]; then
          echo "usage: veshell-run PROGRAM [ARGS...]" >&2
          echo "example: nix run .#veshell-run -- env VESHELL_BACKEND=winit \$HOME/result/bin/veshell" >&2
          exit 2
        fi
        # `nix run` keeps the caller's cwd, and the build's ./result symlink is
        # usually somewhere else — say so instead of letting exec fail cryptically.
        target="$1"
        if [ ! -e "$target" ] && ! command -v "$target" >/dev/null 2>&1; then
          echo "veshell-run: '$target' не найден (cwd=$(pwd))" >&2
          echo "veshell-run: путь к бинарю абсолютный? например \$HOME/result/bin/veshell" >&2
          exit 127
        fi
        export LD_LIBRARY_PATH="${lib.makeLibraryPath x11RuntimeLibs}''${LD_LIBRARY_PATH:+:''${LD_LIBRARY_PATH}}"
        # glvnd ищет ICD в /run/opengl-driver/share/glvnd/egl_vendor.d (nixpkgs
        # патчит этот путь в libEGL); store-овая mesa — запасной вариант, если
        # hardware.graphics не включён.
        export __EGL_VENDOR_LIBRARY_DIRS="${eglVendorDirs}''${__EGL_VENDOR_LIBRARY_DIRS:+:''${__EGL_VENDOR_LIBRARY_DIRS}}"
        export LIBGL_DRIVERS_PATH="${driDriverDirs}''${LIBGL_DRIVERS_PATH:+:''${LIBGL_DRIVERS_PATH}}"
        export GBM_BACKENDS_PATH="${gbmBackendDirs}''${GBM_BACKENDS_PATH:+:''${GBM_BACKENDS_PATH}}"
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
