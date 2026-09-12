# Getting a store in: downloading one, installing it, and loading a database into it.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

download_magento() {
  local distribution="$1" repository package
  case "$distribution" in
    mage-os) repository=https://repo.mage-os.org/ package=mage-os/project-community-edition ;;
    magento) repository=https://repo.magento.com/ package=magento/project-community-edition ;;
    *) die "unknown Magento distribution: $distribution" ;;
  esac
  [[ -z $(ls -A "$MAGENTO_SRC" 2>/dev/null) ]] || die "$MAGENTO_SRC isn't empty, so Magento can't be downloaded into it"
  step "Downloading $package into $MAGENTO_SRC"
  compose run --rm --no-deps php composer create-project --no-interaction --repository-url="$repository" "$package" .
}

# The keys go into Composer's own settings inside the site's volume, never onto a command line on the host.
store_marketplace_keys() {
  KAPELOS_PUBLIC_KEY="$1" KAPELOS_PRIVATE_KEY="$2" compose run --rm --no-deps \
    -e KAPELOS_PUBLIC_KEY -e KAPELOS_PRIVATE_KEY php \
    sh -c 'composer config -g http-basic.repo.magento.com "$KAPELOS_PUBLIC_KEY" "$KAPELOS_PRIVATE_KEY"'
}

# setup:upgrade exits 0 even when the sample data fails, so Magento's own flag file is what decides.
add_sample_data() {
  step "Adding sample products"
  exec_php php -d memory_limit=-1 bin/magento sampledata:deploy
  # Composer copies the sample media into pub/media/downloadable, which the install already made, one folder too deep.
  exec_php sh -c 'if [ -d pub/media/downloadable/downloadable ]; then cp -a pub/media/downloadable/downloadable/. pub/media/downloadable/ && rm -rf pub/media/downloadable/downloadable; fi'
  exec_php php -d memory_limit=-1 bin/magento setup:upgrade
  if [[ $(exec_quiet php cat var/.sample-data-state.flag 2>/dev/null </dev/null) == error ]]; then
    die "Magento couldn't install all the sample data; the reasons are in var/log/system.log under \"Sample Data error\". It can't retry over a half-finished import, so the database starts again: kapelos down, docker compose down -v (which deletes it), remove app/etc/env.php, then kapelos magento-install, which brings the sample data in with it"
  fi
  magento indexer:reindex
}

cmd_demo() {
  local file="$SITES_DIR/demo.env" code="$KAPELOS_HOME/$STORES_DIR/demo"
  if [[ ! -f $file ]]; then
    mkdir -p "$SITES_DIR"
    write_env "$file" \
      "COMPOSE_PROJECT_NAME=kapelos-demo" \
      "MAGENTO_SRC=$code" \
      "APP_HOST=localhost" \
      "MAGENTO_BASE_URL=http://localhost:8080/" \
      "DISPOSABLE=yes"
  fi
  require_free_to_switch demo kapelos-demo
  cmd_use demo quiet
  load_env
  mkdir -p "$MAGENTO_SRC"
  [[ -f $MAGENTO_SRC/composer.json ]] || download_magento mage-os
  cmd_up
  if installed; then
    echo "The demo store is already installed."
  else
    cmd_magento_install
    modules_add
  fi
  cmd_info
}

