#!/usr/bin/env bash
# =============================================================================
#  install_jobserver.sh - Manual installation of Talend JobServer
#                         on the vm_jobserver container (Debian 13, systemd).
#
#  Steps:
#    1. Install Java 21 (Eclipse Temurin)   -> /opt/talend/java/jdk-21...
#    2. JAVA_HOME + PATH for user talend    -> ~talend/.profile and ~/.bashrc
#    3. Unzip the JobServer package         -> /opt/talend/jobserver/Talend-JobServer-...
#                                              symlink /opt/talend/jobserver/current
#    4. Configure TalendJobServer.properties (ports, only keys that exist)
#    5. systemd service (User/Group=talend) -> /etc/systemd/system/talend-jobserver.service
#    6. Checks (service, ports 8000/8001/8888)
#
#  Everything is installed under /opt/talend (volume jobserver_app) and
#  /etc/systemd/system (volume jobserver_systemd): the installation survives
#  "docker compose down / up".
#
#  Usage (inside vm_jobserver, as root):
#     docker exec -it vm_jobserver bash /opt/scripts/vm_jobserver/install_jobserver.sh
#     ... --no-start   install and enable the service without starting it
#     ... --force      reinstall Java and the JobServer (the previous JobServer
#                      folder is kept as <folder>.bak-<date>)
#
#  Offline mode: put the JDK archive in the binaries folder (/opt/binary):
#     OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz
#
#  All variables below can be overridden from the environment, e.g.
#     JS_XMX=4g bash /opt/scripts/vm_jobserver/install_jobserver.sh
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
JAVA_MAJOR="${JAVA_MAJOR:-21}"

JS_USER="${JS_USER:-talend}"
JS_GROUP="${JS_GROUP:-talend}"

TALEND_BASE="${TALEND_BASE:-/opt/talend}"
JAVA_BASE="${JAVA_BASE:-${TALEND_BASE}/java}"
JAVA_LINK="${JAVA_BASE}/jdk${JAVA_MAJOR}"                  # stable JAVA_HOME
JS_BASE="${JOBSERVER_HOME:-${TALEND_BASE}/jobserver}"
JS_LINK="${JS_BASE}/current"                                # stable JobServer home

BINARY_PATH="${BINARY_PATH:-/opt/binary}"
BINARY_JOBSERVER="${BINARY_JOBSERVER:-Talend-JobServer-20260708_1430-V8.0.1.zip}"
JS_ZIP="${JS_ZIP:-${BINARY_PATH}/${BINARY_JOBSERVER}}"

SERVICE_NAME="${SERVICE_NAME:-talend-jobserver}"
JS_COMMAND_PORT="${JS_COMMAND_PORT:-8000}"
JS_FILE_PORT="${JS_FILE_PORT:-8001}"
JS_MONITORING_PORT="${JS_MONITORING_PORT:-8888}"
JS_PROCESS_MESSAGE_PORT="${JS_PROCESS_MESSAGE_PORT:-8555}"

