# Running a site on more than one web server, and with a database replica, then back on one.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

# The replication account on the primary, named so it can't be one of the store's own.
REPLICATION_USER=kapelos_repl

scale_web() {
  printf '%s' "${WEB_SERVERS:-1}"
}

scale_replicas() {
  printf '%s' "${DB_REPLICAS:-0}"
}

scaled() {
  [[ $(scale_web) -gt 1 || $(scale_replicas) -gt 0 ]]
}

# Server N answers directly one port above HTTP_PORT, so web-1 is 8081 by default.
scale_port() {
  printf '%s' "$((${HTTP_PORT:-8080} + $1))"
}

# The web servers after the first, one per line: 2, 3, 4.
scale_extra_servers() {
  local n=2
  while [[ $n -le $(scale_web) ]]; do
    echo "$n"
    n=$((n + 1))
  done
}

scale_extra_services() {
  local n
  for n in $(scale_extra_servers); do
    printf 'php-%s web-%s ' "$n" "$n"
  done
}

# Double-quoted YAML, for a path that may hold spaces.
yaml_string() {
  local value="${1//\\/\\\\}"
  printf '"%s"' "${value//\"/\\\"}"
}

write_if_changed() {
  [[ -f $1 && $(cat "$1") == "$2" ]] || printf '%s\n' "$2" >"$1"
}

# WEB_SERVERS and DB_REPLICAS become a compose file and a VCL of the site's own; the ordinary shape writes neither.
derive_scale() {
  local web replicas dir
  web="$(scale_web)"
  replicas="$(scale_replicas)"
  [[ $web =~ ^[1-4]$ ]] || die "WEB_SERVERS is $web, and Kapelos runs 1 to 4 web servers"
  [[ $replicas =~ ^[01]$ ]] || die "DB_REPLICAS is $replicas, and Kapelos runs 0 or 1 replica"
  [[ ${HTTP_PORT:-8080} =~ ^[0-9]+$ ]] || die "HTTP_PORT is ${HTTP_PORT}, which isn't a port"
  dir="$(site_state_dir)"
  unset KAPELOS_SCALE_FILE
  if ! scaled; then
    rm -f "$dir/scale.yaml" "$dir/scale.vcl"
    return 0
  fi
  mkdir -p "$dir"
  write_if_changed "$dir/scale.yaml" "$(scale_compose_text)"
  if [[ $web -gt 1 ]]; then
    write_if_changed "$dir/scale.vcl" "$(scale_vcl_text)"
  else
    rm -f "$dir/scale.vcl"
  fi
  export KAPELOS_SCALE_FILE="$KAPELOS_HOME/$dir/scale.yaml"
}

scale_compose_text() {
  local n base media
  base="$(yaml_string "$KAPELOS_HOME/compose.yaml")"
  media='"${MAGENTO_SRC}/pub/media"'
  echo "# Written by Kapelos from WEB_SERVERS=$(scale_web) and DB_REPLICAS=$(scale_replicas). kapelos scale changes them."
  echo "services:"
  if [[ $(scale_web) -gt 1 ]]; then
    cat <<EOF
  # Server 1 runs the store's folder. A fixed host name keeps it the same server when its containers are recreated.
  php:
    hostname: web-1
  php-debug:
    hostname: web-1
  cron:
    hostname: web-1
  web:
    ports:
      - "\${BIND_ADDRESS:-127.0.0.1}:$(scale_port 1):80"

  # Varnish sends each request to the next server, then runs the site's own VCL.
  varnish:
    volumes:
      - type: bind
        source: $(yaml_string "$KAPELOS_HOME/$(site_state_dir)/scale.vcl")
        target: /etc/varnish/default.vcl
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: \${VARNISH_VCL:-./etc/varnish/default.vcl}
        target: /etc/varnish/site.vcl
        read_only: true
        bind:
          create_host_path: false
    depends_on:
EOF
    for n in $(scale_extra_servers); do
      cat <<EOF
      web-$n:
        condition: service_started
        restart: true
EOF
    done
    for n in $(scale_extra_servers); do
      cat <<EOF

  # Server $n runs its own copy of the code, which kapelos scale refresh replaces. Media is shared, as on a real cluster.
  php-$n:
    extends:
      file: $base
      service: php
    hostname: web-$n
    volumes:
      - app-$n:/app
      - php-socket-$n:/run/php
      - type: bind
        source: $media
        target: /app/pub/media
        bind:
          create_host_path: false
  web-$n:
    extends:
      file: $base
      service: web
    volumes:
      - type: volume
        source: app-$n
        target: /app
        read_only: true
      - php-socket-$n:/run/php
      - type: bind
        source: $media
        target: /app/pub/media
        read_only: true
        bind:
          create_host_path: false
    ports:
      - "\${BIND_ADDRESS:-127.0.0.1}:$(scale_port "$n"):80"
EOF
    done
  fi
  if [[ $(scale_replicas) -gt 0 ]]; then
    cat <<'EOF'

  # Row-based binary log for the replica. Magento's indexer triggers need the last setting once the log is on.
  db:
    command:
      - --log-bin=mysql-bin
      - --server-id=1
      - --binlog-format=ROW
      - --log-bin-trust-function-creators=1

  # Seeded from one dump of the primary, then kept up by GTID replication.
  db-replica:
    image: mariadb:${MARIADB_VERSION:-11.8}
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD in .env, or run kapelos env}
    command:
      - --server-id=2
      - --read-only=1
      - --relay-log=relay-bin
      - --max-allowed-packet=256M
    volumes:
      - db-replica-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    mem_limit: 1g
    restart: unless-stopped
