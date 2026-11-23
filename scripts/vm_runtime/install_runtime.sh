#!/usr/bin/env bash
# =============================================================================
#  install_runtime.sh - Manual installation of Talend Runtime (Apache Karaf)
#                       on the vm_runtime container (Debian 13, systemd).
#
#  Steps:
#    1. Install Java 21 (Eclipse Temurin)  -> /opt/talend/java/jdk-21...
#    2. JAVA_HOME + PATH for user talend   -> ~talend/.profile and ~/.bashrc
#    3. Unzip the Runtime package          -> /opt/talend/runtime/Talend-Runtime-...
#                                             symlink /opt/talend/runtime/current
#    4. Configure Karaf (etc/*.cfg: HTTP, SSH, JMX ports and listen addresses,
#       bin/setenv: Java and memory) - only keys that exist, originals kept
#    5. Admin password (etc/users.properties)
#    6. systemd service (User/Group=talend) -> /etc/systemd/system/talend-runtime.service
#    7. Checks (service, ports)
#
#  Everything is installed under /opt/talend (volume runtime_app) and
#  /etc/systemd/system (volume runtime_systemd): it survives "docker compose down / up".
#
#  Usage (inside vm_runtime, as root):
#     docker exec -it vm_runtime bash /opt/scripts/vm_runtime/install_runtime.sh
#     ... --no-start   install and enable the service without starting it
#     ... --force      reinstall Java and the Runtime (the previous Runtime folder
#                      is kept as <folder>.bak-<date>)
#  Admin password: asked interactively (empty = keep the current one), or
#     docker exec -it -e RT_ADMIN_PASSWORD='...' vm_runtime bash /opt/scripts/vm_runtime/install_runtime.sh
#
#  Offline: put OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz in /opt/binary.
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
JAVA_MAJOR="${JAVA_MAJOR:-21}"

RT_USER="${RT_USER:-talend}"
RT_GROUP="${RT_GROUP:-talend}"

TALEND_BASE="${TALEND_BASE:-/opt/talend}"
JAVA_BASE="${JAVA_BASE:-${TALEND_BASE}/java}"
JAVA_LINK="${JAVA_BASE}/jdk${JAVA_MAJOR}"                  # stable JAVA_HOME
RT_BASE="${RUNTIME_HOME:-${TALEND_BASE}/runtime}"
RT_LINK="${RT_BASE}/current"                                # stable KARAF_HOME

BINARY_PATH="${BINARY_PATH:-/opt/binary}"
BINARY_RUNTIME="${BINARY_RUNTIME:-Talend-Runtime-V8.0.2.R2026-06-RT.zip}"
RT_ZIP="${RT_ZIP:-${BINARY_PATH}/${BINARY_RUNTIME}}"

SERVICE_NAME="${SERVICE_NAME:-talend-runtime}"
RT_HTTP_PORT="${RT_HTTP_PORT:-8040}"
RT_HTTPS_PORT="${RT_HTTPS_PORT:-9001}"
RT_SSH_PORT="${RT_SSH_PORT:-8101}"
RT_RMI_REGISTRY_PORT="${RT_RMI_REGISTRY_PORT:-1099}"
RT_RMI_SERVER_PORT="${RT_RMI_SERVER_PORT:-44444}"
RT_LISTEN_HOST="${RT_LISTEN_HOST:-0.0.0.0}"     # SSH and JMX: reachable from other containers / the host
RT_XMS="${RT_XMS:-512M}"
RT_XMX="${RT_XMX:-2048M}"
RT_ADMIN_USER="${RT_ADMIN_USER:-tadmin}"
RT_ADMIN_PASSWORD="${RT_ADMIN_PASSWORD:-}"

FORCE=false
START=true
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=true ;;
    --no-start) START=false ;;
    -h|--help)  sed -n '2,29p' "$0"; exit 0 ;;
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

WORK_DIR="$(mktemp -d /tmp/install_runtime.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Marked block in a file (replaced on rerun, never duplicated)
set_block() {
  local file="$1" content="$2" tag="${3:-talend java (install_runtime.sh)}"
  local begin="# >>> ${tag} >>>" end="# <<< ${tag} <<<"
  touch "$file"
  # Repair: a marker glued to the end of the previous line (file that had no
  # final newline, e.g. 'fi# >>> ...') is moved back to its own line
  sed -i "s|^\(.*[^[:space:]]\)[[:space:]]*\(${begin}\)\$|\1\n\2|" "$file"
  sed -i "\|^${begin}\$|,\|^${end}\$|d" "$file"
  # The file must end with a newline, or the block would be glued to its last line
  if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then printf '\n' >> "$file"; fi
  printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$file"
}

