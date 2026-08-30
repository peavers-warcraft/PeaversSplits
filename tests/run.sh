#!/bin/bash
# Runs the offline harness. Needs `lua` on PATH and PeaversSplitsData beside this
# addon - or PEAVERS_SPLITS_DATA pointing at it, which a worktree needs because a
# worktree is not beside its siblings.
set -euo pipefail

cd "$(dirname "$0")/.."
exec lua tests/test_pace.lua
