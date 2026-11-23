#!/usr/bin/env bash
# =============================================================================
#  install_tac.sh - Manual installation of Talend Administration Center
#                   on the vm_tac container (Debian 13, systemd).
#
#  Steps:
#    1. Install Java 21 (Eclipse Temurin)  -> /opt/talend/java/jdk-21...
#    2. JAVA_HOME + PATH for user talend   -> ~talend/.profile and ~/.bashrc
#    3. Install Apache Tomcat 11.0.29      -> /opt/talend/tac/apache-tomcat-11.0.29
#    4. systemd service (User/Group=talend) -> /etc/systemd/system/talend-tac.service
#    5. Deploy the TAC war as ROOT application (http://<host>:8080/)
#       + PostgreSQL JDBC driver in WEB-INF/lib (install_jdbc_postgresql.sh)
#
#  Everything is installed under /opt/talend (persisted volume tac_app), so
#  the installation survives "docker compose down / up".
#
#  Usage (inside vm_tac, as root):
#     docker exec -it vm_tac bash
#     bash /opt/scripts/vm_tac/install_tac.sh            # install + start
#     bash /opt/scripts/vm_tac/install_tac.sh --no-start # install + enable only
#     bash /opt/scripts/vm_tac/install_tac.sh --force    # reinstall Java/Tomcat
#     bash /opt/scripts/vm_tac/install_tac.sh --skip-jdbc  # no PostgreSQL JDBC driver
#
#  Offline mode: put the archives in the binaries folder (/opt/binary), they are
#  used instead of downloading:
#     OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz
#     apache-tomcat-11.0.29.tar.gz
#     postgresql-42.7.14.jar
#
#  All variables below can be overridden from the environment, e.g.
#     TAC_XMX=4g bash /opt/scripts/vm_tac/install_tac.sh
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
JAVA_MAJOR="${JAVA_MAJOR:-21}"
TOMCAT_VERSION="${TOMCAT_VERSION:-11.0.29}"

TAC_USER="${TAC_USER:-talend}"
TAC_GROUP="${TAC_GROUP:-talend}"

TALEND_BASE="${TALEND_BASE:-/opt/talend}"
JAVA_BASE="${JAVA_BASE:-${TALEND_BASE}/java}"
JAVA_LINK="${JAVA_BASE}/jdk${JAVA_MAJOR}"                 # stable JAVA_HOME
TAC_HOME="${TAC_HOME:-${TALEND_BASE}/tac}"
CATALINA_HOME="${TAC_HOME}/apache-tomcat-${TOMCAT_VERSION}"
TOMCAT_LINK="${TAC_HOME}/tomcat"                           # stable CATALINA_HOME
TAC_DIST_DIR="${TAC_HOME}/distrib"                         # unzipped TAC package

BINARY_PATH="${BINARY_PATH:-/opt/binary}"
BINARY_TAC="${BINARY_TAC:-Talend-AdministrationCenter-20260708_1430-V8.0.1.zip}"
TAC_ZIP="${TAC_ZIP:-${BINARY_PATH}/${BINARY_TAC}}"

SERVICE_NAME="${SERVICE_NAME:-talend-tac}"
TAC_HTTP_PORT="${TAC_HTTP_PORT:-8080}"
TAC_XMS="${TAC_XMS:-1g}"
TAC_XMX="${TAC_XMX:-4g}"

TOMCAT_URL="${TOMCAT_URL:-https://archive.apache.org/dist/tomcat/tomcat-11/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz}"

FORCE=false
START=true
INSTALL_JDBC=true
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=true ;;
    --no-start) START=false ;;
    --skip-jdbc) INSTALL_JDBC=false ;;
    -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "line ${LINENO}: ${BASH_COMMAND}"' ERR

WORK_DIR="$(mktemp -d /tmp/install_tac.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Write a marked block into a file (idempotent: the block is replaced on rerun)
set_block() {
  local file="$1" content="$2"
  local begin="# >>> talend java (install_tac.sh) >>>" end="# <<< talend java (install_tac.sh) <<<"
  touch "$file"
  sed -i "\|^${begin}\$|,\|^${end}\$|d" "$file"
  printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$file"
}

