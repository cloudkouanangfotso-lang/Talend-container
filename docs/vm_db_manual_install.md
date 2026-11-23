# vm_db: PostgreSQL 18 for TAC, manual installation step by step

This guide installs and configures the TAC database on `vm_db` by hand. It runs
the same steps as `scripts/vm_db/install_db.sh`, with the same paths and settings,
so you can use either one.

| Item | Value |
|---|---|
| PostgreSQL | 18, from the official PGDG repository (already configured in the image) |
| Cluster | `18/main`, port 5432, UTF8, `en_US.UTF-8`, data checksums |
| Data | `/var/lib/postgresql/18/main` (volume `db_data`) |
| Configuration | `/etc/postgresql/18/main` (volume `db_conf`) |
| Logs | `/var/log/postgresql/postgresql-18-main.log` (volume `db_log`) |
| systemd | `postgresql@18-main.service` (+ `postgresql.service`) |
| TAC database / owner | `talend_tac` / `talend_tac` (`DB_TAC_NAME` / `DB_TAC_USER` in `.env`) |
| Access | password (`scram-sha-256`) from the docker network `172.28.10.0/24` |

> **Debian layout.** Debian (and the PGDG packages) keep the configuration in
> `/etc/postgresql/<version>/<cluster>/` and the data in
> `/var/lib/postgresql/<version>/<cluster>/`. Clusters are managed with the
> `pg_*cluster` tools (`pg_createcluster`, `pg_lsclusters`, `pg_ctlcluster`) and with
> systemd (`postgresql@<version>-<cluster>`), not with `initdb` / `pg_ctl` directly.

---

## Step 0: Open a root shell and set the variables

On the docker host:

```bash
docker exec -it vm_db bash
```

Inside the container (run this block again if you open a new shell):

```bash
PG_VERSION=${DB_PG_VERSION:-18}
PG_CLUSTER=main
PG_PORT=5432
PG_LOCALE=en_US.UTF-8
TAC_DB=${DB_TAC_NAME:-talend_tac}
TAC_USER=${DB_TAC_USER:-talend_tac}
ALLOWED_CIDR=${DB_ALLOWED_CIDR:-172.28.10.0/24}
PG_CONF_DIR=/etc/postgresql/$PG_VERSION/$PG_CLUSTER
PG_DATA_DIR=/var/lib/postgresql/$PG_VERSION/$PG_CLUSTER
```

* `DB_PG_VERSION`, `DB_TAC_NAME`, `DB_TAC_USER` and `DB_ALLOWED_CIDR` come from `.env`
  through docker compose. `${VAR:-default}` keeps the `.env` value and falls back to
  the default if it is missing.
* `DB_ALLOWED_CIDR` is the docker network (`NETWORK_SUBNET`). Every container, and the
  docker host going through the published port, connects from an address in it.

Check the prerequisites:

```bash
cat /proc/1/comm
```

This must print `systemd`.

```bash
cat /etc/apt/sources.list.d/pgdg.list
```

This shows the PGDG repository (`trixie-pgdg`). Debian 13 itself only ships
PostgreSQL 17, so this repository is where version 18 comes from.

```bash
locale -a | grep -i en_US
```

This must show `en_US.utf8`. A database can only use a locale that is generated in
the OS (the image does this at build time).

---

## Step 1: The postgres account (fixed UID/GID)

```bash
id postgres
```

Expected: `uid=1100(postgres) gid=1100(postgres)`. The vm_db image creates this
account (`POSTGRES_UID` in `.env`).

* **Why a fixed UID?** Files in a volume belong to a **number** (UID), not a name. If
  apt created the account, it would take the next free system UID. After a container
  recreate (or an image change) that number could differ, and PostgreSQL could no
  longer read its own data folder. With a fixed UID the volume always matches.
* Only if `id` says `no such user` (an image built before this change), create it
  before installing:

  ```bash
  groupadd --system --gid 1100 postgres
  useradd --system --uid 1100 --gid postgres --home-dir /var/lib/postgresql --no-create-home --shell /bin/bash --comment "PostgreSQL administrator" postgres
  ```

  The `postgresql-common` package sees that `postgres` already exists and reuses it.

---

## Step 2: Install PostgreSQL 18

