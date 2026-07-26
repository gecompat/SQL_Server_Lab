#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
    printf '%s\n' 'UNSUPPORTED_OS'
    exit 2
fi

case "$(uname -m)" in
    x86_64|amd64) ;;
    *)
        printf '%s\n' 'UNSUPPORTED_ARCHITECTURE'
        exit 3
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' 'DOCKER_ENGINE_MISSING'
    exit 4
fi

if ! docker info >/dev/null 2>&1; then
    printf '%s\n' 'DOCKER_ENGINE_UNAVAILABLE'
    exit 5
fi

if ! docker compose version >/dev/null 2>&1; then
    printf '%s\n' 'DOCKER_COMPOSE_MISSING'
    exit 6
fi

if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    printf '%s\n' 'CGROUP_V2_REQUIRED'
    exit 7
fi

printf '%s\n' 'READY'
