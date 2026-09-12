# Running a store you already have, as it is, from its own code and a copy of its database.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

# Names each Composer package or app/code module that ships files encoded with SourceGuardian.
adopt_encoded_packages() {
  (
    cd "$1" || exit
    grep -rlI --include='*.php' -m 1 'sg_load(' vendor app/code 2>/dev/null || true
  ) |
    awk -F/ '$1 == "vendor" { print $2 "/" $3; next } { print $3 "/" $4 }' | sort -u
}

# Any running container, Kapelos's own aside, that mounts this path or anything inside it.
adopt_path_in_use() {
  local path="$1" container
  for container in $(docker ps -q); do
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}} {{.Name}}{{range .Mounts}} {{.Source}}{{end}}' "$container"
  done | awk -v home="$KAPELOS_HOME" -v path="$path" '$1 != home { for (i = 3; i <= NF; i++) if ($i == path || index($i, path "/") == 1) { sub(/^\//, "", $2); print $2; break } }'
}

# Copies a MariaDB data directory into the site's database volume, then gives the copy Kapelos's logins; the original is only read.
adopt_copy_datadir() {
  local source="$1" volume="$2" version="$3" databases="$4"
  docker volume create --label com.docker.compose.project="$COMPOSE_PROJECT_NAME" \
    --label com.docker.compose.volume=db-data "$volume" >/dev/null
  [[ -z $(docker run --rm -v "$volume:/to" alpine ls -A /to) ]] || die "the volume $volume already holds a database. docker volume rm $volume deletes it"
  step "Copying the database files, $(docker run --rm -v "$source:/from:ro" alpine du -sh /from | cut -f1) of them"
  docker run --rm -v "$source:/from:ro" -v "$volume:/to" alpine cp -a /from/. /to/
  step "Giving the copy Kapelos's logins"
  docker run --rm -i -v "$volume:/var/lib/mysql" -e DB_ROOT_PASSWORD -e DB_USER -e DB_PASSWORD -e DATABASES="$databases" \
    --entrypoint bash "mariadb:$version" -s <<'SH'
set -eu
mariadbd --user=mysql --skip-grant-tables --skip-networking --socket=/tmp/adopt.sock >/tmp/adopt.log 2>&1 &
for _ in $(seq 1 300); do mariadb --socket=/tmp/adopt.sock -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
{
  echo "FLUSH PRIVILEGES;"
  echo "ALTER USER root@localhost IDENTIFIED VIA mysql_native_password USING PASSWORD('$DB_ROOT_PASSWORD') OR unix_socket;"
  echo "ALTER USER IF EXISTS root@'%' IDENTIFIED BY '$DB_ROOT_PASSWORD';"
  echo "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';"
  echo "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';"
  for database in $DATABASES; do echo "GRANT ALL PRIVILEGES ON \`$database\`.* TO '$DB_USER'@'%';"; done
  # The image's health check signs in with this file, which only a first start writes.
  if [ ! -f /var/lib/mysql/.my-healthcheck.cnf ]; then
    secret="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    for host in localhost 127.0.0.1 ::1; do echo "CREATE USER IF NOT EXISTS healthcheck@'$host' IDENTIFIED BY '$secret'; GRANT USAGE ON *.* TO healthcheck@'$host';"; done
    printf '[mariadb-client]\nport=3306\nsocket=/run/mysqld/mysqld.sock\nuser=healthcheck\npassword=%s\nprotocol=tcp\n' "$secret" >/var/lib/mysql/.my-healthcheck.cnf
    chown mysql:mysql /var/lib/mysql/.my-healthcheck.cnf
    chmod 600 /var/lib/mysql/.my-healthcheck.cnf
  fi
} | mariadb --socket=/tmp/adopt.sock
mariadb-admin --socket=/tmp/adopt.sock shutdown
wait
SH
}

