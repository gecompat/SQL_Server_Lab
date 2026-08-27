#!/usr/bin/env bash
set -euo pipefail

lock_file="${1:?java artifact lock path is required}"
output_root="${2:?java output root is required}"
sdk_expected_sha256="${3:?SDK JAR SHA-256 is required}"
probe_expected_sha256="${4:?probe JAR SHA-256 is required}"
probe_source="${5:?probe source path is required}"
extension_license="${6:?Microsoft Java extension license path is required}"

work_root="$(mktemp -d)"
trap 'rm -rf -- "${work_root}"' EXIT
download_root="${work_root}/downloads"
mkdir -p "${download_root}"

while IFS='|' read -r artifact version filename sha256 url; do
    if [[ -z "${artifact}" || "${artifact}" == \#* ]]; then
        continue
    fi
    if [[ -z "${version}" || ! "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || ! "${sha256}" =~ ^[a-f0-9]{64}$ ]]; then
        echo "Invalid Java artifact lock record: ${artifact}" >&2
        exit 64
    fi
    target="${download_root}/${filename}"
    wget -q --https-only --secure-protocol=TLSv1_2 --timeout=60 --tries=3 "${url}" -O "${target}"
    echo "${sha256}  ${target}" | sha256sum --check --strict
done < "${lock_file}"

jdk_package="${download_root}/msopenjdk-11_11.0.32-1_amd64.deb"
jdk_extract="${work_root}/jdk-package"
dpkg-deb -x "${jdk_package}" "${jdk_extract}"
jdk_home="${jdk_extract}/usr/lib/jvm/msopenjdk-11-amd64"
test -x "${jdk_home}/bin/javac"
test -x "${jdk_home}/bin/jar"
test -x "${jdk_home}/bin/jlink"

sdk_package="com/microsoft/sqlserver/javalangextension"
sdk_source_root="${work_root}/sdk-source/${sdk_package}"
sdk_classes="${work_root}/sdk-classes"
mkdir -p "${sdk_source_root}" "${sdk_classes}" "${output_root}/libraries" "${output_root}/licenses"
cp "${download_root}/AbstractSqlServerExtensionDataset.java" "${sdk_source_root}/"
cp "${download_root}/AbstractSqlServerExtensionExecutor.java" "${sdk_source_root}/"
cp "${download_root}/PrimitiveDataset.java" "${sdk_source_root}/"

"${jdk_home}/bin/javac" --release 8 -d "${sdk_classes}" \
    "${sdk_source_root}/AbstractSqlServerExtensionDataset.java" \
    "${sdk_source_root}/AbstractSqlServerExtensionExecutor.java" \
    "${sdk_source_root}/PrimitiveDataset.java"
find "${sdk_classes}" -exec touch -d '@1704067200' {} +
mapfile -t sdk_entries < <(cd "${sdk_classes}" && find com -type f -print | LC_ALL=C sort)
(
    cd "${sdk_classes}"
    TZ=UTC "${jdk_home}/bin/jar" cfM "${output_root}/libraries/mssql-java-lang-extension-linux.jar" "${sdk_entries[@]}"
)
echo "${sdk_expected_sha256}  ${output_root}/libraries/mssql-java-lang-extension-linux.jar" | sha256sum --check --strict

probe_classes="${work_root}/probe-classes"
mkdir -p "${probe_classes}"
"${jdk_home}/bin/javac" --release 8 \
    -cp "${output_root}/libraries/mssql-java-lang-extension-linux.jar" \
    -d "${probe_classes}" "${probe_source}"
find "${probe_classes}" -exec touch -d '@1704067200' {} +
mapfile -t probe_entries < <(cd "${probe_classes}" && find sqlserverlab -type f -print | LC_ALL=C sort)
(
    cd "${probe_classes}"
    TZ=UTC "${jdk_home}/bin/jar" cfM "${output_root}/libraries/sql-server-lab-java-probe-1.0.0.jar" "${probe_entries[@]}"
)
echo "${probe_expected_sha256}  ${output_root}/libraries/sql-server-lab-java-probe-1.0.0.jar" | sha256sum --check --strict

"${jdk_home}/bin/jlink" \
    --module-path "${jdk_home}/jmods" \
    --add-modules java.base,java.sql,jdk.crypto.ec \
    --strip-debug \
    --no-header-files \
    --no-man-pages \
    --compress=2 \
    --output "${output_root}/jre"

mkdir -p "${output_root}/extension"
cp "${download_root}/java-lang-extension-linux-release.zip" "${output_root}/extension/"
(
    cd "${output_root}/extension"
    "${jdk_home}/bin/jar" xf java-lang-extension-linux-release.zip
)
echo '4b8ae9f9770ed25bbed7705888c7e65e9cd28e3410d063e90115edc479c1e662  '"${output_root}/extension/libJavaExtension.so.1.0" | sha256sum --check --strict

cp "${extension_license}" "${output_root}/licenses/MICROSOFT-JAVA-EXTENSION-LICENSE.txt"
if [[ -f "${jdk_extract}/usr/share/doc/msopenjdk-11/copyright" ]]; then
    cp "${jdk_extract}/usr/share/doc/msopenjdk-11/copyright" "${output_root}/licenses/MSOPENJDK-11-COPYRIGHT.txt"
else
    echo 'Microsoft Build of OpenJDK 11: GPL-2.0-only WITH Classpath-exception-2.0' > "${output_root}/licenses/MSOPENJDK-11-COPYRIGHT.txt"
fi

"${output_root}/jre/bin/java" -version
test ! -e "${output_root}/jre/bin/javac"
find "${output_root}" -type d -exec chmod 0755 {} +
find "${output_root}/libraries" "${output_root}/extension" "${output_root}/licenses" -type f -exec chmod 0644 {} +
chmod -R a+rX "${output_root}/jre"
test -x "${output_root}/jre/bin/java"
test -x "${output_root}/jre/lib/jspawnhelper"
