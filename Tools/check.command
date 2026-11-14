#!/bin/zsh
set -eu
ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
export TMPDIR="$ROOT/Temporary/"
mkdir -p "$TMPDIR" "$ROOT/Build" "$ROOT/Cache/Swift"
sources=()
for source in "$ROOT"/Sources/*.swift; do
 if [[ "${source:t}" != App.swift ]]; then sources+=("$source"); fi
done
"$(/usr/bin/xcrun --find swiftc)" -O -parse-as-library -sdk "$(/usr/bin/xcrun --show-sdk-path)" -module-cache-path "$ROOT/Cache/Swift" -file-prefix-map "$ROOT=/ScenePaint" "${sources[@]}" "$ROOT"/Checks/*.swift -o "$ROOT/Build/SourceChecks"
"$ROOT/Build/SourceChecks" "${1:-all}"