# True if something listens on the TCP port (no "| grep -q": see pipefail)
listening() { [[ -n "$(ss -Hltn "sport = :$1")" ]]; }

# key = value in a Karaf .cfg / .properties file, only if the key exists
# (active or commented out). Missing keys are reported, never added blindly.
set_cfg() {
  local file="$1" key="$2" value="$3" k
  if [[ ! -f "$file" ]]; then warn "$(basename "$file") not found: ${key} left unchanged"; return 0; fi
  k="$(printf '%s' "$key" | sed 's/[.[\*^$/]/\\&/g')"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=.*|${key} = ${value}|" "$file"
    info "$(basename "$file"): ${key} = ${value}"
  else
    warn "${key} not found in $(basename "$file"): left unchanged"
  fi
}

# Keep the original of a file once (to compare or roll back)
keep_orig() { [[ -f "$1" && ! -f "$1.orig" ]] && cp -p "$1" "$1.orig"; return 0; }

# ----------------------------------------------------------------------------
# 0. Pre-checks
# ----------------------------------------------------------------------------
log "Pre-checks"
[[ $EUID -eq 0 ]] || die "Run this script as root (docker exec -it vm_runtime bash)."
[[ "$(cat /proc/1/comm)" == "systemd" ]] || die "systemd is not PID 1 in this container."
id "${RT_USER}" >/dev/null 2>&1 || die "User ${RT_USER} does not exist."
getent group "${RT_GROUP}" >/dev/null || die "Group ${RT_GROUP} does not exist."
[[ -f "${RT_ZIP}" ]] || die "Runtime package not found: ${RT_ZIP} (check BINARY_HOST_PATH / BINARY_RUNTIME in .env)."
for cmd in curl tar unzip sha256sum systemctl ss; do
  command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
case "$(dpkg --print-architecture)" in
  amd64) JDK_ARCH=x64 ;;
  arm64) JDK_ARCH=aarch64 ;;
  *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
esac
if [[ -n "${RT_ADMIN_PASSWORD}" && "${RT_ADMIN_PASSWORD}" =~ [,\\[:space:]] ]]; then
  die "RT_ADMIN_PASSWORD must not contain spaces, ',' or '\\' (users.properties format)."
fi
info "User/Group : ${RT_USER}:${RT_GROUP}"
info "Package    : ${RT_ZIP}"
info "Java       : ${JAVA_MAJOR} (${JDK_ARCH})"

install -d -o "${RT_USER}" -g "${RT_GROUP}" -m 0755 "${TALEND_BASE}" "${JAVA_BASE}" "${RT_BASE}"

# ----------------------------------------------------------------------------
# 1. Java 21 (Eclipse Temurin JDK) - in the persisted volume, not in /usr
# ----------------------------------------------------------------------------
log "1/7 Java ${JAVA_MAJOR}"
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
  chown -R "${RT_USER}:${RT_GROUP}" "${JAVA_BASE}"
  info "Installed: $("${JAVA_LINK}/bin/java" -version 2>&1 | sed -n 1p)"
fi
# Default Java of the container, used by /etc/profile.d/zz-talend-java.sh (image):
# keeps JAVA_HOME after a container recreate, when the home folder is reset.
ln -sfn "${JAVA_LINK}" "${JAVA_BASE}/default"
chown -h "${RT_USER}:${RT_GROUP}" "${JAVA_BASE}/default"

# ----------------------------------------------------------------------------
# 2. JAVA_HOME + PATH for user talend
# ----------------------------------------------------------------------------
log "2/7 JAVA_HOME and PATH for ${RT_USER}"
RT_USER_HOME="$(getent passwd "${RT_USER}" | cut -d: -f6)"
JAVA_ENV="export JAVA_HOME=${JAVA_LINK}
case \":\$PATH:\" in *\":\$JAVA_HOME/bin:\"*) ;; *) export PATH=\"\$JAVA_HOME/bin:\$PATH\" ;; esac"
for f in "${RT_USER_HOME}/.profile" "${RT_USER_HOME}/.bashrc"; do
  set_block "$f" "${JAVA_ENV}"
  chown "${RT_USER}:${RT_GROUP}" "$f"
