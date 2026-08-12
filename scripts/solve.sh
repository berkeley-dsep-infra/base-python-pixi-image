#!/usr/bin/env bash
# Solve this image's pixi.toml and produce two build-time artifacts:
#   /tmp/explicit.txt          -- conda packages, as a checksummed @EXPLICIT
#                                  list mamba/micromamba can install with zero
#                                  solving (pixi already did the solving).
#   /tmp/pip-requirements.txt  -- [pypi-dependencies] packages, resolved by
#                                  pixi but not installed by it; a plain
#                                  `pip install -r` does that in the real env.
#
# If a 'notebook' conda env already exists (i.e. this is a leaf image built
# on some other pixi image), its live package manifest is merged into
# pixi.toml as fixed pins before solving. This is what lets leaf images stay
# safe: pixi is forced to respect what's already installed rather than
# silently substituting something to satisfy a new package. Base images
# with nothing to inherit from just solve pixi.toml directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v mamba >/dev/null 2>&1 && mamba env list 2>/dev/null | grep -q '^notebook '; then
    mamba list -n notebook --export | tail -n +3 > base-manifest.txt
    python3 "$SCRIPT_DIR/merge-base-manifest.py" base-manifest.txt pixi.toml merged-pixi.toml
    MANIFEST=merged-pixi.toml
else
    MANIFEST=pixi.toml
fi

pixi install --manifest-path "$MANIFEST"
pixi workspace export conda-explicit-spec --manifest-path "$MANIFEST" \
    --platform linux-64 --ignore-pypi-errors spec-out
python3 "$SCRIPT_DIR/dedupe-explicit-spec.py" spec-out/*_conda_spec.txt /tmp/explicit.txt
pixi list --manifest-path "$MANIFEST" --json \
    | python3 "$SCRIPT_DIR/pixi-pypi-requirements.py" > /tmp/pip-requirements.txt
