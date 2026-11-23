# Talend Data Services Platform: Docker Compose (Debian 13)

Six "VM-like" containers based on **Debian 13 (trixie)**. **systemd is PID 1**,
so you install each product **manually** and register it as an enabled systemd
service, just as on a VM. **No application is installed by this project.**

| Container      | Hostname / aliases               | IP (default)   | Image content (prerequisites only)               | Persisted volumes |
|----------------|----------------------------------|----------------|--------------------------------------------------|-------------------|
| `vm_db`        | `vm-db`, `db`, `tacdb`           | 172.28.10.10   | systemd, **PGDG repo configured** (PostgreSQL 18 not installed) | `/var/lib/postgresql`, `/etc/postgresql`, `/var/log/postgresql` |
| `vm_nexus`     | `vm-nexus`, `nexus`              | 172.28.10.11   | systemd, Temurin JDK 17, user `nexus`            | `/opt/sonatype` |
| `vm_rabbitmq`  | `vm-rabbitmq`, `rabbitmq`        | 172.28.10.12   | systemd                                          | `/var/lib/rabbitmq`, `/etc/rabbitmq`, `/var/log/rabbitmq` |
| `vm_tac`       | `vm-tac`, `tac`                  | 172.28.10.20   | systemd, Temurin JDK 17, user `talend`           | `/opt/talend` |
| `vm_jobserver` | `vm-jobserver`, `jobserver`      | 172.28.10.21   | systemd, Temurin JDK 17, user `talend`           | `/opt/talend` |
| `vm_runtime`   | `vm-runtime`, `runtime`          | 172.28.10.22   | systemd, Temurin JDK 17, user `talend`           | `/opt/talend` |

Every container also persists **`/etc/systemd/system`**, so the unit files you
create and the services you enable survive container re-creation.

## Layout

```
.env                    <- ALL variables (binaries path & names, ports, IPs, Java version...)
docker-compose.yml
docker/Dockerfile       <- multi-stage: systemd-base | java | postgres
docker/rootfs/          <- boot helper exporting compose env vars to login shells
docker/certs/           <- optional corporate proxy CA (*.crt), trusted at build time
docs/vm_tac_manual_install.md <- the same TAC install, step by step, by hand
docs/vm_db_manual_install.md  <- the same PostgreSQL 18 setup, step by step, by hand
scripts/                <- installation scripts, mounted read-only at /opt/scripts
  vm_tac/install_tac.sh <- Java 21 + Tomcat 11.0.29 + systemd + TAC war as ROOT
  vm_db/install_db.sh   <- PostgreSQL 18 + configuration + systemd + TAC database
```

## Prerequisites (Windows docker host)

* Docker Desktop with the **WSL2 backend** (cgroup v2). Debian 13 ships systemd 257,
  which **does not boot on cgroup v1** hosts.
* The binaries folder, e.g. `C:\Talend\binaries`, containing:
  * `Talend-AdministrationCenter-20260708_1430-V8.0.1.zip`
  * `Talend-JobServer-20260708_1430-V8.0.1.zip`
  * `Talend-Runtime-V8.0.2.R2026-06-RT.zip`
* Behind an SSL-inspecting proxy: copy the corporate root CA to `docker/certs/*.crt`.

## Configure

Edit `.env`:

```dotenv
BINARY_HOST_PATH=C:/Talend/binaries        # folder on the docker host (forward slashes)
BINARY_TAC=Talend-AdministrationCenter-20260708_1430-V8.0.1.zip
BINARY_JOBSERVER=Talend-JobServer-20260708_1430-V8.0.1.zip
BINARY_RUNTIME=Talend-Runtime-V8.0.2.R2026-06-RT.zip
```

The folder is bind-mounted **read-only** at `/opt/binary` in every container.
With a remote engine (`DOCKER_HOST=...`), `BINARY_HOST_PATH` is resolved **on the
remote Windows host**.

## Start

```bash
docker compose up -d --build
```

```bash
docker compose ps
```

Open a shell (as root, or as the service account):

```bash
docker exec -it vm_tac bash
```

```bash
docker exec -it -u talend -w /opt/talend vm_tac bash -l
```

Inside each container the variables `BINARY_PATH`, `BINARY_TAC`, `BINARY_JOBSERVER`,
`BINARY_RUNTIME`, `TAC_HOME` / `JOBSERVER_HOME` / `RUNTIME_HOME` / `NEXUS_HOME` and
`JAVA_HOME` are available in login shells (`/etc/profile.d/container-env.sh`) and for
systemd units through `EnvironmentFile=/etc/container-env`. For example:

```bash
unzip "$BINARY_PATH/$BINARY_TAC" -d /opt/talend/tac
```

## Manual installation: where to install

