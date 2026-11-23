# vm_tac: manual installation, step by step

This guide installs Talend Administration Center on `vm_tac` by hand. It runs the
same steps as `scripts/vm_tac/install_tac.sh`, with the same paths and settings,
so you can use either one, or follow the guide to understand what the script does.

| Component | Location |
|---|---|
| Java 21 (Eclipse Temurin) | `/opt/talend/java/jdk-21.x`, symlink `/opt/talend/java/jdk21` |
| Tomcat 11.0.29 | `/opt/talend/tac/apache-tomcat-11.0.29`, symlink `/opt/talend/tac/tomcat` |
| TAC web application | `/opt/talend/tac/tomcat/webapps/ROOT`, at `http://localhost:8080/` |
| systemd service | `/etc/systemd/system/talend-tac.service` (`talend:talend`) |

Everything is under `/opt/talend` (volume `tac_app`) and `/etc/systemd/system`
(volume `tac_systemd`), so the installation survives `docker compose down` / `up`.

---

## Step 0: Open a root shell and set the variables

On the docker host:

```bash
docker exec -it vm_tac bash
```

* `docker exec` runs a command in a running container. `-it` gives you an
  interactive terminal. With no `-u`, you are **root**, which you need for
  installing and creating the systemd unit.

Inside the container, define the variables used by every later command.
**If you open a new shell, run this block again.**

```bash
JAVA_MAJOR=21
TOMCAT_VERSION=11.0.29
TAC_USER=talend
TAC_GROUP=talend
JAVA_BASE=/opt/talend/java
JAVA_LINK=$JAVA_BASE/jdk$JAVA_MAJOR
TAC_HOME=/opt/talend/tac
CATALINA_HOME=$TAC_HOME/apache-tomcat-$TOMCAT_VERSION
TOMCAT_LINK=$TAC_HOME/tomcat
TAC_ZIP=$BINARY_PATH/$BINARY_TAC
WORK=/tmp/tac-install
mkdir -p $WORK
```

* `BINARY_PATH` (`/opt/binary`) and `BINARY_TAC` (the TAC zip name) come from
  `.env` through docker compose. They are already set in the container.
* `JAVA_LINK` and `TOMCAT_LINK` are **symlinks** that never change name. The
  service and `.profile` use these, so a later upgrade only means pointing the
  symlink at the new folder.

Check the prerequisites:

```bash
cat /proc/1/comm
```

This must print `systemd`. If it doesn't, systemd is not PID 1 and services can't be enabled.

```bash
id talend
```

This checks that the service account exists (the image creates it, UID 1001).

```bash
ls -l "$TAC_ZIP"
```

This checks that the Windows binaries folder is mounted and that the TAC zip is visible.
`No such file` means `BINARY_HOST_PATH` or `BINARY_TAC` in `.env` is wrong.

```bash
install -d -o talend -g talend -m 0755 $JAVA_BASE $TAC_HOME
```

* `install -d` creates the folders, like `mkdir -p`, and sets the owner (`-o`/`-g`)
  and permissions (`-m 0755`: the owner can write, everyone can read) in one command.

---

## Step 1: Install Java 21 (Eclipse Temurin)

### 1.1 Find the download URL

```bash
JDK_URL=$(curl -fsS -o /dev/null -w '%{redirect_url}' \
  "https://api.adoptium.net/v3/binary/latest/$JAVA_MAJOR/ga/linux/x64/jdk/hotspot/normal/eclipse")
echo $JDK_URL
```

* The Adoptium API always answers with a **redirect** to the newest Java 21 release
  on GitHub. `-w '%{redirect_url}'` prints that target without following it, and
  `-o /dev/null` throws away the response body.
* curl flags: `-f` fails on HTTP errors (404, 500…), `-s` is silent, and `-S` still
  shows the error message if something fails.
* Expected value: `https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.x+y/OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz`
* **Offline:** skip 1.1 and 1.2, copy the JDK `.tar.gz` into the Windows binaries
  folder, and use `JDK_TGZ=/opt/binary/OpenJDK21U-jdk_x64_linux_hotspot_<version>.tar.gz`.

### 1.2 Download and check the archive

```bash
JDK_TGZ=$WORK/jdk.tar.gz
curl -fSL -o $JDK_TGZ "$JDK_URL"
```

* `-L` follows redirects (GitHub redirects again to its storage).
* `-o` saves the file under the given name.

```bash
echo "$(curl -fsSL "$JDK_URL.sha256.txt" | awk '{print $1}')  $JDK_TGZ" | sha256sum -c
```

