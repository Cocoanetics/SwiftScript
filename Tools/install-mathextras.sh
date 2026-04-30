#!/usr/bin/env bash
# Install the MathExtras dynamic library + module into the active Swift
# toolchain so plain `swift script.swift` (or a `#!/usr/bin/env swift`
# shebang) can `import MathExtras` with no extra flags.
#
# Writes to the toolchain that `xcrun --find swift` resolves to. That
# directory is system-owned, so this script needs sudo. Pass the
# environment variable `MATHEXTRAS_PREFIX` to override the destination
# (useful on Linux or for a per-user toolchain).
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -q --product MathExtras

BIN="$(swift build --show-bin-path)"

if [[ -z "${MATHEXTRAS_PREFIX:-}" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    TOOLCHAIN_BASE="$(xcrun --find swift | sed 's|/usr/bin/swift$||')"
    LIB_DIR="$TOOLCHAIN_BASE/usr/lib/swift/macosx"
  else
    SWIFT_BIN="$(command -v swift)"
    TOOLCHAIN_BASE="$(dirname "$(dirname "$SWIFT_BIN")")"
    LIB_DIR="$TOOLCHAIN_BASE/lib/swift/linux"
  fi
else
  LIB_DIR="$MATHEXTRAS_PREFIX"
fi

NEED_SUDO=""
if [[ ! -w "$LIB_DIR" ]]; then NEED_SUDO="sudo"; fi

echo "Installing MathExtras into: $LIB_DIR"

# Copy the .dylib (or .so on Linux) and the matching .swiftmodule bundle.
LIB_NAME="libMathExtras.dylib"
[[ "$(uname)" == "Linux" ]] && LIB_NAME="libMathExtras.so"

$NEED_SUDO cp "$BIN/$LIB_NAME" "$LIB_DIR/$LIB_NAME"
$NEED_SUDO mkdir -p "$LIB_DIR/MathExtras.swiftmodule"
# `swift build` and `swift script.swift` resolve to slightly different
# target triples (`arm64-apple-macosx` vs `arm64-apple-macos`); writing
# both file names lets either invocation find the module.
TRIPLE_BUILD="$(swift -print-target-info | python3 -c 'import sys,json; print(json.load(sys.stdin)["target"]["unversionedTriple"])')"
TRIPLES=("$TRIPLE_BUILD")
case "$TRIPLE_BUILD" in
  *-apple-macosx) TRIPLES+=("${TRIPLE_BUILD%x}") ;;
  *-apple-macos)  TRIPLES+=("${TRIPLE_BUILD}x") ;;
esac
for ext in swiftmodule swiftdoc swiftsourceinfo abi.json; do
  src="$BIN/Modules/MathExtras.$ext"
  if [[ -f "$src" ]]; then
    for t in "${TRIPLES[@]}"; do
      $NEED_SUDO cp "$src" "$LIB_DIR/MathExtras.swiftmodule/$t.$ext"
    done
  fi
done

if [[ "$(uname)" == "Darwin" ]]; then
  # Re-stamp the install_name so dyld finds the library by its leaf name
  # against the toolchain's rpath (matches every other .dylib in there).
  $NEED_SUDO install_name_tool -id "@rpath/$LIB_NAME" "$LIB_DIR/$LIB_NAME"
fi

echo "Done. Test with:"
echo "  swift -e 'import MathExtras; print(gcd(48, 18))'"