done
info "$(su - "${RT_USER}" -c 'echo "JAVA_HOME=$JAVA_HOME"; java -version 2>&1 | sed -n 1p' | tr '\n' ' ')"

# ----------------------------------------------------------------------------
# 3. Unzip the Runtime package
# ----------------------------------------------------------------------------
log "3/7 Talend Runtime package"
if [[ -L "${RT_LINK}" && -d "$(readlink -f "${RT_LINK}")" && "${FORCE}" == false ]]; then
  info "Already installed in $(readlink -f "${RT_LINK}") (use --force to reinstall)"
else
  if systemctl is-active --quiet "${SERVICE_NAME}"; then systemctl stop "${SERVICE_NAME}"; fi
  unzip -q "${RT_ZIP}" -d "${WORK_DIR}/pkg"
  # Karaf home = the folder holding bin/trun (or bin/karaf), wherever it is in the zip
  launcher="$(find "${WORK_DIR}/pkg" -maxdepth 4 -type f -path '*/bin/trun' | sort | sed -n 1p)"
  [[ -n "${launcher}" ]] || launcher="$(find "${WORK_DIR}/pkg" -maxdepth 4 -type f -path '*/bin/karaf' | sort | sed -n 1p)"
  [[ -n "${launcher}" ]] || die "bin/trun (or bin/karaf) not found in ${RT_ZIP}."
  src="$(dirname "$(dirname "${launcher}")")"
  if [[ "${src}" == "${WORK_DIR}/pkg" ]]; then rt_name="$(basename "${RT_ZIP}" .zip)"
  else rt_name="$(basename "${src}")"; fi
  target="${RT_BASE}/${rt_name}"
  if [[ -e "${target}" ]]; then
    backup="${target}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "${target}" "${backup}"
    info "Previous installation kept in ${backup}"
  fi
  mv "${src}" "${target}"
  ln -sfn "${target}" "${RT_LINK}"
  info "Installed in ${target} (symlink ${RT_LINK})"
fi
RT_HOME_REAL="$(readlink -f "${RT_LINK}")"
if [[ -x "${RT_HOME_REAL}/bin/trun" || -f "${RT_HOME_REAL}/bin/trun" ]]; then LAUNCHER=trun; else LAUNCHER=karaf; fi
[[ -f "${RT_HOME_REAL}/bin/${LAUNCHER}" ]] || die "${RT_HOME_REAL}/bin/${LAUNCHER} not found."
[[ -d "${RT_HOME_REAL}/etc" ]] || die "${RT_HOME_REAL}/etc not found: not a Karaf/Talend Runtime folder?"
info "Karaf home : ${RT_LINK} -> ${RT_HOME_REAL}"
info "Launcher   : bin/${LAUNCHER}"

# Unix permissions are not always kept in zip files: make bin/ executable
find "${RT_HOME_REAL}/bin" -maxdepth 1 -type f ! -name '*.bat' -exec chmod 0755 {} +
# Windows line endings (CRLF) break shell scripts: convert them
while IFS= read -r -d '' f; do
  if grep -q $'\r' "$f"; then sed -i 's/\r$//' "$f"; info "Converted CRLF to LF: bin/$(basename "$f")"; fi
done < <(find "${RT_HOME_REAL}/bin" -maxdepth 1 -type f ! -name '*.bat' -print0)
chown -R "${RT_USER}:${RT_GROUP}" "${RT_BASE}"

# ----------------------------------------------------------------------------
# 4. Karaf configuration
# ----------------------------------------------------------------------------
log "4/7 Configure Talend Runtime"
ETC="${RT_HOME_REAL}/etc"
for f in org.ops4j.pax.web.cfg org.apache.karaf.shell.cfg org.apache.karaf.management.cfg users.properties; do
  keep_orig "${ETC}/$f"
done
keep_orig "${RT_HOME_REAL}/bin/setenv"
info "Originals kept as *.orig"

