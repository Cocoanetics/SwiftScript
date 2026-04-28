#!/usr/bin/env bash
# Measure bridge-generator quality on six axes:
#   1. generator-loc          — non-blank, non-comment lines in main.swift
#   2. generator-emit-cases   — distinct `case "swift.<kind>"` arms
#   3. bridged-types          — entries in `bridgedTypes` table
#   4. blocklist-entries      — symbols we have to manually exclude
#   5. auto-bridges-stdlib    — entries in StdlibBridge.generated.swift
#   6. auto-bridges-foundation — entries in FoundationBridge.generated.swift
#   7. tests-pass             — count of passing Swift Testing tests
#   8. probes-pass            — N/M of probes matching swiftc
#
# Output is one `key: value` per line for easy diffing.

set -euo pipefail
cd "$(dirname "$0")/.."

# Static counts (don't require build).
gen_main=Sources/BridgeGeneratorTool/main.swift

# Strip line comments and blank lines for a fair LOC count.
gen_loc=$(awk '
    /^[[:space:]]*\/\// { next }
    /^[[:space:]]*$/    { next }
    { count++ }
    END { print count+0 }
' "$gen_main")

gen_cases=$(grep -cE 'case "swift\.[^"]+"' "$gen_main" || true)
bridged_types=$(awk '
    /^(let|var|nonisolated\(unsafe\) var) (bridgedTypes|primitiveBridges)/ { inside=1; next }
    inside && /^]/      { inside=0 }
    inside && /BridgedType\(/ { count++ }
    inside && /opaqueBridge\(/ { count++ }
    END                 { print count+0 }
' "$gen_main")
blocklist=$(grep -cE '^[A-Za-z][^#]+\(' Resources/foundation-blocklist.txt || true)

# Generated bridge counts. Each registration is one bridge.
stdlib_bridges=$(grep -cE 'i\.register(Method|Init|Computed|StaticValue|StaticMethod|Comparator|Global)' Sources/SwiftScriptInterpreter/Modules/StdlibBridge.generated.swift || true)
foundation_bridges=$(grep -cE 'i\.register(Method|Init|Computed|StaticValue|StaticMethod|Comparator|Global)' Sources/SwiftScriptInterpreter/Modules/FoundationBridge.generated.swift || true)

# Functional checks: tests and probes.
swift build >/dev/null 2>&1 || true
test_total=$(swift test 2>&1 | tail -3 | grep -oE '[0-9]+ tests' | head -1 | grep -oE '[0-9]+' || echo 0)
test_passed=$(swift test 2>&1 | tail -3 | grep -E 'passed' | head -1 | grep -oE '[0-9]+ tests' | grep -oE '[0-9]+' || echo "$test_total")
probes_pass=$(bash Tests/validate.sh 2>&1 | tail -1 | grep -oE '^[0-9]+/[0-9]+' || echo "?/?")

cat <<EOF
generator-loc:           $gen_loc
generator-emit-cases:    $gen_cases
bridged-types-entries:   $bridged_types
blocklist-entries:       $blocklist
stdlib-bridges:          $stdlib_bridges
foundation-bridges:      $foundation_bridges
total-bridges:           $((stdlib_bridges + foundation_bridges))
tests-passed:            $test_passed/$test_total
probes-passed:           $probes_pass
EOF
