# syntax=docker/dockerfile:1
# =============================================================================
#  Talend Data Services Platform - "VM-like" containers on Debian 13 (trixie)
#
#  Every container boots systemd as PID 1, so applications installed manually
#  inside can be registered and enabled as systemd services, exactly like on a
#  VM. NO Talend / Nexus / RabbitMQ / PostgreSQL software is installed here:
#  only the OS, systemd and the prerequisites.
#
#  Build targets (selected from docker-compose.yml):
#    systemd-base  -> vm_rabbitmq
#    java          -> vm_tac, vm_jobserver, vm_runtime, vm_nexus
#    postgres      -> vm_db  (PGDG apt repository configured, PostgreSQL NOT installed)
# =============================================================================

ARG DEBIAN_IMAGE=debian:trixie

# -----------------------------------------------------------------------------
# Stage: systemd-base
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS systemd-base

ARG TZ=Europe/Paris
ARG LOCALE=en_US.UTF-8

ENV container=docker \
    DEBIAN_FRONTEND=noninteractive \
    LANG=${LOCALE} \
    LC_ALL=${LOCALE} \
    TZ=${TZ}

# OS + systemd + the usual admin tools a consultant expects on a server
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        systemd systemd-sysv systemd-timesyncd- dbus \
        ca-certificates curl wget gnupg apt-transport-https \
        unzip zip tar gzip bzip2 xz-utils \
        sudo procps psmisc lsof less vim nano \
        iproute2 iputils-ping net-tools dnsutils netcat-openbsd telnet traceroute \
        openssh-client rsync \
        locales tzdata fontconfig \
 && sed -i "s/^# *${LOCALE} /${LOCALE} /" /etc/locale.gen \
 && locale-gen \
 && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo "${TZ}" > /etc/timezone \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Optional corporate / proxy root CA certificates (*.crt in docker/certs/)
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

# Trim systemd units that make no sense inside a container
RUN find /etc/systemd/system /lib/systemd/system \
        -path '*.wants/*' \
        \( -name '*getty*' -o -name '*udev*' -o -name 'systemd-remount-fs*' \
           -o -name 'systemd-logind*' -o -name 'systemd-firstboot*' \) \
        -exec rm -f {} + 2>/dev/null || true \
 && systemctl mask \
        getty.target console-getty.service \
        systemd-udevd.service systemd-udev-trigger.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
        systemd-remount-fs.service systemd-firstboot.service \
        sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount \
        dev-hugepages.mount systemd-modules-load.service \
        apt-daily.timer apt-daily-upgrade.timer \
 && systemctl set-default multi-user.target

# Export the docker env vars (binary names, paths, ...) to every login shell.
# systemd does not pass the container environment to `su -` / ssh sessions.
COPY rootfs/ /
RUN chmod 0755 /usr/local/sbin/container-env-export \
 && systemctl enable container-env-export.service

# Mount point of the Windows host binaries folder (bind mount, read-only)
RUN mkdir -p /opt/binary

# systemd must receive SIGRTMIN+3 to shut down cleanly
STOPSIGNAL SIGRTMIN+3
# NOTE: never declare VOLUME /sys/fs/cgroup here: it would hide the real cgroup
# filesystem behind an empty volume and systemd fails with "No medium found".
CMD ["/sbin/init"]

# -----------------------------------------------------------------------------
# Stage: java  (TAC, JobServer, Runtime, Nexus)
#   Talend 8 requires Java 17 (Java 21 supported on recent monthly patches).
#   Eclipse Temurin is used because OpenJDK 17 is no longer shipped by trixie.
# -----------------------------------------------------------------------------
FROM systemd-base AS java

ARG JAVA_VERSION=17
ARG APP_USER=talend
ARG APP_UID=1001
ARG APP_HOME=/opt/talend

RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
 && . /etc/os-release \
 && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/adoptium.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends temurin-${JAVA_VERSION}-jdk \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && JHOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")" \
 && echo "JAVA_HOME=${JHOME}" >> /etc/environment \
 && printf 'export JAVA_HOME=%s\nexport PATH="$JAVA_HOME/bin:$PATH"\n' "${JHOME}" > /etc/profile.d/java.sh

# Dedicated, non-root service account owning the application folder.
# The folder is created here so the named volume inherits this ownership.
RUN groupadd --gid ${APP_UID} ${APP_USER} \
 && useradd --uid ${APP_UID} --gid ${APP_UID} --create-home --shell /bin/bash ${APP_USER} \
 && echo "${APP_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${APP_USER} \
 && chmod 0440 /etc/sudoers.d/${APP_USER} \
 && install -d -o ${APP_USER} -g ${APP_USER} -m 0755 ${APP_HOME} \
 && printf '%s soft nofile 65536\n%s hard nofile 65536\n%s soft nproc 8192\n%s hard nproc 8192\n' \
      ${APP_USER} ${APP_USER} ${APP_USER} ${APP_USER} > /etc/security/limits.d/${APP_USER}.conf

# -----------------------------------------------------------------------------
# Stage: postgres  (vm_db)
#   Debian 13 ships PostgreSQL 17; PostgreSQL 18 comes from the official PGDG
#   repository, which is configured here. You install it yourself:
#     apt-get update && apt-get install -y postgresql-18
# -----------------------------------------------------------------------------
FROM systemd-base AS postgres

RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg \
 && . /etc/os-release \
 && echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
