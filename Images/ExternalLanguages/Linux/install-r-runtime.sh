#!/usr/bin/env bash
set -euo pipefail

lock_file="${1:?R package lock is required}"
test -f "${lock_file}"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

expected=(iterators foreach R6 jsonlite CompatibilityAPI RevoScaleR)
installed=()
while IFS='|' read -r package version filename sha256 source; do
    case "${package}" in
        ''|'#'*) continue ;;
    esac
    test -n "${version}"
    [[ "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.tar\.gz$ ]]
    [[ "${sha256}" =~ ^[a-f0-9]{64}$ ]]
    [[ "${source}" =~ ^https://[^?]+$ ]]
    if [[ " ${expected[*]} " != *" ${package} "* ]]; then
        echo "Unexpected R package in lock: ${package}" >&2
        exit 64
    fi

    test "${source##*/}" = "${filename}"
    archive="${work_dir}/${filename}"
    downloaded=false
    for attempt in 1 2 3; do
        if Rscript --vanilla -e 'args <- commandArgs(TRUE); options(timeout=180); download.file(args[[1]], args[[2]], method="libcurl", quiet=TRUE)' "${source}" "${archive}"; then
            downloaded=true
            break
        fi
    done
    test "${downloaded}" = true
    echo "${sha256}  ${archive}" | sha256sum --check --strict
    R CMD INSTALL --no-multiarch "${archive}"
    installed+=("${package}")
done < "${lock_file}"

test "${#installed[@]}" -eq "${#expected[@]}"
for package in "${expected[@]}"; do
    test "$(printf '%s\n' "${installed[@]}" | grep -Fxc "${package}")" -eq 1
done

Rscript --vanilla -e 'expected <- c(iterators="1.0.14", foreach="1.5.2", R6="2.5.1", jsonlite="1.8.4", CompatibilityAPI="1.1.0", RevoScaleR="10.0.1"); stopifnot(all(vapply(names(expected), function(package) as.character(packageVersion(package)) == expected[[package]], logical(1)))); library(RevoScaleR)'