# ----------------------------------------------------------------------------
# 0. Pre-checks
# ----------------------------------------------------------------------------
log "Pre-checks"
[[ $EUID -eq 0 ]] || die "Run this script as root (docker exec -it vm_tac bash)."
[[ "$(cat /proc/1/comm)" == "systemd" ]] || die "systemd is not PID 1 in this container."
id "${TAC_USER}" >/dev/null 2>&1 || die "User ${TAC_USER} does not exist."
getent group "${TAC_GROUP}" >/dev/null || die "Group ${TAC_GROUP} does not exist."
[[ -f "${TAC_ZIP}" ]] || die "TAC package not found: ${TAC_ZIP} (check BINARY_HOST_PATH / BINARY_TAC in .env)."
for cmd in curl tar unzip sha256sum sha512sum systemctl; do
  command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done

case "$(dpkg --print-architecture)" in
  amd64) JDK_ARCH=x64 ;;
  arm64) JDK_ARCH=aarch64 ;;
  *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
esac
info "User/Group : ${TAC_USER}:${TAC_GROUP}"
info "TAC package: ${TAC_ZIP}"
info "Java       : ${JAVA_MAJOR} (${JDK_ARCH})   Tomcat: ${TOMCAT_VERSION}"

install -d -o "${TAC_USER}" -g "${TAC_GROUP}" -m 0755 "${TALEND_BASE}" "${JAVA_BASE}" "${TAC_HOME}"

# ----------------------------------------------------------------------------
# 1. Java 21 (Eclipse Temurin JDK)
# ----------------------------------------------------------------------------
log "1/5 Java ${JAVA_MAJOR}"
if [[ -x "${JAVA_LINK}/bin/java" && "${FORCE}" == false ]]; then
  info "Already installed: $("${JAVA_LINK}/bin/java" -version 2>&1 | sed -n 1p)"
