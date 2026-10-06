# The stack day to day: starting it, its data, its caches, its queues and its addresses.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

# Off unless KAPELOS_MAX_RUNNING or KAPELOS_MEM_BUDGET_GIB is set. It counts every Kapelos project running on
# the Docker daemon, from any folder, so two checkouts on one machine share one limit.
require_room_on_daemon() {
  local current="$1" max="${KAPELOS_MAX_RUNNING:-}" budget="${KAPELOS_MEM_BUDGET_GIB:-}"
  [[ -n $max || -n $budget ]] || return 0
  [[ -z $max || $max =~ ^[1-9][0-9]{0,2}$ ]] || die "KAPELOS_MAX_RUNNING is $max, and it takes a whole number of stores, 1 or more"
  [[ -z $budget || $budget =~ ^[1-9][0-9]{0,4}$ ]] || die "KAPELOS_MEM_BUDGET_GIB is $budget, and it takes a whole number of GiB, 1 or more"
  local running count used listing mine total
  running="$(daemon_kapelos_containers | awk -v me="$current" '$1 != me')"
  # One line per project: its name, its limits added up, and the folder it runs from.
  listing="$(awk '
    NF >= 2 { name = $1; memory[name] += $2; line = $0; sub(/^[^ ]+ [^ ]+ /, "", line); folder[name] = line }
    END { for (name in memory) printf "  %s, %.1f GiB of declared limits, from %s\n", name, memory[name] / 1073741824, folder[name] }
  ' <<<"$running" | sort)"
  count="$(grep -c . <<<"$listing" || true)"
  used="$(awk '{ total += $2 } END { printf "%.0f\n", total }' <<<"$running")"
  [[ -n $listing ]] || listing="  none"
  if [[ -n $max && $((count + 1)) -gt $max ]]; then
    die "starting $current would make $((count + 1)) Kapelos stores running on this Docker, and KAPELOS_MAX_RUNNING is $max. Running now:
$listing
Stop one with kapelos down in its own folder first"
  fi
  [[ -n $budget ]] || return 0
  mine="$(site_memory_limit)"
  total=$((used + mine))
  # Only declared limits can be added up; a container with none counts as nothing, so say how many there are.
  local unlimited note=""
  unlimited="$(awk '$2 == 0' <<<"$running" | grep -c . || true)"
  [[ $unlimited -eq 0 ]] || note="
$unlimited running container$([[ $unlimited -eq 1 ]] && echo " declares" || echo "s declare") no memory limit and $([[ $unlimited -eq 1 ]] && echo "is" || echo "are") not counted, so real use is higher"
  if [[ $total -gt $((budget * 1073741824)) ]]; then
    die "starting $current would bring the declared memory limits of running Kapelos stores to $(gib "$total") GiB: $(gib "$used") GiB already running and $(gib "$mine") GiB for this site, over KAPELOS_MEM_BUDGET_GIB=$budget.${note}
Running now:
$listing
Stop one with kapelos down in its own folder first, or run this site with fewer services"
  fi
}

# --- room for another store ----------------------------------------------
# A first store always starts, as it always has. Another starts only if, after what it used when it last
# ran, KAPELOS_RESERVE_GIB of memory stays free and the machine's five-minute load is under KAPELOS_MAX_LOAD.
# Either set to 0 is off. The defaults are a first guess; the knee measured on a real host replaces them.
DEFAULT_RESERVE_GIB=8
# What a site that has never been measured counts as: a stack with sample data idles near this.
UNMEASURED_SITE_GIB=6
GIB_BYTES=1073741824
# What must stay free where Docker keeps its data before a store starts or a snapshot is taken, in GiB.
# It is the figure kapelos doctor warns under. 0 is off.
DEFAULT_DISK_RESERVE_GIB=20

# Memory this machine can still hand out, in bytes. Linux says so directly. On macOS free, inactive and
# speculative pages can all be handed out; that path was written without a Mac to try it on.
host_available_bytes() {
  local meminfo="${KAPELOS_MEMINFO:-/proc/meminfo}" page
  if [[ -r $meminfo ]]; then
    awk '$1 == "MemAvailable:" { printf "%.0f\n", $2 * 1024; found = 1 } END { exit !found }' "$meminfo"
    return
  fi
  page="$(sysctl -n hw.pagesize 2>/dev/null)" || return 1
  vm_stat 2>/dev/null | awk -v page="$page" '
    /^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); pages += $NF }
    END { if (pages > 0) printf "%.0f\n", pages * page; else exit 1 }'
}

