#!/usr/bin/env bash
# Regenerate Sources/SwiftScriptInterpreter/Modules/FoundationBridge.generated.swift
# by re-extracting Foundation symbol graphs and feeding them through the
# BridgeGeneratorTool.
#
# Re-run any time the allowlist or generator logic changes.
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

# Foundation supplies the value-typed overlay (CharacterSet, URL, Date,
# Data) and StringProtocol extensions; Swift stdlib supplies Int/Double
# numeric methods. The extractor writes `<Module>.symbols.json` plus
# cross-module graphs (`Foundation@Swift.symbols.json` etc.).
extract Foundation
extract Swift

SG_ARGS=()
for f in "$SG_DIR"/*.symbols.json; do
  SG_ARGS+=("--symbol-graph" "$f")
done

echo "running BridgeGeneratorTool..."
swift run -q BridgeGeneratorTool \
  "${SG_ARGS[@]}" \
  --auto-allowlist \
  --blocklist Resources/foundation-blocklist.txt \
  --output-stdlib Sources/SwiftScriptInterpreter/Modules/StdlibBridge.generated.swift \
  --output-foundation Sources/SwiftScriptInterpreter/Modules/FoundationBridge.generated.swift

echo "done."
