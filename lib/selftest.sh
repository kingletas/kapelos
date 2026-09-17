# Kapelos checking itself: kapelos check, check-image and self-test.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

cmd_check() {
  require_tools docker shellcheck yamllint python3

  CHECK_SCRATCH="$(mktemp -d)"
  trap 'rm -rf "$CHECK_SCRATCH"' EXIT
  local scratch="$CHECK_SCRATCH" kept listed

  write_env "$scratch/env" "MAGENTO_SRC=$scratch" "PROXY_NETWORK=proxy"

  echo "compose: base"
  docker compose --env-file "$scratch/env" -f compose.yaml config --quiet
  echo "compose: base + proxy"
  docker compose --env-file "$scratch/env" -f compose.yaml -f compose.proxy.yaml config --quiet
  echo "compose: base + adopt"
  touch "$scratch/env.php"
  set_env_value "$scratch/env" KAPELOS_ENV_PHP "$scratch/env.php"
  docker compose --env-file "$scratch/env" -f compose.yaml -f compose.adopt.yaml config --quiet
  echo "compose: an adopted site with no KAPELOS_ENV_PHP is refused"
  sed '/^KAPELOS_ENV_PHP=/d' "$scratch/env" >"$scratch/env-no-php"
  if docker compose --env-file "$scratch/env-no-php" -f compose.yaml -f compose.adopt.yaml config --quiet 2>/dev/null; then
    die "compose accepted an adopted site with no KAPELOS_ENV_PHP"
  fi

  echo "compose: a missing MAGENTO_SRC is refused"
  sed '/^MAGENTO_SRC=/d' "$scratch/env" >"$scratch/env-no-src"
  if docker compose --env-file "$scratch/env-no-src" -f compose.yaml config --quiet 2>/dev/null; then
    die "compose accepted a stack with no MAGENTO_SRC"
  fi

  echo "project: a store's allowed settings are read, and STORES becomes nginx's map"
  mkdir -p "$scratch/store/.kapelos/commands"
  write_env "$scratch/env-project" "MAGENTO_SRC=$scratch/store" "COMPOSE_PROJECT_NAME=kapelos-check-project" "PROXY_NETWORK=proxy"
  printf 'PHP_VERSION=8.3\nSTORES="second.test=second_store"\n' >"$scratch/store/.kapelos/settings.env"
  (
    ENV_FILE="$scratch/env-project"
    load_env
    [[ $PHP_VERSION == 8.3 && $PROXY_HOSTS == *second.test* ]] && grep -q 'second.test "second_store"' "$NGINX_STORES"
  ) || die "a store's .kapelos/settings.env wasn't applied"
  echo "project: a setting a project can't set is refused, and so is an unsafe value"
  for bad in 'BIND_ADDRESS=0.0.0.0' 'MAGENTO_NGINX_CONF=/etc/passwd' 'STORES=a.test=../x'; do
    printf '%s\n' "$bad" >"$scratch/store/.kapelos/settings.env"
    if (ENV_FILE="$scratch/env-project" && load_env) 2>/dev/null; then
      die "a store's .kapelos/settings.env was allowed to set $bad"
    fi
  done
  rm "$scratch/store/.kapelos/settings.env"
  echo "project: a compose file runs only once trusted, and not after it changes"
  printf 'services:\n  kapelos-check-extra:\n    image: alpine\n' >"$scratch/store/.kapelos/compose.yaml"
  if (ENV_FILE="$scratch/env-project" && compose config --services) >/dev/null 2>&1; then
    die "an untrusted .kapelos/compose.yaml was used"
  fi
  cmd_trust "$scratch/store" >/dev/null
  (ENV_FILE="$scratch/env-project" && compose config --services) | grep -qx kapelos-check-extra ||
    die "a trusted .kapelos/compose.yaml wasn't used"
  printf '    command: ["true"]\n' >>"$scratch/store/.kapelos/compose.yaml"
  if (ENV_FILE="$scratch/env-project" && compose config --services) >/dev/null 2>&1; then
    die "a .kapelos/compose.yaml changed after it was trusted was still used"
  fi
  echo "project: a store's own command runs once trusted, from the store's folder"
  rm "$scratch/store/.kapelos/compose.yaml"
  printf '#!/bin/sh\n# Says hello from the store.\necho "hello $1 from $(pwd)"\n' >"$scratch/store/.kapelos/commands/hello"
  chmod +x "$scratch/store/.kapelos/commands/hello"
  if KAPELOS_ENV="$scratch/env-project" "$KAPELOS_HOME/bin/kapelos" hello there >/dev/null 2>&1; then
    die "an untrusted .kapelos/commands file ran"
  fi
  cmd_trust "$scratch/store" >/dev/null
  [[ $(KAPELOS_ENV="$scratch/env-project" "$KAPELOS_HOME/bin/kapelos" hello there) == "hello there from $scratch/store" ]] ||
    die "a trusted .kapelos/commands file didn't run from the store's folder"
  listed="$(KAPELOS_ENV="$scratch/env-project" "$KAPELOS_HOME/bin/kapelos" help)"
  grep -q 'hello *Says hello from the store' <<<"$listed" || die "kapelos help doesn't list the store's own commands"

  echo "commands: the shipped ones install with their lib, keep a changed file, and are trusted when nothing else is unread"
  rm -rf "$scratch/store/.kapelos/commands"
  KAPELOS_ENV="$scratch/env-project" "$KAPELOS_HOME/bin/kapelos" commands add orders >/dev/null
  [[ -x $scratch/store/.kapelos/commands/orders && -f $scratch/store/.kapelos/commands/lib/place-orders.php ]] ||
    die "kapelos commands add didn't install the command and the lib file it names"
  project_is_trusted "$(cd "$scratch/store" && pwd -P)" || die "kapelos commands add left the store untrusted"
  printf '# changed\n' >>"$scratch/store/.kapelos/commands/orders"
  # Read into a variable rather than piping: grep -q leaves early, and under pipefail the SIGPIPE reads as failure.
  kept="$(KAPELOS_ENV="$scratch/env-project" "$KAPELOS_HOME/bin/kapelos" commands add orders)"
  grep -q '^  kept ' <<<"$kept" || die "kapelos commands add overwrote a command that had been changed"
  KAPELOS_ENV="$scratch/env-project" "$KAPELOS_HOME/bin/kapelos" commands remove orders -f >/dev/null
  [[ ! -e $scratch/store/.kapelos/commands/lib/place-orders.php ]] ||
    die "kapelos commands remove left behind a lib file nothing names any more"

  rm -rf "var/sites/check-project" "$(project_trust_file "$(cd "$scratch/store" && pwd -P)")"

  check_scale "$scratch"

  echo "autoload: a class map naming generated classes that are gone is spotted, and a healthy one is not"
  local tree="$scratch/autoload"
  mkdir -p "$tree/vendor/composer" "$tree/generated/code/Magento"
  printf '<?php return array("X" => $baseDir . "/generated/code/X.php");\n' >"$tree/vendor/composer/autoload_classmap.php"
  printf '<?php\n' >"$tree/generated/code/Magento/Thing.php"
  MAGENTO_SRC="$tree" autoload_is_stale && die "a store with its generated code present was called stale"
  MAGENTO_SRC="$tree" autoload_is_optimised || die "an optimised class map with generated code present wasn't spotted"
  rm -rf "$tree/generated/code"
  MAGENTO_SRC="$tree" autoload_is_stale || die "a class map naming generated classes that are gone wasn't spotted"
  MAGENTO_SRC="$tree" autoload_is_optimised && die "a store with no generated code was called optimised"
  printf '<?php return array();\n' >"$tree/vendor/composer/autoload_classmap.php"
  MAGENTO_SRC="$tree" autoload_is_stale && die "a plain class map with no generated code was called stale"
  MAGENTO_SRC=/nonexistent autoload_is_stale && die "a store that isn't there was called stale"

  echo "kapelos: an unknown command is refused"
  if "$KAPELOS_HOME/bin/kapelos" no-such-command >/dev/null 2>&1; then
    die "an unknown command exited 0"
  fi

  echo "kapelos: runs under bash 3.2, the version macOS ships"
  docker run --rm -v "$KAPELOS_HOME:/kapelos:ro" -w /kapelos bash:3.2 bash -c '
    set -e
    for lib in lib/*.sh; do bash -n "$lib"; done
    bash -n bin/kapelos
    bash bin/kapelos help >/dev/null
    bash bin/kapelos commands >/dev/null
    KAPELOS_ENV=/tmp/no-such-file bash bin/kapelos info >/dev/null 2>&1 && exit 1
    bash bin/kapelos no-such-command >/dev/null 2>&1 && exit 1
    cp -r /kapelos /tmp/k && cd /tmp/k && rm -f .env && bash bin/kapelos env >/dev/null && grep -q "^DB_PASSWORD=.\{32\}$" .env
  ' || die "bin/kapelos failed under bash 3.2"

  echo "shellcheck"
  # -a is what reaches lib/: -x alone follows a source for the names in it and reports nothing found inside.
  shellcheck -a -x bin/kapelos
  shellcheck packaging/*.sh scripts/check-install scripts/install scripts/uninstall
  local command
  for command in share/commands/*; do
    # The lib folder beside them holds PHP and SQL, which check-image parses instead.
    if [[ -f $command ]]; then
      shellcheck "$command"
    fi
  done

  echo "yamllint"
  yamllint --strict compose.yaml compose.proxy.yaml compose.adopt.yaml etc/traefik .github

  rm -rf "$scratch"
  trap - EXIT
  echo "check: all passed"
}

# The compose file and VCL kapelos scale writes, checked without starting anything.
check_scale() {
  local scratch="$1" env="$1/env-scale" plain scaled bad out
  mkdir -p "$scratch/scale/pub/media"
  write_env "$env" "MAGENTO_SRC=$scratch/scale" "COMPOSE_PROJECT_NAME=kapelos-check-scale"

  echo "scale: the ordinary shape adds nothing to the stack"
  plain="$(docker compose --env-file "$env" -f compose.yaml config)"
  [[ $(ENV_FILE="$env" && compose config) == "$plain" ]] || die "a site on one web server and no replica runs a different stack from compose.yaml alone"
  [[ ! -e var/sites/check-scale/scale.yaml ]] || die "the ordinary shape wrote a scale overlay"

  echo "scale: two web servers and a replica are valid compose, each server with its own name, code and port"
  set_env_value "$env" WEB_SERVERS 2
  set_env_value "$env" DB_REPLICAS 1
  scaled="$(ENV_FILE="$env" && compose config --format json)"
  python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
def ports(name):
    return [p["published"] for p in services[name].get("ports", [])]
def mounted(name, path):
    return [v for v in services[name]["volumes"] if v["target"] == path]
assert services["php"]["hostname"] == "web-1", "php is not web-1"
assert services["php-2"]["hostname"] == "web-2", "php-2 is not web-2"
assert mounted("php-2", "/app")[0]["source"] == "app-2", "php-2 does not run its own copy"
assert mounted("web-2", "/app")[0]["source"] == "app-2", "web-2 does not serve its own copy"
assert mounted("php-2", "/run/php")[0]["source"] == "php-socket-2", "php-2 shares server 1 socket"
assert mounted("php-2", "/app/pub/media"), "php-2 does not share the media folder"
assert ports("web") == ["8081"] and ports("web-2") == ["8082"], "the servers are not on 8081 and 8082"
assert "--log-bin=mysql-bin" in services["db"]["command"], "the database has no binary log"
assert "--log-bin-trust-function-creators=1" in services["db"]["command"], "triggers would be refused with the binary log on"
assert "--read-only=1" in services["db-replica"]["command"], "the replica is writable"
assert mounted("varnish", "/etc/varnish/site.vcl"), "Varnish does not load the site VCL beside the round robin"
assert "web-2" in services["varnish"]["depends_on"], "Varnish does not restart when web-2 is recreated"
' <<<"$scaled" || die "the scaled stack is not the shape kapelos scale promises"
  # It holds absolute paths, which run as long as the folder Kapelos lives in.
  yamllint --strict -d '{extends: default, rules: {document-start: disable, line-length: disable}}' var/sites/check-scale/scale.yaml

  echo "scale: the round robin compiles around the site's own VCL"
  # Varnish looks each backend's name up while compiling, so the names are given an address here.
  docker run --rm --add-host web:127.0.0.1 --add-host web-2:127.0.0.1 \
    -v "$KAPELOS_HOME/var/sites/check-scale/scale.vcl:/etc/varnish/default.vcl:ro" \
    -v "$KAPELOS_HOME/etc/varnish/default.vcl:/etc/varnish/site.vcl:ro" \
    --entrypoint varnishd "varnish:$(env_value "$env" VARNISH_VERSION)" -C -f /etc/varnish/default.vcl >/dev/null 2>&1 ||
    die "the VCL kapelos scale writes doesn't compile"

  echo "scale: a replica alone leaves the web servers as they are"
  set_env_value "$env" WEB_SERVERS 1
  scaled="$(ENV_FILE="$env" && compose config --services)"
  if ! grep -qx db-replica <<<"$scaled" || grep -qx php-2 <<<"$scaled"; then
    die "DB_REPLICAS=1 on one web server didn't add just the replica"
  fi
  [[ ! -e var/sites/check-scale/scale.vcl ]] || die "one web server still has a round-robin VCL"

  echo "scale: a shape Kapelos doesn't run is refused"
  for bad in WEB_SERVERS=0 WEB_SERVERS=5 WEB_SERVERS=two DB_REPLICAS=2; do
    set_env_value "$env" WEB_SERVERS 1
    set_env_value "$env" DB_REPLICAS 0
    set_env_value "$env" "${bad%%=*}" "${bad#*=}"
    if (ENV_FILE="$env" && load_env) 2>/dev/null; then
      die "a site with $bad was accepted"
    fi
  done
  set_env_value "$env" DB_REPLICAS 0
  for bad in web=9 replica=2 servers=2; do
    out="$(KAPELOS_ENV="$env" "$KAPELOS_HOME/bin/kapelos" scale "$bad" -y 2>&1)" && die "kapelos scale $bad was accepted"
    grep -q "not ${bad#*=}" <<<"$out" || grep -q "not $bad" <<<"$out" || die "kapelos scale $bad failed for another reason: $out"
  done
  [[ $(env_value "$env" WEB_SERVERS) == 1 ]] || die "a refused kapelos scale changed the settings"

  echo "scale: a store whose own compose file already runs db-replica is refused"
  mkdir -p "$scratch/scale/.kapelos"
  printf 'services:\n  db-replica:\n    image: alpine\n' >"$scratch/scale/.kapelos/compose.yaml"
  out="$(KAPELOS_ENV="$env" "$KAPELOS_HOME/bin/kapelos" scale replica=1 -y 2>&1)" && die "kapelos scale ran beside a store's own db-replica"
  grep -q 'already defines db-replica' <<<"$out" || die "kapelos scale failed for another reason beside a store's own db-replica: $out"
  rm -rf "$scratch/scale/.kapelos"

  rm -rf var/sites/check-scale
}

cmd_check_image() {
  require_tools docker

  local required=(bcmath ftp gd intl pcntl pdo_mysql redis soap sockets xdebug xsl zip "Zend OPcache")
  docker build --quiet -t kapelos-php:check opt/php >/dev/null
  docker build --quiet -t kapelos-php:check-sourceguardian --build-arg INSTALL_SOURCEGUARDIAN=true opt/php >/dev/null

  # The containers add Xdebug's own scan directory, and compiling leaves it out, so both are checked.
  local modules ext missing=0 scan=/usr/local/etc/php/conf.d:/usr/local/etc/php/xdebug.d
  modules="$(docker run --rm -e PHP_INI_SCAN_DIR="$scan" kapelos-php:check php -m)"
  for ext in "${required[@]}"; do
    if ! grep -qix "$ext" <<<"$modules"; then
      echo "missing extension: $ext" >&2
      missing=1
    fi
  done

  if docker run --rm kapelos-php:check php -m | grep -qix xdebug; then
    echo "Xdebug loads without its scan directory, so compiling would load it too" >&2
    missing=1
  fi

  if ! docker run --rm kapelos-php:check-sourceguardian php -m | grep -qix sourceguardian; then
    echo "missing extension: SourceGuardian, in the image built with INSTALL_SOURCEGUARDIAN=true" >&2
    missing=1
  fi
  if grep -qix sourceguardian <<<"$modules"; then
    echo "SourceGuardian is loaded in the default image, where it should be off" >&2
    missing=1
  fi

  echo "the PHP behind the example commands parses"
  docker run --rm -v "$KAPELOS_HOME/share:/share:ro" kapelos-php:check \
    sh -c 'for file in /share/commands/lib/*.php; do php -l "$file" >/dev/null || exit 1; done' ||
    die "a file in share/commands/lib doesn't parse"

  [[ $missing -eq 0 ]] || exit 1
  echo "check-image: every extension is present"
}

# Each check runs in its own subshell with errexit on: a failing step fails the check, and a die ends only that check.
verify() {
  local description="$1" status
  shift
  set +e
  (
    set -e
    "$@"
  ) >/dev/null 2>&1
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    echo "  pass  $description"
  else
    echo "  FAIL  $description"
    SELF_TEST_FAILED=1
  fi
}

http_status() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

status_is() {
  local expected="$1"
  shift
  [[ $(http_status "$@") == "$expected" ]]
}

has_header() {
  local header="$1"
  shift
  curl -s -o /dev/null -D - "$@" | grep -qi "^$header"
}

mail_arrives() {
  exec_quiet php php -r 'exit(mail("someone@example.test", "kapelos self-test", "hello") ? 0 : 1);' &&
    sleep 1 &&
    curl -s "http://127.0.0.1:${MAIL_UI_PORT:-8025}/api/v1/messages" | grep -q 'kapelos self-test'
}

xdebug_off_in_php() {
  [[ $(exec_quiet php php -r 'echo json_encode(xdebug_info("mode"));') == "[]" ]]
}

valkey_empty_after_reset() {
  cmd_cache_reset
  [[ $(exec_quiet valkey-cache valkey-cli DBSIZE) == 0 ]]
}

install_refused() {
  ! (cmd_magento_install)
}

# Adopts the throwaway store as a second site from a dump of its database, then removes that site.
adopted_copy_serves() {
  local dump="$1/adopt.sql.gz" before site=self-test-adopted served
  exec_quiet db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction "$MARIADB_DATABASE"' | gzip >"$dump"
  before="$(cksum <"$MAGENTO_SRC/app/etc/env.php")"
  compose down
  # Its own subshell, so a failure inside adopt stops adopt and still reaches the clean-up below.
  set +e
  (
    set -e
    ADOPT_SWITCH=no cmd_adopt "$MAGENTO_SRC" --dump "$dump" --name "$site" --url "$STORE_URL" --no-reindex
    status_is 200 "$STORE_URL"
    [[ -n $(docker compose -p "kapelos-$site" exec -T rabbitmq rabbitmqctl -q list_queues --no-table-headers name </dev/null) ]]
  )
  served=$?
  set -e
  docker compose --progress quiet -p "kapelos-$site" down -v
  rm -rf "$SITES_DIR/$site.env" "var/sites/$site"
  [[ $served -eq 0 && $(cksum <"$MAGENTO_SRC/app/etc/env.php") == "$before" ]]
}

# With declaring refused, a queue deleted from RabbitMQ has to be reported; with it allowed again, it's declared back.
queue_missing_reported() {
  local user="${RABBITMQ_USER:-magento}" status=0
  exec_quiet rabbitmq rabbitmqctl -q delete_queue product_action_attribute.update </dev/null
  exec_quiet rabbitmq rabbitmqctl -q set_permissions -p / "$user" '^$' '.*' '.*' </dev/null
  cmd_queues || status=$?
  exec_quiet rabbitmq rabbitmqctl -q set_permissions -p / "$user" '.*' '.*' '.*' </dev/null
  [[ $status -ne 0 ]] && cmd_queues
}

store_survives_reimport() {
  local dump="$1/store.sql.gz"
  exec_quiet db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction "$MARIADB_DATABASE"' | gzip >"$dump"
  db_root -e "DROP DATABASE \`${DB_NAME:-magento}\`; CREATE DATABASE \`${DB_NAME:-magento}\`;"
  cmd_import "$dump"
  cmd_connect
  status_is 200 "$STORE_URL"
}

# Everything below runs against a throwaway site in a temporary folder, and removes it at the end.
cmd_self_test() {
  require_tools docker curl gzip
  [[ -z $(running_projects) ]] || die "$(running_projects | head -n 1) is running. The self-test needs the ports to itself; stop it first with: kapelos down"

  cmd_check
  cmd_check_image

  local scratch
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/kapelos-self-test.XXXXXX")"
  ENV_FILE="$scratch/env"
  SELF_TEST_SCRATCH="$scratch"
  trap 'compose down -v >/dev/null 2>&1; remove_self_test_volumes; rm -rf "$SELF_TEST_SCRATCH"' EXIT
  write_env "$ENV_FILE" \
    "COMPOSE_PROJECT_NAME=kapelos-self-test" \
    "MAGENTO_SRC=$scratch/magento" \
    "APP_HOST=localhost" \
    "MAGENTO_BASE_URL=http://localhost:8080/"
  load_env
  mkdir -p "$MAGENTO_SRC"
  STORE_URL="$MAGENTO_BASE_URL"

  download_magento mage-os
  cmd_up
  cmd_magento_install

  echo
  echo "Self-test"
  verify "the storefront answers" status_is 200 "$STORE_URL"
  verify "the admin answers" status_is 200 "${STORE_URL}admin/"
  verify "HTTPS answers, with Traefik's own certificate" https_answers
  verify "an ordinary request goes to the PHP with Xdebug off" xdebug_off_in_php
  verify "an Xdebug cookie goes to the debugging PHP" has_header x-kapelos-xdebug -b XDEBUG_SESSION=1 "$STORE_URL"
  verify "a plain request doesn't" not_debug_routed
  verify "Magento commands run directly" magento cache:status
  verify "every queue the store declares is in RabbitMQ" cmd_queues
  verify "a queue that couldn't be declared is reported missing" queue_missing_reported
  verify "mail reaches Mailpit" mail_arrives
  verify "cache-reset empties Valkey" valkey_empty_after_reset
  verify "installing over an existing database is refused" install_refused
  verify "the Kingletas modules install from their Composer repository and enable" kingletas_modules_install
  verify "site audit runs through, and a fresh store passes all but its dependencies" audit_passes_beyond_dependencies
  verify "a dump loads and connects into an empty database" store_survives_reimport "$scratch"
  verify "deploy reaches production mode" cmd_deploy
  verify "the store answers in production mode" status_is 200 "$STORE_URL"
  verify "develop goes back to developer mode" cmd_develop
  verify "the store answers in developer mode" status_is 200 "$STORE_URL"

  local before
  before="$(site_fingerprint)"
  verify "scale web=2 replica=1 spreads requests over two servers, each also on its own port" scaled_servers_answer
  verify "a write on the primary reaches the replica, and web-2's env.php names it" replica_follows_writes
  verify "composer copies the code to the other server, and a changed store reads as newer until it does" copies_follow_composer
  verify "deploy reaches production mode, scaled" cmd_deploy
  verify "every server is in production mode, and the store answers" every_server_answers production
  verify "develop goes back to developer mode, scaled" cmd_develop
  verify "every server is in developer mode, and the store answers" every_server_answers developer
  verify "a snapshot restore copies the database to the replica again" restore_reseeds_replica
  verify "scale web=1 replica=0 leaves the site exactly as it was before scaling" scaled_back_as_before "$before"
  verify "adopt runs the store from a dump as a second site, declares its queues, and leaves its env.php alone" adopted_copy_serves "$scratch"

  echo
  [[ $SELF_TEST_FAILED -eq 0 ]] || die "self-test failed"
  echo "self-test: every check passed. Removing the throwaway store."
}

# A scaled site's copies and replica aren't in compose.yaml, so down -v alone leaves them when a scaled check fails.
remove_self_test_volumes() {
  docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-kapelos-self-test}" |
    while IFS= read -r volume; do docker volume rm "$volume" >/dev/null 2>&1 || true; done
}

# What scaling back has to return to: the stack, env.php, the database's accounts and binary log, and the site's volumes.
site_fingerprint() {
  {
    compose config
    cksum <"$MAGENTO_SRC/app/etc/env.php"
    db_root -N -e "SELECT CONCAT(user, '@', host) FROM mysql.user ORDER BY 1; SELECT @@log_bin" </dev/null
    exec_quiet db sh -c 'ls /var/lib/mysql | grep -c "^mysql-bin" || true' </dev/null
    docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | sort
  } | sha256_stdin
}

server_header_values() {
  local i
  for i in 1 2 3 4; do
    curl -s -o /dev/null -D - "$STORE_URL" | tr -d '\r' | sed -n 's/^[Xx]-[Kk]apelos-[Ss]erver: //p'
  done
}

scaled_servers_answer() {
  local seen host
  cmd_scale web=2 replica=1 -y
  seen="$(server_header_values)"
  grep -qx web-1 <<<"$seen" || return 1
  grep -qx web-2 <<<"$seen" || return 1
  host="$(printf '%s' "$STORE_URL" | sed -E 's#^https?://([^/]+).*#\1#')"
  status_is 200 -H "Host: $host" "http://127.0.0.1:$(scale_port 2)/"
  [[ $(exec_quiet php-2 hostname </dev/null | tr -d '\r') == web-2 ]]
}

replica_follows_writes() {
  local marker="self-test-$$-$RANDOM" tries=0 table
  table="$(config_table)"
  db_root "${DB_NAME:-magento}" -e "INSERT INTO \`$table\` (scope, scope_id, path, value) VALUES ('default', 0, 'kapelos/self_test/replica', '$marker') ON DUPLICATE KEY UPDATE value = '$marker'" </dev/null
  until [[ $(replica_root -N "${DB_NAME:-magento}" -e "SELECT value FROM \`$table\` WHERE path = 'kapelos/self_test/replica'" </dev/null) == "$marker" ]]; do
    tries=$((tries + 1))
    [[ $tries -lt 30 ]] || return 1
    sleep 1
  done
  db_root "${DB_NAME:-magento}" -e "DELETE FROM \`$table\` WHERE path = 'kapelos/self_test/replica'" </dev/null
  exec_quiet php-2 php -r '$env = include "app/etc/env.php"; exit(($env["db"]["connection"]["replica"]["host"] ?? "") === "db-replica" ? 0 : 1);' </dev/null
}

copies_follow_composer() {
  local file="$MAGENTO_SRC/app/kapelos-self-test.txt" status=0
  ! scale_copy_stale 2 || return 1
  sleep 1
  date >"$file"
  scale_copy_stale 2 || status=1
  cmd_composer dump-autoload --no-interaction >/dev/null || status=1
  exec_quiet php-2 test -f app/kapelos-self-test.txt </dev/null || status=1
  ! scale_copy_stale 2 || status=1
  rm -f "$file"
  return "$status"
}

every_server_answers() {
  local mode="$1"
  [[ $(magento_mode) == "$mode" ]] || return 1
  [[ $(exec_quiet php-2 php bin/magento deploy:mode:show </dev/null | sed -n 's/.*Current application mode: \([a-z]*\).*/\1/p') == "$mode" ]] || return 1
  status_is 200 "$STORE_URL" && status_is 200 "$STORE_URL"
}

