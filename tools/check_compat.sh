#!/bin/bash
# 10.13 compatibility guard: Swift features whose runtime support starts at macOS 10.15.
# Code needing a newer API must use `if #available(macOS X, *)` with a fallback; this script
# only catches whole frameworks/features that cannot be fenced that way.
cd "$(dirname "$0")/.."
PATTERN='^[[:space:]]*import[[:space:]]+(SwiftUI|Combine|Network|UniformTypeIdentifiers)|[^a-zA-Z_]async[[:space:]]+(func|let|throws)|[^a-zA-Z_]await[[:space:]]|[^a-zA-Z_]actor[[:space:]]+[A-Z]|@MainActor|Task[[:space:]]*\{|Task\.detached|AsyncStream|@Observable|@Published'
BAD=0
while IFS= read -r f; do
  hits=$(grep -nE "$PATTERN" "$f" | grep -vE '^[0-9]+:[[:space:]]*//' || true)
  if [ -n "$hits" ]; then
    echo "E-GUARD-3 needs macOS 10.15+: $f"
    echo "$hits" | sed 's/^/E-GUARD-3   line /'
    BAD=1
  fi
done < <(find Sources -name '*.swift' | sort)
[ $BAD = 0 ] && echo "GUARD OK (10.13 compatibility)"
exit $BAD
