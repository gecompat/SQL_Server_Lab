#!/bin/bash
set -euo pipefail

lock_path="${1:?Python wheel lock path is required}"
wheel_root="$(mktemp -d)"

cleanup() {
    rm -rf "${wheel_root}"
}
trap cleanup EXIT

while IFS='|' read -r package version filename sha256 url; do
    if [[ -z "${package}" || "${package}" == \#* ]]; then
        continue
    fi
    target="${wheel_root}/${filename}"
    wget -q --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 "${url}" -O "${target}"
    echo "${sha256}  ${target}" | sha256sum --check --strict
done < "${lock_path}"

python3.10 /opt/sql-server-lab/bin/install-python-wheels.py \
    "${wheel_root}" \
    /usr/lib/python3.10/dist-packages

python3.10 - <<'PY'
from importlib.metadata import version

expected = {
    "dill": "0.3.5.1",
    "numpy": "1.22.0",
    "pandas": "1.4.2",
    "patsy": "0.5.2",
    "revoscalepy": "10.0.1",
}
for package, wanted in expected.items():
    actual = version(package)
    if actual != wanted:
        raise RuntimeError(f"{package}: expected {wanted}, got {actual}")
PY
