# vm_jobserver: manual installation, step by step

This guide installs Talend JobServer on `vm_jobserver` by hand. It runs the same
steps as `scripts/vm_jobserver/install_jobserver.sh`, with the same paths and
settings, so you can use either one.

| Component | Location |
|---|---|
| Java 21 (Eclipse Temurin) | `/opt/talend/java/jdk-21.x`, symlinks `/opt/talend/java/jdk21` and `/opt/talend/java/default` |
| JobServer | `/opt/talend/jobserver/Talend-JobServer-20260708_1430-V8.0.1`, symlink `/opt/talend/jobserver/current` |
| Configuration | `<JobServer>/agent/conf/TalendJobServer.properties` (original kept as `.orig`) |
| systemd service | `/etc/systemd/system/talend-jobserver.service` (`talend:talend`) |
| Ports | 8000 command, 8001 file transfer, 8888 monitoring (published on the docker host) |

Everything is under `/opt/talend` (volume `jobserver_app`) and `/etc/systemd/system`
(volume `jobserver_systemd`), so the installation survives `docker compose down` / `up`.

> **What JobServer does.** TAC (and Talend Studio) deploy Jobs to the JobServer and
> start them there. The JobServer listens on the **command port** (orders from TAC),
> the **file transfer port** (Job archives, logs) and the **monitoring port** (CPU,
> memory and disk usage shown in TAC).

---

## Step 0: Open a root shell and set the variables

On the docker host:

```bash
docker exec -it vm_jobserver bash
```

Inside the container (run this block again if you open a new shell):

```bash
JAVA_MAJOR=21
JAVA_BASE=/opt/talend/java
JAVA_LINK=$JAVA_BASE/jdk$JAVA_MAJOR
JS_BASE=/opt/talend/jobserver
JS_LINK=$JS_BASE/current
JS_ZIP=$BINARY_PATH/$BINARY_JOBSERVER
WORK=/tmp/js-install
mkdir -p $WORK
```

* `BINARY_PATH` (`/opt/binary`) and `BINARY_JOBSERVER` (the JobServer zip name) come
  from `.env` through docker compose.
* `JS_LINK` (`current`) is a symlink that always has the same name. The service and the
  profile use it, so an upgrade only means pointing it at the new folder.

Check the prerequisites:

```bash
cat /proc/1/comm
```

This must print `systemd`.

```bash
id talend
```

This checks that the service account exists (created by the image, UID 1001).

```bash
ls -l "$JS_ZIP"
```

This checks that the binaries folder is mounted and the JobServer zip is visible.

```bash
install -d -o talend -g talend -m 0755 $JAVA_BASE $JS_BASE
```

This creates the folders, owned by `talend`.

---

## Step 1: Install Java 21 (Eclipse Temurin)

These are the same commands as on `vm_tac`. If Java 21 is already installed in this
container (`ls /opt/talend/java/jdk21/bin/java`), skip to 1.4.

### 1.1 Find the download URL

```bash
JDK_URL=$(curl -fsS -o /dev/null -w '%{redirect_url}' \
  "https://api.adoptium.net/v3/binary/latest/$JAVA_MAJOR/ga/linux/x64/jdk/hotspot/normal/eclipse")
echo $JDK_URL
```

* The Adoptium API answers with a **redirect** to the newest Java 21 release on
  GitHub. `-w '%{redirect_url}'` prints that target without following it.
* **Offline:** put the JDK `.tar.gz` in the binaries folder and use
  `JDK_TGZ=/opt/binary/OpenJDK21U-jdk_x64_linux_hotspot_<version>.tar.gz` (skip 1.1 and 1.2).

### 1.2 Download and check

```bash
JDK_TGZ=$WORK/jdk.tar.gz
curl -fSL -o $JDK_TGZ "$JDK_URL"
echo "$(curl -fsSL "$JDK_URL.sha256.txt" | awk '{print $1}')  $JDK_TGZ" | sha256sum -c
```

* The `.sha256.txt` file next to each release holds its SHA-256 hash. `sha256sum -c`
  recomputes it. **Stop if it does not print `OK`.**

### 1.3 Extract and create the symlink