* Each Temurin release has a `.sha256.txt` file next to it. `awk '{print $1}'`
  keeps only the hash (first column).
* `sha256sum -c` reads `<hash>  <file>` (**two** spaces) and recomputes the hash.
  `jdk.tar.gz: OK` means the file is complete and unchanged. **Stop if it says `FAILED`.**

### 1.3 Extract and create the symlink

```bash
JDK_DIR=$(tar -tzf $JDK_TGZ | sed -n '1{s|/.*||;p}')
echo $JDK_DIR
```

* `tar -t` **lists** the archive without extracting it (`-z` for gzip, `-f` for the file).
  The first entry's top folder is the JDK folder name, for example `jdk-21.0.13.1+2`.
* `sed -n '1{s|/.*||;p}'`: on line 1 only, delete everything from the first `/`, then print.

```bash
tar -xzf $JDK_TGZ -C $JAVA_BASE
ln -sfn $JAVA_BASE/$JDK_DIR $JAVA_LINK
chown -R talend:talend $JAVA_BASE
```

* `tar -x` extracts. `-C` sets the target folder.
* `ln -s` creates a symbolic link. `-f` replaces it if it exists, and `-n` replaces
  the link itself instead of creating a link *inside* the folder it points to.
* `chown -R` gives the whole tree to `talend` (recursive).

Check:

```bash
$JAVA_LINK/bin/java -version
```

This must print `openjdk version "21.0.x" ... LTS`.

> **Why not `apt install temurin-21-jdk`?** An apt package goes into `/usr`, which is
> part of the container, not a volume. After `docker compose down` / `up` it would be
> gone, and Tomcat would no longer start. `/opt/talend` is persisted.

---

## Step 2: JAVA_HOME and PATH for user talend

```bash
cat >> /home/talend/.profile <<'EOF'
# >>> talend java (install_tac.sh) >>>
export JAVA_HOME=/opt/talend/java/jdk21
export CATALINA_HOME=/opt/talend/tac/tomcat
case ":$PATH:" in *":$JAVA_HOME/bin:"*) ;; *) export PATH="$JAVA_HOME/bin:$PATH" ;; esac
# <<< talend java (install_tac.sh) <<<
EOF
```

```bash
cat >> /home/talend/.bashrc <<'EOF'
# >>> talend java (install_tac.sh) >>>
export JAVA_HOME=/opt/talend/java/jdk21
export CATALINA_HOME=/opt/talend/tac/tomcat
case ":$PATH:" in *":$JAVA_HOME/bin:"*) ;; *) export PATH="$JAVA_HOME/bin:$PATH" ;; esac
# <<< talend java (install_tac.sh) <<<
EOF
```

```bash
chown talend:talend /home/talend/.profile /home/talend/.bashrc
```

* `cat >> file <<'EOF' … EOF` **appends** the text between the markers to the file
  (a *here-document*). The quotes around `'EOF'` stop the shell from expanding `$PATH`
  now, so the file contains the literal text and `$PATH` is expanded at each login.
* `~/.profile` is read by **login** shells (`su - talend`, `bash -l`, ssh).
  `~/.bashrc` is read by **interactive non-login** shells (`docker exec -u talend vm_tac bash`).
  Both are needed to cover every way of opening a shell.
* The `case` line adds `$JAVA_HOME/bin` to the **front** of `PATH` only if it isn't
  already there, so reloading the file doesn't add it twice. Being first, it wins over
  the Java 17 that ships in the image.
* The `>>>` / `<<<` markers are the ones the script uses. If you run the script later,
  it replaces this block instead of adding a second copy.
* Run this step only **once** by hand: `>>` appends every time.

Check:

```bash
su - talend -c 'echo $JAVA_HOME; java -version'
```

This must print `/opt/talend/java/jdk21` and Java 21.

---

## Step 3: Install Apache Tomcat 11.0.29

### 3.1 Download and check

```bash
TOMCAT_URL=https://archive.apache.org/dist/tomcat/tomcat-11/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz
TOMCAT_TGZ=$WORK/apache-tomcat-$TOMCAT_VERSION.tar.gz
curl -fSL -o $TOMCAT_TGZ $TOMCAT_URL
```

* `archive.apache.org` keeps **every** Tomcat version. The `dlcdn.apache.org` mirror
  only keeps the latest ones, so a fixed version like 11.0.29 would eventually
  disappear from there.
* **Offline:** use `TOMCAT_TGZ=/opt/binary/apache-tomcat-11.0.29.tar.gz` and skip the download.

```bash
echo "$(curl -fsSL $TOMCAT_URL.sha512 | awk '{print $1}')  $TOMCAT_TGZ" | sha512sum -c
```

