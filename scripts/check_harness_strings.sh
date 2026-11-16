#!/bin/bash
# The launch harness (-screen, -tapthrough: fixtures, fakes, the movable clock and its control) is Debug
# only. This looks for its markers in an app bundle's executables (the app binary and, in Debug, the
# Compass.debug.dylib Xcode splits the code into).
#
#   scripts/check_harness_strings.sh absent  path/to/Release/Compass.app   # fails if any marker is there
#   scripts/check_harness_strings.sh present path/to/Debug/Compass.app     # fails if any is missing
#
# `present` on the Debug build proves the markers are real strings in a binary (Swift keeps literals of
# up to 15 bytes inside instructions, where `strings` can't see them, so "-screen" itself can't be one).
# No marker is a source file name: an unstripped binary lists those in its debug map (CI strips the
# Release build like a shipped one anyway).
set -euo pipefail

MODE=${1:?absent|present}
APP=${2:?path to Compass.app}
MARKERS=(
  "tapthrough-evening"        # TapThroughClockControl's accessibility identifier
  "TapThroughClockControl"    # the -tapthrough clock control (type name in Swift metadata)
  "MovableClock"              # the -tapthrough clock
  "LaunchHarness"             # the -screen / -tapthrough fixture and fake wiring
  "unknown -screen ID"        # LaunchOptions' -screen parsing
)

BINARIES=()
for f in "$APP/Compass" "$APP"/*.dylib; do
  [ -f "$f" ] && BINARIES+=("$f")
done
if [ ${#BINARIES[@]} -eq 0 ]; then echo "No executables in $APP"; exit 1; fi
echo "Checking ${BINARIES[*]}"

STRINGS=$(for b in "${BINARIES[@]}"; do strings -a "$b"; done)
FAIL=0
for m in "${MARKERS[@]}"; do
  if grep -qF -- "$m" <<< "$STRINGS"; then found=yes; else found=no; fi
  case "$MODE" in
    absent)  if [ "$found" = yes ]; then echo "::error::Release binary contains the test-harness marker \"$m\""; FAIL=1; else echo "absent:  $m"; fi ;;
    present) if [ "$found" = no ]; then echo "::error::Debug binary lacks the marker \"$m\" (the check would prove nothing)"; FAIL=1; else echo "present: $m"; fi ;;
    *) echo "Unknown mode $MODE"; exit 2 ;;
  esac
done
exit $FAIL