```bash
JDK_DIR=$(tar -tzf $JDK_TGZ | sed -n '1{s|/.*||;p}')
tar -xzf $JDK_TGZ -C $JAVA_BASE
ln -sfn $JAVA_BASE/$JDK_DIR $JAVA_LINK
chown -R talend:talend $JAVA_BASE
$JAVA_LINK/bin/java -version
```

* `tar -t` lists the archive. The first entry's top folder is the JDK folder
  (`jdk-21.0.x+y`). `ln -sfn` creates or replaces the `jdk21` symlink.
* Expected: `openjdk version "21.0.x" ... LTS`.

### 1.4 Default Java of the container

```bash
ln -sfn $JAVA_LINK $JAVA_BASE/default
chown -h talend:talend $JAVA_BASE/default
```

* The image contains `/etc/profile.d/zz-talend-java.sh`. In every shell (login or not,
  root or `talend`) it sets `JAVA_HOME=/opt/talend/java/default` and puts it first in
  `PATH` **when this link exists**.
* Why it matters: `/home/talend` is **not** in a volume. After a container recreate,
  `~/.profile` is reset, but the image file and this link (in the volume) remain, so
  shells keep Java 21 instead of the image's Java 17.
* `chown -h` changes the owner of the **link itself**, not of its target.

---

## Step 2: JAVA_HOME and PATH for user talend

```bash
cat >> /home/talend/.profile <<'EOF'
# >>> talend java (install_jobserver.sh) >>>
export JAVA_HOME=/opt/talend/java/jdk21
export JOBSERVER_HOME=/opt/talend/jobserver/current
case ":$PATH:" in *":$JAVA_HOME/bin:"*) ;; *) export PATH="$JAVA_HOME/bin:$PATH" ;; esac
# <<< talend java (install_jobserver.sh) <<<
EOF
```

```bash
cat >> /home/talend/.bashrc <<'EOF'
# >>> talend java (install_jobserver.sh) >>>
export JAVA_HOME=/opt/talend/java/jdk21
export JOBSERVER_HOME=/opt/talend/jobserver/current
case ":$PATH:" in *":$JAVA_HOME/bin:"*) ;; *) export PATH="$JAVA_HOME/bin:$PATH" ;; esac
# <<< talend java (install_jobserver.sh) <<<
EOF
chown talend:talend /home/talend/.profile /home/talend/.bashrc
```

* `>>` **appends** a block (*here-document*). `'EOF'` in quotes keeps `$PATH` literal in
  the file, so it is expanded at each login.
* `~/.profile` is read by login shells (`su - talend`), and `~/.bashrc` by interactive
  non-login shells (`docker exec -u talend vm_jobserver bash`).
* `JOBSERVER_HOME` is a shortcut: `cd $JOBSERVER_HOME`.
* The markers match the script's, so the script replaces this block instead of adding
  another. Run this step **once** by hand.

Check:

```bash
su - talend -c 'echo $JAVA_HOME; java -version'
```

This must show Java 21.

---

## Step 3: Install the JobServer package

### 3.1 Unzip

```bash
unzip -q "$JS_ZIP" -d $WORK/pkg
ls $WORK/pkg
```

* The zip normally holds **one** top folder, `Talend-JobServer-20260708_1430-V8.0.1`.
  It is unzipped into a work folder first, so you can check its content before
  installing it.

```bash
JS_NAME=$(ls $WORK/pkg)
mv $WORK/pkg/$JS_NAME $JS_BASE/
ln -sfn $JS_BASE/$JS_NAME $JS_LINK
```

* If `ls` shows several entries instead of one folder, create the folder yourself:
  `JS_NAME=$(basename "$JS_ZIP" .zip); mkdir $JS_BASE/$JS_NAME; mv $WORK/pkg/* $JS_BASE/$JS_NAME/`.
* **Reinstall/upgrade:** move the existing folder aside first
  (`mv $JS_BASE/$JS_NAME $JS_BASE/$JS_NAME.bak-$(date +%Y%m%d)`), so its configuration
  stays available.

### 3.2 Find the start/stop scripts and the configuration

