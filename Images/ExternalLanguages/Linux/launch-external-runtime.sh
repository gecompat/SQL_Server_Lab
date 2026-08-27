#!/bin/bash
# The upstream SQL Server custom-setup scripts intentionally probe optional,
# unset MSSQL_* variables. Keep errexit/pipefail, but do not enable nounset
# across those vendor-owned scripts.
set -eo pipefail

/opt/mssql/bin/permissions_check.sh
source /opt/mssql/bin/init_custom_setup.sh

/opt/mssql/bin/launchpadd &
launchpad_pid="$!"

"$@" &
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
