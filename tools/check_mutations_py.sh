#!/bin/bash
# File-safety guard (Python brain). Only these modules may change files on disk:
#   brain/photolab_brain/appfiles.py   the brain's own socket, cache and database files
# Later phases add (and document in docs/PLAN.md): ingest copy engine, volume marker.
# Never edit this list or the pattern to make a build pass; move the code instead.
cd "$(dirname "$0")/.."
ALLOWED="brain/photolab_brain/appfiles.py"
PATTERN='os\.(remove|unlink|rename|replace|rmdir|removedirs|makedirs|mkdir|chmod|chown|truncate|utime|link|symlink|setxattr|removexattr)\(|shutil\.(copy|copy2|copyfile|copytree|move|rmtree|copystat)|\.(write_text|write_bytes|unlink|rmdir|mkdir|touch|rename|replace)\(|open\([^)]*["'"'"'](w|a|x|r\+|wb|ab|xb)|subprocess.*\b(rm|mv|cp|ditto)\b'
BAD=0
while IFS= read -r f; do
  case " $ALLOWED " in *" $f "*) continue ;; esac
  hits=$(grep -nE "$PATTERN" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  if [ -n "$hits" ]; then
    echo "E-GUARD-2 file-changing call outside the allowed modules: $f"
    echo "$hits" | sed 's/^/E-GUARD-2   line /'
    BAD=1
  fi
done < <(find brain/photolab_brain -name '*.py' | sort)
[ $BAD = 0 ] && echo "GUARD OK (Python)"
exit $BAD