FORCE=false
START=true
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=true ;;
    --no-start) START=false ;;
    -h|--help)  sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[1;33mWARNING: %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "line ${LINENO}: ${BASH_COMMAND}"' ERR

WORK_DIR="$(mktemp -d /tmp/install_jobserver.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Marked block in a shell profile (replaced on rerun, never duplicated)
set_block() {
  local file="$1" content="$2"
  local begin="# >>> talend java (install_jobserver.sh) >>>" end="# <<< talend java (install_jobserver.sh) <<<"
  touch "$file"
  sed -i "\|^${begin}\$|,\|^${end}\$|d" "$file"
  printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$file"
}

# True if something listens on the TCP port (no "| grep -q": see pipefail)
listening() { [[ -n "$(ss -Hltn "sport = :$1")" ]]; }

# Set key=value in a .properties file, only if the key exists (active or
# commented out). Unknown keys are reported, never added blindly.
set_prop() {
  local file="$1" key="$2" value="$3" k
  k="$(printf '%s' "$key" | sed 's/[.[\*^$/]/\\&/g')"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=.*|${key}=${value}|" "$file"
    info "${key}=${value}"
  else
    warn "${key} not found in $(basename "$file"): left unchanged"
  fi
}

# ----------------------------------------------------------------------------
# 0. Pre-checks
# ----------------------------------------------------------------------------
log "Pre-checks"
[[ $EUID -eq 0 ]] || die "Run this script as root (docker exec -it vm_jobserver bash)."
[[ "$(cat /proc/1/comm)" == "systemd" ]] || die "systemd is not PID 1 in this container."
id "${JS_USER}" >/dev/null 2>&1 || die "User ${JS_USER} does not exist."
getent group "${JS_GROUP}" >/dev/null || die "Group ${JS_GROUP} does not exist."
[[ -f "${JS_ZIP}" ]] || die "JobServer package not found: ${JS_ZIP} (check BINARY_HOST_PATH / BINARY_JOBSERVER in .env)."
for cmd in curl tar unzip sha256sum systemctl ss; do
  command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
case "$(dpkg --print-architecture)" in
  amd64) JDK_ARCH=x64 ;;
  arm64) JDK_ARCH=aarch64 ;;
  *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
esac
info "User/Group : ${JS_USER}:${JS_GROUP}"
info "Package    : ${JS_ZIP}"
info "Java       : ${JAVA_MAJOR} (${JDK_ARCH})"

install -d -o "${JS_USER}" -g "${JS_GROUP}" -m 0755 "${TALEND_BASE}" "${JAVA_BASE}" "${JS_BASE}"

# ----------------------------------------------------------------------------
# 1. Java 21 (Eclipse Temurin JDK) - in the persisted volume, not in /usr
# ----------------------------------------------------------------------------
log "1/6 Java ${JAVA_MAJOR}"
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
    real_url="$(curl -fsS -o /dev/null -w '%{redirect_url}' "${api}")"
    [[ -n "${real_url}" ]] || die "Cannot resolve the Temurin ${JAVA_MAJOR} download URL from ${api}"
    info "Downloading ${real_url##*/}"
    curl -fsSL -o "${JDK_TGZ}" "${real_url}"
    expected="$(curl -fsSL "${real_url}.sha256.txt" | awk '{print $1}')"
    echo "${expected}  ${JDK_TGZ}" | sha256sum -c --status || die "JDK checksum mismatch."
    info "SHA-256 checksum OK"
  fi
  jdk_dir="$(tar -tzf "${JDK_TGZ}" | sed -n '1{s|/.*||;p}')"
  rm -rf "${JAVA_BASE:?}/${jdk_dir}"
  tar -xzf "${JDK_TGZ}" -C "${JAVA_BASE}"
  ln -sfn "${JAVA_BASE}/${jdk_dir}" "${JAVA_LINK}"
  chown -R "${JS_USER}:${JS_GROUP}" "${JAVA_BASE}"
  info "Installed: $("${JAVA_LINK}/bin/java" -version 2>&1 | sed -n 1p)"
fi
# Default Java of the container, used by /etc/profile.d/zz-talend-java.sh (image):
# keeps JAVA_HOME after a container recreate, when the home folder is reset.
ln -sfn "${JAVA_LINK}" "${JAVA_BASE}/default"
chown -h "${JS_USER}:${JS_GROUP}" "${JAVA_BASE}/default"

# ----------------------------------------------------------------------------
# 2. JAVA_HOME + PATH for user talend
# ----------------------------------------------------------------------------
log "2/6 JAVA_HOME and PATH for ${JS_USER}"
JS_USER_HOME="$(getent passwd "${JS_USER}" | cut -d: -f6)"
JAVA_ENV="export JAVA_HOME=${JAVA_LINK}
export JOBSERVER_HOME=${JS_LINK}
case \":\$PATH:\" in *\":\$JAVA_HOME/bin:\"*) ;; *) export PATH=\"\$JAVA_HOME/bin:\$PATH\" ;; esac"
for f in "${JS_USER_HOME}/.profile" "${JS_USER_HOME}/.bashrc"; do
  set_block "$f" "${JAVA_ENV}"
  chown "${JS_USER}:${JS_GROUP}" "$f"