```bash
find $JS_LINK/ -maxdepth 3 -name 'start_rs.sh' -o -maxdepth 3 -name 'stop_rs.sh'
find $JS_LINK/ -maxdepth 4 -name 'TalendJobServer.properties'
```

* `start_rs.sh` starts the JobServer, `stop_rs.sh` stops it. `TalendJobServer.properties`
  holds its configuration (usually in `agent/conf/`).
* `$JS_LINK/` with a trailing `/`: `find` goes **into** the folder the symlink points to.
* Note the paths: the next steps use them. If they differ from the example below,
  adapt the commands.

```bash
START_SH=$JS_LINK/start_rs.sh
STOP_SH=$JS_LINK/stop_rs.sh
PROPS=$JS_LINK/agent/conf/TalendJobServer.properties
```

### 3.3 Permissions

```bash
find $JS_LINK/ -type f -name '*.sh' -exec chmod 0755 {} +
chown -R talend:talend $JS_BASE
```

* Zip files do not always keep the Unix "executable" permission. Without it,
  `start_rs.sh` cannot be run (`Permission denied`).
* `-exec … {} +` runs `chmod` once on all the files found.
* The JobServer runs as `talend` and writes into its own folder (Jobs, logs, temporary
  files), so `talend` must own it.

---

## Step 4: Configure TalendJobServer.properties

```bash
cp -p $PROPS $PROPS.orig
```

* Keep the original (`-p` keeps its date and permissions) to compare or roll back.

Look at the main settings:

```bash
grep -nE 'PORT|ROOT_PATH|SSL|USERS' $PROPS
```

* This shows the ports, the folders and the security settings of your version.
  The exact keys can vary between JobServer releases: always edit what this file
  contains, and do not add keys it does not have.

The ports must match what docker compose publishes (8000, 8001, 8888, 8555), which
are the JobServer defaults:

| Key (`org.talend.remote.jobserver.server.TalendJobServer.` + …) | Value | Used by |
|---|---|---|
| `COMMAND_SERVER_PORT` | 8000 | TAC sends deploy/run/stop orders |
| `FILE_SERVER_PORT` | 8001 | Job archive and log transfer |
| `MONITORING_PORT` | 8888 | CPU/RAM/disk monitoring in TAC |
| `PROCESS_MESSAGE_PORT` | 8555 | Messages from the running Jobs |

To set a key (here the command port), whether it is active or commented out:

```bash
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(org\.talend\.remote\.jobserver\.server\.TalendJobServer\.COMMAND_SERVER_PORT)[[:space:]]*=.*|\1=8000|' $PROPS
```

* `sed -i` edits the file in place. `-E` enables extended regular expressions.
* `^[[:space:]]*#?[[:space:]]*` matches the start of the line with or without a `#`,
  so a commented-out key is also enabled.
* `(…)` captures the key, and `\1=8000` writes it back with the new value. The dots are
  escaped (`\.`) because in a regular expression `.` means "any character".
* Repeat with `FILE_SERVER_PORT`, `MONITORING_PORT` and `PROCESS_MESSAGE_PORT` if you
  change them (and change the published ports in `docker-compose.yml` / `.env` too).

```bash
diff $PROPS.orig $PROPS
```

This shows exactly what you changed. No output means the file is unchanged.

---

## Step 5: systemd service (User=talend, Group=talend)

### 5.1 How start_rs.sh runs

```bash
grep -vE '^[[:space:]]*#' $START_SH
```

* This shows the script without its comments. Normally it runs `java …` in the
  **foreground** and keeps running as long as the JobServer does, so the service uses
  `Type=simple`.
* If you see `nohup` or a line ending with `&`, the script starts Java in the
  background and exits immediately. Then use `Type=forking` in the unit below.
  Otherwise systemd thinks the service has ended and stops the JobServer.

### 5.2 Create the unit file

```bash
cat > /etc/systemd/system/talend-jobserver.service <<EOF
[Unit]
Description=Talend JobServer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=talend
Group=talend
UMask=0027
Environment=JAVA_HOME=/opt/talend/java/jdk21
Environment=PATH=/opt/talend/java/jdk21/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$(dirname $START_SH)
ExecStart=$START_SH
ExecStop=$STOP_SH
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
```

