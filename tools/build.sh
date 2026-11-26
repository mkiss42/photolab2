#!/bin/bash
# tools/build.sh <legacy|modern> [--no-python] [--no-dmg] [--no-selftest]
#
# Builds build/PhotoLab.app (universal: x86_64 + arm64) and build/PhotoLab2.dmg.
# Writes build/build-log.txt: plain ASCII, numbered lines (B0001...), failures as E-BUILD-n.
#
# Python runtime for the brain: python-build-standalone, one per architecture, fetched by
# tools/fetch_python.sh into build/python-cache (needs network the first time).
# --no-python builds without it (the app then reports "Brain: not available").

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE="${1:-}"
shift || true
WITH_PYTHON=1; WITH_DMG=1; WITH_SELFTEST=1
for a in "$@"; do
  case "$a" in
    --no-python) WITH_PYTHON=0 ;;
    --no-dmg) WITH_DMG=0 ;;
    --no-selftest) WITH_SELFTEST=0 ;;
    *) echo "unknown option $a"; exit 64 ;;
  esac
done

BUILD="$ROOT/build"
mkdir -p "$BUILD"
LOG="$BUILD/build-log.txt"
RAW="$BUILD/build-raw.txt"
: > "$LOG"; : > "$RAW"
N=0
note() { N=$((N+1)); printf 'B%04d %s\n' "$N" "$*" | tee -a "$LOG"; }
fail() { note "$1 FAILED: $2"; note "BUILD FAILED ($1) - last lines of build/build-raw.txt follow"; tail -n 40 "$RAW" | sed 's/^/RAW /' | tee -a "$LOG"; exit 1; }

PROFILE_FILE="$ROOT/profiles/$PROFILE.env"
[ -f "$PROFILE_FILE" ] || { echo "usage: tools/build.sh <legacy|modern>"; exit 64; }
# shellcheck disable=SC1090
source "$PROFILE_FILE"

VERSION="$(tr -d '[:space:]' < VERSION)"
note "PhotoLab $VERSION profile=$PROFILE_NAME"
note "Host: macOS $(sw_vers -productVersion 2>/dev/null) $(uname -m)"

# ---- Toolchain -----------------------------------------------------------------------------
command -v xcrun >/dev/null 2>&1 || fail "E-BUILD-0" "xcrun not found (install Xcode)"
XCODE_VER="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
XCODE_MAJOR="${XCODE_VER%%.*}"
note "Xcode: $XCODE_VER ($(xcode-select -p 2>/dev/null))"
if [ -z "$XCODE_MAJOR" ] || [ "$XCODE_MAJOR" -gt "$XCODE_MAX_MAJOR" ] || [ "$XCODE_MAJOR" -lt "$XCODE_MIN_MAJOR" ]; then
  fail "E-BUILD-0" "profile $PROFILE_NAME needs Xcode $XCODE_MIN_MAJOR to $XCODE_MAX_MAJOR, found ${XCODE_VER:-none}. Select another with: export DEVELOPER_DIR=/Applications/Xcode_XX.app/Contents/Developer"
fi
SWIFTC="$(xcrun -f swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
note "swiftc: $("$SWIFTC" --version 2>&1 | head -1)"
note "SDK: $SDK"

# ---- Guards --------------------------------------------------------------------------------
bash tools/check_mutations.sh >> "$RAW" 2>&1 || fail "E-BUILD-1" "file-safety guard (Swift): see build-raw.txt"
note "guard: Swift file-changing APIs only in the allowed files"
bash tools/check_mutations_py.sh >> "$RAW" 2>&1 || fail "E-BUILD-1" "file-safety guard (Python): see build-raw.txt"
note "guard: Python file-changing APIs only in the allowed files"
bash tools/check_compat.sh >> "$RAW" 2>&1 || fail "E-BUILD-1" "10.13 compatibility guard: see build-raw.txt"
note "guard: no Swift features that need macOS 10.15+"

