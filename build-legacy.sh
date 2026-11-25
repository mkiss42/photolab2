#!/bin/bash
# Build PhotoLab for macOS 10.13 and later (Intel + Apple Silicon). Needs Xcode 26 or older.
exec "$(dirname "$0")/tools/build.sh" legacy "$@"