### 2.1 Disable the automatic cluster

```bash
mkdir -p /etc/postgresql-common
echo "create_main_cluster = false" > /etc/postgresql-common/createcluster.conf
```

* By default, installing `postgresql-18` immediately creates a cluster `18/main` with
  default options (the locale of the moment, port, and so on). This setting turns that
  off, so the cluster is created in Step 3 with the options TAC needs.
* `/etc/postgresql-common/createcluster.conf` is the file that holds the defaults for
  `pg_createcluster`.

### 2.2 Install the packages

```bash
apt-get update
apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold postgresql-18 postgresql-client-18
```

* `apt-get update` refreshes the package lists, including the PGDG repository.
* `postgresql-18` is the server. `postgresql-client-18` adds `psql`, `pg_dump`, and so on.
* `--no-install-recommends` installs only what is required.
* `--force-confold` keeps **your** `createcluster.conf` from 2.1 when the package brings
  its own version, instead of asking a question or replacing it.

Check:

```bash
/usr/lib/postgresql/$PG_VERSION/bin/postgres --version
pg_lsclusters
```

* Expected: `postgres (PostgreSQL) 18.x`. `pg_lsclusters` lists the clusters. The list
  is **empty** at this point on a first install, or shows the existing cluster if the
  volumes already hold one (see "After a container recreate" at the end).

---

## Step 3: Create the cluster 18/main

Skip this step if `pg_lsclusters` already shows `18 main`.

```bash
pg_createcluster $PG_VERSION $PG_CLUSTER --port $PG_PORT --locale $PG_LOCALE --encoding UTF8 -- --data-checksums
```

* `pg_createcluster` is Debian's wrapper around `initdb`. It creates the data folder
  (`/var/lib/postgresql/18/main`) and the configuration folder (`/etc/postgresql/18/main`)
  owned by `postgres`, plus the systemd and log setup.
* `--locale en_US.UTF-8 --encoding UTF8`: TAC stores multilingual text and needs a
  **UTF8** database. The locale sets sorting and character classes.
* Everything after `--` goes to `initdb`. `--data-checksums` detects disk corruption
  (on by default in PostgreSQL 18, written here so it is explicit).
* Local logins use `peer` (Linux user `postgres` = database user `postgres`, no password),
  and TCP logins use `scram-sha-256` (password). These are the Debian defaults.

```bash
pg_lsclusters
```

Expected: `18  main  5432 down  postgres /var/lib/postgresql/18/main ...` (`down` is
normal: the cluster is not started yet).

---

## Step 4: Configuration

### 4.1 Talend settings in conf.d/10-talend.conf

```bash
mkdir -p $PG_CONF_DIR/conf.d
cat > $PG_CONF_DIR/conf.d/10-talend.conf <<EOF
# Settings for Talend Administration Center
listen_addresses = '*'
port = $PG_PORT
max_connections = 200
shared_buffers = 512MB
password_encryption = scram-sha-256
timezone = '${TZ:-Europe/Paris}'
log_timezone = '${TZ:-Europe/Paris}'
log_line_prefix = '%m [%p] %q%u@%d from %h '
log_connections = on
log_disconnections = on
EOF
chown -R postgres:postgres $PG_CONF_DIR/conf.d
chmod 0640 $PG_CONF_DIR/conf.d/10-talend.conf
```

* The settings go in a **separate file**, not into `postgresql.conf`. The original file
  stays untouched, and you can see at a glance what was changed for Talend.
* `<<EOF` without quotes: the shell replaces `$PG_PORT` and `${TZ}` while writing.

| Setting | Why |
|---|---|
| `listen_addresses = '*'` | By default PostgreSQL only listens on `localhost`, so other containers could not connect. `*` = all interfaces of the container. Who may log in is decided by `pg_hba.conf`. |
| `max_connections = 200` | TAC keeps a connection pool, and several components connect at once. The default is 100. |
| `shared_buffers = 512MB` | PostgreSQL's data cache (default 128MB). A common rule is about 25% of the RAM available to the database. |
| `password_encryption = scram-sha-256` | Passwords are stored and checked with SCRAM (the secure method; `md5` is deprecated). |
| `timezone` / `log_timezone` | Same time zone as the containers (`TZ` in `.env`), for timestamps and logs. |
| `log_line_prefix` | Each log line shows the time, process, `user@database` and client host. |
| `log_connections` / `log_disconnections` | Logs who connects. Useful to check that TAC reaches the database. |

