#!/bin/bash
# Build PhotoLab for macOS 12 and later (Intel + Apple Silicon). Works with Xcode 26 and newer.
exec "$(dirname "$0")/tools/build.sh" modern "$@"
