# Prebuilt Flutter *embedder* engine, laid out exactly the way veshell's
# nix/package.nix and nix/shell.nix expect it:
#
#   $out/flutter_embedder.h
#   $out/release/libflutter_engine.so
#
# This replaces upstream's source-built engine (free-explorers/flutter-engine-nix,
# which drags in a from-source LLVM, a bootstrap Dart and a full gn/ninja engine
# build — hours of compile time) with the community prebuilt archive for the
# *same engine revision* that upstream pins in Cargo.toml / nix/flutter-sdk.json.
#
# Trade-off, stated plainly:
#   - you trade upstream's attested source build for a third-party binary
#     (meta-flutter/flutter-engine, the same source upstream's own build script
#     downloaded before the packaging rework);
#   - the AOT snapshot is then produced by the official gen_snapshot from the
#     pinned Flutter SDK rather than by the source-built one. Both come from the
#     same engine revision, which is what determines snapshot compatibility.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  patchelf,
  glibc,
  libglvnd,
  engineVersion,
  engineHash ? "",
  engineProfile ? "release",
  engineArch ? "x86_64",
}:

let
  archiveName = "linux-engine-sdk-${engineProfile}-${engineArch}-${engineVersion}.tar.gz";
  # Only glibc is in NEEDED today; libstdc++/libGL are kept in the search path
  # so a future engine revision does not silently fail to load.
  engineRuntimeLibs = [
    glibc
    (lib.getLib stdenv.cc.cc)
    libglvnd
  ];
in
stdenv.mkDerivation {
  pname = "veshell-flutter-engine-prebuilt";
  inherit engineVersion;
  version = engineVersion;

  src = fetchurl {
    name = archiveName;
    url = "https://github.com/meta-flutter/flutter-engine/releases/download/linux-engine-sdk-${engineProfile}-${engineArch}-${engineVersion}/${archiveName}";
    hash = engineHash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    patchelf
  ];

  # autoPatchelfHook alone is not enough here: it only adds rpath entries for
  # dependencies it had to *resolve*, and since glibc is in its search list it
  # considers the engine fine and leaves RUNPATH empty. On NixOS nothing is in
  # /lib64, so an empty RUNPATH means the library cannot even load libc.
  autoPatchelfLibs = engineRuntimeLibs;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    sdk=$(find . -type d -name engine-sdk | head -n1)
    test -n "$sdk"
    test -s "$sdk/lib/libflutter_engine.so"
    test -s "$sdk/include/flutter_embedder.h"

    install -Dm644 "$sdk/include/flutter_embedder.h" "$out/flutter_embedder.h"
    install -Dm755 "$sdk/lib/libflutter_engine.so" "$out/${engineProfile}/libflutter_engine.so"

    runHook postInstall
  '';

  # postFixup, so stdenv's own rpath shrinking cannot undo it.
  postFixup = ''
    patchelf --set-rpath "${lib.makeLibraryPath [ glibc (lib.getLib stdenv.cc.cc) libglvnd ]}" \
      "$out/${engineProfile}/libflutter_engine.so"
    echo "NEEDED:  $(patchelf --print-needed "$out/${engineProfile}/libflutter_engine.so" | tr '\n' ' ')"
    echo "RUNPATH: $(patchelf --print-rpath  "$out/${engineProfile}/libflutter_engine.so")"
  '';

  # Attributes upstream's nix/shell.nix asserts on. `sourceBuild` is a plain
  # string on purpose: shell.nix interpolates it into --local-engine-src-path,
  # and we drop those flags, so it must never become a real derivation
  # reference (which would pull the source engine build back in).
  passthru = {
    inherit engineVersion;
    runtimeMode = engineProfile;
    outName = "host_${engineProfile}";
    sourceBuild = "/nix/veshell-prebuilt-engine-has-no-source-build";
    prebuilt = true;
  };

  meta = {
    description = "Prebuilt Flutter embedder engine matching Veshell's pinned Flutter SDK";
    homepage = "https://github.com/meta-flutter/flutter-engine";
    license = lib.licenses.bsd3;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