# HTTP / HTTPS (Pax Web = the embedded Jetty serving REST/SOAP services)
set_cfg "${ETC}/org.ops4j.pax.web.cfg" org.osgi.service.http.port        "${RT_HTTP_PORT}"
set_cfg "${ETC}/org.ops4j.pax.web.cfg" org.osgi.service.http.port.secure "${RT_HTTPS_PORT}"
# SSH console (Karaf shell)
set_cfg "${ETC}/org.apache.karaf.shell.cfg" sshPort "${RT_SSH_PORT}"
set_cfg "${ETC}/org.apache.karaf.shell.cfg" sshHost "${RT_LISTEN_HOST}"
# JMX (Karaf defaults to 127.0.0.1: only reachable from inside the container)
set_cfg "${ETC}/org.apache.karaf.management.cfg" rmiRegistryPort "${RT_RMI_REGISTRY_PORT}"
set_cfg "${ETC}/org.apache.karaf.management.cfg" rmiServerPort   "${RT_RMI_SERVER_PORT}"
set_cfg "${ETC}/org.apache.karaf.management.cfg" rmiRegistryHost "${RT_LISTEN_HOST}"
set_cfg "${ETC}/org.apache.karaf.management.cfg" rmiServerHost   "${RT_LISTEN_HOST}"

# bin/setenv is read by bin/trun, bin/start, bin/client...: Java and memory for
# every way of starting the Runtime (service or shell). Appended block = wins.
if [[ -f "${RT_HOME_REAL}/bin/setenv" ]]; then
  # Karaf 4.4 Unix scripts ignore JAVA_MIN_MEM/JAVA_MAX_MEM: the heap goes in
  # EXTRA_JAVA_OPTS (added last to the java command line, so it wins). Both are set.
  set_block "${RT_HOME_REAL}/bin/setenv" "export JAVA_HOME=${JAVA_LINK}
export JAVA_MIN_MEM=${RT_XMS}
export JAVA_MAX_MEM=${RT_XMX}
export EXTRA_JAVA_OPTS=\"\${EXTRA_JAVA_OPTS} -Xms${RT_XMS} -Xmx${RT_XMX}\"" "talend (install_runtime.sh)"
  info "bin/setenv: JAVA_HOME=${JAVA_LINK}, heap -Xms${RT_XMS} -Xmx${RT_XMX} (EXTRA_JAVA_OPTS)"
  # bin/trun sources setenv with /bin/sh: a syntax error there stops the Runtime
  # immediately (exit status 2). Check it now rather than at service start.
  if ! sh_err="$(sh -n "${RT_HOME_REAL}/bin/setenv" 2>&1)"; then
    cp -p "${RT_HOME_REAL}/bin/setenv.orig" "${RT_HOME_REAL}/bin/setenv"
    die "bin/setenv has a syntax error after editing (${sh_err}). The original was restored."
  fi
  info "bin/setenv: syntax OK (sh -n)"
else
  warn "bin/setenv not found: Java and memory are only set in the systemd unit"
fi

# ----------------------------------------------------------------------------
# 5. Admin password (etc/users.properties: "user = password,roles...")
# ----------------------------------------------------------------------------
log "5/7 Admin user ${RT_ADMIN_USER}"
USERS="${ETC}/users.properties"
if [[ ! -f "${USERS}" ]]; then
  warn "users.properties not found: password not changed"
elif ! grep -qE "^[[:space:]]*${RT_ADMIN_USER}[[:space:]]*=" "${USERS}"; then
  warn "User ${RT_ADMIN_USER} not found in users.properties: password not changed"
  info "Users defined: $( { grep -E '^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=' "${USERS}" || true; } | { grep -v '^_g_' || true; } | cut -d= -f1 | tr -d ' ' | tr '\n' ' ')"