# The five-minute load average: sustained work, not a moment's burst.
host_load() {
  local loadavg="${KAPELOS_LOADAVG:-/proc/loadavg}"
  if [[ -r $loadavg ]]; then
    awk '{ print $2 }' "$loadavg"
    return
  fi
  # macOS prints { 1.20 1.45 1.67 }.
  sysctl -n vm.loadavg 2>/dev/null | awk '{ print $3 }' | grep .
}

host_cores() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1
}

footprint_file() {
  printf '%s/footprint' "$(site_state_dir_of "$1")"
}

# The memory a project's running containers use now, in bytes, as docker stats reports it.
project_memory_now() {
  local ids
  ids="$(docker ps -q --filter "label=com.docker.compose.project=$1" 2>/dev/null)" || return 1
  [[ -n $ids ]] || return 1
  # shellcheck disable=SC2086 # one word per container
  docker stats --no-stream --format '{{.MemUsage}}' $ids 2>/dev/null | awk '
    {
      v = $1; n = v + 0; unit = v
      sub(/^[0-9.]+/, "", unit)
      if (unit == "KiB" || unit == "kB") n *= 1024
      else if (unit == "MiB" || unit == "MB") n *= 1048576
      else if (unit == "GiB" || unit == "GB") n *= 1073741824
      total += n
    }
    END { printf "%.0f\n", total }'
}

# Keeps what a running site uses, so the next start of it is admitted against a real number.
record_footprint() {
  local bytes file
  bytes="$(project_memory_now "$1")" || return 0
  [[ $bytes =~ ^[0-9]+$ && $bytes -gt 0 ]] || return 0
  file="$(footprint_file "$1")"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$bytes" >"$file"
}

recorded_footprint() {
  local bytes
  bytes="$(cat "$(footprint_file "$1")" 2>/dev/null)" || return 1
  [[ $bytes =~ ^[0-9]+$ ]] && printf '%s' "$bytes"
}

require_room_for_another() {
  local current="$1" others reserve max_load cores available need load said
  reserve="${KAPELOS_RESERVE_GIB:-$DEFAULT_RESERVE_GIB}"
  cores="$(host_cores)"
  max_load="${KAPELOS_MAX_LOAD:-$(awk -v c="$cores" 'BEGIN { printf "%g\n", c * 0.75 }')}"
  [[ $reserve =~ ^[0-9]{1,5}$ ]] || die "KAPELOS_RESERVE_GIB is $reserve, and it takes the whole GiB of memory to keep free, 0 for no reserve"
  [[ $max_load =~ ^[0-9]{1,4}([.][0-9]+)?$ ]] || die "KAPELOS_MAX_LOAD is $max_load, and it takes a load average such as 6 or 5.5, 0 for no limit"
  [[ $reserve != 0 || $max_load != 0 ]] || return 0
  others="$(daemon_kapelos_containers | awk -v me="$current" '$1 != me { print $1 }' | sort -u | sed 's/^kapelos-//' | tr '\n' ' ')"
  [[ -n $others ]] || return 0
  if [[ $reserve -gt 0 ]]; then
    if available="$(host_available_bytes)"; then
      if need="$(recorded_footprint "$current")"; then
        said="it used $(gib "$need") GiB when it last ran"
      else
        need=$((UNMEASURED_SITE_GIB * GIB_BYTES))
        said="it has never been measured, so it counts as $UNMEASURED_SITE_GIB GiB"
      fi
      [[ $((available - need)) -ge $((reserve * GIB_BYTES)) ]] ||
        die "starting ${current#kapelos-} would leave $(gib $((available - need))) GiB of memory free: $(gib "$available") GiB is free now, and $said. KAPELOS_RESERVE_GIB keeps $reserve GiB free.
Running now: $others
Stop one with kapelos down SITE, in the folder it runs from"
    else
      echo "kapelos: can't read how much memory this machine has free, so the reserve isn't checked" >&2
    fi
  fi
  [[ $max_load != 0 ]] || return 0
  if ! load="$(host_load)"; then
    echo "kapelos: can't read this machine's load, so KAPELOS_MAX_LOAD isn't checked" >&2
    return 0
  fi
  awk -v l="$load" -v m="$max_load" 'BEGIN { exit !(l > m) }' || return 0
  die "this machine's load over the last five minutes is $load, over KAPELOS_MAX_LOAD=$max_load on $cores cores, so ${current#kapelos-} waits for it to settle.
Running now: $others"
}

