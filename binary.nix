# Veshell from upstream's published *binary payload* — the same 15 MB
# `veshell-<version>-x86_64.tar.zst` that the AUR `veshell-bin` package installs.
# Nothing is compiled: the archive is unpacked, its ELFs get store rpaths, and
# the whole thing is exposed through an FHS environment.
#
# Why an FHS environment is not optional here: the payload is built with
# PREFIX=/usr and the resulting paths are *compile-time* constants in the Rust
# binary (`option_env!("VESHELL_LIB_DIR")` / `VESHELL_DATA_DIR`), so it insists
# on /usr/lib/veshell/libapp.so and /usr/share/veshell/data at runtime. There is
# no environment-variable override for those two. Verified on the published
# artifact: it contains "/usr/lib/veshell" and "/usr/share/veshell/data" and
# zero /nix/store references.
#
# `buildFHSEnv` composes /usr from targetPkgs, so putting the unpacked payload
# there reproduces exactly the layout the binary was compiled for, while /nix
# stays bind-mounted and the rpaths below keep working inside and outside.
{
  lib,
  stdenv,
  fetchurl,
  zstd,
  patchelf,
  makeWrapper,
  buildFHSEnv,
  # runtime libraries (sonames the payload links against / dlopens)
  glibc,
  libglvnd,
  libxkbcommon,
  libX11,
  libXi,
  libinput,
  libgbm,
  libdisplay-info,
  seatd,
  systemd,
  wayland,
  libxcb,
  pixman,
  pipewire,
  libpulseaudio,
  gst_all_1,
  glib,
  fontconfig,
  mesa,
  vulkan-loader,
  libepoxy,
  # runtime programs
  xwayland,
  dbus,
  xdg-utils,
  bash,
  coreutils,
  gnugrep,
  gawk,
  procps,
  util-linux,
  # fonts (Flutter resolves "Roboto" through fontconfig)
  makeFontsConf,
  roboto,
  noto-fonts,
  noto-fonts-cjk-sans,
  version ? "0.1.0",
  releaseTag ? "v${version}",
  arch ? "x86_64",
  hash ? "",
}:

let
  runtimeLibs = [
    glibc
    (lib.getLib stdenv.cc.cc)
    libglvnd
    mesa
    libxkbcommon
    libX11 # libX11.so.6 + libX11-xcb.so.1: winit's X11 backend dlopens them
    libXi
    libinput
    libgbm
    libdisplay-info
    seatd
    systemd # libudev
    wayland
    libxcb
    pixman
    pipewire
    libpulseaudio
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    glib
    fontconfig
    vulkan-loader
    libepoxy
  ];

  runtimeProgs = [
    xwayland # smithay spawns Xwayland for X11 clients
    systemd # systemd-run / systemctl --user
    dbus # dbus-update-activation-environment
    xdg-utils
    fontconfig # fc-match
    bash
    coreutils # getconf and friends
    gnugrep
    gawk
    procps
    util-linux
  ];

  fontsConf = makeFontsConf {
    fontDirectories = [
      roboto
      noto-fonts
      noto-fonts-cjk-sans
    ];
  };

  # The unpacked, rpath-fixed payload. Still rooted the way upstream staged it
  # ($out/{bin,lib,share}), which is what makes it land in /usr inside the FHS env.
  payload = stdenv.mkDerivation {
    pname = "veshell-bin-payload";
    inherit version;

    src = fetchurl {
      name = "veshell-${version}-${arch}.tar.zst";
      url = "https://github.com/free-explorers/veshell-packaging/releases/download/${releaseTag}/veshell-${version}-${arch}.tar.zst";
      inherit hash;
    };

    nativeBuildInputs = [
      zstd
      patchelf
    ];

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$TMPDIR/payload" "$out"
      zstd -dcq "$src" | tar -xf - -C "$TMPDIR/payload"
      test -x "$TMPDIR/payload/usr/bin/veshell"
      cp -r --no-preserve=mode "$TMPDIR/payload/usr/." "$out/"

      # The shipped RPATH is /usr/lib/veshell. Point it at the store instead so
      # the binaries resolve their libraries both inside and outside the FHS env;
      # libflutter_engine.so stays findable next to them.
      patchelf --set-rpath "$out/lib/veshell:${lib.makeLibraryPath runtimeLibs}" \
        "$out/bin/veshell"
      patchelf --set-rpath "${lib.makeLibraryPath [
        glibc
        (lib.getLib stdenv.cc.cc)
        libglvnd
      ]}" "$out/lib/veshell/libflutter_engine.so"

      runHook postInstall
    '';

    passthru = {
      inherit releaseTag arch;
    };
  };

  # One FHS environment per entry point: buildFHSEnv execs `runScript "$@"`,
  # so arguments (`--session`) pass through untouched.
  fhs =
    program:
    buildFHSEnv {
      name = "veshell-fhs-${program}";
      targetPkgs = _pkgs: [ payload ] ++ runtimeLibs ++ runtimeProgs;
      runScript = "/usr/bin/${program}";
      extraBwrapArgs = [
        # A Wayland compositor needs the render nodes and the runtime dir.
        "--dev-bind /dev/dri /dev/dri"
        "--bind-try /run/user /run/user"
      ];
      meta = {
        description = "FHS environment for Veshell's prebuilt ${program}";
        homepage = "https://github.com/free-explorers/veshell";
        license = lib.licenses.gpl3Plus;
        platforms = [ "x86_64-linux" ];
      };
    };

  fhsVeshell = fhs "veshell";
  fhsSession = fhs "veshell-session";
  fhsSessionStop = fhs "veshell-session-stop";
