#!/bin/bash
# The upstream SQL Server custom-setup scripts intentionally probe optional,
# unset MSSQL_* variables. Keep errexit/pipefail, but do not enable nounset
# across those vendor-owned scripts.
set -eo pipefail

/opt/mssql/bin/permissions_check.sh

desired_config=/opt/sql-server-lab/config/external-runtime-mssql.conf
sync_extensibility_setting() {
    local setting="$1"
    local value
    value="$(awk -F= -v wanted="${setting}" '
        /^\[extensibility\]$/ { active=1; next }
        /^\[/ { active=0 }
        active {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) {
                sub(/^[^=]*=[[:space:]]*/, "", $0)
                print
                exit
            }
        }
    ' "${desired_config}")"
    if [[ -n "${value}" ]]; then
        /opt/mssql/bin/mssql-conf set "extensibility.${setting}" "${value}"
    else
        /opt/mssql/bin/mssql-conf unset "extensibility.${setting}" >/dev/null 2>&1 || true
    fi
}

test -f "${desired_config}"
desired_ml_eula="$(awk -F= '
    /^\[EULA\]$/ { active=1; next }
    /^\[/ { active=0 }
    active {
        key=$1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        if (key == "accepteulaml") {
            sub(/^[^=]*=[[:space:]]*/, "", $0)
            print
            exit
        }
    }
' "${desired_config}")"
test "${desired_ml_eula}" = 'Y'
/opt/mssql/bin/mssql-conf set EULA accepteulaml "${desired_ml_eula}"

for setting in pythonbinpath rbinpath datadirectories; do
    sync_extensibility_setting "${setting}"
done

for transient_root in /var/opt/mssql-extensibility/data /var/opt/mssql-extensibility/sandboxes; do
    if [[ -d "${transient_root}" ]]; then
        find "${transient_root}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
done

source /opt/mssql/bin/init_custom_setup.sh

runuser -u mssql_launchpadd -- /opt/mssql/bin/launchpadd &
launchpad_pid="$!"

runuser -u mssql -- "$@" &
sql_pid="$!"

terminate_children() {
    kill -TERM "${sql_pid}" "${launchpad_pid}" 2>/dev/null || true
}

trap terminate_children TERM INT

/opt/mssql/bin/run_custom_setup.sh

set +e
wait -n "${sql_pid}" "${launchpad_pid}"
exit_code="$?"
set -e

terminate_children
wait "${sql_pid}" 2>/dev/null || true
wait "${launchpad_pid}" 2>/dev/null || true
exit "${exit_code}"