EOF
  fi
  echo
  echo "volumes:"
  for n in $(scale_extra_servers); do
    cat <<EOF
  app-$n:
  php-socket-$n:
    driver_opts:
      type: tmpfs
      device: tmpfs
      o: mode=1777
EOF
  done
  [[ $(scale_replicas) -eq 0 ]] || echo "  db-replica-data:"
}

scale_vcl_text() {
  local n
  echo "vcl 4.1;"
  echo "# Written by Kapelos from WEB_SERVERS=$(scale_web). Sends each request to the next web server, then runs the site's own VCL."
  echo "import directors;"
  echo
  echo 'backend web_1 { .host = "web"; .port = "80"; .first_byte_timeout = 600s; }'
  for n in $(scale_extra_servers); do
    echo "backend web_$n { .host = \"web-$n\"; .port = \"80\"; .first_byte_timeout = 600s; }"
  done
  echo
  echo "sub vcl_init {"
  echo "    new kapelos_servers = directors.round_robin();"
  echo "    kapelos_servers.add_backend(web_1);"
  for n in $(scale_extra_servers); do
    echo "    kapelos_servers.add_backend(web_$n);"
  done
  echo "}"
  cat <<'EOF'

sub vcl_recv {
    set req.backend_hint = kapelos_servers.backend();
}

# Names the server that built the response, which is how you see the requests spread.
sub vcl_backend_response {
    set beresp.http.X-Kapelos-Server = regsub(beresp.backend.name, "_", "-");
}

include "/etc/varnish/site.vcl";
EOF
}

scale_copies_dir() {
  printf '%s/copies' "$(site_state_dir)"
}

# The env.php the PHP containers read: Kapelos's own for an adopted store, the store's otherwise.
scale_env_php() {
  printf '%s' "${KAPELOS_ENV_PHP:-${MAGENTO_SRC:-}/app/etc/env.php}"
}

# Adds a connection named replica pointing at db-replica, or removes it, through Magento's own formatter so the file
# comes back byte for byte. A replica connection naming another host is the store's, and is left alone.
scale_replica_connection() {
  local want="$1" file
  file="$(scale_env_php)"
  [[ -f $file ]] || return 0
  if [[ $want == add ]]; then
    ! grep -q "'db-replica'" "$file" || return 0
    step "Adding a replica connection to env.php, pointing at db-replica"
  else
    grep -q "'db-replica'" "$file" || return 0
    step "Removing the replica connection from env.php"
  fi
  # Mid-scale, the servers and replica being removed look like orphans to compose run; up removes them next.
  COMPOSE_IGNORE_ORPHANS=true compose run --rm --no-deps -T php php -r '
    require "vendor/autoload.php";
    $file = "app/etc/env.php";
    $env = include $file;
    $current = $env["db"]["connection"]["replica"] ?? null;
    if ($argv[1] === "add" && $current === null) {
        $env["db"]["connection"]["replica"] = array_merge($env["db"]["connection"]["default"], ["host" => "db-replica"]);
    } elseif ($argv[1] === "remove" && ($current["host"] ?? null) === "db-replica") {
        unset($env["db"]["connection"]["replica"]);
    } else {
        fwrite(STDERR, "env.php already has a replica connection to " . ($current["host"] ?? "nowhere") . ", which Kapelos leaves alone\n");
        exit(0);
    }
    file_put_contents($file, (new \Magento\Framework\App\DeploymentConfig\Writer\PhpFormatter())->format($env));
  ' "$want" </dev/null
  # Every copy holds the old env.php now.
  rm -rf "$(scale_copies_dir)"
}