### 4.2 Load conf.d from postgresql.conf

```bash
grep -n "^include_dir" $PG_CONF_DIR/postgresql.conf || printf "\n# Talend settings in conf.d/\ninclude_dir = 'conf.d'\n" >> $PG_CONF_DIR/postgresql.conf
```

* The `postgresql.conf` generated for this cluster does **not** read `conf.d/` by
  default (the line is only there as a comment).
* `grep … || printf … >>`: if an active `include_dir` line already exists, `grep`
  succeeds and nothing happens. Otherwise the line is **appended**. Being the last
  line, the values in `conf.d` override those earlier in the file.

### 4.3 pg_hba.conf: who may connect

```bash
cat >> $PG_CONF_DIR/pg_hba.conf <<EOF
# >>> talend (install_db.sh) >>>
# TYPE  DATABASE        USER            ADDRESS                 METHOD
host    all             all             $ALLOWED_CIDR         scram-sha-256
# <<< talend (install_db.sh) <<<
EOF
```

* `pg_hba.conf` (host-based authentication) is read from top to bottom. The **first**
  line that matches the connection type, database, user and client address decides.
* `host … 172.28.10.0/24 scram-sha-256`: TCP connections from the docker network, to
  any database, as any user, **with a password**. Without this line, connections from
  `vm_tac` or the docker host are refused with `no pg_hba.conf entry for host`.
* The existing lines stay: `local … peer` (the `postgres` Linux user logs in without a
  password) and `host … 127.0.0.1/32 scram-sha-256` (local TCP).
* The markers are the ones the script uses, so the script would replace this block
  instead of adding a second one. Run this step **once** by hand.

```bash
grep -vE '^\s*(#|$)' $PG_CONF_DIR/pg_hba.conf
```

This shows the active lines (comments and empty lines hidden).

---

## Step 5: systemd: enable and start

```bash
systemctl daemon-reload
systemctl enable postgresql.service postgresql@$PG_VERSION-$PG_CLUSTER.service
systemctl restart postgresql@$PG_VERSION-$PG_CLUSTER.service
```

* `postgresql@.service` is a **template** unit. The text after `@` names the cluster
  (`18-main`), so each cluster is its own service. It runs `pg_ctlcluster 18 main start`
  as the `postgres` user.
* `postgresql.service` is the umbrella unit that starts all clusters marked `auto` in
  `/etc/postgresql/18/main/start.conf` at boot. Enabling both makes the database start
  automatically with the container.
* `restart` (rather than `start`) also covers the case where the package already started
  the cluster: the new configuration (listen address, buffers) needs a restart to apply.

```bash
runuser -u postgres -- pg_isready -p $PG_PORT
systemctl status postgresql@$PG_VERSION-$PG_CLUSTER --no-pager
```

* `pg_isready` must print `/var/run/postgresql:5432 - accepting connections`.
  `runuser -u postgres --` runs the command as `postgres` (like `su`, but meant for root).
* `status` must show `Active: active (running)` and `enabled`.

---

## Step 6: Create the TAC user and database

### 6.1 The user (role) and its password

```bash
su - postgres -c "psql -c 'CREATE ROLE $TAC_USER LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE'"
su - postgres -c "psql -c '\password $TAC_USER'"
```

* `su - postgres -c "psql …"` connects as the `postgres` superuser through the local
  socket (`peer` authentication, no password needed).
* `CREATE ROLE … LOGIN`: in PostgreSQL a user is a role that may log in. TAC needs no
  superuser rights, so `NOSUPERUSER NOCREATEDB NOCREATEROLE` gives it the least it needs.
* `\password` **asks** for the password twice and sends it already encrypted (SCRAM).
  The password never appears on the command line, in the shell history or in the
  PostgreSQL logs. Keep it for the TAC configuration page.

### 6.2 The database