# Where Docker keeps its images, volumes and snapshots, when this machine can see the folder. Docker Desktop
# keeps it inside its own virtual machine, and there this answers nothing.
docker_data_dir() {
  local root
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || return 1
  [[ -n $root && -d $root ]] || return 1
  printf '%s' "$root"
}

# Bytes free on the filesystem a folder is on.
free_bytes_in() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024; found = 1 } END { exit !found }'
}

disk_reserve_gib() {
  local reserve="${KAPELOS_DISK_RESERVE_GIB:-$DEFAULT_DISK_RESERVE_GIB}"
  [[ $reserve =~ ^[0-9]{1,6}$ ]] || die "KAPELOS_DISK_RESERVE_GIB is $reserve, and it takes the whole GiB of disk to keep free where Docker keeps its data, 0 for no reserve"
  printf '%s' "$reserve"
}

# A store's database, search index and snapshots all live where Docker keeps its data, and a stopped store keeps
# what it has, so this is asked of every start, the first one too. Where that folder can't be read it asks
# nothing and says nothing: kapelos doctor is where that is said.
require_disk_room_to_start() {
  local site="${1#kapelos-}" reserve root free
  reserve="$(disk_reserve_gib)" || exit 1
  [[ $reserve -gt 0 ]] || return 0
  root="$(docker_data_dir)" || return 0
  free="$(free_bytes_in "$root")" || return 0
  [[ $free -ge $((reserve * GIB_BYTES)) ]] ||
    die "starting $site needs room where Docker keeps its data ($root): $(gib "$free") GiB is free there, and KAPELOS_DISK_RESERVE_GIB keeps $reserve GiB free.
kapelos snapshot lists this site's snapshots, and docker system df shows what else is there"
}

# The bytes a volume holds, measured the way a snapshot copies it.
volume_bytes() {
  docker run --rm -v "$1:/from:ro" alpine du -sk /from 2>/dev/null | awk '{ printf "%.0f\n", $1 * 1024; found = 1 } END { exit !found }'
}

# A snapshot is a second copy of the database, the search index and the queue, so it is refused when that copy
# would eat into the reserve.
require_disk_room_for_snapshot() {
  local site="${COMPOSE_PROJECT_NAME#kapelos-}" reserve root free volume bytes need=0
  reserve="$(disk_reserve_gib)" || exit 1
  [[ $reserve -gt 0 ]] || return 0
  root="$(docker_data_dir)" || return 0
  free="$(free_bytes_in "$root")" || return 0
  for volume in $SNAPSHOT_VOLUMES; do
    if ! bytes="$(volume_bytes "${COMPOSE_PROJECT_NAME}_$volume")"; then
      echo "kapelos: can't measure $volume, so the disk reserve isn't checked for this snapshot" >&2
      return 0
    fi
    need=$((need + bytes))
  done
  [[ $((free - need)) -ge $((reserve * GIB_BYTES)) ]] ||
    die "a snapshot of $site copies $(gib "$need") GiB, which would leave $(gib $((free - need))) GiB free where Docker keeps its data ($root): $(gib "$free") GiB is free now, and KAPELOS_DISK_RESERVE_GIB keeps $reserve GiB free.
kapelos snapshot delete NAME removes an old one"
}

# A site can't start beside a running site of this folder that publishes one of the same ports.
require_ports_free() {
  local current="$1" project file key mine theirs
  for project in $(running_projects); do
    [[ $project != "$current" ]] || continue
    file="$(site_of_project "$project")"
    [[ -n $file ]] || continue
    for key in $PORT_KEYS; do
      mine="${!key:-$(env_value .env.example "$key")}"
      theirs="$(env_value "$file" "$key")"
      [[ -n $theirs ]] || theirs="$(env_value .env.example "$key")"
      [[ $mine != "$theirs" ]] ||
        die "${current#kapelos-} and ${project#kapelos-}, which is running, both publish $key on $mine. Stop it with kapelos down ${project#kapelos-}, or give one of them its own ports with kapelos site ports SITE"
    done
  done
}