cmd_interactive() {
  [[ -t 0 ]] || die "interactive needs a terminal to ask its questions. For a setup with no questions, use: kapelos demo"
  local name source code host https=n sample=n kingletas=n dump="" public="" private="" url

  echo "A few questions, then Kapelos sets the store up without asking again."
  echo
  ask "Name for this site" "store"
  name="$REPLY"
  valid_site_name "$name"
  [[ ! -f $SITES_DIR/$name.env ]] || die "there's already a site called $name. kapelos use $name switches to it"

  echo
  echo "Where does the Magento code come from?"
  echo "  1) Download Mage-OS, which needs no account"
  echo "  2) Download Magento Open Source, which needs Marketplace access keys"
  echo "  3) A folder you already have"
  ask "Choose" 1
  source="$REPLY"
  case "$source" in
    1 | 2)
      code="$KAPELOS_HOME/$STORES_DIR/$name"
      [[ -z $(ls -A "$code" 2>/dev/null) ]] || die "$code isn't empty"
      if [[ $source == 2 ]]; then
        ask "Marketplace public key"
        public="$REPLY"
        read -r -s -p "Marketplace private key (not shown): " private
        echo
        [[ -n $public && -n $private ]] || die "both keys are needed to download Magento Open Source"
      fi
      ;;
    3)
      ask "Path to the Magento folder"
      [[ -d $REPLY && -f $REPLY/bin/magento ]] || die "$REPLY isn't a Magento folder: there's no bin/magento in it"
      code="$(absolute_path "$REPLY")"
      if [[ -f $code/app/etc/env.php ]]; then
        echo "This store is already installed somewhere, so it needs its database."
        ask "Path to a database dump (.sql or .sql.gz)"
        [[ -f $REPLY ]] || die "there's no file at $REPLY"
        dump="$(absolute_path "$(dirname "$REPLY")")/$(basename "$REPLY")"
      fi
      ;;
    *) die "choose 1, 2 or 3" ;;
  esac

  echo
  ask "Hostname for the store" "$name.test"
  host="$REPLY"
  if command -v mkcert >/dev/null && ask_yes "Use HTTPS with a certificate your browser trusts?" y; then
    https=y
  fi
  if [[ $source != 3 ]] && ask_yes "Add sample products? It takes several more minutes" n; then
    sample=y
  fi
  if [[ $source != 3 ]] && ask_yes "Add the Kingletas modules (catalog-access, promotion-access, process-guard, section-policy, cache-vary)?" y; then
    kingletas=y
  fi

  url="http://$host:8080/"
  [[ $https == y ]] && url="https://$host:8443/"

  echo
  echo "Setting up $name at $url. This takes a few minutes and needs nothing more from you."
  echo
  mkdir -p "$SITES_DIR"
  write_env "$SITES_DIR/$name.env" \
    "COMPOSE_PROJECT_NAME=kapelos-$name" \
    "MAGENTO_SRC=$code" \
    "APP_HOST=$host" \
    "MAGENTO_BASE_URL=$url" \
    "DISPOSABLE=$([[ -n $dump ]] && echo no || echo yes)"
  require_free_to_switch interactive "kapelos-$name"
  cmd_use "$name" quiet
  load_env
  mkdir -p "$MAGENTO_SRC"

  if [[ $source == 2 ]]; then
    store_marketplace_keys "$public" "$private"
    download_magento magento
  elif [[ $source == 1 ]]; then
    download_magento mage-os
  fi

  cmd_up
  [[ $https == n ]] || cmd_cert

  if [[ -n $dump ]]; then
    cmd_import "$dump"
    cmd_connect
  else
    cmd_magento_install
    [[ $sample == n ]] || add_sample_data
    [[ $kingletas == n ]] || modules_add
  fi

  if [[ $host != localhost ]] && ! awk -v h="$host" '$1 == "127.0.0.1" { for (i = 2; i <= NF; i++) if ($i == h) found = 1 } END { exit !found }' /etc/hosts 2>/dev/null; then
    echo
    echo "One thing left, which needs your password: add this line to /etc/hosts so $host reaches your machine."
    echo "  127.0.0.1 $host"
  fi
  cmd_info
}

cmd_import() {
  local dump="${1:-}"
  [[ -n $dump ]] || die "name the dump to load, for example: kapelos import ~/backups/store.sql.gz"
  [[ -f $dump ]] || die "there's no file at $dump"
  load_env
  require_running db
  require_empty_database
  step "Loading $dump into ${DB_NAME:-magento}"
  # DEFINER clauses name users from the server the dump came from, and would stop the import here.
  case "$dump" in
    *.gz) gzip -dc "$dump" ;;
    *) cat "$dump" ;;
  esac | sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' | db_root "${DB_NAME:-magento}"
  echo "Loaded $(db_table_count) tables. Now run: kapelos connect"
}

table_prefix() {
  exec_quiet php php -r '$c = include "app/etc/env.php"; echo $c["db"]["table_prefix"] ?? "";' </dev/null
}

config_table() {
  printf '%score_config_data' "$(table_prefix)"
}

