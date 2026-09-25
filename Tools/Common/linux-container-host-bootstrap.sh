#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=180 update
apt-get -o DPkg::Lock::Timeout=180 install -y ca-certificates curl gnupg jq git openssh-server docker.io podman
curl --fail --location --max-time 120 https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
apt-get update
ACCEPT_EULA=Y apt-get install -y powershell mssql-tools18
ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
install -d -m 0755 /var/lib/sql-server-lab
cat >/etc/default/grub.d/99-sql-server-lab-cgroup-v1.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=false"
EOF
update-grub
cat >/usr/local/sbin/sql-server-lab-host-ready <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$(stat -fc %T /sys/fs/cgroup)" = tmpfs
docker info --format '{{.CgroupVersion}}' | grep -qx '1'
podman info --format json | jq -e '(.host.cgroupVersion // .host.cgroupsVersion) | tostring | test("^v?1$")' >/dev/null
command -v pwsh >/dev/null
command -v sqlcmd >/dev/null
EOF
chmod 0755 /usr/local/sbin/sql-server-lab-host-ready
systemctl enable docker.service ssh.service
systemctl reboot
