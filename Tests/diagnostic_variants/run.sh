#!/usr/bin/env bash
# Run each variant through both `swift -` and `swift-script`, normalize
# the diagnostic output, and report match/mismatch per variant.
#
# Normalization:
#   - strip absolute file paths (only the basename matters; line numbers are
#     intrinsic to the diagnostic and stay in)
#   - drop blank lines
#   - drop the source-listing block (the `1 | …` lines that swiftc prints
#     after the message). Both sides should produce the leading message.
#
# Goal: ours and swiftc's leading diagnostic line should match verbatim
# after normalization.

set -uo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$(pwd)/.build/debug/swift-script"
swift build --product swift-script >/dev/null 2>&1

normalize() {
    # Keep only lines that start with `error:` or contain `error:`. Drop
    # source-listing rows and the carat-pointer rows. Strip absolute paths.
    sed -E '
        s|/[^ ]+/diagnostic_variants/|<>/|g
        /^[[:space:]]*$/d
        /^[[:space:]]*[0-9]+ \|/d
        /^[[:space:]]*\|/d
    '
}

pass=0; fail=0
for f in Tests/diagnostic_variants/[0-9]*.swift; do
    name=$(basename "$f")
    swift_out=$(cat "$f" | swift - 2>&1 | normalize)
    ours_out=$("$SCRIPT" "$f" 2>&1 | normalize)
    # Strip path differences in our output too.
    ours_out=$(printf '%s\n' "$ours_out" | sed -E "s|$f|<>/$name|g")

    # Pull the leading "error: <message>" line from each, since swiftc may
    # also emit notes/warnings; we compare on the first error only.
    # Normalize by extracting everything AFTER the literal "error: ".
    swift_err=$(printf '%s\n' "$swift_out" | grep -oE 'error: .*' | head -1 | sed -E 's|^error: *||')
    ours_err=$(printf '%s\n' "$ours_out"  | grep -oE 'error: .*' | head -1 | sed -E 's|^error: *||')

    # Allow either side to be empty (clean run).
    swift_clean=$([ -z "$swift_err" ] && echo yes || echo no)
    ours_clean=$([ -z "$ours_err" ] && echo yes || echo no)

    if [ "$swift_err" = "$ours_err" ] || ([ "$swift_clean" = yes ] && [ "$ours_clean" = yes ]); then
        printf "  ✓ %s\n" "$name"
        pass=$((pass+1))
    else
        printf "  ✗ %s\n" "$name"
        printf "    swiftc: %s\n" "$swift_err"
        printf "    ours:   %s\n" "$ours_err"
        fail=$((fail+1))
    fi
done

echo
echo "$pass/$((pass+fail)) variants match swiftc"