# Asks one address for its page, then for the first stylesheet the page names, which is the theme's.
adopt_check_address() {
  local address="$1" page status css="" css_status="" theme=""
  page="$(mktemp)"
  status="$(curl -sk -o "$page" -w '%{http_code}' --max-time 120 "$address" || echo 000)"
  css="$(grep -o 'https\?://[^"'\'' ]*/static/[^"'\'' ]*/frontend/[^"'\'' ]*\.css' "$page" | head -n 1 || true)"
  rm -f "$page"
  if [[ -n $css ]]; then
    css_status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 60 "$css" || echo 000)"
    theme="$(sed -n 's#.*/static/\(version[0-9]*/\)\{0,1\}frontend/\([^/]*/[^/]*\)/.*#\2#p' <<<"$css")"
  fi
  printf '  %-4s  %s  page %s, theme %s, stylesheet %s\n' "$([[ $status == 200 && $css_status == 200 ]] && echo pass || echo FAIL)" \
    "$address" "$status" "${theme:-none found}" "${css_status:-none}"
  [[ $status == 200 && $css_status == 200 ]]
}

# Writes Kapelos's env.php for an adopted store from the store's own, which it only reads.
write_adopted_env_php() {
  local dir
  dir="$(dirname "$KAPELOS_ENV_PHP")"
  mkdir -p "$dir"
  env_php_builder | compose run --rm --no-deps -T -e KAPELOS_ADOPT=1 -e KAPELOS_STORE_URLS="$(store_urls)" \
    -e DB_NAME -e DB_USER -e DB_PASSWORD -e RABBITMQ_USER -e RABBITMQ_PASSWORD -e MAGENTO_ADMIN_URI -e MAGENTO_BASE_URL \
    -v "$MAGENTO_SRC/app/etc/env.php:/kapelos-in/env.php:ro" -v "$dir:/kapelos-out" \
    php php -- /kapelos-in/env.php "/kapelos-out/$(basename "$KAPELOS_ENV_PHP")"
  chmod 600 "$KAPELOS_ENV_PHP"
}

