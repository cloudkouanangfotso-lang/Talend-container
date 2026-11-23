#!/usr/bin/env bash
# =============================================================================
#  install_db.sh - Install and configure PostgreSQL 18 for Talend
#                  Administration Center on the vm_db container (Debian 13).
#
#  Steps:
#    1. postgres account with a fixed UID/GID (owner of the data volume)
#    2. Install PostgreSQL 18 from the PGDG repository (cluster NOT auto-created)
#    3. Create the cluster 18/main (UTF8, en_US.UTF-8, data checksums)
#    4. Configure postgresql.conf (conf.d/10-talend.conf) and pg_hba.conf
#    5. Enable and start the systemd service (postgresql@18-main)
#    6. Create the TAC role and database
#    7. Checks (local socket + TCP with password)
#
#  Data   : /var/lib/postgresql/18/main   (volume db_data)
#  Config : /etc/postgresql/18/main       (volume db_conf)
#  Logs   : /var/log/postgresql           (volume db_log)
#  The script is idempotent: after "docker compose down / up" just run it again,
#  it reinstalls the binaries and reuses the existing cluster and data.
#
#  Usage (inside vm_db, as root):
#     docker exec -it vm_db bash /opt/scripts/vm_db/install_db.sh
#  Non-interactive (password from the environment, not stored anywhere):
#     docker exec -it -e DB_TAC_PASSWORD='S3cr3t!' vm_db bash /opt/scripts/vm_db/install_db.sh
#
#  Options:
#     --skip-tac-db   install/configure PostgreSQL only, do not create the TAC database
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Parameters (defaults come from .env through docker-compose)
# ----------------------------------------------------------------------------
PG_VERSION="${DB_PG_VERSION:-18}"
PG_CLUSTER="${DB_CLUSTER:-main}"
PG_PORT="${DB_PORT:-5432}"
PG_LOCALE="${DB_LOCALE:-en_US.UTF-8}"
PG_UID="${POSTGRES_UID:-1100}"

SHARED_BUFFERS="${DB_SHARED_BUFFERS:-512MB}"
MAX_CONNECTIONS="${DB_MAX_CONNECTIONS:-200}"
ALLOWED_CIDR="${DB_ALLOWED_CIDR:-172.28.10.0/24}"
PG_TIMEZONE="${TZ:-Europe/Paris}"

TAC_DB="${DB_TAC_NAME:-talend_tac}"
TAC_USER="${DB_TAC_USER:-talend_tac}"
TAC_PASSWORD="${DB_TAC_PASSWORD:-}"

PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER}"
PG_SERVICE="postgresql@${PG_VERSION}-${PG_CLUSTER}"

CREATE_TAC_DB=true
for arg in "$@"; do
  case "$arg" in
    --skip-tac-db) CREATE_TAC_DB=false ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
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

# Run psql as the postgres superuser through the local Unix socket (peer auth)
psql_admin() { ( cd / && runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -p "${PG_PORT}" "$@" ); }

# ----------------------------------------------------------------------------
# 0. Pre-checks
# ----------------------------------------------------------------------------
log "Pre-checks"
[[ $EUID -eq 0 ]] || die "Run this script as root (docker exec -it vm_db bash)."
[[ "$(cat /proc/1/comm)" == "systemd" ]] || die "systemd is not PID 1 in this container."
[[ -f /etc/apt/sources.list.d/pgdg.list ]] || die "PGDG repository not configured (rebuild the vm_db image)."
locale -a | grep -qi "^${PG_LOCALE/UTF-8/utf8}$" || die "Locale ${PG_LOCALE} is not generated in the image."

if [[ "${CREATE_TAC_DB}" == true && -z "${TAC_PASSWORD}" ]]; then
  [[ -t 0 ]] || die "DB_TAC_PASSWORD is not set and no terminal to ask for it (use docker exec -it)."
  while :; do
    read -r -s -p "    Password for database user ${TAC_USER}: " p1; echo
    read -r -s -p "    Confirm password: " p2; echo
    [[ -n "$p1" && "$p1" == "$p2" ]] && { TAC_PASSWORD="$p1"; break; }
    info "Empty or different passwords, try again."
  done
fi
info "PostgreSQL ${PG_VERSION}, cluster ${PG_CLUSTER}, port ${PG_PORT}, locale ${PG_LOCALE}"
info "Allowed network: ${ALLOWED_CIDR}"
if [[ "${CREATE_TAC_DB}" == true ]]; then info "TAC database: ${TAC_DB}, owner ${TAC_USER}"; fi

