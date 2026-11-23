#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ "$(printenv GITHUB_ACTIONS)" != true || "$(printenv RUNNER_ENVIRONMENT)" != github-hosted ||
      "$(printenv RUNNER_OS)" != Linux || "$(uname -m)" != x86_64 ]]; then
  printf '%s\n' 'This acceptance fixture requires a GitHub-hosted Linux x64 runner.' >&2
  exit 2
fi

consumer_sql=''
case $# in
  0) ;;
  1)
    if [[ "$1" != '--verify-consumer-contract' || "$GITHUB_REPOSITORY" != 'gecompat/SQL_Server_Lab' ]]; then exit 2; fi
    consumer_sql='lab-contract'
    ;;
  2)
    if [[ "$1" != '--consumer-sql' || "$GITHUB_REPOSITORY" != 'gecompat/SQL_Server_Analyze' ]]; then exit 2; fi
    consumer_sql="$(realpath -e -- "$2")"
    if [[ "$consumer_sql" != "$(realpath -e -- "$RUNNER_TEMP")/"*/wi0009-consumer.sql ||
          ! -f "$consumer_sql" || ! -s "$consumer_sql" || -L "$2" ]] ||
          (( $(stat -c %s -- "$consumer_sql") > 33554432 )); then exit 2; fi
    ;;
  *) exit 2 ;;
esac

readonly label='io.gecompat.sql-server-lab.polybase-probe'
readonly scope="polybase-$(openssl rand -hex 8)"
readonly root="$(mktemp -d "$RUNNER_TEMP/$scope.XXXXXX")"
readonly store_image="$scope-store"
readonly sql_image="$scope-sql"
readonly volume="$scope-data"
readonly host='s3-probe'
readonly bucket="$scope"
readonly sql_repository='mcr.microsoft.com/mssql/server'
readonly sql_tag='2025-CU9-ubuntu-24.04'
network_id=''
store_id=''
sql_id=''
volume_created=''
stage='initialization'
engine_result=''
consumer_result=''

