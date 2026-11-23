# vm_runtime: Talend Runtime, manual installation step by step

This guide installs Talend Runtime on `vm_runtime` by hand. It runs the same steps
as `scripts/vm_runtime/install_runtime.sh`, with the same paths and settings, so you
can use either one.

| Component | Location |
|---|---|
| Java 21 (Eclipse Temurin) | `/opt/talend/java/jdk-21.x`, symlinks `/opt/talend/java/jdk21` and `/opt/talend/java/default` |
| Talend Runtime | `/opt/talend/runtime/Talend-Runtime-V8.0.2.R2026-06-RT`, symlink `/opt/talend/runtime/current` |
| Configuration | `<Runtime>/etc/` (originals kept as `*.orig`), `<Runtime>/bin/setenv` |
| systemd service | `/etc/systemd/system/talend-runtime.service` (`talend:talend`) |
| Logs | `<Runtime>/log/` and `journalctl -u talend-runtime` |

Everything is under `/opt/talend` (volume `runtime_app`) and `/etc/systemd/system`
(volume `runtime_systemd`), so the installation survives `docker compose down` / `up`.

> **What Talend Runtime is.** It is an **Apache Karaf** OSGi container. Talend Routes
> and Data Services (REST/SOAP) are deployed into it as *features* and *bundles*,
> often from Nexus through TAC's ESB Conductor. `bin/trun` is Talend's Karaf launcher.
> The settings are plain text files in `etc/`.

| Port | Use | Config file / key |
|---|---|---|
| 8040 / 9001 | HTTP / HTTPS: the REST and SOAP services | `etc/org.ops4j.pax.web.cfg`: `org.osgi.service.http.port` / `.port.secure` |
| 8101 | SSH console (Karaf shell) | `etc/org.apache.karaf.shell.cfg`: `sshPort`, `sshHost` |
| 1099 / 44444 | JMX (RMI registry / server): monitoring, TAC | `etc/org.apache.karaf.management.cfg`: `rmiRegistryPort`, `rmiServerPort`, `rmiRegistryHost`, `rmiServerHost` |

---

## Step 0: Open a root shell and set the variables

On the docker host:

```bash
docker exec -it vm_runtime bash
```

Inside the container (run this block again if you open a new shell):

```bash
JAVA_MAJOR=21
JAVA_BASE=/opt/talend/java
JAVA_LINK=$JAVA_BASE/jdk$JAVA_MAJOR
RT_BASE=/opt/talend/runtime
RT_LINK=$RT_BASE/current
RT_ZIP=$BINARY_PATH/$BINARY_RUNTIME
WORK=/tmp/rt-install
mkdir -p $WORK
```

* `BINARY_PATH` (`/opt/binary`) and `BINARY_RUNTIME` (the Runtime zip name) come from
  `.env` through docker compose.
* `RT_LINK` (`current`) is a symlink that always has the same name. The service and the
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
ls -l "$RT_ZIP"
```

This checks that the binaries folder is mounted and the Runtime zip is visible.

```bash
install -d -o talend -g talend -m 0755 $JAVA_BASE $RT_BASE
```

This creates the folders, owned by `talend`.

---

## Step 1: Install Java 21 (Eclipse Temurin)

These are the same commands as on `vm_tac` and `vm_jobserver`. If Java 21 is already
installed in this container (`ls /opt/talend/java/jdk21/bin/java`), skip to 1.4.

### 1.1 Find the download URL

```bash
JDK_URL=$(curl -fsS -o /dev/null -w '%{redirect_url}' \
  "https://api.adoptium.net/v3/binary/latest/$JAVA_MAJOR/ga/linux/x64/jdk/hotspot/normal/eclipse")