# The info line for this site's ports: its slot and every port in it, or the ports as set by hand.
site_block_words() {
  local slot
  if slot="$(slot_of_site "$(follow_link "$ENV_FILE")")"; then
    printf 'slot %s: HTTP %s (and the four above it for more web servers), HTTPS %s, MariaDB %s, Mailpit %s, OpenSearch %s, RabbitMQ %s, LiveReload %s' \
      "$slot" "${HTTP_PORT:-8080}" "${HTTPS_PORT:-8443}" "${DB_PORT:-13306}" "${MAIL_UI_PORT:-8025}" "${OPENSEARCH_PORT:-9200}" "${RABBITMQ_UI_PORT:-15672}" "${LIVERELOAD_PORT:-35729}"
  else
    printf 'set by hand, off the slots: HTTP %s, HTTPS %s, MariaDB %s' "${HTTP_PORT:-8080}" "${HTTPS_PORT:-8443}" "${DB_PORT:-13306}"
  fi
}

# docker compose --wait gives up at once on a container still marked unhealthy from before, so restart those once and wait again.
cmd_up() {
  load_env
  local current
  current="${COMPOSE_PROJECT_NAME:-kapelos}"
  # A site already up is being told about a change to its settings, not started.
  if ! running_projects | grep -qx "$current"; then
    require_ports_free "$current"
    require_room_for_another "$current"
    require_disk_room_to_start "$current"
  fi
  require_room_on_daemon "$current"

  # An adopted site whose adopt stopped part way starts and serves its own env.php, which
  # points at another stack's services, so the store is broken in a way nothing announces.
  if [[ -n ${KAPELOS_ENV_PHP:-} ]]; then
    # A site's project is always kapelos-<site>; see how adopt and env write it.
    local site="${current#kapelos-}"
    [[ -s ${KAPELOS_ENV_PHP} ]] ||
      die "this site was adopted but Kapelos's env.php is missing from $KAPELOS_ENV_PHP, so the adopt didn't finish. Run kapelos adopt again, or remove the site with: kapelos site remove $site"
    case ":${COMPOSE_FILE:-}:" in
      *:compose.adopt.yaml:*) ;;
      *) die "this site was adopted but COMPOSE_FILE doesn't include compose.adopt.yaml, so the store would run on its own env.php. The adopt didn't finish; run kapelos adopt again" ;;
    esac
  fi

  scale_before_up
  # A web server or replica scaled away is an orphan, and goes.
  if ! compose up -d --wait --remove-orphans; then
    local unhealthy
    unhealthy="$(compose ps --status running --format '{{.Service}} {{.Health}}' | awk '$2 == "unhealthy" { print $1 }' | tr '\n' ' ')"
    [[ -n $unhealthy ]] || exit 1
    echo "kapelos: $unhealthy reported unhealthy; restarting and waiting once more" >&2
    # shellcheck disable=SC2086 # one word per service
    compose restart $unhealthy
    compose up -d --wait --remove-orphans
  fi
  scale_after_up
  echo "Store: ${MAGENTO_BASE_URL:-http://localhost:8080/}  ·  kapelos info shows everything else"
}

# Composer changes the code on server 1, so every other server gets the new code. Commands that only read don't copy.
cmd_composer() {
  local status=0 first=""
  load_env
  exec_php composer "$@" || status=$?
  for first in "$@"; do
    [[ $first == -* ]] || break
  done
  case "$first" in
    '' | -* | about | audit | browse | check-platform-reqs | config | depends | diagnose | fund | help | home | licenses | list | outdated | prohibits | search | show | status | suggests | validate | why | why-not) ;;
    *) [[ $status -ne 0 ]] || scale_refresh ;;
  esac
  return "$status"
}

