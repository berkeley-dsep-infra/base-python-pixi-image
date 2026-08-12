#!/usr/bin/env python3
# Drop known package-name collisions from a conda explicit spec before
# installing it. Some conda-forge packages migrated names (e.g. flask_cors ->
# flask-cors) without the old name being deprecated/redirected, so a
# dependency that lists both the old and new name (as localtileserver 0.11.0
# does) makes the solver install both -- two different packages writing the
# same site-packages path, which silently corrupts whichever loses the
# write race while conda's own metadata still records both as installed.
#
# Each entry here is the OLDER of a pair that provides the same import path;
# keep the newer one and drop this one from the install list.
KNOWN_DUPLICATE_PACKAGES = {
    "flask_cors",  # superseded by flask-cors; see localtileserver 0.11.0's recipe
}

import sys

spec_in, spec_out = sys.argv[1], sys.argv[2]

with open(spec_in) as f:
    lines = f.readlines()

with open(spec_out, "w") as f:
    for line in lines:
        url = line.strip()
        if url.startswith("http"):
            # https://.../noarch/<name>-<version>-<build>.conda[#hash]
            filename = url.rsplit("/", 1)[-1]
            pkg_name = filename.rsplit("-", 2)[0]
            if pkg_name in KNOWN_DUPLICATE_PACKAGES:
                continue
        f.write(line)
