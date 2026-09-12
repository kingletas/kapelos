# The stack day to day: starting it, its data, its caches, its queues and its addresses.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

# docker compose --wait gives up at once on a container still marked unhealthy from before, so restart those once and wait again.
cmd_up() {
  load_env
  local current other
  current="${COMPOSE_PROJECT_NAME:-kapelos}"
  other="$(running_projects | grep -vx "$current" | head -n 1 || true)"
  [[ -z $other ]] || die "$other is already running, and Kapelos runs one site at a time. Switch with kapelos use, or stop it with: docker compose -p $other down"

  if ! compose up -d --wait; then
    local unhealthy
    unhealthy="$(compose ps --status running --format '{{.Service}} {{.Health}}' | awk '$2 == "unhealthy" { print $1 }' | tr '\n' ' ')"
    [[ -n $unhealthy ]] || exit 1
    echo "kapelos: $unhealthy reported unhealthy; restarting and waiting once more" >&2
    # shellcheck disable=SC2086 # one word per service
    compose restart $unhealthy
    compose up -d --wait
  fi
  echo "Store: ${MAGENTO_BASE_URL:-http://localhost:8080/}  ·  kapelos info shows everything else"
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
      cmd_up
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
      if compose ps --status running --services 2>/dev/null | grep -qx db && installed; then
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

  deploy_step "Turning on maintenance mode" magento maintenance:enable
  deploy_step "Installing packages without the development ones" exec_php composer install --no-dev --no-interaction
  deploy_step "Upgrading the database" magento setup:upgrade
  deploy_step "Compiling dependency injection" exec_php php -d memory_limit=-1 bin/magento setup:di:compile
  # The class map is built after compiling, or it points at generated classes setup:upgrade just deleted.
  deploy_step "Optimising the autoloader" exec_php composer dump-autoload --optimize --no-dev
  deploy_step "Deploying static files for ${locales[*]}" magento setup:static-content:deploy -f "${locales[@]}"
  if manipulus_in_use; then
    deploy_step "Writing the manipulus bundles into the fresh static files" manipulus_write
    deploy_step "Refreshing the integrity hashes checkout checks the bundles against" magento manipulus:integrity:refresh
  fi
  deploy_step "Switching to production mode" magento deploy:mode:set production --skip-compilation
  deploy_step "Emptying every cache" cmd_cache_reset
  deploy_step "Turning off maintenance mode" magento maintenance:disable
  echo "Deployed. The store is in production mode; kapelos develop goes back."
}

cmd_develop() {
  load_env
  require_running php
  step "Installing packages, including the development ones"
  exec_php composer install --no-interaction
  step "Switching to developer mode"
  magento deploy:mode:set developer
  step "Turning off maintenance mode"
  magento maintenance:disable
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
  running_projects | grep -qx "$site" && state=running
  if [[ -f etc/tls/cert.pem ]] && command -v openssl >/dev/null &&
    openssl x509 -in etc/tls/cert.pem -noout -text 2>/dev/null | grep -qE "DNS:${APP_HOST:-magento.test}(,|\$)"; then
    cert="trusted, from kapelos cert"
  fi

  cat <<EOF

  Site         $site, $state. Settings in $(follow_link "$ENV_FILE")
  Code         ${MAGENTO_SRC:-not set}

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

  Xdebug       listen on port 9003, and map /app to ${MAGENTO_SRC:-your Magento folder}
               the browser extension's cookie or ?XDEBUG_TRIGGER=1 sends a request to the debugging PHP

EOF
}