else
  shopt -s nullglob
  local_jdk=( "${BINARY_PATH}"/OpenJDK${JAVA_MAJOR}U-jdk_${JDK_ARCH}_linux_hotspot_*.tar.gz )
  shopt -u nullglob
  if (( ${#local_jdk[@]} > 0 )); then
    JDK_TGZ="${local_jdk[-1]}"
    info "Using local archive ${JDK_TGZ}"
  else
    JDK_TGZ="${WORK_DIR}/jdk.tar.gz"
    api="https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/linux/${JDK_ARCH}/jdk/hotspot/normal/eclipse"
    info "Downloading latest Temurin ${JAVA_MAJOR} from Adoptium"
    # First redirect = GitHub release asset (its .sha256.txt sits next to it)
    real_url="$(curl -fsS -o /dev/null -w '%{redirect_url}' "${api}")"
    [[ -n "${real_url}" ]] || die "Cannot resolve the Temurin ${JAVA_MAJOR} download URL from ${api}"
    curl -fsSL -o "${JDK_TGZ}" "${real_url}"
    info "Downloaded ${real_url##*/}"
    expected="$(curl -fsSL "${real_url}.sha256.txt" | awk '{print $1}')"
    echo "${expected}  ${JDK_TGZ}" | sha256sum -c --status || die "JDK checksum mismatch."
    info "SHA-256 checksum OK"
  fi
  jdk_dir="$(tar -tzf "${JDK_TGZ}" | sed -n '1{s|/.*||;p}')"
  rm -rf "${JAVA_BASE:?}/${jdk_dir}"
  tar -xzf "${JDK_TGZ}" -C "${JAVA_BASE}"
  ln -sfn "${JAVA_BASE}/${jdk_dir}" "${JAVA_LINK}"
  chown -R "${TAC_USER}:${TAC_GROUP}" "${JAVA_BASE}"
  info "Installed: $("${JAVA_LINK}/bin/java" -version 2>&1 | sed -n 1p)"
fi

# ----------------------------------------------------------------------------
# 2. JAVA_HOME + PATH for user talend
#    ~/.profile  : login shells (su - talend, ssh, docker exec ... bash -l)
#    ~/.bashrc   : interactive non-login shells (docker exec -u talend ... bash)
#    Written after /etc/profile.d, so it overrides the image default (Java 17).
# ----------------------------------------------------------------------------
log "2/5 JAVA_HOME and PATH for ${TAC_USER}"
TAC_USER_HOME="$(getent passwd "${TAC_USER}" | cut -d: -f6)"
JAVA_ENV="export JAVA_HOME=${JAVA_LINK}
export CATALINA_HOME=${TOMCAT_LINK}
case \":\$PATH:\" in *\":\$JAVA_HOME/bin:\"*) ;; *) export PATH=\"\$JAVA_HOME/bin:\$PATH\" ;; esac"
for f in "${TAC_USER_HOME}/.profile" "${TAC_USER_HOME}/.bashrc"; do
  set_block "$f" "${JAVA_ENV}"
  chown "${TAC_USER}:${TAC_GROUP}" "$f"
done
info "$(su - "${TAC_USER}" -c 'echo "JAVA_HOME=$JAVA_HOME"; java -version 2>&1 | sed -n 1p')"

# ----------------------------------------------------------------------------
# 3. Apache Tomcat 11.0.29
# ----------------------------------------------------------------------------
log "3/5 Apache Tomcat ${TOMCAT_VERSION}"
if [[ -x "${CATALINA_HOME}/bin/catalina.sh" && "${FORCE}" == false ]]; then
  info "Already installed in ${CATALINA_HOME}"
else
  if [[ -f "${BINARY_PATH}/apache-tomcat-${TOMCAT_VERSION}.tar.gz" ]]; then
    TOMCAT_TGZ="${BINARY_PATH}/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
    info "Using local archive ${TOMCAT_TGZ}"
  else
    TOMCAT_TGZ="${WORK_DIR}/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
    info "Downloading ${TOMCAT_URL}"
    curl -fsSL -o "${TOMCAT_TGZ}" "${TOMCAT_URL}"
    expected="$(curl -fsSL "${TOMCAT_URL}.sha512" | awk '{print $1}')"
    echo "${expected}  ${TOMCAT_TGZ}" | sha512sum -c --status || die "Tomcat checksum mismatch."
    info "SHA-512 checksum OK"
  fi
  if systemctl is-active --quiet "${SERVICE_NAME}"; then systemctl stop "${SERVICE_NAME}"; fi
  rm -rf "${CATALINA_HOME}"
  tar -xzf "${TOMCAT_TGZ}" -C "${TAC_HOME}"
  ln -sfn "${CATALINA_HOME}" "${TOMCAT_LINK}"

  # Remove default web applications (security + TAC becomes the ROOT app)
  rm -rf "${CATALINA_HOME}"/webapps/{ROOT,docs,examples,manager,host-manager}
  info "Installed in ${CATALINA_HOME} (symlink ${TOMCAT_LINK})"
fi

# HTTP port of the HTTP/1.1 connector
sed -i -E "s|<Connector port=\"[0-9]+\" protocol=\"HTTP/1.1\"|<Connector port=\"${TAC_HTTP_PORT}\" protocol=\"HTTP/1.1\"|" \
  "${CATALINA_HOME}/conf/server.xml"

# setenv.sh: JVM settings used by catalina.sh (and therefore by systemd)
cat > "${CATALINA_HOME}/bin/setenv.sh" <<EOF
#!/bin/sh
# Generated by install_tac.sh - JVM settings for Talend Administration Center
JAVA_HOME="${JAVA_LINK}"
CATALINA_PID="\${CATALINA_BASE}/temp/tomcat.pid"
CATALINA_OPTS="\${CATALINA_OPTS} -Xms${TAC_XMS} -Xmx${TAC_XMX}"
CATALINA_OPTS="\${CATALINA_OPTS} -Dfile.encoding=UTF-8 -Djava.awt.headless=true"
CATALINA_OPTS="\${CATALINA_OPTS} -Djava.security.egd=file:/dev/./urandom"
export JAVA_HOME CATALINA_PID CATALINA_OPTS
EOF
chmod 0750 "${CATALINA_HOME}/bin/setenv.sh"
info "Port ${TAC_HTTP_PORT}, heap ${TAC_XMS}/${TAC_XMX} (bin/setenv.sh)"

# ----------------------------------------------------------------------------
# 4. Deploy Talend Administration Center as the ROOT application
# ----------------------------------------------------------------------------
log "4/5 Deploy Talend Administration Center as ROOT"
rm -rf "${TAC_DIST_DIR}"
install -d "${TAC_DIST_DIR}"
unzip -q "${TAC_ZIP}" -d "${TAC_DIST_DIR}"
mapfile -t wars < <(find "${TAC_DIST_DIR}" -type f -iname 'org.talend.administrator*.war')
(( ${#wars[@]} == 0 )) && mapfile -t wars < <(find "${TAC_DIST_DIR}" -type f -iname '*.war')
(( ${#wars[@]} == 1 )) || die "Expected exactly one TAC war in ${TAC_ZIP}, found ${#wars[@]}: ${wars[*]:-none}"
info "War file: ${wars[0]#${TAC_DIST_DIR}/}"

if systemctl is-active --quiet "${SERVICE_NAME}"; then systemctl stop "${SERVICE_NAME}"; fi
rm -rf "${CATALINA_HOME}/webapps/ROOT" "${CATALINA_HOME}/webapps/ROOT.war" \
       "${CATALINA_HOME}/work/Catalina/localhost/ROOT"
# Exploded deployment: lets you edit WEB-INF/classes/configuration.properties
install -d "${CATALINA_HOME}/webapps/ROOT"
unzip -q "${wars[0]}" -d "${CATALINA_HOME}/webapps/ROOT"
chown -R "${TAC_USER}:${TAC_GROUP}" "${TAC_HOME}"
info "Deployed to ${CATALINA_HOME}/webapps/ROOT"

# PostgreSQL JDBC driver: the redeploy above recreated WEB-INF/lib, so it is
# installed again each time (from the persisted copy in ${TAC_HOME}/drivers).
if [[ "${INSTALL_JDBC}" == true ]]; then
  TAC_USER="${TAC_USER}" TAC_GROUP="${TAC_GROUP}" TAC_HOME="${TAC_HOME}" \
  TOMCAT_LINK="${TOMCAT_LINK}" WEBAPP_DIR="${CATALINA_HOME}/webapps/ROOT" \
  BINARY_PATH="${BINARY_PATH}" SERVICE_NAME="${SERVICE_NAME}" \
    bash "$(dirname "$(readlink -f "$0")")/install_jdbc_postgresql.sh" --no-restart
fi

# ----------------------------------------------------------------------------
# 5. systemd service
# ----------------------------------------------------------------------------
log "5/5 systemd service ${SERVICE_NAME}.service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Talend Administration Center (Apache Tomcat ${TOMCAT_VERSION})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TAC_USER}
Group=${TAC_GROUP}
UMask=0027
Environment=JAVA_HOME=${JAVA_LINK}
Environment=CATALINA_HOME=${TOMCAT_LINK}
Environment=CATALINA_BASE=${TOMCAT_LINK}
WorkingDirectory=${TOMCAT_LINK}
ExecStart=${TOMCAT_LINK}/bin/catalina.sh run
# The JVM exits with 143 on SIGTERM: this is a clean stop
SuccessExitStatus=143
TimeoutStartSec=300
TimeoutStopSec=120
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

if [[ "${START}" == true ]]; then
  systemctl restart "${SERVICE_NAME}.service"
  info "Waiting for Tomcat on port ${TAC_HTTP_PORT}..."
  for _ in $(seq 1 60); do
    if curl -s -o /dev/null "http://localhost:${TAC_HTTP_PORT}/"; then break; fi
    sleep 5
  done
  systemctl --no-pager --lines=0 status "${SERVICE_NAME}" || true
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${TAC_HTTP_PORT}/" || true)"
  info "HTTP status on http://localhost:${TAC_HTTP_PORT}/ : ${code}"
fi

log "Done"
cat <<EOF
    Java        : ${JAVA_LINK} -> $(readlink -f "${JAVA_LINK}")
    Tomcat      : ${TOMCAT_LINK} -> ${CATALINA_HOME}
    TAC (ROOT)  : ${CATALINA_HOME}/webapps/ROOT
    TAC config  : ${CATALINA_HOME}/webapps/ROOT/WEB-INF/classes/configuration.properties
    Logs        : ${CATALINA_HOME}/logs   |  journalctl -u ${SERVICE_NAME} -f
    Service     : systemctl {status|stop|start|restart} ${SERVICE_NAME}
    URL         : http://localhost:\${HOST_PORT_TAC_HTTP:-8080}/  (from the docker host)

    Next: open the URL, configure the database connection to vm_db
          (jdbc:postgresql://vm-db:5432/<tac_db>) with the TAC configuration page.
EOF
