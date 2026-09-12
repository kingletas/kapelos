# The tools that run against a store: the modules, the browser suites, act and PHPUnit.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

tool_state() {
  local dir="var/tools/${COMPOSE_PROJECT_NAME:-kapelos}/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

cmd_sample_data() {
  load_env
  require_running php
  installed || die "the store isn't installed yet. Run: kapelos magento-install"
  add_sample_data
  cmd_cache_reset
}

cmd_bluetir() {
  load_env
  require_site_running
  local mode=order
  case "${1:-}" in
    order | pages | probe | persona | baseline | acceptance)
      mode="$1"
      shift
      ;;
  esac
  if [[ $mode == order ]] && ! disposable; then
    die "bluetir's order mode places a real order, and this site isn't marked DISPOSABLE=yes. Pages, probe, persona, baseline and acceptance don't write: kapelos bluetir pages"
  fi
  tool_state bluetir >/dev/null
  compose --progress quiet build bluetir >/dev/null
  compose run --rm --no-deps bluetir -c /kapelos/store.yml -b "${MAGENTO_BASE_URL%/}" --mode "$mode" "$@"
}

cmd_drexbot() {
  load_env
  require_site_running
  local state flag="" ca=()
  state="$(tool_state drexbot)"
  disposable && flag=1
  # drexbot never turns certificate checks off, so an HTTPS store's mkcert root is handed to it.
  if [[ $MAGENTO_BASE_URL == https://* ]] && command -v mkcert >/dev/null && [[ -f "$(mkcert -CAROOT)/rootCA.pem" ]]; then
    ca=(-v "$(mkcert -CAROOT)/rootCA.pem:/tmp/kapelos-ca.pem:ro" -e NODE_EXTRA_CA_CERTS=/tmp/kapelos-ca.pem)
  fi
  compose --progress quiet build drexbot >/dev/null
  [[ $# -gt 0 ]] || set -- run --target magento
  if [[ $1 == run && -z $(ls -A "$state/baselines" 2>/dev/null) ]]; then
    step "Capturing what's in the store first, which drexbot's checks read"
    compose run --rm --no-deps -e MAGENTO_DISPOSABLE="$flag" ${ca[@]+"${ca[@]}"} drexbot baseline --target magento
  fi
  compose run --rm --no-deps -e MAGENTO_DISPOSABLE="$flag" ${ca[@]+"${ca[@]}"} drexbot "$@"
  # drexbot prints only what changed since its last run, so a run where everything passed says nothing.
  if [[ $1 == run ]]; then
    echo "drexbot reports only what changed. Every check's result is in $state/results/, and --verbose lists them as they run."
  fi
}

manipulus_where() {
  local locale
  read -r locale _ <<<"${DEPLOY_LOCALES:-en_US}"
  printf '%s\n' --root /site --theme "${MANIPULUS_THEME:-frontend/Magento/luma}" --locale "$locale"
}

manipulus_plan_file() {
  printf 'var/tools/%s/manipulus/manipulus.plan.json' "${COMPOSE_PROJECT_NAME:-kapelos}"
}

manipulus_write() {
  local location=() line
  while IFS= read -r line; do location+=("$line"); done < <(manipulus_where)
  compose --progress quiet build manipulus >/dev/null
  compose run --rm --no-deps -T manipulus build "${location[@]}" --plan /out/manipulus.plan.json --module /site/app/code/Manipulus/Bundles "$@"
}

# The bundles live in pub/static, which a production setup:upgrade clears, so a deploy writes them again after the static files.
manipulus_in_use() {
  [[ -f $MAGENTO_SRC/app/code/Manipulus/Bundles/registration.php && -f $(manipulus_plan_file) ]]
}

# manipulus reads the static files a production deploy writes.
cmd_manipulus() {
  load_env
  local command="${1:-plan}" theme="${MANIPULUS_THEME:-frontend/Magento/luma}" location=() line locale
  [[ $# -gt 0 ]] && shift
  while IFS= read -r line; do location+=("$line"); done < <(manipulus_where)
  locale="${location[5]}"
  # In developer mode pub/static holds only what's been requested so far, and a plan made from that is empty.
  require_running php
  if ! magento deploy:mode:show </dev/null 2>/dev/null | grep -q production ||
    [[ ! -f $MAGENTO_SRC/pub/static/$theme/$locale/requirejs-config.js ]]; then
    die "manipulus reads the static files a production deploy writes, and this store isn't in production mode with $theme/$locale deployed. Run kapelos deploy first"
  fi
  tool_state manipulus >/dev/null
  compose --progress quiet build manipulus >/dev/null
  case "$command" in
    plan) compose run --rm --no-deps manipulus plan "${location[@]}" --out /out/manipulus.plan.json "$@" ;;
    build)
      [[ -f $(manipulus_plan_file) ]] || die "there's no plan yet. Run: kapelos manipulus plan"
      manipulus_write "$@"
      case " $* " in
        *" -n "* | *" --dry-run "*) return ;;
      esac
      # A deployed store's optimised class map names generated classes that module:enable deletes, so it's rebuilt plain first.
      exec_php composer dump-autoload --no-interaction
      magento module:enable Manipulus_Bundles
      echo "Manipulus_Bundles is written and enabled. kapelos deploy puts it live, and writes the bundles again after the static files every time."
      ;;
    graph | css | check | explain) compose run --rm --no-deps manipulus "$command" "${location[@]}" "$@" ;;
    *) compose run --rm --no-deps manipulus "$command" "$@" ;;
  esac
}

# act is downloaded once and run only if it matches the checksum Kapelos records in etc/act.tsv.
act_binary() {
  local os arch platform version expected actual file tmp
  case "$(uname -s)" in
    Linux) os=Linux ;;
    Darwin) os=Darwin ;;
    *) die "kapelos ci runs on Linux and macOS" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "act has no build for $(uname -m)" ;;
  esac
  platform="${os}_$arch"
  read -r version expected < <(grep -vE '^[[:space:]]*(#|$)' etc/act.tsv | awk -v p="$platform" '$2 == p { print $1, $3 }')
  [[ -n ${expected:-} ]] || die "etc/act.tsv has no checksum for $platform"
  file="var/bin/act-$version"
  if [[ ! -x $file ]]; then
    require_tools curl tar
    mkdir -p var/bin
    tmp="$(mktemp -d)"
    step "Downloading act $version for $platform" >&2
    curl -fsSL -o "$tmp/act.tar.gz" "https://github.com/nektos/act/releases/download/$version/act_$platform.tar.gz"
    actual="$({ sha256sum "$tmp/act.tar.gz" 2>/dev/null || shasum -a 256 "$tmp/act.tar.gz"; } | awk '{ print $1 }')"
    if [[ $actual != "$expected" ]]; then
      rm -rf "$tmp"
      die "the act download doesn't match the checksum in etc/act.tsv, so it was thrown away"
    fi
    tar -xzf "$tmp/act.tar.gz" -C "$tmp" act
    mv "$tmp/act" "$file"
    chmod +x "$file"
    rm -rf "$tmp"
  fi
  printf '%s' "$KAPELOS_HOME/$file"
}