cmd_debug() {
  [[ $# -gt 0 ]] || die "name the Magento command to debug, for example: kapelos debug cache:flush"
  require_running php-debug
  if [[ -t 0 ]]; then
    compose exec -e XDEBUG_TRIGGER=1 php-debug php bin/magento "$@"
  else
    compose exec -T -e XDEBUG_TRIGGER=1 php-debug php bin/magento "$@"
  fi
}

cmd_db() {
  case "${1:-}" in
    '') compose_exec db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"' ;;
    dump)
      shift
      db_dump "$@"
      ;;
    import)
      shift
      cmd_import "$@"
      ;;
    *) die "kapelos db opens a prompt; kapelos db dump [FILE] and kapelos db import FILE move a database in and out" ;;
  esac
}

# A dump holds whatever customers the store holds, so it's written readable only by you.
db_dump() {
  load_env
  require_running db
  local file="${1:-var/dumps/${COMPOSE_PROJECT_NAME:-kapelos}-$(date +%Y%m%d-%H%M%S).sql.gz}"
  [[ $file == *.sql.gz ]] || die "a dump is written gzipped, so name it FILE.sql.gz"
  [[ ! -e $file ]] || die "$file already exists"
  mkdir -p "$(dirname "$file")"
  step "Dumping ${DB_NAME:-magento} into $file"
  (
    umask 077
    exec_quiet db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --routines --triggers "$1"' sh "${DB_NAME:-magento}" </dev/null | gzip >"$file.partial"
  )
  mv "$file.partial" "$file"
  echo "Wrote $file, $(du -h "$file" | cut -f 1)."
}

snapshot_names() {
  docker volume ls --filter "label=kapelos.snapshot.project=$COMPOSE_PROJECT_NAME" \
    --format '{{.Label "kapelos.snapshot"}}' | sort -u
}

valid_snapshot_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "a snapshot name uses lowercase letters, digits and dashes: $1"
}

# Copies one volume into another, emptying the destination first.
copy_volume() {
  docker run --rm -v "$1:/from:ro" -v "$2:/to" alpine sh -c 'find /to -mindepth 1 -delete && cp -a /from/. /to/'
}

cmd_snapshot() {
  load_env
  local action="${1:-list}" name="" yes=no volume created
  [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y) yes=yes ;;
      *) name="$1" ;;
    esac
    shift
  done
  case "$action" in
    list)
      local found=0
      for name in $(snapshot_names); do
        found=1
        created="$(docker volume inspect -f '{{index .Labels "kapelos.snapshot.created"}}' "${COMPOSE_PROJECT_NAME}_snapshot-$name-db-data" 2>/dev/null || true)"
        printf '  %-24s %s\n' "$name" "$created"
      done
      [[ $found -eq 1 ]] || echo "No snapshots yet. kapelos snapshot save NAME takes one."
      ;;
    save)
      [[ -n $name ]] || die "name the snapshot: kapelos snapshot save NAME"
      valid_snapshot_name "$name"
      [[ -z $(snapshot_names | grep -x "$name" || true) ]] || die "there's already a snapshot called $name. kapelos snapshot delete $name removes it"
      require_disk_room_for_snapshot
      step "Pausing the database, search and queue so the copy is consistent"
      compose stop db opensearch rabbitmq
      created="$(date '+%Y-%m-%d %H:%M')"
      for volume in $SNAPSHOT_VOLUMES; do
        docker volume create --label "kapelos.snapshot=$name" --label "kapelos.snapshot.project=$COMPOSE_PROJECT_NAME" \
          --label "kapelos.snapshot.created=$created" "${COMPOSE_PROJECT_NAME}_snapshot-$name-$volume" >/dev/null
        step "Copying $volume"
        copy_volume "${COMPOSE_PROJECT_NAME}_$volume" "${COMPOSE_PROJECT_NAME}_snapshot-$name-$volume"
      done
      cmd_up
      echo "Saved $name. kapelos snapshot restore $name puts it back."
      ;;
    restore)
      [[ -n $name ]] || die "name the snapshot: kapelos snapshot restore NAME. kapelos snapshot lists them"
      [[ -n $(snapshot_names | grep -x "$name" || true) ]] || die "there's no snapshot called $name. kapelos snapshot lists them"
      confirm "Replace this site's database, search index and queue with the snapshot $name? What's there now is lost unless you save it first." "$yes" || exit 1
      step "Stopping the database, search and queue"
      compose stop db opensearch rabbitmq
      for volume in $SNAPSHOT_VOLUMES; do
        step "Restoring $volume"
        copy_volume "${COMPOSE_PROJECT_NAME}_snapshot-$name-$volume" "${COMPOSE_PROJECT_NAME}_$volume"
      done
      # The restored database has a different history from the one the replica follows, so it's copied again.
      SCALE_RESEED_NEXT=yes cmd_up
      [[ $(scale_replicas) -eq 0 ]] || scale_seed_replica
      cmd_cache_reset
      echo "Restored $name."
      ;;
    delete)
      [[ -n $name ]] || die "name the snapshot: kapelos snapshot delete NAME"
      [[ -n $(snapshot_names | grep -x "$name" || true) ]] || die "there's no snapshot called $name"
      confirm "Delete the snapshot $name? It can't be brought back." "$yes" || exit 1
      for volume in $SNAPSHOT_VOLUMES; do
        docker volume rm "${COMPOSE_PROJECT_NAME}_snapshot-$name-$volume" >/dev/null
      done
      echo "Deleted $name."
      ;;
    *) die "kapelos snapshot [list], save NAME, restore NAME or delete NAME" ;;
  esac
}