* Same check as for Java, but Apache publishes a **SHA-512** hash. Expect `OK`.

### 3.2 Extract, create the symlink, remove the default apps

```bash
tar -xzf $TOMCAT_TGZ -C $TAC_HOME
ln -sfn $CATALINA_HOME $TOMCAT_LINK
rm -rf $CATALINA_HOME/webapps/{ROOT,docs,examples,manager,host-manager}
```

* The archive creates `apache-tomcat-11.0.29/` in `/opt/talend/tac`.
* `{ROOT,docs,…}` is **brace expansion**: bash turns it into five paths.
* The default apps are removed for two reasons. `ROOT` must be free for TAC, and
  `manager` / `examples` are a security risk if they stay exposed.

### 3.3 HTTP port

```bash
grep -n 'Connector port=' $CATALINA_HOME/conf/server.xml
```

* This shows the HTTP connector (`port="8080" protocol="HTTP/1.1"`). 8080 is what
  docker compose publishes (`HOST_PORT_TAC_HTTP` → 8080), so **no change is needed**.
  To use another port inside the container:
  `sed -i 's|<Connector port="8080"|<Connector port="9080"|' $CATALINA_HOME/conf/server.xml`
  (and change the container port in `docker-compose.yml`).

### 3.4 JVM settings: bin/setenv.sh

```bash
cat > $CATALINA_HOME/bin/setenv.sh <<'EOF'
#!/bin/sh
# JVM settings for Talend Administration Center
JAVA_HOME="/opt/talend/java/jdk21"
CATALINA_PID="${CATALINA_BASE}/temp/tomcat.pid"
CATALINA_OPTS="${CATALINA_OPTS} -Xms1g -Xmx4g"
CATALINA_OPTS="${CATALINA_OPTS} -Dfile.encoding=UTF-8 -Djava.awt.headless=true"
CATALINA_OPTS="${CATALINA_OPTS} -Djava.security.egd=file:/dev/./urandom"
export JAVA_HOME CATALINA_PID CATALINA_OPTS
EOF
chmod 0750 $CATALINA_HOME/bin/setenv.sh
```

* `catalina.sh` loads `bin/setenv.sh` automatically at each start. This is the place
  Tomcat recommends for your settings, so `catalina.sh` itself stays untouched.
* `JAVA_HOME`: makes Tomcat use Java 21 whatever the caller's environment is.
* `-Xms1g -Xmx4g`: starting and maximum heap. Size `-Xmx` to the TAC load and the
  RAM given to Docker Desktop.
* `-Dfile.encoding=UTF-8`: stable encoding for logs and files. `-Djava.awt.headless=true`:
  no graphical display in a container.
* `-Djava.security.egd=file:/dev/./urandom`: faster startup in containers, where the
  entropy source can block.
* `CATALINA_OPTS` (unlike `JAVA_OPTS`) only applies to the running server, not to `shutdown.sh`.
* `chmod 0750`: the owner can read, write and run it, the group can read and run it,
  others have no access.

---

## Step 4: Deploy TAC as the ROOT application

### 4.1 Unzip the TAC package and find the war

```bash
rm -rf $TAC_HOME/distrib && mkdir -p $TAC_HOME/distrib
unzip -q "$TAC_ZIP" -d $TAC_HOME/distrib
WAR=$(find $TAC_HOME/distrib -type f -iname 'org.talend.administrator*.war')
echo "$WAR"
```

* The TAC zip contains the war plus other material (documentation, tools, database
  scripts). It is kept in `/opt/talend/tac/distrib` for reference.
* `unzip -q` is quiet, `-d` sets the target folder.
* `find -iname` searches without caring about case. **`echo` must print exactly one path.**

### 4.2 Deploy as ROOT (exploded)

```bash
rm -rf $CATALINA_HOME/webapps/ROOT $CATALINA_HOME/webapps/ROOT.war $CATALINA_HOME/work/Catalina/localhost/ROOT
mkdir -p $CATALINA_HOME/webapps/ROOT
unzip -q "$WAR" -d $CATALINA_HOME/webapps/ROOT
chown -R talend:talend $TAC_HOME
```

* In Tomcat, the application in `webapps/ROOT` answers on `/`: TAC is at
  `http://localhost:8080/` instead of `/org.talend.administrator`.
* A war is a zip file. Unzipping it yourself (an *exploded* deployment) instead of
  copying `ROOT.war` lets you edit `WEB-INF/classes/configuration.properties` in
  place, and Tomcat never re-extracts the war over your changes.
