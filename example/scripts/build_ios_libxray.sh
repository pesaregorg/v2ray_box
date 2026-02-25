#!/usr/bin/env bash
set -euo pipefail

LIBXRAY_REPO_URL="https://github.com/XTLS/libXray.git"
LIBXRAY_REF="main"
PROJECT_ROOT="$(pwd)"
LIBXRAY_DIR=""
APPLE_TOOL="gomobile"
KEEP_SOURCE=false
TMP_DIR=""

usage() {
  cat <<'EOF'
Usage: build_ios_libxray.sh [options]

Build iOS LibXray.xcframework from XTLS/libXray and place it in:
  ios/Frameworks/LibXray.xcframework

Options:
  --project-root <path>      Flutter app root (default: current directory)
  --libxray-dir <path>       Use an existing local libXray directory
  --libxray-ref <ref|main|latest> libXray git ref to use when auto-cloning (default: main)
  --libxray-repo <url>       libXray git repo URL (default: https://github.com/XTLS/libXray.git)
  --apple-tool <gomobile|go> libXray apple build tool (default: gomobile)
  --keep-source              Keep temporary cloned source (if auto-cloned)
  -h, --help                 Show this help

Examples:
  sh scripts/build_ios_libxray.sh
  sh scripts/build_ios_libxray.sh --project-root /path/to/flutter_app
  sh scripts/build_ios_libxray.sh --libxray-dir /path/to/libXray
  sh scripts/build_ios_libxray.sh --apple-tool go
EOF
}

log() { printf '[libxray-ios] %s\n' "$*" >&2; }
err() { printf '[libxray-ios] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || err "Missing required command: $cmd"
}

validate_apple_tool() {
  case "$APPLE_TOOL" in
    gomobile|go) ;;
    *) err "Invalid --apple-tool: $APPLE_TOOL (allowed: gomobile,go)" ;;
  esac
}

resolve_latest_ref() {
  # "latest" here means latest development head (default branch), not latest release.
  local branch
  branch="$(curl -fsSL "https://api.github.com/repos/XTLS/libXray" | jq -r '.default_branch // empty')" || true
  if [[ -n "$branch" && "$branch" != "null" ]]; then
    printf '%s\n' "$branch"
    return
  fi

  printf 'main\n'
}

prepare_source_dir() {
  if [[ -n "$LIBXRAY_DIR" ]]; then
    [[ -d "$LIBXRAY_DIR" ]] || err "libXray directory not found: $LIBXRAY_DIR"
    [[ -f "$LIBXRAY_DIR/build/main.py" ]] || err "Invalid libXray directory (missing build/main.py): $LIBXRAY_DIR"
    printf '%s\n' "$LIBXRAY_DIR"
    return
  fi

  TMP_DIR="$(mktemp -d)"
  local source_dir="$TMP_DIR/libXray"
  local ref_to_use="$LIBXRAY_REF"
  if [[ "$ref_to_use" == "latest" ]]; then
    ref_to_use="$(resolve_latest_ref)"
  fi

  log "Cloning libXray ($ref_to_use) from $LIBXRAY_REPO_URL ..."
  if ! git clone --depth 1 --branch "$ref_to_use" "$LIBXRAY_REPO_URL" "$source_dir" >/dev/null 2>&1; then
    log "Branch/tag clone failed for ref '$ref_to_use'; trying default clone + checkout..."
    git clone --depth 1 "$LIBXRAY_REPO_URL" "$source_dir" >/dev/null
    (
      cd "$source_dir"
      git fetch --depth 1 origin "$ref_to_use" >/dev/null 2>&1 || true
      git checkout "$ref_to_use" >/dev/null
    )
  fi
  printf '%s\n' "$source_dir"
}

detect_built_xcframework() {
  local source_dir="$1"
  if [[ -d "$source_dir/LibXray.xcframework" ]]; then
    printf '%s\n' "$source_dir/LibXray.xcframework"
    return
  fi

  local found
  found="$(find "$source_dir" -maxdepth 3 -type d -name 'LibXray.xcframework' | head -n1 || true)"
  [[ -n "$found" ]] || err "Build succeeded but LibXray.xcframework was not found under $source_dir"
  printf '%s\n' "$found"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      [[ $# -ge 2 ]] || err "Missing value for --project-root"
      PROJECT_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --libxray-dir)
      [[ $# -ge 2 ]] || err "Missing value for --libxray-dir"
      LIBXRAY_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --libxray-ref)
      [[ $# -ge 2 ]] || err "Missing value for --libxray-ref"
      LIBXRAY_REF="$2"
      shift 2
      ;;
    --libxray-repo)
      [[ $# -ge 2 ]] || err "Missing value for --libxray-repo"
      LIBXRAY_REPO_URL="$2"
      shift 2
      ;;
    --apple-tool)
      [[ $# -ge 2 ]] || err "Missing value for --apple-tool"
      APPLE_TOOL="$2"
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
require_cmd python3
require_cmd curl
require_cmd jq
require_cmd xcodebuild

[[ -f "$PROJECT_ROOT/pubspec.yaml" ]] || err "pubspec.yaml not found at project root: $PROJECT_ROOT"
validate_apple_tool

SOURCE_DIR="$(prepare_source_dir)"
OUT_DIR="$PROJECT_ROOT/ios/Frameworks"
OUT_PATH="$OUT_DIR/LibXray.xcframework"
mkdir -p "$OUT_DIR"

export PATH="$(go env GOPATH)/bin:$PATH"

log "Building Apple xcframework (${APPLE_TOOL}) from: $SOURCE_DIR"
(
  cd "$SOURCE_DIR"
  python3 build/main.py apple "$APPLE_TOOL"
)

BUILT_PATH="$(detect_built_xcframework "$SOURCE_DIR")"
rm -rf "$OUT_PATH"
cp -R "$BUILT_PATH" "$OUT_PATH"

log "Saved: ${OUT_PATH#$PROJECT_ROOT/}"
log "Done."
