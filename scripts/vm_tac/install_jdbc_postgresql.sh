#!/usr/bin/env bash
# =============================================================================
#  install_jdbc_postgresql.sh - Install the PostgreSQL JDBC driver (pgJDBC)
#                               into Talend Administration Center on vm_tac.
#
#  TAC connects to its database (vm_db, PostgreSQL 18) through this driver.
#  Talend documents its location as the TAC web application's WEB-INF/lib:
#     /opt/talend/tac/tomcat/webapps/ROOT/WEB-INF/lib/postgresql-<version>.jar
#
#  Steps:
#    1. Get postgresql-<version>.jar: local copy in /opt/binary or
#       /opt/talend/tac/drivers, otherwise Maven Central (SHA-1 checked)
#    2. Check the jar (zip integrity + org.postgresql.Driver present)
#    3. Keep a copy in /opt/talend/tac/drivers (persisted, reused on redeploy)
#    4. Replace any other postgresql-*.jar in WEB-INF/lib (one driver only)
#    5. Restart the talend-tac service if it is running
#
#  install_tac.sh calls this script after each deployment of the war, because
#  a redeploy recreates webapps/ROOT and removes the driver.
#
#  Usage (inside vm_tac, as root, after install_tac.sh):
#     docker exec -it vm_tac bash /opt/scripts/vm_tac/install_jdbc_postgresql.sh
#     ... --no-restart            install without restarting TAC
#     PG_JDBC_VERSION=42.7.13 ... install another version
#
#  Offline: put postgresql-<version>.jar in the binaries folder (/opt/binary).
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
PG_JDBC_VERSION="${PG_JDBC_VERSION:-${TAC_JDBC_PG_VERSION:-42.7.14}}"
TAC_USER="${TAC_USER:-talend}"
TAC_GROUP="${TAC_GROUP:-talend}"
TAC_HOME="${TAC_HOME:-/opt/talend/tac}"
TOMCAT_LINK="${TOMCAT_LINK:-${TAC_HOME}/tomcat}"
WEBAPP_DIR="${WEBAPP_DIR:-${TOMCAT_LINK}/webapps/ROOT}"
DRIVERS_DIR="${DRIVERS_DIR:-${TAC_HOME}/drivers}"
BINARY_PATH="${BINARY_PATH:-/opt/binary}"
SERVICE_NAME="${SERVICE_NAME:-talend-tac}"
MAVEN_REPO="${MAVEN_REPO:-https://repo1.maven.org/maven2}"

JAR="postgresql-${PG_JDBC_VERSION}.jar"
JAR_URL="${MAVEN_REPO}/org/postgresql/postgresql/${PG_JDBC_VERSION}/${JAR}"
LIB_DIR="${WEBAPP_DIR}/WEB-INF/lib"

RESTART=true
for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=false ;;
    -h|--help)    sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "line ${LINENO}: ${BASH_COMMAND}"' ERR

WORK_DIR="$(mktemp -d /tmp/pgjdbc.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ----------------------------------------------------------------------------
# 0. Pre-checks
# ----------------------------------------------------------------------------
log "PostgreSQL JDBC driver ${PG_JDBC_VERSION} for TAC"
[[ $EUID -eq 0 ]] || die "Run this script as root (docker exec -it vm_tac bash)."
[[ -d "${LIB_DIR}" ]] || die "${LIB_DIR} not found: deploy TAC first (install_tac.sh)."
[[ "${PG_JDBC_VERSION}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Invalid version: ${PG_JDBC_VERSION}"
for cmd in curl unzip sha1sum; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done

# ----------------------------------------------------------------------------
# 1. Get the jar
# ----------------------------------------------------------------------------
log "1/5 Get ${JAR}"
if [[ -f "${BINARY_PATH}/${JAR}" ]]; then
  SRC="${BINARY_PATH}/${JAR}"
  info "Using local file ${SRC}"
elif [[ -f "${DRIVERS_DIR}/${JAR}" ]]; then
  SRC="${DRIVERS_DIR}/${JAR}"
  info "Using cached copy ${SRC}"
else
  SRC="${WORK_DIR}/${JAR}"
  info "Downloading ${JAR_URL}"
  curl -fsSL --retry 3 -o "${SRC}" "${JAR_URL}" \
    || die "Download failed (no Internet access? put ${JAR} in the binaries folder)."
  # Maven Central publishes a SHA-1 checksum next to each file
  expected="$(curl -fsSL --retry 3 "${JAR_URL}.sha1" | awk '{print $1}')"
  [[ "${expected}" =~ ^[0-9a-f]{40}$ ]] || die "Could not read ${JAR_URL}.sha1"
  echo "${expected}  ${SRC}" | sha1sum -c --status || die "SHA-1 checksum mismatch for ${JAR}."
  info "SHA-1 checksum OK"
fi

# ----------------------------------------------------------------------------
# 2. Check the jar
# ----------------------------------------------------------------------------
log "2/5 Check the jar"
unzip -tqq "${SRC}" >/dev/null || die "${SRC} is not a valid jar (corrupted file?)."
# (no "| grep -q": it closes the pipe early and pipefail would report a failure)
unzip -l "${SRC}" 'org/postgresql/Driver.class' >/dev/null || die "${SRC} does not contain org.postgresql.Driver."
info "Valid jar, contains org.postgresql.Driver"

# ----------------------------------------------------------------------------
# 3. Persisted copy (reused when TAC is redeployed, even offline)
# ----------------------------------------------------------------------------
log "3/5 Copy to ${DRIVERS_DIR}"
install -d -o "${TAC_USER}" -g "${TAC_GROUP}" -m 0755 "${DRIVERS_DIR}"
if [[ "${SRC}" != "${DRIVERS_DIR}/${JAR}" ]]; then
  install -o "${TAC_USER}" -g "${TAC_GROUP}" -m 0644 "${SRC}" "${DRIVERS_DIR}/${JAR}"
fi
info "${DRIVERS_DIR}/${JAR}"

# ----------------------------------------------------------------------------
# 4. Install into WEB-INF/lib (only one PostgreSQL driver in the classpath)
# ----------------------------------------------------------------------------
log "4/5 Install into ${LIB_DIR}"
shopt -s nullglob
for old in "${LIB_DIR}"/postgresql-*.jar; do
  [[ "$(basename "$old")" == "${JAR}" ]] && continue
  info "Removing other driver version: $(basename "$old")"
  rm -f "$old"
done
shopt -u nullglob
install -o "${TAC_USER}" -g "${TAC_GROUP}" -m 0644 "${DRIVERS_DIR}/${JAR}" "${LIB_DIR}/${JAR}"
info "Installed ${LIB_DIR}/${JAR}"

# ----------------------------------------------------------------------------
# 5. Restart TAC so the driver is loaded
# ----------------------------------------------------------------------------
log "5/5 TAC service"
if [[ "${RESTART}" == true ]] && systemctl is-active --quiet "${SERVICE_NAME}"; then
  systemctl restart "${SERVICE_NAME}"
  info "${SERVICE_NAME} restarted"
else
  info "${SERVICE_NAME} not restarted (stopped, or --no-restart): the driver is loaded at the next start"
fi

log "Done"
cat <<EOF
    Driver class : org.postgresql.Driver
    JDBC URL     : jdbc:postgresql://vm-db:5432/<tac_database>
EOF
