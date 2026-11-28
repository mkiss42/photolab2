#!/bin/bash
# tools/build.sh <legacy|modern> [--no-python] [--no-dmg] [--no-selftest]
#
# Builds build/PhotoLab.app (universal: x86_64 + arm64) and build/PhotoLab.dmg.
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
      -framework AppKit -framework Quartz -framework NetFS -framework QuickLook -framework AVKit \
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
  <key>CFBundleDisplayName</key><string>PhotoLab</string>
  <key>CFBundleIdentifier</key><string>com.smp.photolab</string>
  <key>CFBundleExecutable</key><string>PhotoLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM</string>
  <key>LSMinimumSystemVersionByArchitecture</key>
  <dict><key>x86_64</key><string>$MIN_SYSTEM</string><key>arm64</key><string>${TARGET_ARM64##*macosx}</string></dict>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>PhotoLab</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHumanReadableCopyright</key><string>Internal tool. Based on Find 0.18.16.</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Folder or file</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.item</string></array>
  </dict></array>
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

# ExifTool (Perl, run by /usr/bin/perl): metadata reading/writing (Find's ExifToolServer).
if [ -f Resources/exiftool/exiftool ] && cp -R Resources/exiftool "$APP/Contents/Resources/exiftool"; then
  note "ExifTool bundled: $(/usr/bin/perl "$APP/Contents/Resources/exiftool/exiftool" -config "" -ver 2>&1 | head -1)"
else
  fail "E-BUILD-3" "ExifTool could not be bundled"
fi
if iconutil -c icns Resources/PhotoLab.iconset -o "$APP/Contents/Resources/PhotoLab.icns" >> "$RAW" 2>&1; then
  note "icon: ok"
else
  note "WARN icon could not be built (generic icon)"
fi
# The Python brain is not wired into the Find-based app yet (PLAN.md): not bundled.
note "brain: not bundled in this phase"

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

# ---- Self-tests (Find's): Safety Self-Check, Search, Index, Photo Metadata ----------------
if [ "$WITH_SELFTEST" = 1 ]; then
  EXE="$APP/Contents/MacOS/PhotoLab"
  VOUT="$("$EXE" --version 2>&1)"
  note "version check: $VOUT"
  case "$VOUT" in PhotoLab*) ;; *) fail "E-BUILD-7" "the built app did not start" ;; esac
  RUNNERS=("native")
  if [ "$(uname -m)" = "arm64" ] && arch -x86_64 /usr/bin/true >/dev/null 2>&1; then RUNNERS+=("x86_64"); fi
  for R in "${RUNNERS[@]}"; do
    for T in selfcheck searchtest indextest phototest; do
      ST="$BUILD/$T-$R.txt"
      if [ "$R" = native ]; then "$EXE" --$T > "$ST" 2>&1; else arch -x86_64 "$EXE" --$T > "$ST" 2>&1; fi
      RC=$?
      SUM="$(grep -iE 'passed|failed|PASS|FAIL' "$ST" | tail -n 1)"
      note "[$R] $T rc=$RC ${SUM}"
      grep -E '^(FAIL|E-|W-)' "$ST" | head -n 20 | while IFS= read -r l; do note "[$R]   $l"; done
      if [ "$T" = phototest ]; then
        [ $RC -eq 2 ] && fail "E-BUILD-11" "photo metadata self-test: a file changed while being read ($R)"
      elif [ $RC -ne 0 ]; then
        tail -n 30 "$ST" >> "$RAW"
        fail "E-BUILD-8" "$T failed ($R)"
      fi
    done
  done
  # PhotoLab: the kept-open FTP connection, against a local test server when CI started one.
  if [ -n "${PHOTOLAB_FTP_TEST:-}" ]; then
    ST="$BUILD/ftptest.txt"
    "$EXE" --ftptest "$PHOTOLAB_FTP_TEST" > "$ST" 2>&1
    RC=$?
    note "ftptest rc=$RC $(grep -E 'PASSED|FAILED' "$ST" | tail -n 1)"
    grep -E '^(FAIL|E-)' "$ST" | head -n 20 | while IFS= read -r l; do note "  $l"; done
    if [ $RC -ne 0 ]; then tail -n 60 "$ST" >> "$RAW"; fail "E-BUILD-12" "FTP self-test failed"; fi
  fi
fi

# ---- Disk image ----------------------------------------------------------------------------
if [ "$WITH_DMG" = 1 ]; then
  STAGE="$BUILD/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG="$BUILD/PhotoLab.dmg"; rm -f "$DMG"
  if hdiutil create -volname "PhotoLab" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >> "$RAW" 2>&1; then
    note "disk image: build/PhotoLab.dmg ($(du -h "$DMG" | cut -f1))"
  else
    fail "E-BUILD-6" "hdiutil could not create the disk image (build/PhotoLab.app is still usable)"
  fi
fi

note "DONE"