# ----------------------------------------------------------------------------
# 1. postgres account with a fixed UID/GID
#    The data volume keeps its owner across container re-creation only if the
#    postgres account always gets the same IDs.
# ----------------------------------------------------------------------------
log "1/7 postgres account (UID/GID ${PG_UID})"
if ! getent group postgres >/dev/null; then
  groupadd --system --gid "${PG_UID}" postgres
fi
if ! id postgres >/dev/null 2>&1; then
  useradd --system --uid "${PG_UID}" --gid postgres --home-dir /var/lib/postgresql \
          --no-create-home --shell /bin/bash --comment "PostgreSQL administrator" postgres
fi
info "$(id postgres)"
install -d -o postgres -g postgres -m 0755 /var/lib/postgresql /var/log/postgresql /etc/postgresql
if [[ -d "${PG_DATA_DIR}" ]]; then
  owner="$(stat -c %u "${PG_DATA_DIR}")"
  [[ "${owner}" == "$(id -u postgres)" ]] || die "${PG_DATA_DIR} belongs to UID ${owner}, postgres is $(id -u postgres)."
fi

# ----------------------------------------------------------------------------
# 2. Install PostgreSQL 18 (PGDG). The automatic "main" cluster is disabled:
#    the cluster is created explicitly in step 3 with our options.
# ----------------------------------------------------------------------------
log "2/7 Install PostgreSQL ${PG_VERSION}"
install -d /etc/postgresql-common
if [[ -f /etc/postgresql-common/createcluster.conf ]]; then
  sed -i -E 's/^#?\s*create_main_cluster\s*=.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf
else
  echo "create_main_cluster = false" > /etc/postgresql-common/createcluster.conf
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
  -o Dpkg::Options::=--force-confold \
  "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
grep -q '^create_main_cluster = false' /etc/postgresql-common/createcluster.conf \
  || sed -i -E 's/^#?\s*create_main_cluster\s*=.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf
info "$(/usr/lib/postgresql/${PG_VERSION}/bin/postgres --version)"