# Replaces server N's copy of the code with the store's folder. The shared media and the server's own logs stay.
scale_copy() {
  local n="$1" marker adopted=()
  marker="$(scale_copies_dir)/web-$n"
  mkdir -p "$(scale_copies_dir)"
  step "Copying the store's code to web-$n"
  compose stop "php-$n" >/dev/null 2>&1 || true
  [[ -z ${KAPELOS_ENV_PHP:-} ]] || adopted=(-v "$KAPELOS_ENV_PHP:/kapelos/env.php:ro")
  # Taken before the copy starts, so an edit made while it runs still reads as newer than the copy.
  touch "$marker.partial"
  COMPOSE_IGNORE_ORPHANS=true compose run --rm --no-deps -T --user 0:0 --entrypoint bash -e KAPELOS_OWNER="${HOST_UID:-1000}:${HOST_GID:-1000}" \
    -v "$MAGENTO_SRC:/kapelos/from:ro" ${adopted[@]+"${adopted[@]}"} "php-$n" -c '
      set -euo pipefail
      cd /app
      find . -mindepth 1 -maxdepth 1 ! -name pub ! -name var -exec rm -rf {} +
      [ ! -d pub ] || find pub -mindepth 1 -maxdepth 1 ! -name media -exec rm -rf {} +
      [ ! -d var ] || find var -mindepth 1 -maxdepth 1 ! -name log ! -name report -exec rm -rf {} +
      tar -C /kapelos/from --exclude=./pub/media --exclude=./var/log --exclude=./var/report \
        --exclude=./var/cache --exclude=./var/page_cache --exclude=./var/session -cf - . | tar -xpf -
      [ ! -f /kapelos/env.php ] || cp /kapelos/env.php app/etc/env.php
      for folder in . pub var app/etc; do
        [ ! -d "$folder" ] || chown "$KAPELOS_OWNER" "$folder"
      done
    ' </dev/null
  mv "$marker.partial" "$marker"
}

# A copy is missing when its volume or its record of being made is.
scale_copy_missing() {
  [[ -f $(scale_copies_dir)/web-$1 ]] || return 0
  ! docker volume inspect "${COMPOSE_PROJECT_NAME:-kapelos}_app-$1" >/dev/null 2>&1
}

# Whether the store's code has changed since server N's copy. Folders Magento writes while serving don't count.
scale_copy_stale() {
  local marker
  marker="$(scale_copies_dir)/web-$1"
  [[ -f $marker ]] || return 0
  [[ -n $(find "$MAGENTO_SRC" \( -path "$MAGENTO_SRC/var" -o -path "$MAGENTO_SRC/generated" -o -path "$MAGENTO_SRC/pub/static" \
    -o -path "$MAGENTO_SRC/pub/media" -o -path "$MAGENTO_SRC/.git" \) -prune -o -newer "$marker" -print 2>/dev/null | head -n 1) ]]
}

# Every other server gets the store's code again, and starts on it.
scale_refresh() {
  local n services=()
  [[ $(scale_web) -gt 1 ]] || return 0
  for n in $(scale_extra_servers); do
    scale_copy "$n"
    services+=("php-$n")
  done
  compose up -d --wait --no-deps "${services[@]}"
}

