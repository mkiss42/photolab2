#!/bin/bash
# tools/fetch_python.sh <x86_64|arm64> <dest-dir>
# Puts a relocatable CPython 3.11 (python-build-standalone, install_only_stripped) at <dest-dir>,
# trimmed of tests/IDLE/tkinter. Downloads are cached in build/python-cache.
# Pin a release with PBS_TAG=YYYYMMDD; default is the newest release that has 3.11.
set -euo pipefail
ARCH="$1"; DEST="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/python-cache"; mkdir -p "$CACHE"
case "$ARCH" in
  x86_64) TRIPLE=x86_64-apple-darwin ;;
  arm64) TRIPLE=aarch64-apple-darwin ;;
  *) echo "unknown arch $ARCH"; exit 64 ;;
esac
PY_MINOR="${PY_MINOR:-3.11}"
REPO=astral-sh/python-build-standalone

api() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then gh api "$1"
  else curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} "https://api.github.com/$1"; fi
}

if [ -n "${PBS_TAG:-}" ]; then REL="repos/$REPO/releases/tags/$PBS_TAG"; else REL="repos/$REPO/releases/latest"; fi
URL="$(api "$REL" | python3 -c '
import json, re, sys
minor, triple = sys.argv[1], sys.argv[2]
pat = re.compile(r"cpython-%s\.\d+\+\d+-%s-install_only_stripped\.tar\.gz$" % (re.escape(minor), re.escape(triple)))
for a in json.load(sys.stdin).get("assets", []):
    if pat.search(a["name"]):
        print(a["browser_download_url"]); break
' "$PY_MINOR" "$TRIPLE")"
[ -n "$URL" ] || { echo "no cpython-$PY_MINOR $TRIPLE asset in $REL"; exit 1; }
FILE="$CACHE/$(basename "$URL")"
[ -f "$FILE" ] || curl -fL --retry 3 -o "$FILE" "$URL"
echo "python: $URL"

rm -rf "$DEST"; mkdir -p "$DEST"
tar -xzf "$FILE" -C "$DEST" --strip-components 1
LIB="$(ls -d "$DEST"/lib/python3.* | head -1)"
rm -rf "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" "$LIB"/lib-dynload/_tkinter* "$DEST/share" "$DEST/include"
find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} +
echo "python $ARCH ready at $DEST ($(du -sh "$DEST" | cut -f1))"