restore_reseeds_replica() {
  cmd_snapshot save self-test-scaled
  cmd_snapshot restore self-test-scaled -y
  cmd_snapshot delete self-test-scaled -y
  replica_follows_writes
}

scaled_back_as_before() {
  cmd_scale web=1 replica=0 -y
  status_is 200 "$STORE_URL" && [[ $(site_fingerprint) == "$1" ]]
}

# Whether the dependencies pass depends on what advisories are published that week; everything else the audit checks has to.
audit_passes_beyond_dependencies() {
  local out
  out="$(cmd_site audit 2>&1 || true)"
  [[ $out == *"Security headers Magento sends"* ]] || return 1
  ! printf '%s\n' "$out" | sed -n '/^Credentials, checked/,$p' | grep -q '^  FAIL '
}

kingletas_modules_install() {
  modules_add
  [[ $(modules_status | grep -c ' yes ') -eq $(module_rows | wc -l | tr -d ' ') ]] || return 1
  store_has_repository "$(repository_url kingletas)" && [[ -z $(legacy_module_repositories) ]]
}

not_debug_routed() {
  ! has_header x-kapelos-xdebug "$STORE_URL"
}

# The store's address is HTTP, so Magento may redirect; a TLS handshake that fails gives 000.
https_answers() {
  [[ $(http_status -k "https://localhost:${HTTPS_PORT:-8443}/") != 000 ]]
}