# What kapelos up does for a scaled site before starting it: env.php, then any missing copy.
scale_before_up() {
  local n
  if [[ $(scale_replicas) -gt 0 ]]; then
    scale_replica_connection add
  else
    scale_replica_connection remove
  fi
  scaled || return 0
  [[ $(scale_web) -eq 1 || -d $MAGENTO_SRC/pub/media ]] || die "$MAGENTO_SRC has no pub/media, which every web server shares"
  for n in $(scale_extra_servers); do
    if scale_copy_missing "$n"; then
      scale_copy "$n"
    fi
  done
}

# And after: a replica that was never seeded is seeded. One that stopped is reported, since the reason may be the finding.
scale_after_up() {
  [[ $(scale_replicas) -gt 0 ]] || return 0
  # Set by a caller that reseeds straight after, such as snapshot restore, so a break it expects isn't reported.
  [[ ${SCALE_RESEED_NEXT:-no} == no ]] || return 0
  local state
  state="$(scale_replica_state)"
  case "$state" in
    none) scale_seed_replica ;;
    running* | connecting*) ;;
    *) echo "kapelos: replication to db-replica has stopped: $state. kapelos scale reseed copies the database to it again" >&2 ;;
  esac
}

replica_root() {
  exec_quiet db-replica sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot "$@"' sh "$@"
}

# SQL with a value in single quotes. Values reach mariadb on stdin, never on a command line.
sql_quote() {
  local value="${1//\\/\\\\}"
  printf "'%s'" "${value//\'/\'\'}"
}

# running, with how far behind; connecting; none when replication was never set up; otherwise why it stopped.
scale_replica_state() {
  local status io sql error
  status="$(replica_root -e 'SHOW SLAVE STATUS\G' </dev/null 2>/dev/null)" || {
    echo "db-replica isn't answering"
    return
  }
  if [[ -z $status ]]; then
    echo none
    return
  fi
  io="$(sed -n 's/^ *Slave_IO_Running: //p' <<<"$status")"
  sql="$(sed -n 's/^ *Slave_SQL_Running: //p' <<<"$status")"
  error="$(sed -n -e 's/^ *Last_IO_Error: \(..*\)/\1/p' -e 's/^ *Last_SQL_Error: \(..*\)/\1/p' <<<"$status" | head -n 1)"
  if [[ $io == Yes && $sql == Yes ]]; then
    echo "running, $(sed -n 's/^ *Seconds_Behind_Master: //p' <<<"$status") seconds behind"
    return
  fi
  # The primary was restarted a moment ago, and the replica is retrying it. Its last refused attempt stays in Last_IO_Error meanwhile.
  if [[ $io == Connecting && $sql == Yes ]]; then
    echo "connecting to the primary"
    return
  fi
  echo "receiving ${io:-no}, applying ${sql:-no}${error:+: $error}"
}

