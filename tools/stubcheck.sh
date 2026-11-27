#!/bin/bash
# Type-check the AppKit layer on Linux against hand-written AppKit stand-ins (LinuxSupport/AppKitStubs.swift).
# Catches internal mistakes and Swift 4.1 language errors; it can't prove the real AppKit API matches.
cd "$(dirname "$0")/.."
TC=/home/claude/toolchain
export LD_LIBRARY_PATH=$TC/compat
SWIFTC=$TC/swift-4.1.3-RELEASE-ubuntu16.04/usr/bin/swiftc
OUT=/tmp/stubcheck/src
rm -rf $OUT && mkdir -p $OUT
for f in Sources/App/*.swift Sources/Darwin/*.swift; do
  sed -e 's/^import AppKit$/import Foundation/' -e 's/^import CoreServices$//' -e 's/^import ImageIO$//' -e 's/^import QuickLook$//' -e 's/^import Quartz$//' -e 's/^import AVKit$//' -e 's/^import CoreText$//' -e 's/^import AVFoundation$//' -e 's/^import Darwin$/import Glibc/' -e 's/@objc([^)]*)//g' -e 's/@objc //g' -e 's/error as NSError/error as! NSError/g' -e 's/ as CFString/ as! CFString/g' -e 's/ as String\b/ as! String/g' "$f" \
    | perl -pe 's/#selector\(((?:[^()]|\([^()]*\))*)\)/selCheck($1)/g' > $OUT/$(basename "$f")
done
# main.swift must be the only top-level-code file
ERRS=$($SWIFTC -swift-version 4 -typecheck Sources/Core/*.swift LinuxSupport/AppKitStubs.swift $OUT/*.swift 2>&1 | grep -E "error")
if [ -n "$ERRS" ]; then
  echo "$ERRS" | head -${1:-60}
  exit 1
fi
exit 0
