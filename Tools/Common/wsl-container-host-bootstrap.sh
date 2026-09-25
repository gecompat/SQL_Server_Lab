#!/usr/bin/env bash
# Nur fuer einen neu angelegten, eigenen Ubuntu-22.04-WSL-Labhost.
set -euo pipefail
test "$(id -u)" = 0
expected_id="${1:?Eigene WSL-Host-ID fehlt}"
[[ "$expected_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]
test "$(cat /etc/sql-server-lab-wsl-host-id)" = "$expected_id"
grep -qi microsoft /proc/sys/kernel/osrelease
. /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 22.04
test -f /sys/fs/cgroup/memory/memory.limit_in_bytes
test -f /sys/fs/cgroup/pids/cgroup.procs
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=180 update
apt-get -o DPkg::Lock::Timeout=180 install -y ca-certificates curl gnupg git docker.io podman
# Ubuntu 22.04 CNI requires the legacy interface with this WSL kernel.
# This helper is restricted to the newly owned host, before SQL workloads.
if test "$(readlink -f /usr/sbin/iptables)" != /usr/sbin/xtables-legacy-multi; then
    test -z "$(docker ps -q)"
    test -z "$(podman ps -q)"
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    systemctl restart docker.service
fi
package=$(mktemp /tmp/sqllab-msrepo.XXXXXX.deb)
trap 'rm -f -- "$package"' EXIT
curl --fail --location --max-time 120 https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o "$package"
dpkg -i "$package"
apt-get -o DPkg::Lock::Timeout=180 update
ACCEPT_EULA=Y apt-get -o DPkg::Lock::Timeout=180 install -y powershell mssql-tools18
if ! command -v sqlcmd >/dev/null; then
    ln -s /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
fi
systemctl enable --now docker.service
docker info --format '{{.CgroupVersion}}' | grep -qx 1
command -v pwsh
test -x /opt/mssql-tools18/bin/sqlcmd