# Copies the whole database into the replica from one consistent dump, and starts replication at the position that dump records.
scale_seed_replica() {
  require_running db db-replica
  local name="${DB_NAME:-magento}" gtid state tries=0
  [[ $name =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME $name has characters Kapelos won't put in SQL"
  if [[ -z ${DB_REPLICATION_PASSWORD:-} ]]; then
    set_env_value "$ENV_FILE" DB_REPLICATION_PASSWORD "$(random_secret)"
    load_env
  fi

  step "Letting db-replica read the binary log"
  printf "SET sql_log_bin = 0; CREATE OR REPLACE USER '%s'@'%%' IDENTIFIED BY %s; GRANT REPLICATION SLAVE ON *.* TO '%s'@'%%';" \
    "$REPLICATION_USER" "$(sql_quote "$DB_REPLICATION_PASSWORD")" "$REPLICATION_USER" | db_root

  step "Copying $name to db-replica from one dump"
  replica_root -e "STOP SLAVE; RESET SLAVE ALL; DROP DATABASE IF EXISTS \`$name\`" </dev/null
  gtid="$(exec_quiet db-replica bash -c '
    set -euo pipefail
    export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
    mariadb-dump -h db -uroot --single-transaction --master-data=2 --gtid --routines --triggers --events --databases "$1" |
      awk "!found && /gtid_slave_pos/ { print > \"/tmp/kapelos-gtid\"; found = 1 } { print }" |
      mariadb -uroot
    sed -n "s/.*gtid_slave_pos=.\([^\x27]*\).*/\1/p" /tmp/kapelos-gtid
    rm -f /tmp/kapelos-gtid
  ' sh "$name" </dev/null)"

  step "Starting replication at ${gtid:-the start of the binary log}"
  printf "CREATE OR REPLACE USER %s@'%%' IDENTIFIED BY %s; GRANT SELECT ON \`%s\`.* TO %s@'%%';
    SET GLOBAL gtid_slave_pos = %s;
    CHANGE MASTER TO MASTER_HOST = 'db', MASTER_PORT = 3306, MASTER_USER = '%s', MASTER_PASSWORD = %s, MASTER_USE_GTID = slave_pos, MASTER_CONNECT_RETRY = 5;
    START SLAVE;" \
    "$(sql_quote "${DB_USER:-magento}")" "$(sql_quote "$DB_PASSWORD")" "$name" "$(sql_quote "${DB_USER:-magento}")" \
    "$(sql_quote "$gtid")" "$REPLICATION_USER" "$(sql_quote "$DB_REPLICATION_PASSWORD")" | replica_root

  until state="$(scale_replica_state)" && [[ $state == running* ]]; do
    tries=$((tries + 1))
    [[ $tries -lt 60 ]] || die "replication to db-replica didn't start: $state"
    sleep 1
  done
  echo "Replicating: $state."
}

# What scaling down leaves behind that belongs to the larger shape: copies, the replica's data, the binary log and its account.
scale_remove_leftovers() {
  local project="${COMPOSE_PROJECT_NAME:-kapelos}" volume n
  for volume in $(docker volume ls -q --filter "label=com.docker.compose.project=$project"); do
    n=""
    case "$volume" in
      "${project}_app-"* | "${project}_php-socket-"*) n="${volume##*-}" ;;
      "${project}_db-replica-data") [[ $(scale_replicas) -gt 0 ]] || n=replica ;;
    esac
    [[ -n $n ]] || continue
    [[ $n == replica || ($n =~ ^[0-9]+$ && $n -gt $(scale_web)) ]] || continue
    docker volume rm "$volume" >/dev/null
    [[ $n == replica ]] || rm -f "$(scale_copies_dir)/web-$n"
  done
  [[ $(scale_replicas) -eq 0 ]] || return 0
  if [[ -n $(db_root -N -e "SELECT 1 FROM mysql.user WHERE user = '$REPLICATION_USER'" </dev/null) ]]; then
    step "Removing the replication account"
    db_root -e "DROP USER '$REPLICATION_USER'@'%'" </dev/null
  fi
  if [[ $(db_root -N -e "SELECT @@log_bin" </dev/null) == 0 ]] &&
    exec_quiet db sh -c 'ls /var/lib/mysql/mysql-bin.* >/dev/null 2>&1' </dev/null; then
    step "Removing the binary log, which nothing reads now"
    exec_quiet db sh -c 'rm -f /var/lib/mysql/mysql-bin.*' </dev/null
  fi
}

# Runs a Magento command on server 1 and on every other server's copy.
magento_on_every_server() {
  local n
  magento "$@"
  for n in $(scale_extra_servers); do
    exec_quiet "php-$n" php bin/magento "$@" </dev/null
  done
}

