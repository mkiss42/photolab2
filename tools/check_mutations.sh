#!/bin/bash
# File-safety guard (Swift). Only these files may use APIs that change files on disk:
#   Sources/Core/FileOperations.swift  user files (rename, new folder, Trash, move, copy, undo)
#   Sources/Core/AppFiles.swift        PhotoLab's own logs, support files, caches, report zip
#   Sources/Platform/Platform.swift    the macOS primitives FileOperations uses
# Never edit this list or the pattern to make a build pass; move the code instead.
cd "$(dirname "$0")/.."
ALLOWED="Sources/Core/FileOperations.swift Sources/Core/AppFiles.swift Sources/Platform/Platform.swift"
PATTERN='removeItem|moveItem|copyItem|trashItem|replaceItem|createDirectory|createFile|setAttributes|createSymbolicLink|linkItem|write\(to:|write\(toFile:|writeToFile|writeToURL|atomicWrite|FileHandle\(forWriting|FileHandle\(forUpdating|[^a-zA-Z_.]mkdir\(|[^a-zA-Z_.]rmdir\(|[^a-zA-Z_.]unlink\(|[^a-zA-Z_.]rename\(|renamex_np|renameat|[^a-zA-Z_.]chmod\(|[^a-zA-Z_.]chown\(|[^a-zA-Z_.]truncate\(|ftruncate|fopen\(|O_WRONLY|O_RDWR|O_CREAT|setResourceValue|setxattr|removexattr|recycle\(|/usr/bin/ditto|/bin/mv|/bin/rm|/bin/cp'
BAD=0
while IFS= read -r f; do
  case " $ALLOWED " in *" $f "*) continue ;; esac
  hits=$(grep -nE "$PATTERN" "$f" | grep -vE '^[0-9]+:[[:space:]]*//' || true)
  if [ -n "$hits" ]; then
    echo "E-GUARD-1 file-changing API outside the allowed files: $f"
    echo "$hits" | sed 's/^/E-GUARD-1   line /'
    BAD=1
  fi
done < <(find Sources -name '*.swift' | sort)
[ $BAD = 0 ] && echo "GUARD OK (Swift)"
exit $BAD
