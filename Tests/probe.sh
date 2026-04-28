#!/bin/bash
# Probe a Swift snippet through both `swift -` (the script runner) and our
# interpreter, then print a side-by-side comparison.
#
# Usage:   probe.sh <label> <code>
# Example: probe.sh "compound +=" 'var n = 5; n += 3; print(n)'
#
# Output format (per probe):
#   ===== <label> =====
#   $ <code>
#   swift:        <one-line outcome>
#   swift-script: <one-line outcome>
#   match:        OK | DIFFERS

set -e
cd "$(dirname "$0")/.."

label="$1"
code="$2"

# Build silently if needed.
swift build --product swift-script >/dev/null 2>&1

run_swift() {
    local out
    out=$(printf '%s\n' "$1" | swift - 2>&1)
    local rc=$?
    # Compress to one line, strip ANSI cruft, cap length.
    printf '%s' "$out" \
        | tr '\n' '\v' \
        | sed -e 's/\x1B\[[0-9;]*[A-Za-z]//g' \
        | head -c 220
    if [ $rc -ne 0 ]; then printf ' [exit %d]' $rc; fi
}

run_script() {
    local out
    out=$(./.build/debug/swift-script -e "$1" 2>&1)
    local rc=$?
    printf '%s' "$out" \
        | tr '\n' '\v' \
        | head -c 220
    if [ $rc -ne 0 ]; then printf ' [exit %d]' $rc; fi
}

a=$(run_swift "$code")
b=$(run_script "$code")

echo "===== $label ====="
printf '$ %s\n' "$code"
printf 'swift:        %s\n' "$a"
printf 'swift-script: %s\n' "$b"

# Coarse match: extract the first "error: ..." message (stripping file:line:col
# and Swift's caret-diagram source dump). For success cases, just compare the
# whitespace-collapsed text.
norm() {
    local s
    s=$(printf '%s' "$1" | tr '\v' '\n')
    if printf '%s' "$s" | grep -q 'error:'; then
        printf '%s' "$s" \
            | grep 'error:' \
            | head -1 \
            | sed -E 's/^.*error: //' \
            | sed -E 's/\[exit [0-9]+\]//g' \
            | tr -s '[:space:]'
    else
        printf '%s' "$s" \
            | sed -E 's/\[exit [0-9]+\]//g' \
            | tr -s '[:space:]'
    fi
}
if [ "$(norm "$a")" = "$(norm "$b")" ]; then
    echo 'match:        OK'
else
    echo 'match:        DIFFERS'
fi
echo