else
  if [[ -z "${RT_ADMIN_PASSWORD}" && -t 0 ]]; then
    while :; do
      read -r -s -p "    New password for ${RT_ADMIN_USER} (empty = keep the current one): " p1; echo
      [[ -z "$p1" ]] && break
      read -r -s -p "    Confirm password: " p2; echo
      if [[ "$p1" != "$p2" ]]; then info "Different passwords, try again."; continue; fi
      if [[ "$p1" =~ [,\\[:space:]] ]]; then info "No spaces, ',' or '\\' allowed, try again."; continue; fi
      RT_ADMIN_PASSWORD="$p1"; break
    done
  fi
  if [[ -n "${RT_ADMIN_PASSWORD}" ]]; then
    # Keep the roles (everything after the first comma), replace the password
    awk -v u="${RT_ADMIN_USER}" -v pw="${RT_ADMIN_PASSWORD}" '
      $0 ~ "^[[:space:]]*" u "[[:space:]]*=" {
        val = $0; sub(/^[^=]*=[[:space:]]*/, "", val)
        roles = ""; if (index(val, ",") > 0) roles = substr(val, index(val, ","))
        print u " = " pw roles; next }
      { print }' "${USERS}" > "${WORK_DIR}/users.properties"
    cat "${WORK_DIR}/users.properties" > "${USERS}"
    chmod 0640 "${USERS}"
    info "Password of ${RT_ADMIN_USER} changed (roles kept)"
  else
    current="$(grep -E "^[[:space:]]*${RT_ADMIN_USER}[[:space:]]*=" "${USERS}" | sed -E 's/^[^=]*=[[:space:]]*//; s/,.*//')"
    if [[ "${current}" == "${RT_ADMIN_USER}" ]]; then
      warn "${RT_ADMIN_USER} still has the DEFAULT password: change it (set RT_ADMIN_PASSWORD or rerun with a terminal)"
    else
      info "Password of ${RT_ADMIN_USER} kept"
    fi
  fi
  # Any other account still using its default password (password = user name)?
  defaults="$(awk -F'=' '/^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ && $1 !~ /^_g_/ {
      u=$1; gsub(/[[:space:]]/, "", u); v=$2; sub(/^[[:space:]]*/, "", v); sub(/,.*/, "", v)
      if (u == v) printf "%s ", u }' "${USERS}")"
  if [[ -n "${defaults}" ]]; then
    warn "Users with their DEFAULT password (password = user name): ${defaults}- change them in ${USERS}"
  fi
fi
chown -R "${RT_USER}:${RT_GROUP}" "${RT_BASE}"

if ! sh_err="$(sh -n "${RT_HOME_REAL}/bin/${LAUNCHER}" 2>&1)"; then
  die "bin/${LAUNCHER} has a syntax error: ${sh_err}"
fi

# ----------------------------------------------------------------------------
# 6. systemd service
#    "bin/trun server" runs Karaf in the foreground without an interactive
#    console: Type=simple. Karaf shuts down cleanly on SIGTERM.
# ----------------------------------------------------------------------------
log "6/7 systemd service ${SERVICE_NAME}.service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Talend Runtime (Apache Karaf)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RT_USER}
Group=${RT_GROUP}
UMask=0027
Environment=JAVA_HOME=${JAVA_LINK}
Environment=PATH=${JAVA_LINK}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=${RT_LINK}
ExecStart=${RT_LINK}/bin/${LAUNCHER} server
# The JVM exits with 143 on SIGTERM: this is a clean stop
SuccessExitStatus=0 143
TimeoutStartSec=180
TimeoutStopSec=120
Restart=on-failure
RestartSec=15
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

# ----------------------------------------------------------------------------
# 7. Start and checks
# ----------------------------------------------------------------------------
log "7/7 Start and checks"
if [[ "${START}" == true ]]; then
  systemctl restart "${SERVICE_NAME}.service"
  info "Waiting for the HTTP port ${RT_HTTP_PORT} (the first start can take 1-2 minutes)..."
  for _ in $(seq 1 60); do
    listening "${RT_HTTP_PORT}" && break
    systemctl is-active --quiet "${SERVICE_NAME}" || break
    sleep 3
  done
  systemctl --no-pager --lines=5 status "${SERVICE_NAME}" || true
  for port in "${RT_HTTP_PORT}" "${RT_SSH_PORT}" "${RT_RMI_REGISTRY_PORT}"; do
    if listening "${port}"; then info "port ${port}: listening"
    else warn "port ${port}: not listening (yet). Check: journalctl -u ${SERVICE_NAME} and ${RT_LINK}/log/"; fi
  done
else
  info "Service enabled, not started (--no-start)"
fi

log "Done"
cat <<EOF
    Java        : ${JAVA_LINK} -> $(readlink -f "${JAVA_LINK}")
    Runtime     : ${RT_LINK} -> ${RT_HOME_REAL}
    Config      : ${ETC}  (originals: *.orig)
    Service     : systemctl {status|stop|start|restart} ${SERVICE_NAME}
    Logs        : ${RT_LINK}/log/tesb.log (or karaf.log) | journalctl -u ${SERVICE_NAME}
    Console     : su - ${RT_USER} -c '${RT_LINK}/bin/client'   (or ssh -p ${RT_SSH_PORT} ${RT_ADMIN_USER}@localhost)
    HTTP        : http://localhost:\${HOST_PORT_RT_HTTP:-8040}/services  (from the docker host)

    In TAC (ESB Conductor), use host vm-runtime and SSH/JMX ports ${RT_SSH_PORT} / ${RT_RMI_REGISTRY_PORT}.
EOF