in
stdenv.mkDerivation {
  pname = "veshell-bin";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/lib/systemd/user" \
             "$out/share/wayland-sessions" "$out/share/xdg-desktop-portal/portals"

    ln -s "${fhsVeshell}/bin/veshell-fhs-veshell"                 "$out/bin/veshell"
    ln -s "${fhsSession}/bin/veshell-fhs-veshell-session"          "$out/bin/veshell-session"
    ln -s "${fhsSessionStop}/bin/veshell-fhs-veshell-session-stop" "$out/bin/veshell-session-stop"

    # Portal descriptor + backend preference list are read from /usr/share (i.e.
    # the system profile), not from inside the FHS env.
    cp "${payload}/share/xdg-desktop-portal/veshell-portals.conf" "$out/share/xdg-desktop-portal/"
    cp "${payload}/share/xdg-desktop-portal/portals/veshell.portal" "$out/share/xdg-desktop-portal/portals/"

    # Session entry and user units must point at the FHS launchers, not /usr/bin.
    substitute "${payload}/share/wayland-sessions/veshell.desktop" \
      "$out/share/wayland-sessions/veshell.desktop" \
      --replace-fail '"/usr/bin/veshell-session"' "$out/bin/veshell-session"
    substitute "${payload}/lib/systemd/user/veshell.service" \
      "$out/lib/systemd/user/veshell.service" \
      --replace-fail '"/usr/bin/veshell"' "$out/bin/veshell" \
      --replace-fail '"/usr/bin/veshell-session-stop"' "$out/bin/veshell-session-stop"
    cp "${payload}/lib/systemd/user/veshell-shutdown.target" "$out/lib/systemd/user/"

    # Read-only conveniences (the payload itself is what the FHS env serves).
    ln -s "${payload}/share/veshell" "$out/share/veshell"
    ln -s "${payload}/share/licenses" "$out/share/licenses"
    ln -s "${payload}/lib/veshell" "$out/lib/veshell"

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/bin/veshell" \
      --set-default FONTCONFIG_FILE "${fontsConf}" \
      --prefix PATH : "${lib.makeBinPath runtimeProgs}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibs}" \
      --set-default LIBGL_DRIVERS_PATH "/run/opengl-driver/lib/dri:${mesa}/lib/dri" \
      --set-default __EGL_VENDOR_LIBRARY_DIRS "/run/opengl-driver/share/glvnd/egl_vendor.d:${mesa}/share/glvnd/egl_vendor.d" \
      --suffix GST_PLUGIN_SYSTEM_PATH_1_0 : "${lib.makeSearchPath "lib/gstreamer-1.0" [
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
      ]}"
  '';

  passthru = {
    inherit payload fontsConf;
    fhsEnvs = {
      veshell = fhsVeshell;
      session = fhsSession;
      sessionStop = fhsSessionStop;
    };
    providedSessions = [ "veshell" ];
    prebuilt = true;
  };

  meta = {
    description = "Veshell from upstream's prebuilt binary payload (no compilation)";
    longDescription = ''
      Unpacks the distro-agnostic payload published on the
      free-explorers/veshell-packaging release and runs it inside an FHS
      environment, because the binary has /usr/lib/veshell and
      /usr/share/veshell/data compiled in.
    '';
    homepage = "https://github.com/free-explorers/veshell";
    license = lib.licenses.gpl3Plus;
    mainProgram = "veshell";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