* `<<EOF` **without** quotes: the shell fills in `$START_SH`, `$STOP_SH` and
  `$(dirname $START_SH)` (the folder of the script) while writing the file.
  `cat /etc/systemd/system/talend-jobserver.service` shows the result.

| Line | Meaning |
|---|---|
| `Type=simple` | systemd watches the process started by `ExecStart` (see 5.1). |
| `User=talend` / `Group=talend` | The JobServer **and the Jobs it starts** run as `talend:talend`, never as root. |
| `UMask=0027` | New files are `rw-r-----`: no access for other users. |
| `Environment=JAVA_HOME` / `PATH` | systemd does not read `.profile`. `start_rs.sh` calls `java` from `PATH`, so Java 21 must come first. |
| `WorkingDirectory` | `start_rs.sh` uses paths relative to its own folder. |
| `ExecStop=stop_rs.sh` | Clean stop through Talend's script. Remaining processes then get SIGTERM. Remove the line if your package has no `stop_rs.sh`. |
| `SuccessExitStatus=143` | Java exits with 143 (128 + SIGTERM) when stopped. This tells systemd that is not a failure. |
| `Restart=on-failure` | Restarts the JobServer 10 s after a crash, not after a normal stop. |
| `LimitNOFILE` / `LimitNPROC` | Limits for the JobServer and its Jobs (`limits.d` does not apply to services). |
| `WantedBy=multi-user.target` | `enable` makes it start with the container. |

### 5.3 Enable and start

```bash
systemctl daemon-reload
systemctl enable --now talend-jobserver
```

* `daemon-reload` makes systemd read the new unit (needed after every edit).
* `enable --now` enables it at boot **and** starts it now.

---

## Step 6: Checks

```bash
systemctl status talend-jobserver --no-pager
```

Expect `Active: active (running)` and `enabled`.

```bash
ss -ltnp | grep -E ':(8000|8001|8888|8555) '
```

* `ss` lists the listening TCP sockets (`-l` listening, `-t` TCP, `-n` numeric,
  `-p` process). Ports 8000, 8001 and 8888 must appear with a `java` process. Some
  versions only open 8555 while a Job runs.

```bash
ps -o user,group,cmd -C java
```

The JobServer runs as `talend talend`.

```bash
readlink -f /proc/$(pgrep -n -u talend java)/exe
```

* `pgrep -n -u talend java` gives the PID of the newest `java` process of `talend`.
  `/proc/<pid>/exe` is a link to the program it runs, and `readlink -f` resolves it.
  Expected: `/opt/talend/java/jdk-21.x/bin/java`. `ps` only shows `java`, because
  `start_rs.sh` finds it through `PATH`.

```bash
journalctl -u talend-jobserver -f
```

This follows the JobServer output live (Ctrl+C to quit).

From **vm_tac**, check that TAC can reach the ports:

```bash
docker exec vm_tac bash -c 'for p in 8000 8001 8888; do timeout 3 bash -c "</dev/tcp/vm-jobserver/$p" && echo "vm-jobserver:$p reachable"; done'
```

Clean up:

```bash
rm -rf /tmp/js-install
```

### Register the JobServer in TAC

In TAC: **Servers > Add**.

| Field | Value |
|---|---|
| Label | `vm_jobserver` (free text) |
| Host | `vm-jobserver` (hyphen, not `_`) |
| Command port | 8000 |
| File transfer port | 8001 |
| Monitoring port | 8888 |

If TLS is enabled on the JobServer (see the SSL key in `TalendJobServer.properties`),
enable the matching option on the server in TAC.

---

## Everyday commands

| Action | Command |
|---|---|
| Stop / start / restart | `systemctl stop\|start\|restart talend-jobserver` |
| Change a setting | edit `TalendJobServer.properties`, then `systemctl restart talend-jobserver` |
| Change the unit | edit it, then `systemctl daemon-reload && systemctl restart talend-jobserver` |
| Logs since the last boot | `journalctl -u talend-jobserver -b` |
| Shell as talend | `su - talend` (or from the host: `docker exec -it -u talend vm_jobserver bash -l`) |
