#!/usr/bin/env bash
set -euo pipefail

SINGBOX_REPO_URL="https://github.com/SagerNet/sing-box.git"
SINGBOX_REF="latest"
PROJECT_ROOT="$(pwd)"
SINGBOX_DIR=""
SINGBOX_APPLE_DIR=""
KEEP_SOURCE=false
TMP_DIR=""
APPLE_PLATFORMS="ios,iossimulator"

usage() {
  cat <<'EOF'
Usage: build_ios_libsingbox.sh [options]

Build iOS Libbox.xcframework from SagerNet/sing-box and place it in:
  ios/Frameworks/Libbox.xcframework

Options:
  --project-root <path>      Flutter app root (default: current directory)
  --singbox-dir <path>       Use an existing local sing-box directory
  --singbox-apple-dir <path> Use an existing local sing-box-for-apple directory
  --singbox-ref <ref|main|latest> sing-box git ref to use when auto-cloning (default: latest release tag)
  --singbox-repo <url>       sing-box git repo URL (default: https://github.com/SagerNet/sing-box.git)
  --platform <list>          gomobile target platform list (default: ios,iossimulator)
  --keep-source              Keep temporary cloned source (if auto-cloned)
  -h, --help                 Show this help

Examples:
  sh scripts/build_ios_libsingbox.sh
  sh scripts/build_ios_libsingbox.sh --project-root /path/to/flutter_app
  sh scripts/build_ios_libsingbox.sh --singbox-dir /path/to/sing-box
  sh scripts/build_ios_libsingbox.sh --platform ios,iossimulator,macos
EOF
}

log() { printf '[libsingbox-ios] %s\n' "$*" >&2; }
err() { printf '[libsingbox-ios] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || err "Missing required command: $cmd"
}

resolve_latest_release_tag() {
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')" || true
  if [[ -n "$tag" && "$tag" != "null" ]]; then
    printf '%s\n' "$tag"
    return
  fi
  printf 'v1.12.22\n'
}

resolve_latest_ref() {
  resolve_latest_release_tag
}

prepare_source_dir() {
  if [[ -n "$SINGBOX_DIR" ]]; then
    [[ -d "$SINGBOX_DIR" ]] || err "sing-box directory not found: $SINGBOX_DIR"
    [[ -f "$SINGBOX_DIR/go.mod" ]] || err "Invalid sing-box directory (missing go.mod): $SINGBOX_DIR"
    [[ -f "$SINGBOX_DIR/cmd/internal/build_libbox/main.go" ]] || err "Invalid sing-box directory (missing cmd/internal/build_libbox/main.go): $SINGBOX_DIR"
    printf '%s\n' "$SINGBOX_DIR"
    return
  fi

  TMP_DIR="$(mktemp -d)"
  local source_dir="$TMP_DIR/sing-box"
  local ref_to_use="$SINGBOX_REF"
  if [[ "$ref_to_use" == "latest" ]]; then
    ref_to_use="$(resolve_latest_ref)"
  fi

  log "Cloning sing-box ($ref_to_use) from $SINGBOX_REPO_URL ..."
  if ! git clone --depth 1 --branch "$ref_to_use" "$SINGBOX_REPO_URL" "$source_dir" >/dev/null 2>&1; then
    log "Branch/tag clone failed for ref '$ref_to_use'; trying default clone + checkout..."
    git clone --depth 1 "$SINGBOX_REPO_URL" "$source_dir" >/dev/null
    (
      cd "$source_dir"
      git fetch --depth 1 origin "$ref_to_use" >/dev/null 2>&1 || true
      git checkout "$ref_to_use" >/dev/null
    )
  fi
  printf '%s\n' "$source_dir"
}

prepare_singbox_apple_dir() {
  local source_dir="$1"

  if [[ -n "$SINGBOX_APPLE_DIR" ]]; then
    [[ -d "$SINGBOX_APPLE_DIR" ]] || err "sing-box-for-apple directory not found: $SINGBOX_APPLE_DIR"
    printf '%s\n' "$SINGBOX_APPLE_DIR"
    return
  fi

  local sibling_dir
  sibling_dir="$(cd "$source_dir/.." && pwd)/sing-box-for-apple"
  if [[ -d "$sibling_dir" ]]; then
    printf '%s\n' "$sibling_dir"
    return
  fi

  # For temporary auto-cloned sing-box, create an empty sibling directory so
  # sing-box builder can move Libbox.xcframework there (same behavior as upstream Makefile flow).
  if [[ -n "${TMP_DIR:-}" && "$source_dir" == "$TMP_DIR/"* ]]; then
    mkdir -p "$sibling_dir"
    printf '%s\n' "$sibling_dir"
    return
  fi

  printf '%s\n' ""
}

ensure_gomobile_tools() {
  local go_bin
  go_bin="$(go env GOPATH)/bin"
  export PATH="$go_bin:$PATH"

  # sing-box build_libbox requires sagernet/gomobile features (for example -libname).
  local needs_install="true"
  if [[ -x "$go_bin/gomobile" && -x "$go_bin/gobind" ]]; then
    if "$go_bin/gomobile" bind -h 2>&1 | grep -q -- "-libname"; then
      needs_install="false"
    fi
  fi

  if [[ "$needs_install" == "true" ]]; then
    log "Installing compatible gomobile/gobind (github.com/sagernet/gomobile@v0.1.11) ..."
    go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.11
    go install github.com/sagernet/gomobile/cmd/gobind@v0.1.11
  fi

  gomobile init
}

detect_built_xcframework() {
  local source_dir="$1"
  local apple_dir="$2"

  if [[ -n "$apple_dir" && -d "$apple_dir/Libbox.xcframework" ]]; then
    printf '%s\n' "$apple_dir/Libbox.xcframework"
    return
  fi

  if [[ -d "$source_dir/Libbox.xcframework" ]]; then
    printf '%s\n' "$source_dir/Libbox.xcframework"
    return
  fi

  local found
  found="$(find "$source_dir" "${apple_dir:-/non-existent}" -maxdepth 3 -type d -name 'Libbox.xcframework' 2>/dev/null | head -n1 || true)"
  [[ -n "$found" ]] || err "Build succeeded but Libbox.xcframework was not found"
  printf '%s\n' "$found"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      [[ $# -ge 2 ]] || err "Missing value for --project-root"
      PROJECT_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --singbox-dir)
      [[ $# -ge 2 ]] || err "Missing value for --singbox-dir"
      SINGBOX_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --singbox-apple-dir)
      [[ $# -ge 2 ]] || err "Missing value for --singbox-apple-dir"
      SINGBOX_APPLE_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --singbox-ref)
      [[ $# -ge 2 ]] || err "Missing value for --singbox-ref"
      SINGBOX_REF="$2"
      shift 2
      ;;
    --singbox-repo)
      [[ $# -ge 2 ]] || err "Missing value for --singbox-repo"
      SINGBOX_REPO_URL="$2"
      shift 2
      ;;
    --platform)
      [[ $# -ge 2 ]] || err "Missing value for --platform"
      APPLE_PLATFORMS="${2// /}"
      shift 2
      ;;
    --keep-source)
      KEEP_SOURCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

trap 'if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" && "$KEEP_SOURCE" != "true" ]]; then rm -rf "$TMP_DIR"; fi' EXIT

require_cmd git
require_cmd go
require_cmd curl
require_cmd jq
require_cmd xcodebuild

[[ -f "$PROJECT_ROOT/pubspec.yaml" ]] || err "pubspec.yaml not found at project root: $PROJECT_ROOT"
[[ -n "$APPLE_PLATFORMS" ]] || err "--platform cannot be empty"

SOURCE_DIR="$(prepare_source_dir)"
APPLE_DIR="$(prepare_singbox_apple_dir "$SOURCE_DIR")"
ensure_gomobile_tools

OUT_DIR="$PROJECT_ROOT/ios/Frameworks"
OUT_PATH="$OUT_DIR/Libbox.xcframework"
mkdir -p "$OUT_DIR"

log "Building Libbox.xcframework from: $SOURCE_DIR"
(
  cd "$SOURCE_DIR"
  go run ./cmd/internal/build_libbox -target apple -platform "$APPLE_PLATFORMS"
)

BUILT_PATH="$(detect_built_xcframework "$SOURCE_DIR" "$APPLE_DIR")"
rm -rf "$OUT_PATH"
cp -R "$BUILT_PATH" "$OUT_PATH"

log "Saved: ${OUT_PATH#$PROJECT_ROOT/}"
log "Done."