| Product      | Install into (persisted)                   | Run as   |
|--------------|--------------------------------------------|----------|
| TAC          | `/opt/talend/tac`                          | `talend` |
| JobServer    | `/opt/talend/jobserver`                    | `talend` |
| Runtime      | `/opt/talend/runtime`                      | `talend` |
| Nexus        | `/opt/sonatype/nexus-x.y.z` + `/opt/sonatype/sonatype-work` | `nexus` |
| RabbitMQ     | `apt-get install rabbitmq-server` (Debian 13), data in `/var/lib/rabbitmq` | `rabbitmq` |
| PostgreSQL 18| `apt-get update && apt-get install postgresql-18` (PGDG repo is preconfigured) | `postgres` |

Then put your unit files in `/etc/systemd/system/` and run
`systemctl daemon-reload && systemctl enable --now <service>`. They start
automatically each time the container starts.

> **Important: apt-installed packages.** PostgreSQL and RabbitMQ binaries live in
> `/usr` (image layer), but their data and config are persisted. Use
> `docker compose stop` / `start` / `restart`, which keep the binaries. After
> `docker compose down` + `up` or a rebuild, the container is new: re-run the
> `apt-get install` (data, config and enabled units are preserved). To freeze a
> fully installed container, run `docker commit vm_db talend-dsp/vm_db:installed`
> and point `image:` at it. Talend and Nexus products under `/opt` are not affected.

## Automated TAC installation (`vm_tac`)

`scripts/vm_tac/install_tac.sh` runs **inside** `vm_tac`, as root (to do the same steps by hand, with an explanation of each
command, see [docs/vm_tac_manual_install.md](docs/vm_tac_manual_install.md)):

```bash
docker exec -it vm_tac bash /opt/scripts/vm_tac/install_tac.sh
```

| Step | Result |
|------|--------|
| 1. Java 21 (Eclipse Temurin, latest 21 GA, SHA-256 checked) | `/opt/talend/java/jdk-21.x` with symlink `/opt/talend/java/jdk21` |
| 2. `JAVA_HOME` + `PATH` for `talend` | block in `~talend/.profile` and `~talend/.bashrc` |
| 3. Apache Tomcat 11.0.29 (SHA-512 checked) | `/opt/talend/tac/apache-tomcat-11.0.29` with symlink `/opt/talend/tac/tomcat`; default webapps removed; `bin/setenv.sh` (JAVA_HOME, heap) |
| 4. TAC war from `$BINARY_PATH/$BINARY_TAC` | exploded as `webapps/ROOT`, so TAC answers on `http://localhost:8080/` |
| 5. systemd | `/etc/systemd/system/talend-tac.service`, `User=talend`, `Group=talend`, enabled and started |

Everything goes under `/opt/talend` (volume `tac_app`) and `/etc/systemd/system`
(volume `tac_systemd`), so the installation survives `docker compose down` / `up`.
Java 21 is installed from a tarball for that reason (an apt package in `/usr` would be lost).

Options and variables:

```bash
docker exec -it vm_tac bash /opt/scripts/vm_tac/install_tac.sh --no-start
```

```bash
docker exec -it -e TAC_XMX=6g vm_tac bash /opt/scripts/vm_tac/install_tac.sh --force
```

* `--no-start`: install and enable the service without starting it. `--force`:
  reinstall Java and Tomcat. The war is always redeployed, which **overwrites**
  `WEB-INF/classes/configuration.properties`, so back it up before re-running
  on a configured TAC.
* Variables: `JAVA_MAJOR` (21), `TOMCAT_VERSION` (11.0.29), `TAC_HTTP_PORT` (8080),
  `TAC_XMS` (1g), `TAC_XMX` (4g), `SERVICE_NAME` (talend-tac), `TAC_USER`/`TAC_GROUP` (talend).
* **Offline:** if `OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz` and/or
  `apache-tomcat-11.0.29.tar.gz` are in the binaries folder, they are used
  instead of downloading.

Service management: `systemctl status|restart talend-tac`, logs with
`journalctl -u talend-tac -f` and `/opt/talend/tac/tomcat/logs`.

## Automated database setup (`vm_db`)

`scripts/vm_db/install_db.sh` runs **inside** `vm_db`, as root. It asks for the
password of the TAC database user (nothing is stored in the project). To do the
same steps by hand, with each command explained, see
[docs/vm_db_manual_install.md](docs/vm_db_manual_install.md).

```bash
docker exec -it vm_db bash /opt/scripts/vm_db/install_db.sh
```

