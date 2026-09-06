#!/usr/bin/env bash
# Refuse to modify the live plugin while Hades II is running.
#
# The plugin folder in r2modman is a JUNCTION to src/, so every write THERE is a
# write to the running game's mod. Files outside src/ -- tests, docs, .git -- are
# no longer inside the watched folder, which is why the layout was split.
#
# The loader picks up a change within seconds and re-runs the plugin chunk. See
# MODDING_HADES2.md section 2: a live hot-reload cycle crashed a RealHecate
# session mid-development -- four reloads in ninety seconds, the last three
# seconds before an EXCEPTION_ACCESS_VIOLATION inside Lua's garbage collector.
# Sabotage cycles -- deliberately broken code -- must never run in a live
# session.
#
# Source this and call `guard` before any write to src/.
guard() {
  if tasklist 2>/dev/null | grep -qi hades2; then
    echo "REFUSING: Hades II is running. This folder is junctioned into the live"
    echo "profile, so editing src/ hot-reloads it into the running game."
    return 1
  fi
  return 0
}