# Prints the PHP that rewrites the servers an env.php names so the store runs on Kapelos; everything else in it is kept.
# It reads the file named by its first argument and writes the second. KAPELOS_ADOPT=1 keeps the store's mode and pins its addresses in the file instead of the database.
env_php_builder() {
  cat <<'PHP'
<?php
[, $in, $out] = $argv;
$env = is_file($in) ? include $in : [];
$adopt = getenv('KAPELOS_ADOPT') === '1';
$url = getenv('MAGENTO_BASE_URL');
$dbName = getenv('DB_NAME') ?: 'magento';
$withoutSecrets = function (array $options): array {
    foreach (array_keys($options) as $key) {
        if ($key === 'password' || str_starts_with((string) $key, 'sentinel')) {
            unset($options[$key]);
        }
    }
    return $options;
};

// Every connection moves to Kapelos's database server, and one naming the store's own database gets DB_NAME.
$main = $env['db']['connection']['default']['dbname'] ?? null;
$env['db']['table_prefix'] = $env['db']['table_prefix'] ?? '';
$env['db']['connection']['default'] = $env['db']['connection']['default'] ?? [];
foreach ($env['db']['connection'] as $name => $connection) {
    $own = $name === 'default' || ($connection['dbname'] ?? null) === $main;
    $env['db']['connection'][$name] = array_merge($connection, [
        'host' => 'db',
        'dbname' => $own ? $dbName : $connection['dbname'],
        'username' => getenv('DB_USER') ?: 'magento',
        'password' => getenv('DB_PASSWORD'),
        'model' => $connection['model'] ?? 'mysql4',
        'engine' => $connection['engine'] ?? 'innodb',
        'initStatements' => $connection['initStatements'] ?? 'SET NAMES utf8;',
        'active' => '1',
    ]);
}
// A read replica has nowhere to point here, so reads go to the one database.
unset($env['db']['slave_connection']);

$session = is_array($env['session']['redis'] ?? null) ? $withoutSecrets($env['session']['redis']) : [];
$env['session'] = ['save' => 'redis', 'redis' => array_merge(['disable_locking' => '1'], $session, [
    'host' => 'valkey-session', 'port' => '6379', 'database' => '0',
])];

$frontends = $env['cache']['frontend'] ?? [];
$prefix = $frontends['default']['id_prefix'] ?? 'kapelos_';
foreach (['default' => '0', 'page_cache' => '1'] as $frontend => $database) {
    $current = $frontends[$frontend] ?? [];
    $backend = (string) ($current['backend'] ?? '');
    $valkey = ['server' => 'valkey-cache', 'port' => '6379', 'database' => $database];
    if (stripos($backend, 'RemoteSynchronizedCache') !== false) {
        $remote = $current['backend_options']['remote_backend_options'] ?? [];
        $current['backend_options']['remote_backend_options'] = array_merge($withoutSecrets($remote), $valkey);
    } else {
        $current['backend'] = stripos($backend, 'redis') !== false ? $backend : 'Magento\\Framework\\Cache\\Backend\\Redis';
        $current['backend_options'] = array_merge($withoutSecrets($current['backend_options'] ?? []), $valkey);
    }
    $current['id_prefix'] = $current['id_prefix'] ?? $prefix;
    $frontends[$frontend] = $current;
}
$env['cache']['frontend'] = $frontends;

$amqp = is_array($env['queue']['amqp'] ?? null) ? $env['queue']['amqp'] : [];
unset($amqp['ssl'], $amqp['ssl_options']);
$env['queue']['amqp'] = array_merge($amqp, [
    'host' => 'rabbitmq', 'port' => '5672', 'user' => getenv('RABBITMQ_USER') ?: 'magento',
    'password' => getenv('RABBITMQ_PASSWORD'), 'virtualhost' => '/',
]);
$env['http_cache_hosts'] = [['host' => 'varnish', 'port' => '80']];
$env['lock'] = ['provider' => 'db'];
$env['remote_storage'] = ['driver' => 'file'];
if (!$adopt) {
    $env['MAGE_MODE'] = 'developer';
}
$env['backend']['frontName'] = $env['backend']['frontName'] ?? (getenv('MAGENTO_ADMIN_URI') ?: 'admin');
$env['install']['date'] = $env['install']['date'] ?? date('D, d M Y H:i:s O');
$env['crypt']['key'] = $env['crypt']['key'] ?? bin2hex(random_bytes(16));

// Search goes to Kapelos's OpenSearch, and mail through PHP's sendmail, which Kapelos hands to its mail catcher.
$search = $withoutSecrets($env['system']['default']['catalog']['search'] ?? []);
unset($search['opensearch_username'], $search['opensearch_password']);
$env['system']['default']['catalog']['search'] = array_merge($search, [
    'engine' => 'opensearch', 'opensearch_server_hostname' => 'opensearch',
    'opensearch_server_port' => '9200', 'opensearch_enable_auth' => '0',
]);
$smtp = $env['system']['default']['system']['smtp'] ?? [];
unset($smtp['host'], $smtp['port'], $smtp['username'], $smtp['password']);
$env['system']['default']['system']['smtp'] = array_merge($smtp, ['transport' => 'sendmail']);

// An adopted store's addresses are pinned here, so its database copy is never changed; connect changes the database instead.
$point = function (array &$config, string $address) use ($adopt): void {
    foreach (['unsecure' => '{{unsecure_base_url}}', 'secure' => '{{secure_base_url}}'] as $kind => $link) {
        if ($adopt) {
            $config['web'][$kind]['base_url'] = $address;
            $config['web'][$kind]['base_link_url'] = $link;
            $config['web'][$kind]['base_static_url'] = '';
            $config['web'][$kind]['base_media_url'] = '';
            continue;
        }
        if (isset($config['web'][$kind]['base_url'])) {
            $config['web'][$kind]['base_url'] = $address;
        }
        unset($config['web'][$kind]['base_link_url'], $config['web'][$kind]['base_static_url'], $config['web'][$kind]['base_media_url']);
    }
    if ($adopt) {
        $secure = str_starts_with($address, 'https://') ? '1' : '0';
        $config['web']['secure']['use_in_frontend'] = $secure;
        $config['web']['secure']['use_in_adminhtml'] = $secure;
        $config['web']['cookie']['cookie_domain'] = '';
    } else {
        unset($config['web']['cookie']['cookie_domain']);
    }
};
$point($env['system']['default'], $url);
foreach (['websites', 'stores'] as $scope) {
    foreach (array_keys($env['system'][$scope] ?? []) as $code) {
        if (isset($env['system'][$scope][$code]['web'])) {
            $point($env['system'][$scope][$code], $url);
        }
    }
}
foreach (preg_split('/\s+/', trim((string) getenv('KAPELOS_STORE_URLS')), -1, PREG_SPLIT_NO_EMPTY) as $pair) {
    [$code, $address] = explode('=', $pair, 2);
    $env['system']['stores'][$code] = $env['system']['stores'][$code] ?? [];
    $point($env['system']['stores'][$code], $address);
}
if ($adopt) {
    $env['system']['default']['admin']['url']['use_custom'] = '0';
    $env['system']['default']['admin']['url']['use_custom_path'] = '0';
}

file_put_contents($out, "<?php\nreturn " . var_export($env, true) . ";\n");
PHP
}