# ----------------------------------------------------------------------------
# 3. Cluster 18/main
# ----------------------------------------------------------------------------
log "3/7 Cluster ${PG_VERSION}/${PG_CLUSTER}"
if [[ -f "${PG_CONF_DIR}/postgresql.conf" && -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
  info "Existing cluster reused (data from the volume)"
else
  [[ -e "${PG_DATA_DIR}" && -n "$(ls -A "${PG_DATA_DIR}" 2>/dev/null)" ]] \
    && die "${PG_DATA_DIR} is not empty but has no configuration in ${PG_CONF_DIR}: check the volumes."
  pg_createcluster "${PG_VERSION}" "${PG_CLUSTER}" \
    --port "${PG_PORT}" --locale "${PG_LOCALE}" --encoding UTF8 \
    -- --data-checksums
  info "Cluster created"
fi
pg_lsclusters
info "(Status 'down' is normal here: the cluster is started by systemd in step 5/7.)"

# ----------------------------------------------------------------------------
# 4. Configuration
#    postgresql.conf : our settings in conf.d/10-talend.conf, loaded by an
#                      include_dir line at the end; the rest of the file is untouched
#    pg_hba.conf     : password access (scram-sha-256) from the docker network
# ----------------------------------------------------------------------------
log "4/7 Configuration"
install -d -o postgres -g postgres -m 0755 "${PG_CONF_DIR}/conf.d"
cat > "${PG_CONF_DIR}/conf.d/10-talend.conf" <<EOF
# Generated by install_db.sh - settings for Talend Administration Center
listen_addresses = '*'
port = ${PG_PORT}
max_connections = ${MAX_CONNECTIONS}
shared_buffers = ${SHARED_BUFFERS}
password_encryption = scram-sha-256
timezone = '${PG_TIMEZONE}'
log_timezone = '${PG_TIMEZONE}'
log_line_prefix = '%m [%p] %q%u@%d from %h '
log_connections = on
log_disconnections = on
EOF
chown postgres:postgres "${PG_CONF_DIR}/conf.d/10-talend.conf"
chmod 0640 "${PG_CONF_DIR}/conf.d/10-talend.conf"
info "Wrote ${PG_CONF_DIR}/conf.d/10-talend.conf"
# Make postgresql.conf read conf.d/ (last line, so these settings win)
if ! grep -qE "^\s*include_dir\s*=\s*'conf\.d'" "${PG_CONF_DIR}/postgresql.conf"; then
  printf "\n# Added by install_db.sh: Talend settings in conf.d/\ninclude_dir = 'conf.d'\n" >> "${PG_CONF_DIR}/postgresql.conf"
  info "Added include_dir = 'conf.d' to postgresql.conf"
fi

HBA="${PG_CONF_DIR}/pg_hba.conf"
begin="# >>> talend (install_db.sh) >>>"; end="# <<< talend (install_db.sh) <<<"
sed -i "\|^${begin}\$|,\|^${end}\$|d" "${HBA}"
cat >> "${HBA}" <<EOF
${begin}
# TYPE  DATABASE        USER            ADDRESS                 METHOD
host    all             all             ${ALLOWED_CIDR}         scram-sha-256
${end}
EOF
info "pg_hba.conf: host all all ${ALLOWED_CIDR} scram-sha-256"

# ----------------------------------------------------------------------------
# 5. systemd
#    postgresql@18-main runs the cluster. postgresql.service is the umbrella
#    unit that starts every cluster at boot.
# ----------------------------------------------------------------------------
log "5/7 systemd service ${PG_SERVICE}"
systemctl daemon-reload
systemctl enable postgresql.service "${PG_SERVICE}.service"
systemctl restart "${PG_SERVICE}.service"
for _ in $(seq 1 30); do
  runuser -u postgres -- pg_isready -q -p "${PG_PORT}" && break
  sleep 1
done
if ! runuser -u postgres -- pg_isready -p "${PG_PORT}"; then
  systemctl --no-pager status "${PG_SERVICE}" || true
  tail -n 20 "/var/log/postgresql/postgresql-${PG_VERSION}-${PG_CLUSTER}.log" 2>/dev/null || true
  die "PostgreSQL did not start: see the service status and log above."
fi
systemctl --no-pager --lines=0 status "${PG_SERVICE}" || true

# ----------------------------------------------------------------------------
# 6. TAC role and database
#    psql variables (:'name') quote the values safely, whatever the password contains.
# ----------------------------------------------------------------------------
if [[ "${CREATE_TAC_DB}" == true ]]; then
  log "6/7 TAC role ${TAC_USER} and database ${TAC_DB}"
  psql_admin -q -v role="${TAC_USER}" -v pw="${TAC_PASSWORD}" -v db="${TAC_DB}" -v loc="${PG_LOCALE}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'role', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8'' LC_COLLATE %L LC_CTYPE %L TEMPLATE template0',
              :'db', :'role', :'loc', :'loc')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db', :'role') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('GRANT ALL ON DATABASE %I TO %I', :'db', :'role') \gexec
SQL
  info "Role and database ready"
else
  log "6/7 TAC database skipped (--skip-tac-db)"
fi

# ----------------------------------------------------------------------------
# 7. Checks
# ----------------------------------------------------------------------------
log "7/7 Checks"
pg_lsclusters
psql_admin -At -c "SELECT 'server: ' || version()"
psql_admin -At -c "SHOW data_checksums" | sed 's/^/    data_checksums: /'
psql_admin -At -c "SHOW listen_addresses" | sed 's/^/    listen_addresses: /'
if [[ "${CREATE_TAC_DB}" == true ]]; then
  PGPASSWORD="${TAC_PASSWORD}" psql -X -h 127.0.0.1 -p "${PG_PORT}" -U "${TAC_USER}" -d "${TAC_DB}" -At \
    -c "SELECT '    TCP login OK: ' || current_user || '@' || current_database() || ' (' || pg_encoding_to_char(encoding) || ', ' || datcollate || ')' FROM pg_database WHERE datname = current_database()" \
    || die "TCP login with ${TAC_USER} failed."
fi

log "Done"
cat <<EOF
    Service   : systemctl {status|restart} ${PG_SERVICE}
    Config    : ${PG_CONF_DIR}/conf.d/10-talend.conf , ${PG_CONF_DIR}/pg_hba.conf
    Data      : ${PG_DATA_DIR}
    Logs      : /var/log/postgresql/postgresql-${PG_VERSION}-${PG_CLUSTER}.log
    Admin     : su - postgres -c psql

    TAC database connection (TAC configuration page):
      Type     : PostgreSQL
      URL      : jdbc:postgresql://vm-db:${PG_PORT}/${TAC_DB}
      User     : ${TAC_USER}
    From the docker host: localhost:\${HOST_PORT_DB:-5432}
EOF
