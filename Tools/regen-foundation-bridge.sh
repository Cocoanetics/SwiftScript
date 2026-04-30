#!/usr/bin/env bash
# Regenerate the Foundation + stdlib bridge files. The generator
# extracts Apple's Foundation symbol graph and classifies each
# emitted bridge entry as cross-platform or Apple-only by checking
# it against a swift-corelibs-foundation extract — anything that
# isn't in scl gets gated behind `#if canImport(Darwin)` so Linux
# and Windows builds skip it. No hand-editing of generated files
# is needed.
#
# Re-run after generator/blocklist changes, or after refreshing
# the scl extract.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="${BRIDGE_TARGET:-arm64-apple-macos26.0}"
SG_DIR="$(mktemp -d)"
trap 'rm -rf "$SG_DIR"' EXIT

extract() {
  local module="$1"
  echo "extracting $module symbol graph (target=$TARGET)..."
  xcrun swift-symbolgraph-extract \
    -module-name "$module" \
    -sdk "$SDK" \
    -target "$TARGET" \
    -minimum-access-level public \
    -output-dir "$SG_DIR" \
    >/dev/null 2>&1 || true
}

extract Foundation
extract Swift

SG_ARGS=()
for f in "$SG_DIR"/*.symbols.json; do
  SG_ARGS+=("--symbol-graph" "$f")
done

# scl-foundation extract — refresh by running
# `Tools/refresh-scl-symbols.sh /path/to/swift-corelibs-foundation`
# (commits Resources/foundation-symbols-scl.txt). The extract is
# checked into the repo so regen contributors don't need a local
# scl-foundation clone.
SCL_SYMBOLS="Resources/foundation-symbols-scl.txt"
SCL_ARGS=()
if [[ -f "$SCL_SYMBOLS" ]]; then
  SCL_ARGS+=("--scl-symbols" "$SCL_SYMBOLS")
else
  echo "warning: $SCL_SYMBOLS not found; emitting all symbols as cross-platform"
  echo "         (run Tools/refresh-scl-symbols.sh to generate it)"
fi

echo "running BridgeGeneratorTool..."
swift run -q BridgeGeneratorTool \
  "${SG_ARGS[@]}" \
  "${SCL_ARGS[@]}" \
  --auto-allowlist \
  --blocklist Resources/foundation-blocklist.txt \
  --output-stdlib Sources/SwiftScriptInterpreter/Modules/StdlibBridge.generated.swift \
  --output-foundation Sources/SwiftScriptInterpreter/Modules/FoundationBridge.generated.swift

echo "done."