| Step | Result |
|---|---|
| 1. `postgres` account | fixed UID/GID 1100 (`POSTGRES_UID`), so the data volume keeps the right owner |
| 2. PostgreSQL 18 (PGDG) | `postgresql-18` + client, automatic cluster creation disabled |
| 3. Cluster `18/main` | port 5432, UTF8, `en_US.UTF-8`, data checksums |
| 4. Configuration | `conf.d/10-talend.conf` (`listen_addresses='*'`, `max_connections`, `shared_buffers`, SCRAM, logging) and a `pg_hba.conf` rule for the docker network (`NETWORK_SUBNET`) |
| 5. systemd | `postgresql@18-main` and `postgresql` enabled and started |
| 6. TAC database | role `talend_tac` (login, no admin rights) owning database `talend_tac` (UTF8) |
| 7. Checks | version, settings, TCP login with the password |

* Database and user names, `shared_buffers` and `max_connections` come from `.env`
  (`DB_TAC_NAME`, `DB_TAC_USER`, `DB_SHARED_BUFFERS`, `DB_MAX_CONNECTIONS`).
* Non-interactive: `docker exec -it -e DB_TAC_PASSWORD='…' vm_db bash /opt/scripts/vm_db/install_db.sh`.
  `--skip-tac-db` installs PostgreSQL without creating the TAC database.
* Safe to run again. **After a container recreate** it reinstalls the binaries and
  reuses the existing cluster and data. Running it again with a password also
  resets the TAC user's password.
* TAC connection: `jdbc:postgresql://vm-db:5432/talend_tac`, user `talend_tac`.

## Network and traffic

* **Container to container**: by container name (`vm_db`) or by hostname/alias
  (`vm-db`, `db`). Use the **hyphenated names** in Talend configuration
  (JDBC URL, JobServer host, Nexus URL...). Java/Tomcat consider host names with
  `_` invalid (`URI.getHost()` returns null, Tomcat rejects the Host header).
  Example JDBC URL: `jdbc:postgresql://vm-db:5432/tac`.
* **Docker host to container**: published ports on `localhost` (or the host IP, see
  `HOST_BIND_IP`):

| Service                     | Host port (default) |
|-----------------------------|---------------------|
| TAC (ROOT application)      | http://localhost:8080/ |
| JobServer cmd / file / monitor / process | 8000 / 8001 / 8888 / 8555 |
| Runtime HTTP / HTTPS / SSH  | 8040 / 9001 / 8101 |
| Runtime RMI / RMI server / JMS | 1099 / 44444 / 61616 |
| Runtime embedded JobServer  | 8100 / 8102 / 8889 (to container 8000 / 8001 / 8888) |
| Nexus                       | http://localhost:8081 |
| RabbitMQ AMQP / AMQPS / UI  | 5672 / 5671 / http://localhost:15672 |
| PostgreSQL                  | 5432 |

* **Container to docker host**: `host.docker.internal` (e.g. Talend Studio, LDAP or
  SMTP running on Windows).
* Port clashes on the host: change the `HOST_PORT_*` variables only; container ports
  stay at the product defaults.

## Volumes and lifecycle

| Command | Effect |
|---------|--------|
| `docker compose stop` / `start` | VM-like power off / on. Everything is kept. |
| `docker compose down` | Removes containers. **Volumes kept.** |
| `docker compose down -v` | **Deletes all volumes, including installed apps and data.** |
| `docker volume ls --filter label=com.docker.compose.project=talend-dsp` | List volumes |

Backup a volume (example: TAC):

```bash
docker run --rm -v talend-dsp_tac_app:/data -v "${PWD}:/backup" debian:trixie tar czf /backup/tac_app.tgz -C /data .
```

## Notes

* Containers run `privileged` with the host cgroup namespace, which systemd
  needs on Docker Desktop. A tighter alternative is commented in `docker-compose.yml`.
* Java version: `JAVA_VERSION=17` in `.env` (21 is possible on recent Talend 8
  patches). Rebuild with `docker compose build`.
* `nofile` is raised to 65536 (required by Nexus and recommended for Talend).

## Troubleshooting

### Container restarts in a loop: `Cannot determine cgroup we are running in: No medium found`

systemd cannot see a writable **cgroup v2** filesystem at `/sys/fs/cgroup`.

1. Rebuild and recreate the containers (the compose file bind-mounts
   `/sys/fs/cgroup` read-write and the images must not declare a volume on it):

   ```bash
   docker compose down
   ```

   ```bash
   docker compose up -d --build --force-recreate --renew-anon-volumes
   ```

   (`down` without `-v` keeps your named volumes.)

2. Check that the engine uses cgroup v2. In PowerShell:

   ```bash
   docker info --format "{{.CgroupVersion}}"
   ```

   It must print `2`. If it prints `1` (typical when Docker Engine runs inside a
   WSL distro with an old WSL configuration), force cgroup v2 in
   `%UserProfile%\.wslconfig` on Windows:

   ```ini
   [wsl2]
   kernelCommandLine = cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1
   ```

   Then restart WSL and Docker:

   ```bash
   wsl --shutdown
   ```

`Failed to initialize kmod context: Operation not supported` is harmless:
containers cannot load kernel modules.
