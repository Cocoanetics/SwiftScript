#!/bin/bash
# Validation: run every script in Examples/llm_probes/ through both `swift -`
# and our `swift-script`, and compare outputs line-for-line.
set -e
cd "$(dirname "$0")/.."

swift build --product swift-script >/dev/null 2>&1
SCRIPT="$(pwd)/.build/debug/swift-script"

pass=0
fail=0
for f in Examples/llm_probes/*.swift; do
    name=$(basename "$f")
    expected=$(cat "$f" | swift - 2>&1 || true)
    actual=$("$SCRIPT" "$f" 2>&1 || true)
    if [ "$expected" = "$actual" ]; then
        printf "  ✓ %s\n" "$name"
        pass=$((pass + 1))
    else
        printf "  ✗ %s\n" "$name"
        printf "    expected:\n"
        printf '%s\n' "$expected" | sed 's/^/      /'
        printf "    actual:\n"
        printf '%s\n' "$actual" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
done

echo
echo "$pass/$((pass + fail)) probes match swift output"
