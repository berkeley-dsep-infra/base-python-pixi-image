#!/usr/bin/env python3
# `pixi workspace export conda-explicit-spec` handles the conda side of the
# resolved environment natively -- this script only covers what it can't:
# the [pypi-dependencies] packages, extracted from `pixi list --json` (the
# full resolved closure, not --explicit, so this also picks up their own
# transitive PyPI-only dependencies) into a plain pip requirements list.
import json
import sys

packages = json.load(sys.stdin)
for p in sorted((p for p in packages if p["kind"] == "pypi"), key=lambda p: p["name"]):
    print(f"{p['name']}=={p['version']}")
