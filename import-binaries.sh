#!/usr/bin/env bash
#
# Download upstream's *published Nix closures* and register them in the store,
# so that building veshell compiles nothing at all.
#
#   ./import-binaries.sh --check      # metadata only: does the release match this pin?
#   ./import-binaries.sh --engine     # 757 MB: source-built engine + toolchain
#   ./import-binaries.sh --all        # + 895 MB: package, Flutter SDK, shell
#   ./import-binaries.sh --all --attested
#
# Two trust levels:
#
#   default     verify sha256 of every part against the release's own
#               *-SHA256SUMS, and verify the release metadata against what THIS
#               checkout predicts (engine/runtime outputs, nixpkgs revision,
#               veshell commit). Same trust model as any pinned fetchurl hash.
#
#   --attested  delegate to upstream's import-release.sh, which additionally
#               checks the GitHub Actions workflow attestation. Needs an
#               authenticated `gh`. This is what docs/nixos.md recommends.
#
# Importing registers prebuilt store paths: it is a trust decision, not a build.

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ENGINE_REPO="free-explorers/flutter-engine-nix"
PKG_REPO="free-explorers/veshell-packaging"
PKG_TAG="v0.1.0"
SYSTEM="x86_64-linux"

c_g=$'\033[1;32m'; c_b=$'\033[1;34m'; c_r=$'\033[1;31m'; c_0=$'\033[0m'
log() { printf '%s==>%s %s\n' "$c_b" "$c_0" "$*" >&2; }
ok()  { printf '%s ok %s %s\n' "$c_g" "$c_0" "$*" >&2; }
die() { printf '%s !! %s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

for tool in nix jq curl; do
  command -v "$tool" >/dev/null || die "нужен $tool (nix-shell -p jq curl)"
done
command -v xz >/dev/null || die "нужен xz (nix-shell -p xz)"

# The pinned upstream checkout, straight from this flake's input.
SRC="${VESHELL_SRC:-$(nix eval --raw ".#legacyPackages.${SYSTEM}.veshellSrc")}"
[ -f "$SRC/nix/release.nix" ] || die "не похоже на чекаут veshell: $SRC"

ev() { nix-instantiate "$SRC/nix/release.nix" --eval --strict --json -A "$1" | jq -r .; }

RUNTIME="$(ev runtime.outPath)"
RAW_ENGINE="$(ev rawEngine.outPath)"
NIXPKGS_REV="$(ev nixpkgsRevision)"
ENGINE_COMMIT="$(jq -r .revision "$SRC/nix/engine-repository.json")"
ENGINE_SRC_TARBALL="$(ev engineSource)"

RUNTIME_HASH="${RUNTIME#/nix/store/}"; RUNTIME_HASH="${RUNTIME_HASH%%-*}"
ENGINE_TAG="nix-engine-${RUNTIME_HASH}"
VESHELL_REV="$(nix eval --raw ".#legacyPackages.${SYSTEM}.veshellRev")"

SUDO=""
[ -w /nix/store ] || SUDO="sudo"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
fetch_release() { # <repo> <tag> <prefix>
  local repo="$1" tag="$2" prefix="$3" base meta sums
  base="https://github.com/${repo}/releases/download/${tag}"
  meta="$WORK/${prefix}-metadata.json"
  sums="$WORK/${prefix}-SHA256SUMS"

  log "${repo}@${tag}"
  curl -fsSL "$base/${prefix}-metadata.json" -o "$meta" || die "нет ${prefix}-metadata.json"
  curl -fsSL "$base/${prefix}-SHA256SUMS"  -o "$sums"  || die "нет ${prefix}-SHA256SUMS"

  local parts part
  parts="$(jq -r '.parts[]' "$meta")"
  [ -n "$parts" ] || die "в метаданных нет списка parts"
  if [ "$MODE" = check ]; then
    ok "метаданные получены, части не скачиваю (--check): $(echo $parts | tr '\n' ' ')"
    printf '%s\n' "$meta"
    return 0
  fi
  for part in $parts; do
    curl -fsSL "$base/$part" -o "$WORK/$part" || die "не скачался $part"
    ( cd "$WORK" && grep -E "^[0-9a-f]{64}  ?${part}\$" "$sums" | sha256sum -c - ) \
      || die "контрольная сумма $part не сошлась"
    ok "sha256 $part"
  done
  printf '%s\n' "$meta"
}

import_stream() { # <metadata-file> <part-glob-prefix>
  local meta="$1" prefix="$2"
  local parts
  parts="$(jq -r '.parts[]' "$meta")"
  log "импортирую closure в /nix/store ($(jq -r '.closure | length' "$meta") путей)"
  # shellcheck disable=SC2086
  ( cd "$WORK" && cat $parts ) | xz -dc | ${SUDO} nix-store --import
  ok "closure ${prefix} импортирован"
}

check_engine_metadata() { # <metadata-file>
  local meta="$1"
  jq -e \
    --arg runtime "$RUNTIME" \
    --arg raw "$RAW_ENGINE" \
    --arg commit "$ENGINE_COMMIT" \
    --arg rev "$NIXPKGS_REV" \
    --arg sys "$SYSTEM" \
    '(.runtimeOutput == $runtime)
     and (.engineOutput == $raw)
     and (.rawEngineOutput == $raw)
     and (.sourceCommit == $commit)
     and (.nixpkgsRevision == $rev)
     and (.system == $sys)' \
    "$meta" >/dev/null \
    || die "метаданные движка не совпадают с этим чекаутом (см. $meta)"
  ok "engine: runtimeOutput/engineOutput/nixpkgsRevision совпадают с локальными"
}

check_package_metadata() { # <metadata-file>
  local meta="$1"
  jq -e \
    --arg vcommit "$VESHELL_REV" \
    --arg runtime "$RUNTIME" \
    --arg raw "$RAW_ENGINE" \
    --arg rev "$NIXPKGS_REV" \
    '(.veshellCommit == $vcommit)
     and (.runtimeOutput == $runtime)
     and (.rawEngineOutput == $raw)
     and (.nixpkgsRevision == $rev)' \
    "$meta" >/dev/null \
    || die "метаданные пакета не совпадают с этим чекаутом (см. $meta)"
  ok "package: veshellCommit=${VESHELL_REV:0:10} и выходы движка совпадают"
}

do_engine() {
  local meta
  meta="$(fetch_release "$ENGINE_REPO" "$ENGINE_TAG" engine)"
  check_engine_metadata "$meta"
  [ "$MODE" = check ] && return 0
  import_stream "$meta" engine
}

do_package() {
  local meta
  # The app closure references the engine closure, so the engine goes first.
  do_engine
  meta="$(fetch_release "$PKG_REPO" "$PKG_TAG" package)"
  check_package_metadata "$meta"
  [ "$MODE" = check ] && return 0
  import_stream "$meta" package
  cat <<EOF

Теперь сборка не должна ничего компилировать:
  nix build .#veshell-upstream      # == nix-build \$SRC/nix/release.nix -A package
EOF
}

do_attested() {
  log "делегирую upstream-овскому import-release.sh (нужен аутентифицированный gh)"
  command -v gh >/dev/null || die "--attested требует gh (nix-shell -p gh)"
  EXPECTED_ENGINE_OUTPUT="$RAW_ENGINE" \
  EXPECTED_RAW_ENGINE_OUTPUT="$RAW_ENGINE" \
  EXPECTED_RUNTIME_OUTPUT="$RUNTIME" \
    bash "$ENGINE_SRC_TARBALL/import-release.sh" \
      "$ENGINE_COMMIT" "$ENGINE_TAG" engine refs/heads/main --trust-github-release
  ok "engine: аттестованный импорт выполнен"
  log "для app-closure см. docs/nixos.md upstream (import-release.sh из veshell-packaging)"
}

# ---------------------------------------------------------------------------
MODE=build
WHAT=""
ATTESTED=0
for arg in "$@"; do
  case "$arg" in
    --check)     MODE=check ;;
    --attested)  ATTESTED=1 ;;
    --engine)    WHAT=engine ;;
    --package|--all) WHAT=package ;;
    -h|--help)   sed -n '2,26p' "$0"; exit 0 ;;
    *)           die "неизвестный аргумент: $arg (см. --help)" ;;
  esac
done
# --check alone verifies the engine release; add --all to check the app closure too.
[ -n "$WHAT" ] || WHAT=engine

log "чекаут upstream: $SRC"
log "runtime  = $RUNTIME"
log "rawEngine= $RAW_ENGINE"
log "engine tag = $ENGINE_TAG"

if [ "$ATTESTED" = 1 ] && [ "$MODE" != check ]; then
  do_attested
  [ "$WHAT" = package ] && log "app closure: повторите с --attested по инструкции в docs/nixos.md"
  exit 0
fi

case "$WHAT" in
  engine)  do_engine ;;
  package) do_package ;;
esac

[ "$MODE" = check ] && ok "релизы соответствуют этому пину — можно импортировать"
exit 0
