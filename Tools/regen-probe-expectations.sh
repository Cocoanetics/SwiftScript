#!/usr/bin/env bash
# Refresh the checked-in golden outputs for the LLM probe scripts.
#
# Each Examples/llm_probes/NN_*.swift runs under **stock** `swift`
# (the reference semantics) and its stdout is committed as
# Examples/llm_probes/expected/NN_*.out. The interpreter's
# ProbeConformanceTests suite replays every probe and diffs against
# these files, so any silent divergence between swift-script and
# stock Swift fails CI instead of waiting for a reader to notice a
# suspicious number (issue #8).
#
# Probes must therefore stay deterministic: no wall-clock dates, no
# unordered-collection iteration without sorting, no environment
# echoes.
set -euo pipefail

cd "$(dirname "$0")/../Examples/llm_probes"
mkdir -p expected

for f in *.swift; do
  n="${f%.swift}"
  echo "running $n under stock swift..."
  swift "$f" > "expected/$n.out"
done

echo "done. Commit Examples/llm_probes/expected/ alongside probe changes."
