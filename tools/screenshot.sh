#!/usr/bin/env bash
# Renders the room to screenshots/room.png so a person can look at it.
#
#   tools/screenshot.sh
#   tools/screenshot.sh --admin   # an admin's beacon, and the room through a blind
#
# Uses xvfb-run because this needs a rendering context and the machines this runs on have
# no display. Nothing here is headless-safe: `--headless` gives a null renderer and every
# frame it saves is empty, which is worse than no screenshot because it looks like one.
#
# Copied from game-arena's rather than shared with it: these are separate repositories
# and that is the family's rule.
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution 1600x900 --script tools/screenshot.gd -- "$@"