cmd_valkey() {
  local instance="${1:-cache}"
  [[ $# -gt 0 ]] && shift
  case "$instance" in
    cache | session) compose_exec "valkey-$instance" valkey-cli "$@" ;;
    *) die "choose the cache or the session instance: kapelos valkey cache, kapelos valkey session" ;;
  esac
}

# varnishadm in the Varnish container: a ban, the ban list, the backends.
cmd_varnish() {
  [[ $# -gt 0 ]] || die "say what varnishadm should do: kapelos varnish ban.list, kapelos varnish backend.list"
  compose_exec varnish varnishadm "$@"
}

# Cache files written under other settings can stop bin/magento from starting at all, so they go first.
clear_cache_files() {
  step "Removing Magento's cache files in var/cache and var/page_cache"
  exec_quiet php sh -c 'rm -rf var/cache/* var/page_cache/*'
}

# Sessions live in valkey-session and are left alone, so no one signed in is logged out.
cmd_cache_reset() {
  require_running php valkey-cache varnish
  clear_cache_files
  step "Magento: cache:flush"
  magento cache:flush >/dev/null
  step "Valkey: emptying the cache and full-page cache"
  compose_exec valkey-cache valkey-cli FLUSHALL >/dev/null
  step "Varnish: banning every cached page"
  compose_exec varnish varnishadm "ban req.url ~ ." >/dev/null
  echo "Every cache is empty."
}

cmd_cron() {
  load_env
  local action="${1:-status}" yes=no
  [[ ${2:-} != -y ]] || yes=yes
  case "$action" in
    status)
      [[ ${CRON:-no} == yes ]] && echo "Cron is on for this site." || echo "Cron is off for this site."
      if compose ps --status running --services 2>/dev/null | holds -qx db && installed; then
        db_root -t "${DB_NAME:-magento}" -e "SELECT status, COUNT(*) AS jobs, MAX(executed_at) AS last_run FROM \`$(table_prefix)cron_schedule\` WHERE scheduled_at > NOW() - INTERVAL 1 HOUR GROUP BY status" </dev/null
      fi
      ;;
    run) magento cron:run ;;
    on)
      # Scheduled jobs run with the store's own settings, so a store you brought sends its real feeds and exports.
      if ! disposable; then
        confirm "This site isn't marked DISPOSABLE=yes, so its scheduled jobs use its real settings: feeds, exports and emails to outside servers will run. Turn cron on?" "$yes" || exit 1
      fi
      set_env_value "$ENV_FILE" CRON yes
      cmd_up
      echo "Cron is on: Magento's scheduled jobs run every minute, and start its queue consumers."
      ;;
    off)
      set_env_value "$ENV_FILE" CRON no
      docker compose --env-file "$ENV_FILE" -p "${COMPOSE_PROJECT_NAME:-kapelos}" rm -s -f cron >/dev/null 2>&1 || true
      echo "Cron is off."
      ;;
    *) die "kapelos cron [status], on [-y], off or run" ;;
  esac
}

