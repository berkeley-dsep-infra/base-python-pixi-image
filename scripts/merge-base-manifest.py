#!/usr/bin/env python3
# Build a pixi.toml that solves this leaf image's own [dependencies] together
# with a fixed pin for every conda package already installed in the base
# image. This is what keeps the leaf image safe: pixi is *forced* to respect
# whatever's already installed, so anything that would require changing it
# surfaces as a solve error, not a silent substitution (see the nbclient
# downgrade incident this approach was built to catch).
#
# Usage: merge-base-manifest.py <base 'mamba list --export' output> <own pixi.toml> <output pixi.toml>
import re
import sys

base_export_path, own_pixi_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

base_pins = {}
python_pin = None
with open(base_export_path) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#") or line.endswith("=pypi_0"):
            continue
        parts = line.split("=", 2)
        if len(parts) != 3:
            continue
        name, version, _build = parts
        if name == "python":
            python_pin = version  # exact pin comes from what's actually installed
            continue
        base_pins[name] = version

if python_pin is None:
    sys.exit("could not find python in base manifest")

new_pins = {}
pypi_lines = []
in_pypi = False
with open(own_pixi_path) as f:
    for line in f:
        stripped = line.strip()
        if stripped.startswith("[pypi-dependencies]"):
            in_pypi = True
            continue
        if in_pypi:
            if stripped and not stripped.startswith("#"):
                pypi_lines.append(line.rstrip("\n"))
            continue
        if stripped.startswith("python "):
            continue  # this leaf's own python line is a floating match (e.g. "3.14.*"), not authoritative
        m = re.match(r'^([a-zA-Z0-9_.-]+)\s*=\s*"==([^"]+)"', stripped)
        if not m:
            continue
        new_pins[m.group(1)] = m.group(2)

# new_pins wins on conflict: this leaf image's own choices override whatever
# the base happens to have, same as `--freeze-installed` semantics but
# explicit rather than implied.
merged = dict(base_pins)
merged.update(new_pins)

with open(out_path, "w") as f:
    f.write('[workspace]\n')
    f.write('channels = ["conda-forge"]\n')
    f.write('platforms = ["linux-64"]\n')
    f.write('name = "leaf-solve"\n')
    f.write('version = "0.1.0"\n\n')
    f.write('[dependencies]\n')
    f.write(f'python = "=={python_pin}"\n')
    for name, version in sorted(merged.items()):
        f.write(f'"{name}" = "=={version}"\n')
    if pypi_lines:
        f.write('\n[pypi-dependencies]\n')
        for line in pypi_lines:
            f.write(line + "\n")
