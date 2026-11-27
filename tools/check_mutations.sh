#!/bin/bash
# Safety gate: only three files may call APIs that change files on disk.
#   Sources/Core/FileOperations.swift  - user files (rename, new folder, trash, move, copy)
#   Sources/Core/AppFiles.swift        - Find's own logs/themes/temp files, guarded to Find's folders
#   Sources/Darwin/DarwinPlatform.swift - the macOS primitives FileOperations uses
# Any other source file using one of these APIs fails the build.
cd "$(dirname "$0")/.."
PATTERN='removeItem|moveItem|copyItem|trashItem|replaceItem|createDirectory|createFile|setAttributes|createSymbolicLink|linkItem|write\(to:|write\(toFile:|writeToFile|writeToURL|FileHandle\(forWriting|FileHandle\(forUpdating|[^a-zA-Z_.]mkdir\(|[^a-zA-Z_.]rmdir\(|[^a-zA-Z_.]unlink\(|[^a-zA-Z_.]rename\(|renamex_np|renameat|[^a-zA-Z_.]chmod\(|[^a-zA-Z_.]chown\(|[^a-zA-Z_.]truncate\(|\.platform\.|exclusiveRename\(|moveToTrash\(|fopen\(|[^a-zA-Z_]open\([^)]*O_(WRONLY|RDWR|CREAT)|NSFileHandle|recycle\(|setResourceValue|setxattr|removexattr'
ALLOWED='Sources/Core/FileOperations.swift Sources/Core/AppFiles.swift Sources/Darwin/DarwinPlatform.swift'
BAD=0
for f in $(find Sources -name '*.swift' | sort); do
  skip=0
  for a in $ALLOWED; do [ "$f" = "$a" ] && skip=1; done
  [ $skip = 1 ] && continue
  # ignore comment lines
  hits=$(grep -nE "$PATTERN" "$f" | grep -vE '^[0-9]+:\s*//' || true)
  if [ -n "$hits" ]; then
    echo "E-GUARD-2 file-changing API used outside the allowed files: $f"
    echo "$hits" | sed 's/^/E-GUARD-2 line /'
    BAD=1
  fi
done
if [ $BAD = 0 ]; then echo "GUARD OK only FileOperations, AppFiles and DarwinPlatform change files"; fi
exit $BAD