# Declares the store's exchanges, queues and bindings the way setup:upgrade does, and nothing else, then checks each queue is in RabbitMQ.
# Magento's installer logs a failure instead of raising it, so the check is what shows one.
cmd_queues() {
  load_env
  require_running php rabbitmq
  step "Declaring the store's queues in RabbitMQ"
  local names expected present missing total
  if ! names="$(exec_quiet php php -r '
    require "app/bootstrap.php";
    $objects = \Magento\Framework\App\Bootstrap::create(BP, $_SERVER)->getObjectManager();
    $objects->get(\Magento\Framework\Amqp\TopologyInstaller::class)->install();
    $types = $objects->get(\Magento\Framework\MessageQueue\ConnectionTypeResolver::class);
    foreach ($objects->get(\Magento\Framework\MessageQueue\Topology\ConfigInterface::class)->getQueues() as $queue) {
        if ($types->getConnectionType($queue->getConnection()) === "amqp") { echo "queue ", $queue->getName(), "\n"; }
    }
  ' </dev/null)"; then
    printf '  %-4s  RabbitMQ  Magento stopped before it could declare its queues; the error is above\n' FAIL
    return 1
  fi
  expected="$(sed -n 's/^queue //p' <<<"$names" | sort -u)"
  present="$(exec_quiet rabbitmq rabbitmqctl -q list_queues --no-table-headers name </dev/null | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$present") | awk 'NF' | paste -sd ' ' -)"
  total="$(awk 'NF { n++ } END { print n + 0 }' <<<"$expected")"
  if [[ -n $missing ]]; then
    printf '  %-4s  RabbitMQ  %s of %s queues; missing %s\n' FAIL "$((total - $(wc -w <<<"$missing")))" "$total" "$missing"
    echo "        Magento logs why in the store's var/log/system.log, under \"AMQP topology installation failed\""
    return 1
  fi
  printf '  %-4s  RabbitMQ  %s of %s queues\n' pass "$total" "$total"
}

# npm, npx and grunt in a Node container at the store's root; grunt watch also publishes LiveReload's port.
cmd_node() {
  local program="$1" ports=()
  shift
  load_env
  mkdir -p var/npm-cache
  if [[ $program == grunt ]]; then
    [[ " $* " != *" watch "* && " $* " != *" watch:"* ]] || ports=(--service-ports)
    set -- grunt "$@"
    program=npx
  fi
  compose run --rm --no-deps ${ports[@]+"${ports[@]}"} node "$program" "$@"
}

deploy_step() {
  local description="$1"
  shift
  step "$description"
  if ! "$@"; then
    echo "kapelos: stopped at: $description" >&2
    echo "The store is still in maintenance mode. Fix the problem and run kapelos deploy again, or go back with kapelos develop." >&2
    exit 1
  fi
}