cmd_adopt() {
  local path="" name="" datadir="" dump="" url="" proxy="" reindex=yes store stores=() urls="" facts
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name | --datadir | --dump | --url | --store | --proxy)
        [[ $# -ge 2 ]] || die "$1 needs a value"
        case "$1" in
          --name) name="$2" ;;
          --datadir) datadir="$2" ;;
          --dump) dump="$2" ;;
          --url) url="$2" ;;
          --store) stores+=("$2") ;;
          --proxy) proxy="$2" ;;
        esac
        shift 2
        ;;
      --no-reindex)
        reindex=no
        shift
        ;;
      -*) die "adopt doesn't know $1. See: kapelos help" ;;
      *)
        [[ -z $path ]] || die "adopt takes one store folder, and got a second: $1"
        path="$1"
        shift
        ;;
    esac
  done
  [[ -n $path ]] || die "name the store's folder, for example: kapelos adopt ~/projects/store --datadir ~/projects/store-db"
  [[ -f $path/bin/magento ]] || die "$path isn't a Magento folder: there's no bin/magento in it"
  [[ -f $path/app/etc/env.php ]] || die "$path has no app/etc/env.php, so it isn't installed. For a store that isn't, use kapelos env and kapelos magento-install"
  [[ -n $datadir || -n $dump ]] || die "adopt needs the store's database: --datadir for a MariaDB data directory, or --dump for a dump"
  [[ -z $datadir || -z $dump ]] || die "give --datadir or --dump, not both"
  [[ -z $dump || -f $dump ]] || die "there's no file at $dump"
  # Docker records a mount by its resolved path, so these are resolved too.
  path="$(cd "$path" && pwd -P)"
  if [[ -n $datadir ]]; then
    [[ -d $datadir ]] || die "there's no folder at $datadir"
    datadir="$(cd "$datadir" && pwd -P)"
    docker run --rm -v "$datadir:/from:ro" alpine test -f /from/ibdata1 || die "$datadir doesn't look like a MariaDB data directory: there's no ibdata1 in it"
  fi
  [[ -z $dump ]] || dump="$(absolute_path "$(dirname "$dump")")/$(basename "$dump")"

  [[ -n $name ]] || name="$(basename "$path" | tr '[:upper:]_. ' '[:lower:]---')"
  valid_site_name "$name"
  [[ ! -f $SITES_DIR/$name.env ]] || die "there's already a site called $name. Pick another with --name, or kapelos use $name"
  [[ -n $url ]] || url="http://$name.test:8080/"
  [[ $url =~ ^(https?)://([A-Za-z0-9.-]+)(:[0-9]+)?/$ ]] || die "--url should look like http://store.test:8080/ or https://store.test/, and it's: $url"
  local host="${BASH_REMATCH[2]}" port="${BASH_REMATCH[3]}"
  for store in ${stores[@]+"${stores[@]}"}; do
    [[ $store =~ ^[A-Za-z0-9.-]+=[a-z0-9_]+$ ]] || die "--store takes HOST=STORE_CODE, such as second.test=second_store, and got: $store"
  done
  if [[ -z $port && $host != localhost ]]; then
    [[ -n $proxy ]] || die "$url has no port, so it has to come through a reverse proxy. Name its Docker network with --proxy, or give an address such as http://$host:8080/"
  fi

  require_trusted "$path"
  local busy
  busy="$(adopt_path_in_use "$path"; [[ -z $datadir ]] || adopt_path_in_use "$datadir")"
  [[ -z $busy ]] || die "$(tr '\n' ' ' <<<"$busy")is running with this store's code or database. Stop it first: two stacks serving one store fight over it"

  echo "Adopting $path as the site $name, at $url"
  local settings=(
    "COMPOSE_PROJECT_NAME=kapelos-$name"
    "MAGENTO_SRC=$path"
    "APP_HOST=$host"
    "MAGENTO_BASE_URL=$url"
    "DISPOSABLE=no"
    "KAPELOS_ENV_PHP=$KAPELOS_HOME/var/sites/$name/env.php"
  )
  if [[ -n $proxy ]]; then
    settings+=("PROXY_NETWORK=$proxy" "COMPOSE_FILE=compose.yaml:compose.proxy.yaml")
  fi
  [[ ${#stores[@]} -eq 0 ]] || settings+=("STORES=${stores[*]}")

  step "Looking for extensions encoded with SourceGuardian"
  local encoded
  encoded="$(adopt_encoded_packages "$path")"
  if [[ -n $encoded ]]; then
    echo "        $(tr '\n' ' ' <<<"$encoded")"
    settings+=("INSTALL_SOURCEGUARDIAN=true")
  fi
  require_free_to_switch adopt "kapelos-$name"
  mkdir -p "$SITES_DIR" "var/sites/$name"
  write_env "$SITES_DIR/$name.env" "${settings[@]}"
  # The self-test adopts a store without changing which site you're on.
  [[ ${ADOPT_SWITCH:-yes} == no ]] || cmd_use "$name" quiet
  ENV_FILE="$SITES_DIR/$name.env"
  load_env

  # Magento's own nginx rules run only its four entry points, so any other script in pub/ answers 404 here.
  local scripts
  scripts="$(cd "$path/pub" && for script in *.php; do
    case "$script" in index.php | get.php | static.php | health_check.php | '*.php') ;; *) printf '%s ' "$script" ;; esac
  done)"
  if [[ -n $scripts ]]; then
    echo "        pub/ has PHP files Magento's nginx rules won't run, so they answer 404: $scripts"
    echo "        If the store's own web server runs any of them, give Kapelos its rules with MAGENTO_NGINX_CONF."
  fi

  step "Building this site's PHP"
  compose --progress quiet build php
  # Reads what the store is from its own files, with its own Composer libraries.
  facts="$(compose run --rm --no-deps -T php php -r '
    require "vendor/autoload.php";
    $env = include "app/etc/env.php";
    $lock = json_decode(file_get_contents("composer.lock"), true);
    $edition = "unknown";
    foreach ($lock["packages"] as $package) {
        if (preg_match("#^(magento|mage-os)/product-[a-z]+-edition$#", $package["name"])) { $edition = $package["name"] . " " . $package["version"]; }
    }
    $wanted = json_decode(file_get_contents("composer.json"), true)["require"]["php"] ?? "*";
    $php = "";
    foreach (["8.4", "8.3", "8.2", "8.1"] as $candidate) {
        if (Composer\Semver\Semver::satisfies("$candidate.99", $wanted) || Composer\Semver\Semver::satisfies("$candidate.0", $wanted)) { $php = $candidate; break; }
    }
    $main = $env["db"]["connection"]["default"]["dbname"] ?? "magento";
    $databases = [$main => true];
    foreach ($env["db"]["connection"] ?? [] as $connection) { $databases[$connection["dbname"] ?? $main] = true; }
    printf("edition=%s\nphp=%s\nwanted=%s\nmode=%s\nmain=%s\ndatabases=%s\nadmin=%s\n", $edition, $php, $wanted, $env["MAGE_MODE"] ?? "default", $main, implode(" ", array_keys($databases)), $env["backend"]["frontName"] ?? "admin");
  ')"
  local edition wanted mode main databases php_version admin
  edition="$(sed -n 's/^edition=//p' <<<"$facts")"
  php_version="$(sed -n 's/^php=//p' <<<"$facts")"
  wanted="$(sed -n 's/^wanted=//p' <<<"$facts")"
  mode="$(sed -n 's/^mode=//p' <<<"$facts")"
  main="$(sed -n 's/^main=//p' <<<"$facts")"
  databases="$(sed -n 's/^databases=//p' <<<"$facts")"
  admin="$(sed -n 's/^admin=//p' <<<"$facts")"
  echo "        $edition, $mode mode, PHP $wanted, database $main"
  local release row mariadb opensearch valkey rabbitmq varnish nginx
  release="$(magento_release "$path")"
  row="$(release_versions "$release")"
  if [[ -n $row ]]; then
    IFS=$'\t' read -r mariadb opensearch valkey rabbitmq varnish nginx <<<"$row"
    mariadb="${mariadb%% *}" opensearch="${opensearch%% *}" valkey="${valkey%% *}"
    rabbitmq="${rabbitmq%% *}" varnish="${varnish%% *}" nginx="${nginx%% *}"
    echo "        for Magento $release: MariaDB $mariadb, OpenSearch $opensearch, Valkey $valkey, RabbitMQ $rabbitmq, Varnish $varnish, nginx $nginx"
    set_env_value "$ENV_FILE" MARIADB_VERSION "$mariadb"
    set_env_value "$ENV_FILE" OPENSEARCH_VERSION "$opensearch"
    set_env_value "$ENV_FILE" VALKEY_VERSION "$valkey"
    set_env_value "$ENV_FILE" RABBITMQ_VERSION "$rabbitmq"
    set_env_value "$ENV_FILE" VARNISH_VERSION "$varnish"
    set_env_value "$ENV_FILE" NGINX_VERSION "$nginx"
  else
    echo "        Magento ${release:-of an unknown release} isn't in etc/magento-versions.tsv, so it runs Kapelos's default service versions"
  fi
  [[ -n $php_version ]] || die "the store wants PHP $wanted, and Kapelos builds 8.1 to 8.4"
  set_env_value "$ENV_FILE" DB_NAME "$main"
  if [[ $php_version != "${PHP_VERSION:-8.4}" ]]; then
    set_env_value "$ENV_FILE" PHP_VERSION "$php_version"
    load_env
    step "Building PHP $php_version, which the store needs"
    compose --progress quiet build php
  fi
  load_env

  step "Writing Kapelos's env.php for the store, which keeps its own"
  write_adopted_env_php
  set_env_value "$ENV_FILE" COMPOSE_FILE "$(env_value "$ENV_FILE" COMPOSE_FILE):compose.adopt.yaml"
  load_env

  if [[ -n $datadir ]]; then
    local version
    version="$(docker run --rm -v "$datadir:/from:ro" alpine cat /from/mariadb_upgrade_info 2>/dev/null | grep -o '^[0-9]*\.[0-9]*' || true)"
    if [[ -n $version ]]; then
      set_env_value "$ENV_FILE" MARIADB_VERSION "$version"
      load_env
    fi
    adopt_copy_datadir "$datadir" "${COMPOSE_PROJECT_NAME}_db-data" "${MARIADB_VERSION:-11.4}" "$databases"
  fi

  cmd_up
  [[ -z $dump ]] || cmd_import "$dump"
  clear_cache_files

  local behind
  if ! behind="$(magento setup:db:status 2>&1 </dev/null)"; then
    if [[ $mode == developer || $mode == default ]]; then
      step "Upgrading the database to match the code"
      magento setup:upgrade
    else
      # In production mode setup:upgrade clears the compiled code, which only a deploy puts back, so the store runs as it is.
      echo "        The database is behind the code: $(tr '\n' ' ' <<<"$behind")"
      echo "        Left as it is, since setup:upgrade in $mode mode clears the compiled code. The checks below show whether the store serves anyway."
    fi
  fi
  if ! magento app:config:status >/dev/null 2>&1; then
    magento app:config:import --no-interaction
  fi

  local package file result
  for package in $encoded; do
    file="$(cd "$path" && { grep -rlI --include='*.php' -m 1 'sg_load(' "vendor/$package" "app/code/$package" 2>/dev/null || true; } | head -n 1)"
    result="$(exec_quiet php php -r 'require "vendor/autoload.php"; include $argv[1];' "$file" 2>&1 </dev/null | grep -io 'sourceguardian[^<]*' | head -n 1 || true)"
    echo "        $package: ${result:-loads}"
  done

  local products
  products="$(db_root -N "${DB_NAME:-magento}" -e "SELECT COUNT(*) FROM \`$(table_prefix)catalog_product_entity\`" </dev/null)"
  if [[ $reindex == yes ]]; then
    step "Building the search index for $products products, which starts empty here"
    # An index the old server left marked as working refuses a reindex, and nothing is working on it here.
    magento indexer:reset catalogsearch_fulltext
    local started=$SECONDS
    magento indexer:reindex catalogsearch_fulltext
    echo "        $((SECONDS - started)) s"
  else
    echo "        The search index starts empty, so Magento's own category listings and search show no products until it's built."
    echo "        For $products products: kapelos magento indexer:reset catalogsearch_fulltext, then kapelos magento indexer:reindex catalogsearch_fulltext"
  fi
  cmd_cache_reset

  # RabbitMQ starts empty, and Magento declares its queues only in setup:upgrade, which the store's mode or a current database skips.
  local failed=0
  cmd_queues || failed=1

  urls="$(store_urls)"
  step "Asking each address for its page and its theme"
  local address status known
  known="$(db_root -N "${DB_NAME:-magento}" -e "SELECT code FROM \`$(table_prefix)store\` WHERE store_id > 0" </dev/null | tr '\n' ' ')"
  adopt_check_address "$url" || failed=1
  for address in $urls; do
    if [[ " $known " != *" ${address%%=*} "* ]]; then
      printf '  %-4s  %s  runs the store %s, which this database doesn'\''t have. Its stores: %s\n' FAIL "${address#*=}" "${address%%=*}" "$known"
      failed=1
      continue
    fi
    adopt_check_address "${address#*=}" || failed=1
  done
  status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 120 "$url$admin/" || echo 000)"
  printf '  %-4s  %s  page %s\n' "$([[ $status == 200 ]] && echo pass || echo FAIL)" "$url$admin/" "$status"
  [[ $status == 200 ]] || failed=1
  echo
  echo "Adopted. The store's own app/etc/env.php is unchanged; Kapelos's version is var/sites/$name/env.php."
  [[ $failed -eq 0 ]] || die "not every check passed; the lines above say which"
}