done
info "$(su - "${JS_USER}" -c 'echo "JAVA_HOME=$JAVA_HOME"; java -version 2>&1 | sed -n 1p' | tr '\n' ' ')"

# ----------------------------------------------------------------------------
# 3. Unzip the JobServer package
# ----------------------------------------------------------------------------
log "3/6 Talend JobServer package"
if [[ -L "${JS_LINK}" && -d "$(readlink -f "${JS_LINK}")" && "${FORCE}" == false ]]; then
  info "Already installed in $(readlink -f "${JS_LINK}") (use --force to reinstall)"
else
  if systemctl is-active --quiet "${SERVICE_NAME}"; then systemctl stop "${SERVICE_NAME}"; fi
  unzip -q "${JS_ZIP}" -d "${WORK_DIR}/pkg"
  # The zip normally holds one top folder (Talend-JobServer-<version>)
  mapfile -t tops < <(find "${WORK_DIR}/pkg" -mindepth 1 -maxdepth 1)
  if (( ${#tops[@]} == 1 )) && [[ -d "${tops[0]}" ]]; then
    js_name="$(basename "${tops[0]}")"; src="${tops[0]}"
  else
    js_name="$(basename "${JS_ZIP}" .zip)"; src="${WORK_DIR}/pkg"
  fi
  target="${JS_BASE}/${js_name}"
  if [[ -e "${target}" ]]; then
    backup="${target}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "${target}" "${backup}"
    info "Previous installation kept in ${backup}"
  fi
  mv "${src}" "${target}"
  ln -sfn "${target}" "${JS_LINK}"
  info "Installed in ${target} (symlink ${JS_LINK})"
fi
JS_HOME_REAL="$(readlink -f "${JS_LINK}")"

# Locate the start/stop scripts and the configuration (layout may vary by version)
START_SH="$(find "${JS_HOME_REAL}" -maxdepth 3 -type f -name 'start_rs.sh' | sort | sed -n 1p)"
STOP_SH="$(find "${JS_HOME_REAL}" -maxdepth 3 -type f -name 'stop_rs.sh' | sort | sed -n 1p)"
PROPS="$(find "${JS_HOME_REAL}" -maxdepth 4 -type f -name 'TalendJobServer.properties' | sort | sed -n 1p)"
[[ -n "${START_SH}" ]] || die "start_rs.sh not found in ${JS_HOME_REAL}."
[[ -n "${PROPS}" ]]    || die "TalendJobServer.properties not found in ${JS_HOME_REAL}."
# Paths through the stable symlink, so a reinstall only moves the symlink
START_SH="${JS_LINK}/${START_SH#${JS_HOME_REAL}/}"
if [[ -n "${STOP_SH}" ]]; then STOP_SH="${JS_LINK}/${STOP_SH#${JS_HOME_REAL}/}"; fi
PROPS="${JS_LINK}/${PROPS#${JS_HOME_REAL}/}"
info "Start script : ${START_SH}"
info "Stop script  : ${STOP_SH:-<none>}"
info "Properties   : ${PROPS}"

# Unix permissions are not always kept in zip files
find "${JS_HOME_REAL}" -type f -name '*.sh' -exec chmod 0755 {} +
chown -R "${JS_USER}:${JS_GROUP}" "${JS_BASE}"

# ----------------------------------------------------------------------------
# 4. TalendJobServer.properties
# ----------------------------------------------------------------------------
log "4/6 Configure $(basename "${PROPS}")"
[[ -f "${PROPS}.orig" ]] || cp -p "${PROPS}" "${PROPS}.orig"
info "Original kept as ${PROPS}.orig"
P=org.talend.remote.jobserver.server.TalendJobServer
set_prop "${PROPS}" "${P}.COMMAND_SERVER_PORT"   "${JS_COMMAND_PORT}"
set_prop "${PROPS}" "${P}.FILE_SERVER_PORT"      "${JS_FILE_PORT}"
set_prop "${PROPS}" "${P}.MONITORING_PORT"       "${JS_MONITORING_PORT}"
set_prop "${PROPS}" "${P}.PROCESS_MESSAGE_PORT"  "${JS_PROCESS_MESSAGE_PORT}"
chown "${JS_USER}:${JS_GROUP}" "${PROPS}"

# ----------------------------------------------------------------------------
# 5. systemd service
#    start_rs.sh normally runs the JobServer in the foreground: Type=simple,
#    systemd watches the process directly. If the script starts Java in the
#    background (nohup ... &) and exits, Type=forking is used instead, otherwise
#    systemd would consider the service finished and kill the JobServer.
# ----------------------------------------------------------------------------
log "5/6 systemd service ${SERVICE_NAME}.service"
SERVICE_TYPE=simple
if grep -vE '^[[:space:]]*#' "${START_SH}" | grep -E 'nohup|[^&]&[[:space:]]*$' >/dev/null; then
  SERVICE_TYPE=forking
  warn "start_rs.sh starts the JobServer in the background: using Type=forking"
fi
info "Type=${SERVICE_TYPE}"
STOP_LINE="# no stop_rs.sh found: systemd stops the JobServer with SIGTERM"
if [[ -n "${STOP_SH}" ]]; then STOP_LINE="ExecStop=${STOP_SH}"; fi
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Talend JobServer
After=network-online.target
Wants=network-online.target

[Service]
Type=${SERVICE_TYPE}
User=${JS_USER}
Group=${JS_GROUP}
UMask=0027
Environment=JAVA_HOME=${JAVA_LINK}
Environment=PATH=${JAVA_LINK}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$(dirname "${START_SH}")
ExecStart=${START_SH}
${STOP_LINE}
# The JVM exits with 143 on SIGTERM: this is a clean stop
SuccessExitStatus=143
TimeoutStartSec=120
TimeoutStopSec=60
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

# ----------------------------------------------------------------------------
# 6. Start and check
# ----------------------------------------------------------------------------
log "6/6 Start and checks"
if [[ "${START}" == true ]]; then
  systemctl restart "${SERVICE_NAME}.service"
  info "Waiting for the command port ${JS_COMMAND_PORT}..."
  for _ in $(seq 1 30); do
    listening "${JS_COMMAND_PORT}" && break
    systemctl is-active --quiet "${SERVICE_NAME}" || break
    sleep 2
  done
  systemctl --no-pager --lines=5 status "${SERVICE_NAME}" || true
  for port in "${JS_COMMAND_PORT}" "${JS_FILE_PORT}" "${JS_MONITORING_PORT}"; do
    if listening "${port}"; then info "port ${port}: listening"
    else warn "port ${port}: not listening (yet). Check: journalctl -u ${SERVICE_NAME}"; fi
  done
else
  info "Service enabled, not started (--no-start)"
fi

log "Done"
cat <<EOF
    Java        : ${JAVA_LINK} -> $(readlink -f "${JAVA_LINK}")
    JobServer   : ${JS_LINK} -> ${JS_HOME_REAL}
    Properties  : ${PROPS}
    Service     : systemctl {status|stop|start|restart} ${SERVICE_NAME}
    Logs        : journalctl -u ${SERVICE_NAME} -f

    Register it in TAC (Servers > Add):
      Host name       : vm-jobserver
      Command port    : ${JS_COMMAND_PORT}
      File transfer   : ${JS_FILE_PORT}
      Monitoring port : ${JS_MONITORING_PORT}
EOF
