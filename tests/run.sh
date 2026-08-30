#!/bin/bash
# Runs the offline harness. Needs `lua` on PATH, and the sibling repos this
# addon is tested against:
#
#   PeaversSplitsData  - the real published pool (PEAVERS_SPLITS_DATA)
#   PeaversCommons     - the real widgets the settings pages draw with
#                        (PEAVERS_COMMONS)
#
# Both are found beside the addon in a normal checkout. A worktree is not beside
# its siblings, so it needs the variables.
set -euo pipefail

cd "$(dirname "$0")/.."

status=0
for test in tests/test_*.lua; do
	echo "=== $test"
	lua "$test" || status=1
done

exit "$status"