echo $JDK_URL
```

* The Adoptium API answers with a **redirect** to the newest Java 21 release on GitHub.
  `-w '%{redirect_url}'` prints that target without following it.
* **Offline:** put the JDK `.tar.gz` in the binaries folder and use
  `JDK_TGZ=/opt/binary/OpenJDK21U-jdk_x64_linux_hotspot_<version>.tar.gz` (skip 1.1 and 1.2).

### 1.2 Download and check

```bash
JDK_TGZ=$WORK/jdk.tar.gz
curl -fSL -o $JDK_TGZ "$JDK_URL"
echo "$(curl -fsSL "$JDK_URL.sha256.txt" | awk '{print $1}')  $JDK_TGZ" | sha256sum -c
```

* `sha256sum -c` recomputes the hash published next to the release. **Stop if it does
  not print `OK`.**

### 1.3 Extract and create the symlink

```bash
JDK_DIR=$(tar -tzf $JDK_TGZ | sed -n '1{s|/.*||;p}')
tar -xzf $JDK_TGZ -C $JAVA_BASE
ln -sfn $JAVA_BASE/$JDK_DIR $JAVA_LINK
chown -R talend:talend $JAVA_BASE
$JAVA_LINK/bin/java -version
```

* Expected: `openjdk version "21.0.x" ... LTS`.

### 1.4 Default Java of the container

```bash
ln -sfn $JAVA_LINK $JAVA_BASE/default
chown -h talend:talend $JAVA_BASE/default
```

* `/etc/profile.d/zz-talend-java.sh` (in the image) puts `/opt/talend/java/default`
  first in every shell when this link exists. Shells keep Java 21 after a container
  recreate, even though `/home/talend` is reset.

---

## Step 2: JAVA_HOME and PATH for user talend

```bash
cat >> /home/talend/.profile <<'EOF'
# >>> talend java (install_runtime.sh) >>>
export JAVA_HOME=/opt/talend/java/jdk21
export KARAF_HOME=/opt/talend/runtime/current
case ":$PATH:" in *":$JAVA_HOME/bin:"*) ;; *) export PATH="$JAVA_HOME/bin:$PATH" ;; esac
# <<< talend java (install_runtime.sh) <<<
EOF
```

```bash
cat >> /home/talend/.bashrc <<'EOF'
# >>> talend java (install_runtime.sh) >>>
export JAVA_HOME=/opt/talend/java/jdk21
export KARAF_HOME=/opt/talend/runtime/current
case ":$PATH:" in *":$JAVA_HOME/bin:"*) ;; *) export PATH="$JAVA_HOME/bin:$PATH" ;; esac
# <<< talend java (install_runtime.sh) <<<
EOF
chown talend:talend /home/talend/.profile /home/talend/.bashrc
```

* `>>` **appends** the block. `'EOF'` in quotes keeps `$PATH` literal in the file.
* `KARAF_HOME` is the standard Karaf variable for the installation folder. The Karaf
  scripts also work it out themselves.
* The markers match the script's, so the script replaces this block instead of adding
  another. Run this step **once** by hand.

```bash
su - talend -c 'echo $JAVA_HOME; java -version'
```

This must show Java 21.

---

## Step 3: Install the Runtime package

### 3.1 Unzip and find the Karaf home

```bash
unzip -q "$RT_ZIP" -d $WORK/pkg
find $WORK/pkg -maxdepth 4 -path '*/bin/trun'
```

* The **Karaf home** is the folder that contains `bin/trun` (with `etc/`, `deploy/`,
  `lib/`, `system/` next to it). Normally it is the zip's top folder,
  `Talend-Runtime-V8.0.2.R2026-06-RT`. `find` shows where it is in your package.

```bash
TRUN=$(find $WORK/pkg -maxdepth 4 -path '*/bin/trun' | sed -n 1p)
RT_SRC=$(dirname $(dirname $TRUN))
RT_NAME=$(basename $RT_SRC)
echo "$RT_SRC -> $RT_BASE/$RT_NAME"
```

* `dirname` removes the last part of a path, twice: `…/bin/trun` → `…/bin` → `…` (the
  Karaf home). `basename` keeps the last part (the folder name).

```bash
mv $RT_SRC $RT_BASE/
ln -sfn $RT_BASE/$RT_NAME $RT_LINK
```

* **Reinstall/upgrade:** first move the existing folder aside
  (`mv $RT_BASE/$RT_NAME $RT_BASE/$RT_NAME.bak-$(date +%Y%m%d)`). It holds your
  configuration and the deployed features (`etc/`, `deploy/`, `data/`).

### 3.2 Permissions

```bash
find $RT_LINK/bin -maxdepth 1 -type f ! -name '*.bat' -exec chmod 0755 {} +
chown -R talend:talend $RT_BASE
```

* Zip files do not always keep the Unix "executable" permission. `bin/trun`, `start`,
  `stop` and `client` must be executable. The Windows `.bat` files are left alone.
* Karaf writes into its own folder (`data/` cache, `log/`, `deploy/`), so `talend` must
  own it.

---

## Step 4: Configure the Runtime

### 4.1 Keep the originals

```bash
cd $RT_LINK
for f in etc/org.ops4j.pax.web.cfg etc/org.apache.karaf.shell.cfg etc/org.apache.karaf.management.cfg etc/users.properties bin/setenv; do [ -f $f.orig ] || cp -p $f $f.orig; done
```

* `[ -f $f.orig ] || cp …`: a copy is made only if none exists yet, so the **first**
  original is never overwritten when you run this again.

Look at the current values:

```bash
grep -HnE '^[[:space:]]*#?[[:space:]]*(org\.osgi\.service\.http\.port|sshPort|sshHost|rmiRegistryPort|rmiServerPort|rmiRegistryHost|rmiServerHost)[[:space:]]*=' etc/*.cfg
```

* `-H` prints the file name, `-n` the line number. The regular expression also shows
  commented-out keys (`#?`).

### 4.2 Ports and listen addresses

One `sed` command per key. Each one works whether the key is active or commented out:

```bash
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(org\.osgi\.service\.http\.port)[[:space:]]*=.*|\1 = 8040|' etc/org.ops4j.pax.web.cfg
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(org\.osgi\.service\.http\.port\.secure)[[:space:]]*=.*|\1 = 9001|' etc/org.ops4j.pax.web.cfg
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(sshPort)[[:space:]]*=.*|\1 = 8101|' etc/org.apache.karaf.shell.cfg
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(sshHost)[[:space:]]*=.*|\1 = 0.0.0.0|' etc/org.apache.karaf.shell.cfg
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(rmiRegistryPort)[[:space:]]*=.*|\1 = 1099|' etc/org.apache.karaf.management.cfg
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(rmiServerPort)[[:space:]]*=.*|\1 = 44444|' etc/org.apache.karaf.management.cfg
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(rmiRegistryHost)[[:space:]]*=.*|\1 = 0.0.0.0|' etc/org.apache.karaf.management.cfg
sed -i -E 's|^[[:space:]]*#?[[:space:]]*(rmiServerHost)[[:space:]]*=.*|\1 = 0.0.0.0|' etc/org.apache.karaf.management.cfg
```

* `sed -i -E 's|…|…|'` edits in place with extended regular expressions. `|` is used as
  the separator instead of `/`, so paths and values never need escaping.
* `^[[:space:]]*#?[[:space:]]*(key)[[:space:]]*=.*` matches the whole line of the key,
  commented out or not. `\1 = value` writes back the key (group 1) with the new value.
  Dots in key names are escaped (`\.`), because `.` alone means "any character".
* The ports are the Karaf/Talend defaults, the same ones docker compose publishes.
  Only change them together with `docker-compose.yml` / `.env`.
* **`0.0.0.0` (all interfaces) for SSH and JMX:** Karaf 4 binds JMX to `127.0.0.1` by
  default, which other containers and the docker host cannot reach. TAC needs JMX to
  monitor the Runtime. HTTP (Pax Web) already listens on all interfaces.
* A key that is not in your file is simply not changed. Do not add keys this version
  does not know.

```bash
diff etc/org.apache.karaf.management.cfg.orig etc/org.apache.karaf.management.cfg
```

This shows the changes (repeat for the other files).

### 4.3 Java and memory: bin/setenv

```bash
cat >> bin/setenv <<'EOF'
# >>> talend (install_runtime.sh) >>>
export JAVA_HOME=/opt/talend/java/jdk21
export JAVA_MIN_MEM=512M
export JAVA_MAX_MEM=2048M
# <<< talend (install_runtime.sh) <<<
EOF
```

* `bin/setenv` is read by `bin/trun`, `start`, `stop` and `client`, so every way of
  starting the Runtime (systemd or a shell) uses the same Java and memory.
* `JAVA_MIN_MEM` / `JAVA_MAX_MEM` become `-Xms` / `-Xmx` (start / max heap). Raise
  `JAVA_MAX_MEM` when many Routes or Services are deployed.
* The block is **appended at the end**, so it wins over any value set earlier in the file.

---

## Step 5: Admin password (etc/users.properties)

```bash
grep -vE '^[[:space:]]*(#|$)' etc/users.properties
```

* Each line is `user = password,roles`. Lines starting with `_g_\:` define **groups**
  (`_g_:admingroup = group,admin,manager,…`), and users get their roles by belonging
  to a group.
* Talend ships default accounts whose password **equals the user name** (for example
  `tadmin = tadmin,_g_:admingroup`). **Change them** before exposing the Runtime.

Set a new password for `tadmin`, keeping its roles:

```bash
read -r -s -p "New password for tadmin: " RT_PW; echo
sed -i -E "s|^([[:space:]]*tadmin[[:space:]]*=[[:space:]]*)[^,]*|\1${RT_PW}|" etc/users.properties
unset RT_PW
chmod 0640 etc/users.properties
```

* `read -s` reads the password without showing it, so it is not in the shell history.
  `unset` removes it from the shell afterwards.
* `([[:space:]]*tadmin[[:space:]]*=[[:space:]]*)[^,]*`: group 1 is `tadmin = `, and
  `[^,]*` is the password, which is everything **up to the first comma**. Only the
  password is replaced; `,_g_:admingroup` stays.
* Do not use spaces, `,`, `\`, `|` or `&` in the password: they have a meaning in this
  file or in the `sed` command.
* `chmod 0640`: passwords are stored in plain text, so other users get no access.
* Repeat for every other default account you see (for example `tesb`), or delete the
  lines of accounts you do not use.
* Karaf reloads `users.properties` by itself. A restart is not required.

---

## Step 6: systemd service (User=talend, Group=talend)

```bash
chown -R talend:talend $RT_BASE
cat > /etc/systemd/system/talend-runtime.service <<'EOF'
[Unit]
Description=Talend Runtime (Apache Karaf)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=talend
Group=talend
UMask=0027
Environment=JAVA_HOME=/opt/talend/java/jdk21
Environment=JAVA_MIN_MEM=512M
Environment=JAVA_MAX_MEM=2048M
Environment=KARAF_HOME=/opt/talend/runtime/current
Environment=PATH=/opt/talend/java/jdk21/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=/opt/talend/runtime/current
ExecStart=/opt/talend/runtime/current/bin/trun server
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
```

| Line | Meaning |
|---|---|
| `ExecStart=… bin/trun server` | `server` runs Karaf in the **foreground without an interactive console** (the console needs a terminal, which a service does not have). `Type=simple`: systemd watches this process. |
| `User=talend` / `Group=talend` | Karaf and everything it runs use `talend:talend`, never root. |
| `UMask=0027` | New files are `rw-r-----`. |
| `Environment=` | systemd does not read `.profile`. Java and memory are also set here, in case `bin/setenv` changes. |
| `WorkingDirectory` | The Karaf home, so relative paths resolve from it. |
| `SuccessExitStatus=0 143` | On `systemctl stop`, systemd sends SIGTERM and Karaf shuts down cleanly. Java then exits with 143 (128 + SIGTERM), which counts as success here. |
| `TimeoutStartSec=180` / `TimeoutStopSec=120` | The first start installs the features (slow). A stop waits for the Routes to end. |
| `Restart=on-failure` | Restarts after a crash, not after a normal stop. |
| `LimitNOFILE=65536` | Karaf opens many files (bundles, sockets). |

> Talend also documents the Karaf **wrapper** feature (`feature:install wrapper`,
> `wrapper:install`) to create a service. This unit replaces it: it is simpler, and it
> lives in the persisted `/etc/systemd/system`.

```bash
systemctl daemon-reload
systemctl enable --now talend-runtime
```

* `daemon-reload` reads the new unit. `enable --now` enables it at boot and starts it now.

---

## Step 7: Checks

```bash
systemctl status talend-runtime --no-pager
```

Expect `Active: active (running)` and `enabled`.

```bash
ss -ltnp | grep -E ':(8040|8101|1099|44444) '
```

* Ports 8040 (HTTP), 8101 (SSH) and 1099 (JMX) must show a `java` process. The first
  start can take one or two minutes. Run it again if a port is still missing.
* `0.0.0.0:1099` (not `127.0.0.1:1099`) confirms that 4.2 worked.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8040/services
```

* Any HTTP code (`200`, or `404` while nothing is deployed) means the HTTP server
  answers. `000` means it does not answer (yet).

```bash
ls $RT_LINK/log/
```

```bash
tail -50 $RT_LINK/log/tesb.log
```

* Karaf's log (`tesb.log` in Talend Runtime, `karaf.log` in plain Karaf). Errors
  during the first start show here.

Karaf console as `talend` (type `logout` or Ctrl+D to quit):

```bash
su - talend -c "$RT_LINK/bin/client"
```

* `bin/client` connects to the running Runtime over SSH (port 8101). Useful commands:
  `feature:list -i` (installed features), `bundle:list` (bundles and their state),
  `log:tail` (live log), `system:version`.
* From another machine: `ssh -p 8101 tadmin@<docker host>` with the password from Step 5.

From **vm_tac**, check that TAC can reach the Runtime:

```bash
docker exec vm_tac bash -c 'for p in 8040 8101 1099; do timeout 3 bash -c "</dev/tcp/vm-runtime/$p" && echo "vm-runtime:$p reachable"; done'
```

Clean up:

```bash
rm -rf /tmp/rt-install
```

### In TAC

In TAC (**ESB Conductor**, **ESB Infrastructure**), declare the Runtime with host
`vm-runtime` (hyphen, not `_`), SSH port 8101 and JMX port 1099, and the `tadmin`
user. ESB Conductor deploys features from **Nexus**, so the Runtime must also be able
to reach `vm-nexus:8081`.

---

## Everyday commands

| Action | Command |
|---|---|
| Stop / start / restart | `systemctl stop\|start\|restart talend-runtime` |
| Console | `su - talend -c /opt/talend/runtime/current/bin/client` |
| Live log | `tail -f /opt/talend/runtime/current/log/tesb.log` |
| Change memory | edit the block in `bin/setenv` **and** the unit, then `systemctl daemon-reload && systemctl restart talend-runtime` |
| Change a port | edit `etc/*.cfg` (Karaf applies most changes live; restart to be sure) |
| Deploy a bundle/feature by hand | copy the `.jar` / `.kar` into `/opt/talend/runtime/current/deploy/` |
| Clean the cache (after a failed upgrade) | `systemctl stop talend-runtime && rm -rf /opt/talend/runtime/current/data/cache && systemctl start talend-runtime` |