cleanup() {
  local rc=$? cleanup_rc=0 id
  trap - EXIT INT TERM
  for id in "$sql_id" "$store_id"; do
    [[ -n "$id" ]] || continue
    if [[ "$(docker container inspect --format "{{index .Config.Labels \"$label\"}}" "$id")" == "$scope" ]]; then
      docker container rm -f -v "$id" >/dev/null || cleanup_rc=1
      if docker container inspect "$id" >/dev/null 2>&1; then cleanup_rc=1; fi
    else
      cleanup_rc=1
    fi
  done
  if [[ -n "$volume_created" ]]; then
    if [[ "$(docker volume inspect --format "{{index .Labels \"$label\"}}" "$volume_created")" == "$scope" ]]; then
      docker volume rm "$volume_created" >/dev/null || cleanup_rc=1
      if docker volume inspect "$volume_created" >/dev/null 2>&1; then cleanup_rc=1; fi
    else
      cleanup_rc=1
    fi
  fi
  if [[ -n "$network_id" ]]; then
    if [[ "$(docker network inspect --format "{{index .Labels \"$label\"}}" "$network_id")" == "$scope" ]]; then
      docker network rm "$network_id" >/dev/null || cleanup_rc=1
      if docker network inspect "$network_id" >/dev/null 2>&1; then cleanup_rc=1; fi
    else
      cleanup_rc=1
    fi
  fi
  for id in "$sql_image" "$store_image"; do
    if docker image inspect "$id" >/dev/null 2>&1; then
      if [[ "$(docker image inspect --format "{{index .Config.Labels \"$label\"}}" "$id")" == "$scope" ]]; then
        docker image rm "$id" >/dev/null || cleanup_rc=1
        if docker image inspect "$id" >/dev/null 2>&1; then cleanup_rc=1; fi
      else
        cleanup_rc=1
      fi
    fi
  done
  if [[ "$root" == "$RUNNER_TEMP/$scope."* && -d "$root" && ! -L "$root" ]]; then
    rm -rf -- "$root" || cleanup_rc=1
    if [[ -e "$root" || -L "$root" ]]; then cleanup_rc=1; fi
  else
    cleanup_rc=1
  fi
  if (( cleanup_rc != 0 )); then
    printf '%s\n' 'POLYBASE_S3_CLEANUP=FAIL' >&2
    if (( rc == 0 )); then rc=1; fi
  else
    printf '%s\n' 'POLYBASE_S3_CLEANUP=PASS'
  fi
  if (( rc != 0 )); then
    printf 'POLYBASE_S3_FAILED_STAGE=%s\n' "$stage" >&2
  else
    printf '%s\n' "$engine_result"
    if [[ -n "$consumer_result" ]]; then printf '%s\n' "$consumer_result"; fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage='source_resolution'
mkdir "$root/sql-build" "$root/store-build" "$root/mounted"
readonly store_media='https://github.com/seaweedfs/seaweedfs/releases/download/4.55/linux_amd64.tar.gz'
readonly store_sha='f156c609eeaf9e5fcfeea33fd70411222005f83760aa95893c9d58eff006b45c'
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --max-time 120 --max-filesize 160000000 "$store_media" --output "$root/weed.tar.gz"
printf '%s  %s\n' "$store_sha" "$root/weed.tar.gz" | sha256sum --check --status
tar --extract --gzip --to-stdout --file "$root/weed.tar.gz" weed > "$root/store-build/weed"
chmod 0555 "$root/store-build/weed"
curl --fail --silent --show-error --proto '=https' --max-time 30 --max-filesize 1000000 \
  --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  --dump-header "$root/sql-headers" --output "$root/sql-manifest" \
  "https://mcr.microsoft.com/v2/mssql/server/manifests/$sql_tag"
sql_digest="$(awk 'tolower($1)=="docker-content-digest:" {sub(/\r$/,"",$2); print $2}' "$root/sql-headers")"
[[ "$sql_digest" == 'sha256:2b5b581621126574f3d1f75e78d3eebe8d05aedb59ad0cfdf9aa42cb0634d726' ]]
[[ "$sql_digest" == "sha256:$(sha256sum "$root/sql-manifest" | cut -d ' ' -f 1)" ]]
sql_ref="$sql_repository@$sql_digest"
docker pull --platform linux/amd64 "$sql_ref" >"$root/sql-pull.log" 2>&1
printf 'POLYBASE_S3_INPUTS=SEAWEEDFS_4.55|%s|SQL2025_CU9|%s\n' "$store_sha" "$sql_digest"

stage='tls_and_identities'
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -sha256 -subj '/CN=Example PolyBase Fixture CA' \
  -keyout "$root/ca.key" -out "$root/sql-build/probe-ca.crt" \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  >"$root/pki.log" 2>&1
openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=$host" \
  -keyout "$root/mounted/store.key" -out "$root/store.csr" >>"$root/pki.log" 2>&1
printf 'subjectAltName=DNS:%s\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n' "$host" >"$root/leaf.ext"
openssl x509 -req -in "$root/store.csr" -CA "$root/sql-build/probe-ca.crt" -CAkey "$root/ca.key" \
  -CAcreateserial -days 1 -sha256 -extfile "$root/leaf.ext" -out "$root/mounted/store.crt" >>"$root/pki.log" 2>&1
admin_key="$(openssl rand -hex 10)"
admin_secret="$(openssl rand -hex 20)"
read_key="$(openssl rand -hex 10)"
read_secret="$(openssl rand -hex 20)"
MSSQL_SA_PASSWORD="Aa1!$(openssl rand -hex 20)"
SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
export MSSQL_SA_PASSWORD SQLCMDPASSWORD
master_password="Aa1!$(openssl rand -hex 20)"
for value in "$admin_key" "$admin_secret" "$read_key" "$read_secret" "$SQLCMDPASSWORD" "$master_password"; do
  printf '::add-mask::%s\n' "$value"
done
printf '{"identities":[{"name":"fixture-writer","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List"]},{"name":"fixture-reader","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Read:%s","List:%s"]}]}\n' \
  "$admin_key" "$admin_secret" "$read_key" "$read_secret" "$bucket" "$bucket" >"$root/mounted/identities.json"
printf 'user = "%s:%s"\n' "$admin_key" "$admin_secret" >"$root/writer.curl"
printf 'user = "%s:%s"\n' "$read_key" "$read_secret" >"$root/reader.curl"
# The container retains no DAC override. Only its explicitly supplied fixture group can read this mount.
fixture_gid="$(id -g)"
[[ "$fixture_gid" =~ ^[0-9]+$ ]]
chmod 0750 "$root/mounted"
chmod 0640 "$root/mounted/store.key" "$root/mounted/store.crt" "$root/mounted/identities.json"

stage='owned_images'
printf 'FROM scratch\nLABEL %s=%s\nCOPY weed /weed\nENTRYPOINT ["/weed"]\n' "$label" "$scope" >"$root/store-build/Dockerfile"
printf 'FROM %s\nUSER root\nLABEL %s=%s\nCOPY probe-ca.crt /usr/local/share/ca-certificates/sql-lab-probe.crt\nRUN chmod 0644 /usr/local/share/ca-certificates/sql-lab-probe.crt && update-ca-certificates && install -d -m 0755 /var/opt/mssql/security/ca-certificates && install -m 0644 /usr/local/share/ca-certificates/sql-lab-probe.crt /var/opt/mssql/security/ca-certificates/sql-lab-probe.crt\nUSER mssql\n' \
  "$sql_ref" "$label" "$scope" >"$root/sql-build/Dockerfile"
docker build --network none --tag "$store_image" "$root/store-build" >"$root/store-build.log" 2>&1
docker build --network none --tag "$sql_image" "$root/sql-build" >"$root/sql-build.log" 2>&1

stage='owned_network_and_store'
network_id="$(docker network create --internal --label "$label=$scope" "$scope")"
volume_created="$(docker volume create --label "$label=$scope" "$volume")"
[[ "$volume_created" == "$volume" && "$(docker volume inspect --format "{{index .Labels \"$label\"}}" "$volume")" == "$scope" ]]
store_id="$(docker container create --name "$scope-store" --network "$network_id" --network-alias "$host" \
  --label "$label=$scope" --memory 512m --cap-drop ALL --group-add "$fixture_gid" --security-opt no-new-privileges --tmpfs /tmp:rw,nosuid,nodev \
  --mount "type=volume,source=$volume,target=/data" --mount "type=bind,source=$root/mounted,target=/probe,readonly" \
  "$store_image" mini -dir=/data "-ip=$host" -ip.bind=0.0.0.0 -s3.port=8333 -s3.port.https=0 \
  -s3.key.file=/probe/store.key -s3.cert.file=/probe/store.crt \
  -s3.config=/probe/identities.json -s3.iam=false -s3.autoCreateBucket=false)"
docker container start "$store_id" >/dev/null
store_curl() {
  local owner state pid
  owner="$(docker container inspect --format "{{index .Config.Labels \"$label\"}}" "$store_id")" || return 98
  [[ "$owner" == "$scope" ]] || return 98
  state="$(docker container inspect --format '{{.State.Running}} {{.State.Pid}}' "$store_id")" || return 98
  read -r state pid <<< "$state"
  [[ "$state" == true && "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 97
  [[ "/proc/$pid/ns/net" -ef /proc/self/ns/net ]] && return 98
  sudo -n nsenter --target "$pid" --net -- /usr/bin/curl "$@"
}

s3() {
  local identity=$1
  shift
  store_curl --silent --show-error --noproxy '*' --proto '=https' --connect-timeout 3 --max-time 15 \
    --cacert "$root/sql-build/probe-ca.crt" --resolve "$host:8333:127.0.0.1" \
    --aws-sigv4 'aws:amz:us-east-1:s3' --config "$root/$identity.curl" "$@"
}

stage='s3_readiness'
ready=0
ready_rc=0
for attempt in {1..30}; do
  if s3 writer --fail "https://$host:8333/" >"$root/s3-ready.log" 2>&1; then
    ready=1
    break
  else
    ready_rc=$?
  fi
  if [[ "$ready_rc" == 97 || "$ready_rc" == 98 ]]; then break; fi
  sleep 2
done
if [[ "$ready" != 1 ]]; then
  if docker container logs --tail 30 "$store_id" 2>&1 | grep -Ei 'permission denied|operation not permitted' >/dev/null; then
    printf '%s\n' 'POLYBASE_S3_STORE_DIAGNOSTIC=PERMISSION' >&2
  fi
  printf 'POLYBASE_S3_READINESS_EXIT=%s|STORE_EXIT=%s\n' "$ready_rc" \
    "$(docker container inspect --format '{{.State.ExitCode}}' "$store_id")" >&2
  exit 1
fi
stage='s3_hostname_control'
wrong_host_rc=0
store_curl --silent --show-error --noproxy '*' --proto '=https' --max-time 10 \
  --cacert "$root/sql-build/probe-ca.crt" --resolve "wrong-s3-probe:8333:127.0.0.1" \
  https://wrong-s3-probe:8333/ >"$root/wrong-host.log" 2>&1 || wrong_host_rc=$?
[[ "$wrong_host_rc" == 60 ]]
stage='s3_seed_and_policy'
s3 writer --fail --request PUT "https://$host:8333/$bucket" >"$root/bucket.log" 2>&1
printf '7,ExampleSeven\n11,ExampleEleven\n' >"$root/fixture.csv"
object_url="https://$host:8333/$bucket/fixture.csv"
s3 writer --fail --upload-file "$root/fixture.csv" "$object_url" >"$root/put.log" 2>&1
s3 reader --fail --output "$root/readback.csv" "$object_url" 2>"$root/get.log"
cmp -s "$root/fixture.csv" "$root/readback.csv"
denial="$(s3 reader --output "$root/denied.xml" --write-out '%{http_code}' \
  --upload-file "$root/fixture.csv" "https://$host:8333/$bucket/denied.csv" 2>"$root/denied.log")"
[[ "$denial" == 403 ]]

stage='owned_sql_start'
sql_id="$(docker container create --name "$scope-sql" --network "$network_id" --label "$label=$scope" --memory 3g \
  --env ACCEPT_EULA=Y --env MSSQL_PID=Developer --env MSSQL_SA_PASSWORD "$sql_image")"
docker container start "$sql_id" >/dev/null
sql() {
  docker exec -i --env SQLCMDPASSWORD "$sql_id" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -C -b -r1 -l 3 -t 45 -h -1 -W "$@"
}
ready=0
for attempt in {1..40}; do
  if sql -Q "SET NOCOUNT ON; SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion'));" \
    >"$root/sql-version" 2>"$root/sql-ready.log"; then
    ready=1
    break
  fi
  sleep 2
done
[[ "$ready" == 1 && "$(tr -d '[:space:]' < "$root/sql-version")" == 17.0.5005.3 ]]

stage='sql_external_table'
cat >"$root/read.sql" <<SQL
SET NOCOUNT ON;
CREATE DATABASE [ExamplePolyBaseProbe];
GO
USE [ExamplePolyBaseProbe];
SET NOCOUNT ON;
CREATE MASTER KEY ENCRYPTION BY PASSWORD='$master_password';
CREATE DATABASE SCOPED CREDENTIAL [ExampleReader] WITH IDENTITY='S3 Access Key',SECRET='$read_key:$read_secret';
CREATE EXTERNAL DATA SOURCE [ExampleStore] WITH (LOCATION='s3://$host:8333/',CREDENTIAL=[ExampleReader]);
CREATE EXTERNAL FILE FORMAT [ExampleCsv] WITH (FORMAT_TYPE=DELIMITEDTEXT,FORMAT_OPTIONS(FIELD_TERMINATOR=','));
CREATE EXTERNAL TABLE dbo.ExampleExternal ([Id] int NOT NULL,[Name] varchar(32) NOT NULL)
WITH (LOCATION='/$bucket/fixture.csv',DATA_SOURCE=[ExampleStore],FILE_FORMAT=[ExampleCsv]);
PRINT 'POLYBASE_SQL_DDL=PASS';
SELECT [Id],[Name] INTO #Observed FROM dbo.ExampleExternal;
DECLARE @Expected TABLE ([Id] int NOT NULL,[Name] varchar(32) NOT NULL);
INSERT @Expected VALUES (7,'ExampleSeven'),(11,'ExampleEleven');
IF (SELECT COUNT_BIG(*) FROM #Observed)<>2
   OR EXISTS(SELECT * FROM #Observed EXCEPT SELECT * FROM @Expected)
   OR EXISTS(SELECT * FROM @Expected EXCEPT SELECT * FROM #Observed)
    THROW 50000,'Unexpected native external rows.',1;
IF NOT EXISTS(SELECT 1 FROM sys.external_tables t
   INNER JOIN sys.external_data_sources s ON s.data_source_id=t.data_source_id
   INNER JOIN sys.external_file_formats f ON f.file_format_id=t.file_format_id
   WHERE t.object_id=OBJECT_ID(N'dbo.ExampleExternal') AND s.name=N'ExampleStore' AND f.name=N'ExampleCsv')
   OR (SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.ExampleExternal'))<>2
    THROW 50001,'Unexpected native external metadata.',1;
SELECT 'POLYBASE_S3_NATIVE=PASS|SQL2025_CU9|CSV_ROWS=2|COLUMNS=2|READ_ONLY_KEY=1';
GO
SQL
if ! sql <"$root/read.sql" >"$root/sql-results" 2>"$root/sql-error"; then
  grep -Fx 'POLYBASE_SQL_DDL=PASS' "$root/sql-error" >&2 || true
  sed -nE 's/^Msg ([0-9]+),.*/POLYBASE_SQL_ERROR=\1/p' "$root/sql-error" | sort -u >&2
  exit 1
fi
engine_result="$(grep -Fx 'POLYBASE_S3_NATIVE=PASS|SQL2025_CU9|CSV_ROWS=2|COLUMNS=2|READ_ONLY_KEY=1' "$root/sql-results")"

if [[ -n "$consumer_sql" ]]; then
  stage='consumer_network_isolation'
  docker network disconnect "$network_id" "$store_id"
  [[ "$(docker container inspect --format '{{len .NetworkSettings.Networks}}' "$store_id")" == 0 ]]
  [[ "$(docker container inspect --format '{{len .NetworkSettings.Networks}}' "$sql_id")" == 1 ]]
  if [[ "$consumer_sql" == 'lab-contract' ]]; then
    consumer_sql="$root/wi0009-consumer.sql"
    cat >"$consumer_sql" <<'SQL'
USE [ExamplePolyBaseProbe];
GO
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.external_tables WHERE object_id=OBJECT_ID(N'dbo.ExampleExternal'))
    THROW 50002,'Native external table is unavailable to the SQL consumer.',1;
SELECT 'POLYBASE_S3_CONSUMER=PASS';
GO
SQL
  fi
  stage='consumer_sql_input'
  # Bind validation and execution to the same private UTF-8 byte stream.
  python3 - "$consumer_sql" "$root/validated-consumer.sql" <<'PY'
import pathlib
import re
import sys

with pathlib.Path(sys.argv[1]).open('rb') as source:
    raw = source.read(32 * 1024 * 1024 + 1)
if not raw or len(raw) > 32 * 1024 * 1024 or b'\0' in raw:
    raise SystemExit(2)
try:
    sql = raw.decode('utf-8')
except UnicodeError:
    raise SystemExit(2) from None
directives = re.compile(r'^(?::|!!|(?:ED|EXIT|QUIT|RESET)(?:[\s(]|$))', re.IGNORECASE)
if any(directives.match(line.lstrip().lstrip('\ufeff').lstrip()) for line in sql.splitlines()):
    raise SystemExit(2)
pathlib.Path(sys.argv[2]).write_bytes(raw)
PY
  stage='sql_catalog_consumer'
  if ! sql -x <"$root/validated-consumer.sql" >"$root/consumer-results" 2>"$root/consumer-error"; then
    sed -nE 's/^Msg ([0-9]+),.*/POLYBASE_CONSUMER_SQL_ERROR=\1/p' "$root/consumer-error" | sort -u >&2
    if grep -qiE '^Sqlcmd: Error:' "$root/consumer-error"; then
      printf '%s\n' 'POLYBASE_CONSUMER_SQLCMD_ERROR=1' >&2
    fi
    exit 1
  fi
  consumer_result="$(grep -Fx 'POLYBASE_S3_CONSUMER=PASS' "$root/consumer-results")"
  [[ "$consumer_result" == 'POLYBASE_S3_CONSUMER=PASS' ]]
fi
