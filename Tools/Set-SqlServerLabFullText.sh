#!/bin/sh
# Executes only inside an owned SQL container. SQL build is supplied by SQL,
# never guessed from a mutable image tag. apt downloads verify repository hashes.
set -eu
mode=$1
build=$2
year=$3
case "$mode" in on|off) ;; *) exit 40;; esac
case "$build" in ''|*[!0-9.]*|.*|*.) exit 41;; esac
case "$year" in 2019|2022|2025) ;; *) exit 42;; esac
test "$(id -u)" = 0
target=/opt/mssql/lib/sqlservr.fts.sfp
receipt=/opt/mssql/.sql-lab-fulltext
for path in /opt /opt/mssql /opt/mssql/lib; do
    test -d "$path" && test ! -L "$path"
done
test ! -L "$target"
test ! -L "$receipt"
if [ "$mode" = off ]; then
    # Only remove the exact unchanged capsule installed by this workflow.
    test -d "$receipt" && test -f "$receipt/capsule.sha256"
    test ! -L "$receipt/capsule.sha256"
    test -f "$target"
    sha256sum --check --status "$receipt/capsule.sha256"
    rm -- "$target" "$receipt/capsule.sha256" "$receipt/package.txt"
    rmdir -- "$receipt"
    exit 0
fi
test ! -e "$target"
test ! -e "$receipt"
. /etc/os-release
test "$ID" = ubuntu
test "$(dpkg --print-architecture)" = amd64
case "$year/$VERSION_ID" in
    2019/18.04|2019/20.04|2022/20.04|2022/22.04|2025/22.04|2025/24.04) ;;
    *) exit 43;;
esac
case "$VERSION_CODENAME" in bionic|focal|jammy|noble) ;; *) exit 44;; esac
test -f /usr/share/keyrings/microsoft-prod.gpg
work=$(mktemp -d /var/tmp/sql-lab-fulltext.XXXXXXXX)
stage=''
trap 'rm -rf -- "$work"; if [ -n "$stage" ]; then rm -f -- "$stage"; fi' EXIT
mkdir -p "$work/lists/partial" "$work/payload"
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/%s/mssql-server-%s %s main\n' "$VERSION_ID" "$year" "$VERSION_CODENAME" > "$work/source.list"
# Retry only repository/download I/O, before any feature files are published.
apt_opts="-o Dir::Etc::sourcelist=$work/source.list -o Dir::Etc::sourceparts=- -o Dir::State::lists=$work/lists -o Acquire::Retries=2 -o Acquire::https::Timeout=30 -o APT::Get::List-Cleanup=0"
# Intentional word splitting: apt_opts contains only generated fixed paths/options.
apt-get $apt_opts update
versions=$(apt-cache $apt_opts madison mssql-server-fts | awk -v prefix="$build-" 'index($3,prefix)==1 {print $3}' | sort -u)
test "$(printf '%s\n' "$versions" | wc -l)" = 1
case "$versions" in ''|*[!0-9A-Za-z.+:~_-]*) exit 45;; esac
cd "$work"
apt-get $apt_opts download "mssql-server-fts=$versions"
set -- "$work"/mssql-server-fts_*.deb
test "$#" = 1 && test -f "$1"
test "$(dpkg-deb -f "$1" Package)" = mssql-server-fts
test "$(dpkg-deb -f "$1" Version)" = "$versions"
test "$(dpkg-deb -f "$1" Architecture)" = amd64
# Current official images omit the engine's dpkg record. Installing this package
# with apt would install/replace the engine. Extract only Microsoft's FTS capsule;
# neither maintainer scripts nor the engine nor semantic-search DB are installed.
dpkg-deb --fsys-tarfile "$1" | tar -x -C "$work/payload" ./opt/mssql/lib/sqlservr.fts.sfp
capsule="$work/payload/opt/mssql/lib/sqlservr.fts.sfp"
test -f "$capsule" && test ! -L "$capsule"
engine_before=$(sha256sum /opt/mssql/lib/sqlservr.sfp)
mkdir -m 700 "$receipt"
printf '%s\n' "$versions" > "$receipt/package.txt"
hash=$(sha256sum "$capsule" | cut -d' ' -f1)
printf '%s  %s\n' "$hash" "$target" > "$receipt/capsule.sha256"
stage=$(mktemp /opt/mssql/lib/.sql-lab-fulltext.XXXXXXXX)
install -o 0 -g 0 -m 644 "$capsule" "$stage"
test "$(sha256sum "$stage" | cut -d' ' -f1)" = "$hash"
# Publish a complete capsule atomically; never expose a partial copy to SQL,
# and never overwrite a concurrently created or foreign target.
ln -- "$stage" "$target"
sha256sum --check --status "$receipt/capsule.sha256"
test "$(sha256sum /opt/mssql/lib/sqlservr.sfp)" = "$engine_before"