# ---- Compile -------------------------------------------------------------------------------
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
note "sources: ${#SOURCES[@]} Swift files"
OBJ="$BUILD/obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"
RPATH_FLAGS=()
if [ "$EMBED_SWIFT_RUNTIME" = 1 ]; then
  RPATH_FLAGS=(-Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
for pair in "x86_64:$TARGET_X86_64" "arm64:$TARGET_ARM64"; do
  ARCH="${pair%%:*}"; TARGET="${pair#*:}"
  if "$SWIFTC" -O -wmo -swift-version 5 -module-name PhotoLab \
      -sdk "$SDK" -target "$TARGET" \
      -framework AppKit -framework Quartz \
      ${RPATH_FLAGS[@]+"${RPATH_FLAGS[@]}"} \
      "${SOURCES[@]}" -o "$OBJ/PhotoLab-$ARCH" >> "$RAW" 2>&1; then
    note "compile $ARCH ($TARGET): ok"
  else
    grep -E 'error:' "$RAW" | head -40 | while IFS= read -r l; do note "  $l"; done
    fail "E-BUILD-2" "Swift compile error ($ARCH)"
  fi
done

# ---- App bundle ----------------------------------------------------------------------------
APP="$BUILD/PhotoLab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create "$OBJ/PhotoLab-x86_64" "$OBJ/PhotoLab-arm64" -output "$APP/Contents/MacOS/PhotoLab" >> "$RAW" 2>&1 \
  || fail "E-BUILD-3" "lipo could not make the universal binary"
note "universal binary: $(lipo -archs "$APP/Contents/MacOS/PhotoLab")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PhotoLab</string>
  <key>CFBundleDisplayName</key><string>PhotoLab 2</string>
  <key>CFBundleIdentifier</key><string>com.smp.photolab2</string>
  <key>CFBundleExecutable</key><string>PhotoLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM</string>
  <key>LSMinimumSystemVersionByArchitecture</key>
  <dict><key>x86_64</key><string>$MIN_SYSTEM</string><key>arm64</key><string>${TARGET_ARM64##*macosx}</string></dict>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>PhotoLab asks Finder to show Get Info windows.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
note "Info.plist: version $VERSION, minimum macOS $MIN_SYSTEM"

if [ "$EMBED_SWIFT_RUNTIME" = 1 ]; then
  xcrun swift-stdlib-tool --copy --scan-executable "$APP/Contents/MacOS/PhotoLab" \
      --platform macosx --destination "$APP/Contents/Frameworks" >> "$RAW" 2>&1
  COUNT=$(ls "$APP/Contents/Frameworks" 2>/dev/null | grep -c '^libswift' || true)
  if [ "$COUNT" -gt 0 ]; then
    note "Swift runtime for macOS < 10.14.4: $COUNT libraries embedded"
  else
    fail "E-BUILD-4" "no Swift runtime libraries could be embedded; the app would not start on 10.13-10.14.3"
  fi
fi

# Brain source
mkdir -p "$APP/Contents/Resources/brain"
cp brain/run_brain.py "$APP/Contents/Resources/brain/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' brain/photolab_brain "$APP/Contents/Resources/brain/" \
  || fail "E-BUILD-3" "could not copy the brain"
note "brain: $(find "$APP/Contents/Resources/brain" -name '*.py' | wc -l | tr -d ' ') Python files"

# Python runtimes
if [ "$WITH_PYTHON" = 1 ]; then
  for ARCH in x86_64 arm64; do
    DEST="$APP/Contents/Resources/python-$ARCH"
    if bash tools/fetch_python.sh "$ARCH" "$DEST" >> "$RAW" 2>&1; then
      note "python-$ARCH: $("$DEST/bin/python3" -c 'import platform;print(platform.python_version())' 2>/dev/null || echo 'bundled (other architecture, not runnable here)')"
    else
      fail "E-BUILD-7" "could not fetch the Python runtime for $ARCH (see build-raw.txt; or build with --no-python)"
    fi
  done
else
  note "python: not bundled (--no-python)"
fi

# ---- Sign ----------------------------------------------------------------------------------
# Inside out: every Mach-O file (Python runtimes, extension modules, Swift runtime) on its own,
# then the app itself. No --deep: it only understands nested bundles.
SIGNED=0
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    codesign --force --sign - "$f" >> "$RAW" 2>&1 || fail "E-BUILD-5" "codesign failed on ${f#$APP/}"
    SIGNED=$((SIGNED+1))
  fi
done < <(find "$APP/Contents/Resources" "$APP/Contents/Frameworks" -type f -print0)
if codesign --force --sign - "$APP" >> "$RAW" 2>&1 && codesign --verify --strict "$APP" >> "$RAW" 2>&1; then
  note "codesign (ad-hoc): ok, $SIGNED nested binaries signed, app verified"
else
  fail "E-BUILD-5" "codesign failed on the app bundle"
fi

# ---- Self-test -----------------------------------------------------------------------------
if [ "$WITH_SELFTEST" = 1 ]; then
  # Native slice first; on Apple Silicon also the Intel slice under Rosetta when available.
  RUNNERS=("native")
  if [ "$(uname -m)" = "arm64" ] && arch -x86_64 /usr/bin/true >/dev/null 2>&1; then RUNNERS+=("x86_64"); fi
  for R in "${RUNNERS[@]}"; do
    ST="$BUILD/selftest-$R.txt"
    if [ "$R" = native ]; then CMD=("$APP/Contents/MacOS/PhotoLab" --self-test)
    else CMD=(arch -x86_64 "$APP/Contents/MacOS/PhotoLab" --self-test); fi
    if "${CMD[@]}" > "$ST" 2>&1; then
      grep -E '^SELFTEST' "$ST" | while IFS= read -r l; do note "[$R] $l"; done
    else
      grep -E '^SELFTEST' "$ST" | while IFS= read -r l; do note "[$R] $l"; done
      tail -n 30 "$ST" >> "$RAW"
      fail "E-BUILD-8" "self-test failed ($R)"
    fi
  done
fi

# ---- Disk image ----------------------------------------------------------------------------
if [ "$WITH_DMG" = 1 ]; then
  STAGE="$BUILD/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG="$BUILD/PhotoLab2.dmg"; rm -f "$DMG"
  if hdiutil create -volname "PhotoLab 2" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >> "$RAW" 2>&1; then
    note "disk image: build/PhotoLab2.dmg ($(du -h "$DMG" | cut -f1))"
  else
    fail "E-BUILD-6" "hdiutil could not create the disk image (build/PhotoLab.app is still usable)"
  fi
fi

note "DONE"