* `work/Catalina/localhost/ROOT` holds Tomcat's compiled JSP cache. Clearing it avoids
  stale pages after a redeploy.
* `chown -R talend:talend`: Tomcat runs as `talend` and must be able to write `logs/`,
  `temp/`, `work/` and the TAC configuration.

> **Re-deploying overwrites `configuration.properties`.** Back it up first:
> `cp $CATALINA_HOME/webapps/ROOT/WEB-INF/classes/configuration.properties /opt/talend/tac/`

---

## Step 5: systemd service (User=talend, Group=talend)

### 5.1 Create the unit file

```bash
cat > /etc/systemd/system/talend-tac.service <<'EOF'
[Unit]
Description=Talend Administration Center (Apache Tomcat 11.0.29)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=talend
Group=talend
UMask=0027
Environment=JAVA_HOME=/opt/talend/java/jdk21
Environment=CATALINA_HOME=/opt/talend/tac/tomcat
Environment=CATALINA_BASE=/opt/talend/tac/tomcat
WorkingDirectory=/opt/talend/tac/tomcat
ExecStart=/opt/talend/tac/tomcat/bin/catalina.sh run
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
```

What each line does:

| Line | Meaning |
|---|---|
| `After=` / `Wants=network-online.target` | Start once the network is up (TAC connects to `vm_db`). |
| `Type=simple` + `catalina.sh run` | `run` keeps Tomcat in the **foreground**, so systemd watches the Java process directly. This is more reliable than `startup.sh`, which forks and needs a PID file. |
| `User=talend` / `Group=talend` | Tomcat runs as `talend:talend`, never as root. |
| `UMask=0027` | New files (logs…) are created `rw-r-----`: the owner writes, the group reads, others have no access. |
| `Environment=` | Variables given to the process. systemd does **not** read `.profile` or `.bashrc`, so they must be set here. |
| `WorkingDirectory=` | Current folder of the process. Relative paths in TAC resolve from here. |
| `SuccessExitStatus=143` | On `systemctl stop`, Java exits with 143 (128 + SIGTERM). This tells systemd that is a clean stop, not a failure. |
| `TimeoutStartSec` / `TimeoutStopSec` | Time allowed to start (TAC is slow on first start) and to stop before systemd kills it. |
| `Restart=on-failure` + `RestartSec=10` | Restarts Tomcat automatically 10 s after a crash, but not after a normal `systemctl stop`. |
| `LimitNOFILE` / `LimitNPROC` | Open-file and process limits (`/etc/security/limits.d` does **not** apply to systemd services). |
| `WantedBy=multi-user.target` | `enable` hooks the service to the normal boot target, so it starts with the container. |

### 5.2 Enable and start

```bash
systemctl daemon-reload
```

systemd caches unit files. This tells it to read the new or changed file again
(needed after **every** edit of the unit).

```bash
systemctl enable talend-tac
```

This creates the symlink `/etc/systemd/system/multi-user.target.wants/talend-tac.service`,
so the service **starts automatically** each time the container starts.

```bash
systemctl start talend-tac
```

This starts it now. (`systemctl enable --now talend-tac` does both in one command.)

---

## Step 6: Checks

```bash
systemctl status talend-tac
```

Expect `Active: active (running)` and `enabled;` on the `Loaded:` line.

```bash
ps -o user,group,cmd -C java
```

The Java process must run as `talend talend` and use `/opt/talend/java/jdk21/bin/java`.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
```

Expect `200` or `302` once TAC is deployed (the first start can take a minute).

```bash
journalctl -u talend-tac -f
```

Follow the service output live (Ctrl+C to quit). Tomcat's own logs are in
`/opt/talend/tac/tomcat/logs/catalina.<date>.log`. TAC's logs are in the same folder.

Clean up the downloads:

```bash
rm -rf /tmp/tac-install
```

From the docker host, open **http://localhost:8080/** and configure the TAC database
on the configuration page. Use the hyphenated host name, for example
`jdbc:postgresql://vm-db:5432/<tac_db>`.

---

## Everyday commands

| Action | Command |
|---|---|
| Stop / start / restart | `systemctl stop\|start\|restart talend-tac` |
| Disable autostart | `systemctl disable talend-tac` |
| Change the heap | edit `/opt/talend/tac/tomcat/bin/setenv.sh`, then `systemctl restart talend-tac` |
| Change the unit | edit the file, then `systemctl daemon-reload && systemctl restart talend-tac` |
| Logs since the last boot | `journalctl -u talend-tac -b` |
| Shell as talend | `su - talend` (or from the host: `docker exec -it -u talend vm_tac bash -l`) |
