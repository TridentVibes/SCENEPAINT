#!/bin/zsh
set -eu
ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
export TMPDIR="$ROOT/Temporary/"
mkdir -p "$TMPDIR"
export HF_HOME="$ROOT/Cache/HuggingFace"
export HF_HUB_DISABLE_TELEMETRY=1
command -v hf >/dev/null || { print 'Install the official Hugging Face hf CLI first: https://huggingface.co/docs/huggingface_hub/guides/cli'; exit 1; }
python3 "$ROOT/Tools/download-models.py"
mkdir -p "$ROOT/Cache/Swift" "$ROOT/Cache/Clang"
export CLANG_MODULE_CACHE_PATH="$ROOT/Cache/Clang"
"$(/usr/bin/xcrun --find swiftc)" -parse-as-library -module-cache-path "$ROOT/Cache/Swift" -sdk "$(/usr/bin/xcrun --show-sdk-path)" "$ROOT/Tools/CompileModels.swift" -o "$ROOT/Cache/CompileModels"
for package in "$ROOT"/Models/*.mlpackage "$ROOT"/Models/SAM2BasePlus/*.mlpackage "$ROOT"/Models/SAM2/*.mlpackage; do
 "$ROOT/Cache/CompileModels" "$package" "${package:h}"
done
print 'Pinned models downloaded and compiled. Model licenses remain separate from the app MIT license.'