# Rewrites the settings an imported store carries from its old server, so it runs here.
cmd_connect() {
  load_env
  require_running php db
  [[ $(db_table_count) -gt 0 ]] || die "the database is empty. Load the store's dump first: kapelos import DUMP"

  [[ $MAGENTO_BASE_URL =~ ^https?://[A-Za-z0-9.:-]+/$ ]] || die "MAGENTO_BASE_URL should look like http://store.test:8080/, and it's: $MAGENTO_BASE_URL"
  local secure=0 table
  [[ $MAGENTO_BASE_URL == https://* ]] && secure=1

  # bin/magento can't start while env.php still names the old servers, so env.php is rewritten directly.
  step "Pointing app/etc/env.php at Kapelos's database, caches, queue, search and mail"
  env_php_builder | compose exec -T -e DB_NAME -e DB_USER -e DB_PASSWORD -e RABBITMQ_USER -e RABBITMQ_PASSWORD \
    -e MAGENTO_ADMIN_URI -e MAGENTO_BASE_URL php php -- app/etc/env.php app/etc/env.php
  clear_cache_files
  # Magento refuses every command until settings pinned in env.php are imported again.
  magento app:config:import --no-interaction

  table="$(config_table)"
  step "Setting every store's address to $MAGENTO_BASE_URL"
  db_root "${DB_NAME:-magento}" -e "
    UPDATE \`$table\` SET value = '$MAGENTO_BASE_URL'
      WHERE path IN ('web/unsecure/base_url', 'web/secure/base_url');
    UPDATE \`$table\` SET value = '$secure'
      WHERE path IN ('web/secure/use_in_frontend', 'web/secure/use_in_adminhtml');
    DELETE FROM \`$table\` WHERE path IN (
      'web/unsecure/base_link_url', 'web/secure/base_link_url',
      'web/unsecure/base_static_url', 'web/secure/base_static_url',
      'web/unsecure/base_media_url', 'web/secure/base_media_url',
      'web/cookie/cookie_domain', 'admin/url/use_custom', 'admin/url/custom',
      'admin/url/use_custom_path', 'admin/url/custom_path');"

  if ! magento setup:db:status >/dev/null 2>&1; then
    step "Upgrading the database to match the code"
    magento setup:upgrade
  fi
  magento deploy:mode:set developer
  step "Rebuilding the search index, which starts empty here"
  magento indexer:reindex
  cmd_cache_reset
  echo "Connected. Log in to the admin with an account from the imported database, or make one with: kapelos admin:user:create"
}

cmd_magento_install() {
  load_env
  : "${MAGENTO_BASE_URL:?set MAGENTO_BASE_URL in the settings}"
  : "${MAGENTO_ADMIN_PASSWORD:?set MAGENTO_ADMIN_PASSWORD in the settings, or run kapelos env}"

  if installed; then
    die "this tree already has app/etc/env.php, so it's installed. For a store from elsewhere, use kapelos import and kapelos connect"
  fi
  require_empty_database

  # Magento accepts a secure address only when it is https, so an http store gets none.
  local secure=()
  if [[ $MAGENTO_BASE_URL == https://* ]]; then
    secure=(--base-url-secure="$MAGENTO_BASE_URL" --use-secure=1 --use-secure-admin=1)
  fi

  step "Installing Magento"
  exec_php php -d memory_limit=-1 bin/magento setup:install \
    --no-interaction \
    --base-url="$MAGENTO_BASE_URL" \
    ${secure[@]+"${secure[@]}"} \
    --use-rewrites=1 \
    --db-host=db \
    --db-name="${DB_NAME:-magento}" \
    --db-user="${DB_USER:-magento}" \
    --db-password="$DB_PASSWORD" \
    --search-engine=opensearch \
    --opensearch-host=opensearch \
    --opensearch-port=9200 \
    --opensearch-enable-auth=0 \
    --amqp-host=rabbitmq \
    --amqp-port=5672 \
    --amqp-user="${RABBITMQ_USER:-magento}" \
    --amqp-password="$RABBITMQ_PASSWORD" \
    --amqp-virtualhost=/ \
    --session-save=redis \
    --session-save-redis-host=valkey-session \
    --session-save-redis-port=6379 \
    --session-save-redis-db=0 \
    --cache-backend=redis \
    --cache-backend-redis-server=valkey-cache \
    --cache-backend-redis-port=6379 \
    --cache-backend-redis-db=0 \
    --page-cache=redis \
    --page-cache-redis-server=valkey-cache \
    --page-cache-redis-port=6379 \
    --page-cache-redis-db=1 \
    --http-cache-hosts=varnish:80 \
    --backend-frontname="${MAGENTO_ADMIN_URI:-admin}" \
    --admin-user="${MAGENTO_ADMIN_USER:-admin}" \
    --admin-password="$MAGENTO_ADMIN_PASSWORD" \
    --admin-email="${MAGENTO_ADMIN_EMAIL:-admin@example.test}" \
    --admin-firstname=Store \
    --admin-lastname=Admin

  magento deploy:mode:set developer
  echo
  echo "Installed. Storefront: $MAGENTO_BASE_URL"
}
