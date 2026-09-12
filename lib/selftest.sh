# Kapelos checking itself: kapelos check, check-image and self-test.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

cmd_check() {
  require_tools docker shellcheck yamllint

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

cmd_check_image() {
  require_tools docker

  local required=(bcmath ftp gd intl pcntl pdo_mysql redis soap sockets xdebug xsl zip "Zend OPcache")
  docker build --quiet -t kapelos-php:check opt/php >/dev/null
  docker build --quiet -t kapelos-php:check-sourceguardian --build-arg INSTALL_SOURCEGUARDIAN=true opt/php >/dev/null

  local modules ext missing=0
  modules="$(docker run --rm kapelos-php:check php -m)"
  for ext in "${required[@]}"; do
    if ! grep -qix "$ext" <<<"$modules"; then
      echo "missing extension: $ext" >&2
      missing=1
    fi
  done

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
  trap 'compose down -v >/dev/null 2>&1; rm -rf "$SELF_TEST_SCRATCH"' EXIT
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
  verify "the Kingletas modules install and enable" kingletas_modules_install
  verify "site audit runs through, and a fresh store passes all but its dependencies" audit_passes_beyond_dependencies
  verify "a dump loads and connects into an empty database" store_survives_reimport "$scratch"
  verify "deploy reaches production mode" cmd_deploy
  verify "the store answers in production mode" status_is 200 "$STORE_URL"
  verify "develop goes back to developer mode" cmd_develop
  verify "the store answers in developer mode" status_is 200 "$STORE_URL"
  verify "adopt runs the store from a dump as a second site, declares its queues, and leaves its env.php alone" adopted_copy_serves "$scratch"

  echo
  [[ $SELF_TEST_FAILED -eq 0 ]] || die "self-test failed"
  echo "self-test: every check passed. Removing the throwaway store."
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
  [[ $(modules_status | grep -c ' yes ') -eq $(module_rows | wc -l | tr -d ' ') ]]
}

not_debug_routed() {
  ! has_header x-kapelos-xdebug "$STORE_URL"
}

# The store's address is HTTP, so Magento may redirect; a TLS handshake that fails gives 000.
https_answers() {
  [[ $(http_status -k "https://localhost:${HTTPS_PORT:-8443}/") != 000 ]]
}