scale_status() {
  local n host running=no
  running_projects | grep -qx "${COMPOSE_PROJECT_NAME:-kapelos}" && running=yes
  if ! scaled; then
    echo "One web server and no replica, the ordinary shape. kapelos scale web=2 replica=1 adds a server and a replica."
    return
  fi
  host="$(printf '%s' "${MAGENTO_BASE_URL:-http://localhost:8080/}" | sed -E 's#^https?://([^/]+).*#\1#')"
  echo "web=$(scale_web) replica=$(scale_replicas). kapelos scale web=1 replica=0 goes back to the ordinary shape."
  echo
  printf '  %-11s %-26s %s\n' web-1 "http://${BIND_ADDRESS:-127.0.0.1}:$(scale_port 1)/" "the store's folder"
  for n in $(scale_extra_servers); do
    local copy="no copy yet"
    if [[ -f $(scale_copies_dir)/web-$n ]]; then
      copy="a copy from $(date -r "$(scale_copies_dir)/web-$n" '+%Y-%m-%d %H:%M' 2>/dev/null)"
      ! scale_copy_stale "$n" || copy="$copy, older than the store's code"
    fi
    printf '  %-11s %-26s %s\n' "web-$n" "http://${BIND_ADDRESS:-127.0.0.1}:$(scale_port "$n")/" "$copy"
  done
  if [[ $(scale_replicas) -gt 0 ]]; then
    if [[ $running == yes ]]; then
      printf '  %-11s %s\n' db-replica "$(scale_replica_state)"
    else
      printf '  %-11s %s\n' db-replica "stopped with the site"
    fi
  fi
  echo
  if [[ $running == no ]]; then
    echo "The site is stopped. kapelos up starts it in this shape."
  else
    [[ $(scale_web) -eq 1 ]] || echo "Varnish sends requests to each server in turn, and X-Kapelos-Server names the one that answered. To reach one directly: curl -H 'Host: $host' http://${BIND_ADDRESS:-127.0.0.1}:$(scale_port 2)/"
    echo "kapelos scale refresh copies the code to the other servers again; deploy, develop, composer and modules do it for you."
  fi
}

# A store's own compose file that already runs a service by one of these names would be merged into Kapelos's.
scale_names_free() {
  local file="${MAGENTO_SRC:-}/.kapelos/compose.yaml" taken
  [[ -f $file ]] || return 0
  taken="$(grep -oE '^  (db-replica|php-[0-9]+|web-[0-9]+):' "$file" | tr -d ' :' | paste -sd ' ' -)"
  [[ -z $taken ]] || die "the store's .kapelos/compose.yaml already defines $taken, which kapelos scale runs itself. Remove them from it first, with their volumes if you're done with them"
}

cmd_scale() {
  load_env
  case "${1:-}" in
    '')
      scale_status
      return
      ;;
    refresh)
      require_site_running
      [[ $(scale_web) -gt 1 ]] || die "this site runs one web server, so there is no copy to refresh"
      scale_refresh
      cmd_cache_reset
      return
      ;;
    reseed)
      require_site_running
      [[ $(scale_replicas) -gt 0 ]] || die "this site has no replica. kapelos scale replica=1 adds one"
      scale_seed_replica
      return
      ;;
  esac

  local web replicas yes=no arg removing=""
  web="$(scale_web)"
  replicas="$(scale_replicas)"
  for arg in "$@"; do
    case "$arg" in
      web=*) web="${arg#web=}" ;;
      replica=* | replicas=*) replicas="${arg#*=}" ;;
      -y) yes=yes ;;
      *) die "kapelos scale takes web=N, replica=N and -y, or refresh or reseed, not $arg" ;;
    esac
  done
  [[ $web =~ ^[1-4]$ ]] || die "web is a number of web servers from 1 to 4, not $web"
  [[ $replicas =~ ^[01]$ ]] || die "replica is 0 or 1, not $replicas"
  if [[ $web == "$(scale_web)" && $replicas == "$(scale_replicas)" ]]; then
    scale_status
    return
  fi
  scale_names_free
  require_site_running

  if [[ $web -lt $(scale_web) ]]; then
    removing="web-$((web + 1))"
    [[ $((web + 1)) -eq $(scale_web) ]] || removing="web-$((web + 1)) to web-$(scale_web)"
    removing="$removing with its copy of the code"
  fi
  [[ $replicas -ge $(scale_replicas) ]] || removing="${removing:+$removing, and }db-replica with its data, and the primary's binary log"
  if [[ -n $removing ]]; then
    echo "Scaling down removes $removing. The store's own folder and database stay as they are."
    confirm "Go ahead?" "$yes" || exit 1
  fi

  [[ -n ${DB_REPLICATION_PASSWORD:-} || $replicas -eq 0 ]] || set_env_value "$ENV_FILE" DB_REPLICATION_PASSWORD "$(random_secret)"
  set_env_value "$ENV_FILE" WEB_SERVERS "$web"
  set_env_value "$ENV_FILE" DB_REPLICAS "$replicas"
  load_env
  cmd_up
  scale_remove_leftovers
  cmd_cache_reset
  echo
  scale_status
}
