#!/usr/bin/env bash
# Build the MathExtras dynamic library + .swiftmodule so a stock-`swift`
# script can `import MathExtras`. SwiftPM already builds it as part of
# `swift build`; this wrapper exists to print the resolved -I/-L paths
# and the matching shebang line.
#
# For a one-time setup that lets `swift script.swift` work with no flags,
# run `Tools/install-mathextras.sh` instead — it copies the module into
# the active toolchain.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -q --product MathExtras

BIN="$(swift build --show-bin-path)"
MOD="$BIN/Modules"

cat <<EOF
Built MathExtras.

The .swiftmodule carries an autolink record for libMathExtras, so
consumers don't need '-lMathExtras' explicitly — '-I' for the module
plus '-L' for the dylib is enough.

To run a stock-swift script that uses 'import MathExtras' inline:

  swift -I "$MOD" -L "$BIN" script.swift

Or bake the flags into a shebang via env -S (the paths are absolute,
so this binds the script to your current build directory):

  #!/usr/bin/env -S swift -I $MOD -L $BIN
  import MathExtras
  print(gcd(48, 18))

For a portable shebang (no machine-specific paths in the script), run
'sudo bash Tools/install-mathextras.sh' once and use:

  #!/usr/bin/env swift
  import MathExtras
EOF