# act copies the store into each job rather than mounting it, so a workflow can never change your files.
cmd_ci() {
  load_env
  [[ -d $MAGENTO_SRC/.github/workflows ]] || die "the store has no .github/workflows, so there's nothing for act to run"
  require_tools docker
  local act
  act="$(act_binary)"
  mkdir -p var/ci/cache var/ci/config
  (
    cd "$MAGENTO_SRC"
    # act keeps a failed job's container and volumes unless told otherwise.
    XDG_CACHE_HOME="$KAPELOS_HOME/var/ci/cache" XDG_CONFIG_HOME="$KAPELOS_HOME/var/ci/config" "$act" --rm \
      -P ubuntu-latest=catthehacker/ubuntu:act-latest \
      -P ubuntu-24.04=catthehacker/ubuntu:act-24.04 \
      -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
      "$@"
  )
}

module_rows() {
  grep -vE '^[[:space:]]*(#|$)' "$MODULES_FILE"
}

# The rows named on the command line by package or short name, or every module when none is.
selected_module_rows() {
  local name found
  if [[ $# -eq 0 ]]; then
    module_rows | awk -F'\t' '$4 == "module"'
    return
  fi
  for name in "$@"; do
    found="$(module_rows | awk -F'\t' -v n="$name" '$4 == "module" && ($1 == n || $1 == "kingletas/module-" n || $2 == n)')"
    [[ -n $found ]] || die "there's no Kingletas module called $name. kapelos modules lists them"
    printf '%s\n' "$found"
  done
}

# Called inside loops that read their list from standard input, so it must never read from it.
package_installed() {
  exec_quiet php test -f "vendor/$1/composer.json" </dev/null
}

modules_status() {
  module_rows | awk -F'\t' '{ print $1 "\t" $2 "\t" $4 }' | exec_quiet php php -r '
    $installed = json_decode((string) @file_get_contents("vendor/composer/installed.json"), true) ?: [];
    $versions = [];
    foreach ($installed["packages"] ?? $installed as $package) {
        $versions[$package["name"]] = $package["pretty_version"] ?? $package["version"];
    }
    $config = is_file("app/etc/config.php") ? include "app/etc/config.php" : [];
    printf("  %-36s %-10s %-8s %s\n", "Package", "Version", "Enabled", "Role");
    while (($line = fgets(STDIN)) !== false) {
        [$package, $module, $role] = explode("\t", rtrim($line, "\n"));
        $there = isset($versions[$package]);
        $enabled = $there ? (($config["modules"][$module] ?? 0) ? "yes" : "no") : "-";
        printf("  %-36s %-10s %-8s %s\n", $package, $there ? $versions[$package] : "-", $enabled, $role);
    }'
}

modules_add() {
  local rows package module version role repository requires=() modules=()
  rows="$(selected_module_rows "$@")"
  step "Adding the Kingletas repositories to composer.json"
  while IFS=$'\t' read -r package module version role repository; do
    exec_quiet php composer config "repositories.${package/\//-}" "{\"type\":\"vcs\",\"url\":\"$repository\",\"no-api\":true}" </dev/null
  done < <(module_rows)
  while IFS=$'\t' read -r package module version role repository; do
    requires+=("$package:$version")
    modules+=("$module")
  done <<<"$rows"

  step "Installing ${requires[*]}"
  exec_php composer require --no-interaction "${requires[@]}"
  # A dependency is enabled only if Composer brought it in, so a list that grows never names a missing module.
  while IFS=$'\t' read -r package module version role repository; do
    [[ $role == dependency ]] && package_installed "$package" && modules+=("$module")
  done < <(module_rows)
  step "Enabling ${modules[*]}"
  magento module:enable "${modules[@]}"
  magento setup:upgrade
  cmd_cache_reset
  echo "Added. kapelos modules shows what's installed."
}

modules_remove() {
  local rows package module version role repository packages=() modules=() leaving
  rows="$(selected_module_rows "$@")"
  while IFS=$'\t' read -r package module version role repository; do
    package_installed "$package" || continue
    packages+=("$package")
    modules+=("$module")
  done <<<"$rows"
  if [[ ${#packages[@]} -eq 0 ]]; then
    echo "None of those is installed."
    return
  fi

  # Composer names the dependencies that leave with them, so their modules are disabled too.
  leaving="$(exec_quiet php composer remove --dry-run --no-interaction "${packages[@]}" </dev/null 2>&1 |
    sed -n 's/.*Removing \(kingletas\/[a-z0-9-]*\).*/\1/p' | sort -u)"
  while IFS=$'\t' read -r package module version role repository; do
    [[ $role == dependency ]] && grep -qx "$package" <<<"$leaving" && modules+=("$module")
  done < <(module_rows)

  step "Disabling ${modules[*]}"
  magento module:disable "${modules[@]}"
  step "Removing ${packages[*]}"
  exec_php composer remove --no-interaction "${packages[@]}" </dev/null

  local any=0
  while IFS=$'\t' read -r package module version role repository; do
    package_installed "$package" && any=1
  done < <(module_rows)
  if [[ $any -eq 0 ]]; then
    step "No Kingletas package is left, so their repositories come out of composer.json too"
    while IFS=$'\t' read -r package module version role repository; do
      exec_quiet php composer config --unset "repositories.${package/\//-}" </dev/null
    done < <(module_rows)
  fi
  magento setup:upgrade
  cmd_cache_reset
  echo "Removed."
}

cmd_modules() {
  local action="${1:-status}"
  [[ $# -gt 0 ]] && shift
  load_env
  require_running php
  case "$action" in
    status) modules_status ;;
    add) modules_add "$@" ;;
    remove) modules_remove "$@" ;;
    *) die "kapelos modules shows them; kapelos modules add [NAME...] and kapelos modules remove [NAME...] change them" ;;
  esac
}

# The Test/Unit or Test/Integration folders under each path, so one kind of test never runs as the other.
test_dirs() {
  exec_quiet php sh -c '
    kind="$1"
    shift
    for path in "$@"; do
      case "$path" in
        */Test/"$kind" | */Test/"$kind"/*) echo "$path" ;;
        *) find "$path" -type d -path "*/Test/$kind" -prune 2>/dev/null ;;
      esac
    done' sh "$@"
}

run_unit_tests() {
  local relative=() dir
  while IFS= read -r dir; do
    [[ -n $dir ]] && relative+=("../../../$dir")
  done < <(test_dirs Unit "$@")
  if [[ ${#relative[@]} -eq 0 ]]; then
    echo "No unit tests under $*."
    return 0
  fi
  step "Unit tests: $*"
  # Magento's unit configuration names files relative to its own folder, so PHPUnit starts there.
  exec_php sh -c 'cd dev/tests/unit && config=phpunit.xml && { [ -f "$config" ] || config=phpunit.xml.dist; } && exec php -d memory_limit=-1 ../../../vendor/bin/phpunit -c "$config" "$@"' sh "${relative[@]}"
}

safe_value() {
  [[ $2 =~ ^[A-Za-z0-9_.@-]+$ ]] || die "$1 has characters the integration test settings can't carry: $2"
}

# Integration tests get their own database, queue vhost and search prefix, so they never touch the store's data.
prepare_integration_tests() {
  local db="${DB_NAME:-magento}_integration" user="${DB_USER:-magento}" config=dev/tests/integration/etc/install-config-mysql.php
  safe_value DB_USER "$user"
  safe_value DB_PASSWORD "$DB_PASSWORD"
  safe_value RABBITMQ_USER "${RABBITMQ_USER:-magento}"
  safe_value RABBITMQ_PASSWORD "$RABBITMQ_PASSWORD"

  db_root -e "CREATE DATABASE IF NOT EXISTS \`$db\`; GRANT ALL ON \`$db\`.* TO '$user'@'%';"
  exec_quiet rabbitmq sh -c 'rabbitmqctl -q add_vhost integration 2>/dev/null; rabbitmqctl -q set_permissions -p integration "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"' >/dev/null

  if exec_quiet php test -f "$config"; then
    return
  fi
  step "Writing $config, which points the tests at their own database. It holds local passwords, so keep it out of git"
  exec_quiet php sh -c 'cat > "$1"' sh "$config" <<PHP
<?php
// Written by kapelos test: a database, queue vhost and search prefix of their own, apart from the store's.
return [
    'db-host' => 'db',
    'db-user' => '$user',
    'db-password' => '$DB_PASSWORD',
    'db-name' => '$db',
    'db-prefix' => '',
    'backend-frontname' => 'backend',
    'search-engine' => 'opensearch',
    'opensearch-host' => 'opensearch',
    'opensearch-port' => 9200,
    'opensearch-index-prefix' => 'integration',
    'amqp-host' => 'rabbitmq',
    'amqp-port' => '5672',
    'amqp-user' => '${RABBITMQ_USER:-magento}',
    'amqp-password' => '$RABBITMQ_PASSWORD',
    'amqp-virtualhost' => 'integration',
    'consumers-wait-for-messages' => '0',
    'admin-user' => \\Magento\\TestFramework\\Bootstrap::ADMIN_NAME,
    'admin-password' => \\Magento\\TestFramework\\Bootstrap::ADMIN_PASSWORD,
    'admin-email' => \\Magento\\TestFramework\\Bootstrap::ADMIN_EMAIL,
    'admin-firstname' => \\Magento\\TestFramework\\Bootstrap::ADMIN_FIRSTNAME,
    'admin-lastname' => \\Magento\\TestFramework\\Bootstrap::ADMIN_LASTNAME,
];
PHP
}

run_integration_tests() {
  local relative=() dir
  while IFS= read -r dir; do
    [[ -n $dir ]] && relative+=("../../../$dir")
  done < <(test_dirs Integration "$@")
  if [[ ${#relative[@]} -eq 0 ]]; then
    echo "No integration tests under $*."
    return 0
  fi
  prepare_integration_tests
  step "Integration tests: $*. Magento installs itself into the test database first, which takes a minute or two"
  # A phpunit.xml of your own wins over Magento's .dist, so TESTS_CLEANUP can be turned off there.
  exec_php sh -c 'cd dev/tests/integration && config=phpunit.xml && { [ -f "$config" ] || config=phpunit.xml.dist; } && exec php -d memory_limit=-1 ../../../vendor/bin/phpunit -c "$config" "$@"' sh "${relative[@]}"
}

cmd_test() {
  local suite=all
  case "${1:-}" in
    unit | integration | all)
      suite="$1"
      shift
      ;;
  esac
  load_env
  require_running php
  exec_quiet php test -x vendor/bin/phpunit || die "PHPUnit isn't installed in this store. After kapelos deploy, kapelos develop brings the development packages back"
  [[ $# -gt 0 ]] || set -- app/code

  local failed=0
  if [[ $suite == unit || $suite == all ]]; then
    run_unit_tests "$@" || failed=1
  fi
  if [[ $suite == integration || $suite == all ]]; then
    run_integration_tests "$@" || failed=1
  fi
  [[ $failed -eq 0 ]] || die "tests failed"
}