# Runs the steps a server deployment runs, in the same order, on the mounted tree.
cmd_deploy() {
  load_env
  require_running php
  local locales
  read -r -a locales <<<"${DEPLOY_LOCALES:-en_US}"
  [[ ${#locales[@]} -gt 0 ]] || locales=(en_US)

  deploy_step "Turning on maintenance mode" magento_on_every_server maintenance:enable
  deploy_step "Installing packages without the development ones" exec_php composer install --no-dev --no-interaction
  deploy_step "Upgrading the database" magento setup:upgrade
  deploy_step "Compiling dependency injection" exec_php_no_xdebug php -d memory_limit=-1 bin/magento setup:di:compile
  # The class map is built after compiling, or it points at generated classes setup:upgrade just deleted.
  deploy_step "Optimising the autoloader" exec_php composer dump-autoload --optimize --no-dev
  deploy_step "Deploying static files for ${locales[*]}" magento setup:static-content:deploy -f "${locales[@]}"
  if manipulus_in_use; then
    deploy_step "Writing the manipulus bundles into the fresh static files" manipulus_write
    deploy_step "Refreshing the integrity hashes checkout checks the bundles against" magento manipulus:integrity:refresh
  fi
  deploy_step "Switching to production mode" magento deploy:mode:set production --skip-compilation
  [[ $(scale_web) -eq 1 ]] || deploy_step "Copying the release to every other web server" scale_refresh
  deploy_step "Emptying every cache" cmd_cache_reset
  deploy_step "Turning off maintenance mode" magento_on_every_server maintenance:disable
  echo "Deployed. The store is in production mode; kapelos develop goes back."
}

cmd_develop() {
  load_env
  require_running php
  step "Installing packages, including the development ones"
  exec_php composer install --no-interaction
  step "Switching to developer mode"
  magento deploy:mode:set developer
  scale_refresh
  step "Turning off maintenance mode"
  magento_on_every_server maintenance:disable
  cmd_cache_reset
  echo "Back in developer mode."
}

# mkcert makes certificates from a local authority; mkcert -install, which trusts it, changes the system, so I leave it to you.
cmd_cert() {
  load_env
  require_tools mkcert
  local host="${APP_HOST:-magento.test}"
  (
    umask 077
    mkcert -cert-file etc/tls/cert.pem -key-file etc/tls/key.pem "$host" localhost 127.0.0.1
  )
  # Traefik watches this folder, so the certificate is served as soon as the file appears.
  cat >etc/traefik/dynamic/tls.yml <<'YAML'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/tls/cert.pem
        keyFile: /etc/traefik/tls/key.pem
YAML
  echo "Serving https://$host:${HTTPS_PORT:-8443}/ with it. If your browser still warns, run mkcert -install once."
}

cmd_info() {
  load_env
  local bind="${BIND_ADDRESS:-127.0.0.1}" state=stopped cert="Traefik's own self-signed certificate, until kapelos cert"
  local site="${COMPOSE_PROJECT_NAME:-kapelos}"
  running_projects | holds -qx "$site" && state=running
  if [[ -f etc/tls/cert.pem ]] && command -v openssl >/dev/null &&
    openssl x509 -in etc/tls/cert.pem -noout -text 2>/dev/null | holds -qE "DNS:${APP_HOST:-magento.test}(,|\$)"; then
    cert="trusted, from kapelos cert"
  fi

  cat <<EOF

  Site         $site, $state. Settings in $(follow_link "$ENV_FILE")
  Code         ${MAGENTO_SRC:-not set}
  Ports        $(site_block_words)

  Store        ${MAGENTO_BASE_URL:-not set}
  Admin        ${MAGENTO_BASE_URL%/}/${MAGENTO_ADMIN_URI:-admin}
               user ${MAGENTO_ADMIN_USER:-admin}, password ${MAGENTO_ADMIN_PASSWORD:-not set}
  HTTPS        https://${APP_HOST:-localhost}:${HTTPS_PORT:-8443}/  ($cert)
EOF
  if [[ ,${COMPOSE_PROFILES:-}, == *,mail,* ]]; then
    echo "  Mail         http://$bind:${MAIL_UI_PORT:-8025}  (every email the store sends lands here)"
  else
    echo "  Mail         sent to ${SMTP_HOST:-mailpit}:${SMTP_PORT:-1025}, your own mail catcher"
  fi
  cat <<EOF

  Database     $bind:${DB_PORT:-13306}, database ${DB_NAME:-magento}
               user ${DB_USER:-magento}, password ${DB_PASSWORD:-not set}  ·  root password ${DB_ROOT_PASSWORD:-not set}
               or a prompt: kapelos db
  Valkey       kapelos valkey cache  ·  kapelos valkey session   (not published outside the stack)
  OpenSearch   http://$bind:${OPENSEARCH_PORT:-9200}
  RabbitMQ     http://$bind:${RABBITMQ_UI_PORT:-15672}  user ${RABBITMQ_USER:-magento}, password ${RABBITMQ_PASSWORD:-not set}
EOF
  if scaled; then
    local n servers
    servers="web-1 http://$bind:$(scale_port 1)/"
    for n in $(scale_extra_servers); do
      servers="$servers  ·  web-$n http://$bind:$(scale_port "$n")/"
    done
    echo "  Servers      $servers"
    [[ $(scale_replicas) -eq 0 ]] || echo "  Replica      db-replica, connection replica in env.php  ·  kapelos scale shows how it's doing"
  fi
  cat <<EOF

  Xdebug       listen on port 9003, and map /app to ${MAGENTO_SRC:-your Magento folder}
               the browser extension's cookie or ?XDEBUG_TRIGGER=1 sends a request to the debugging PHP

EOF
}