```bash
su - postgres -c "psql -c \"CREATE DATABASE $TAC_DB OWNER $TAC_USER ENCODING 'UTF8' LC_COLLATE '$PG_LOCALE' LC_CTYPE '$PG_LOCALE' TEMPLATE template0\""
su - postgres -c "psql -c 'REVOKE ALL ON DATABASE $TAC_DB FROM PUBLIC'"
su - postgres -c "psql -c 'GRANT ALL ON DATABASE $TAC_DB TO $TAC_USER'"
```

* `OWNER talend_tac`: the TAC user owns the database. Since PostgreSQL 15 the `public`
  schema belongs to the database owner, so TAC can create its tables there. **TAC
  creates its schema itself** at the first connection, so no SQL script is needed.
* `ENCODING 'UTF8' … TEMPLATE template0`: `template0` is the clean template. It is
  required to choose an encoding or locale different from the template's.
* `REVOKE ALL … FROM PUBLIC`: by default every role may connect to every database. This
  limits `talend_tac` to the TAC user (and superusers).

Check:

```bash
su - postgres -c "psql -c '\l $TAC_DB'"
```

This shows owner `talend_tac`, encoding `UTF8` and collation `en_US.UTF-8`.

---

## Step 7: Checks

Login over TCP with the password, as TAC will do (type the password from 6.1):

```bash
psql -h 127.0.0.1 -U $TAC_USER -d $TAC_DB -c "select current_user, current_database(), version()"
```

* `-h 127.0.0.1` forces a **TCP** connection, so `scram-sha-256` (password) is used
  instead of `peer`.

Effective settings:

```bash
su - postgres -c "psql -Atc \"select name || ' = ' || setting || coalesce(' ' || unit, '') from pg_settings where name in ('listen_addresses','port','max_connections','shared_buffers','data_checksums','password_encryption')\""
```

* `shared_buffers` shows in 8kB pages: `65536 8kB` = 512MB.

From **vm_tac**, check that the port can be reached (bash only, no client needed):

```bash
docker exec vm_tac bash -c 'timeout 3 bash -c "</dev/tcp/vm-db/5432" && echo "vm-db:5432 reachable"'
```

From the **docker host** (any PostgreSQL client, pgAdmin, DBeaver…): host `localhost`,
port `5432` (`HOST_PORT_DB`), database `talend_tac`, user `talend_tac`.

### TAC configuration page

| Field | Value |
|---|---|
| Database type | PostgreSQL |
| Server / Port | `vm-db` / `5432` |
| Database | `talend_tac` |
| URL | `jdbc:postgresql://vm-db:5432/talend_tac` |
| User / Password | `talend_tac` / the password from 6.1 |

Use **`vm-db`** (hyphen), not `vm_db`: Java treats host names containing `_` as invalid.

---

## After a container recreate (`docker compose down` / `up`, rebuild)

The data, configuration, logs and enabled units are in volumes, but the PostgreSQL
**binaries** (`/usr/lib/postgresql`) are part of the container and are gone. Systemd
then shows the service as failed, because the program no longer exists.

Run Step 2 again (2.1 and 2.2), then start the service:

```bash
systemctl restart postgresql@18-main
```

Do **not** run Step 3 or Step 6 again: `pg_lsclusters` shows the existing cluster, and
the TAC database and its data are still there. (Running `install_db.sh` again does all
of this automatically and leaves the data alone.)

---

## Everyday commands

| Action | Command |
|---|---|
| Status / restart | `systemctl status postgresql@18-main` / `systemctl restart postgresql@18-main` |
| Reload config (no restart) | `systemctl reload postgresql@18-main` (enough for `pg_hba.conf` and most logging settings) |
| Clusters | `pg_lsclusters` |
| Logs | `tail -f /var/log/postgresql/postgresql-18-main.log` |
| psql as admin | `su - postgres -c psql` |
| Change the TAC password | `su - postgres -c "psql -c '\password talend_tac'"` (then update TAC) |
| Backup the TAC database | `su - postgres -c "pg_dump -Fc talend_tac" > /var/lib/postgresql/talend_tac.dump` |
| Restore | `su - postgres -c "pg_restore -d talend_tac --clean /var/lib/postgresql/talend_tac.dump"` |

> `shared_buffers`, `max_connections`, `listen_addresses` and `port` need a **restart**.
> Changes to `pg_hba.conf` only need a **reload**.
