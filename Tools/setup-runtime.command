#!/bin/zsh
set -eu
ROOT="${0:A:h:h}"
PYTHON="${SCENEPAINT_PYTHON:-python3.12}"
export PIP_CACHE_DIR="$ROOT/Cache/Pip"
"$PYTHON" -c 'import sys; assert sys.version_info[:2] == (3,12), "Use Python 3.12 for the pinned runtime"'
"$PYTHON" -m venv "$ROOT/Runtime/Geometry"
"$ROOT/Runtime/Geometry/bin/python" -m pip install -r "$ROOT/Geometry/requirements.lock"
print 'Local development runtime installed. Inference runs offline after model setup.'
