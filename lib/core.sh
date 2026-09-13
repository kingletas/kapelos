# Settings, trust, and the helpers that talk to the containers. Everything else builds on this.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

die() {
  echo "kapelos: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "$tool is not installed, and this command needs it"
  done
}

follow_link() {
  local file="$1" target
  while [[ -L $file ]]; do
    target="$(readlink "$file")"
    [[ $target == /* ]] || target="$(dirname "$file")/$target"
    file="$target"
  done
  printf '%s' "$file"
}

# Reads KEY=VALUE lines without running them, so a settings file can never execute anything.
load_env() {
  [[ -f $ENV_FILE ]] || die "no settings in $ENV_FILE yet. Start with: kapelos demo, kapelos interactive, or kapelos env"
  local line key value
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in '' | '#'*) continue ;; esac
    [[ $line == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$value" in
      \"*\") value="${value#\"}" && value="${value%\"}" ;;
      \'*\') value="${value#\'}" && value="${value%\'}" ;;
    esac
    export "$key=$value"
  done <"$ENV_FILE"
  load_project_settings
  derive_settings
}

project_value_ok() {
  local key="$1" value="$2" part
  case "$key" in
    *_VERSION) [[ $value =~ ^[0-9][0-9A-Za-z.-]*$ ]] ;;
    INSTALL_SOURCEGUARDIAN) [[ $value == true || $value == false ]] ;;
    MAGENTO_NGINX_CONF) [[ $value =~ ^/app/[A-Za-z0-9._/-]+$ && $value != *..* ]] ;;
    STORES) [[ $value =~ ^[A-Za-z0-9.-]+=[a-z0-9_]+( [A-Za-z0-9.-]+=[a-z0-9_]+)*$ ]] ;;
    DEPLOY_LOCALES) [[ $value =~ ^[a-z]{2}_[A-Z]{2}( [a-z]{2}_[A-Z]{2})*$ ]] ;;
    MANIPULUS_THEME) [[ $value =~ ^(frontend|adminhtml)/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$ ]] ;;
    AUDIT_PATHS)
      for part in $value; do
        [[ $part =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]*$ && $part != *..* ]] || return 1
      done
      ;;
    *) return 1 ;;
  esac
}

# The file comes with the store's code, so every line is checked and anything else is refused by name.
load_project_settings() {
  local file="${MAGENTO_SRC:-}/.kapelos/settings.env" line key value
  [[ -n ${MAGENTO_SRC:-} && -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in '' | '#'*) continue ;; esac
    [[ $line == *=* ]] || die "$file: every line is KEY=value, and this one isn't: $line"
    key="${line%%=*}"
    value="${line#*=}"
    case "$value" in
      \"*\") value="${value#\"}" && value="${value%\"}" ;;
      \'*\') value="${value#\'}" && value="${value%\'}" ;;
    esac
    [[ " $PROJECT_KEYS " == *" $key "* ]] || die "$file sets $key, which a project can't. It may set: $PROJECT_KEYS"
    project_value_ok "$key" "$value" || die "$file sets $key=$value, which isn't a value Kapelos accepts for $key"
    export "$key=$value"
  done <"$file"
}

# Where Kapelos keeps what it generates for one site.
site_state_dir() {
  site_state_dir_of "${COMPOSE_PROJECT_NAME:-kapelos}"
}

# STORES becomes nginx's hostname-to-store map, and every hostname the reverse proxy sends here.
derive_settings() {
  [[ -n ${STORES:-} ]] || return 0
  local dir map pair hosts="${APP_HOST:-magento.test}"
  dir="$(site_state_dir)"
  map="$(
    echo "# Written by Kapelos from STORES. Which Magento store each hostname runs."
    echo 'map $host $kapelos_run_code {'
    echo '    default "";'
    for pair in $STORES; do echo "    ${pair%%=*} \"${pair#*=}\";"; done
    echo '}'
    echo
    echo 'map $host $kapelos_run_type {'
    echo '    default "";'
    for pair in $STORES; do echo "    ${pair%%=*} \"store\";"; done
    echo '}'
  )"
  mkdir -p "$dir"
  [[ -f $dir/stores.conf && $(cat "$dir/stores.conf") == "$map" ]] || printf '%s\n' "$map" >"$dir/stores.conf"
  export NGINX_STORES="$KAPELOS_HOME/$dir/stores.conf"
  for pair in $STORES; do hosts="$hosts,${pair%%=*}"; done
  [[ -n ${PROXY_HOSTS:-} ]] || export PROXY_HOSTS="$hosts"
}

# Each STORES hostname as code=address, with the scheme and port of MAGENTO_BASE_URL.
store_urls() {
  local pair scheme port="" base="${MAGENTO_BASE_URL:-http://localhost:8080/}"
  scheme="${base%%://*}"
  [[ $base =~ ^https?://[^/:]+(:[0-9]+)/ ]] && port="${BASH_REMATCH[1]}"
  for pair in ${STORES:-}; do
    printf '%s=%s://%s%s/ ' "${pair#*=}" "$scheme" "${pair%%=*}" "$port"
  done
}

sha256_stdin() {
  if command -v sha256sum >/dev/null; then
    sha256sum | cut -d ' ' -f 1
  else
    shasum -a 256 | cut -d ' ' -f 1
  fi
}

# The files in a store's .kapelos that run code, relative to it: its compose file and its commands.
project_code_files() {
  (
    cd "$1/.kapelos" 2>/dev/null || exit 0
    [[ ! -f compose.yaml ]] || echo compose.yaml
    [[ ! -d commands ]] || find commands -type f
  ) | LC_ALL=C sort
}

# A store's compose additions and commands run with your permissions, so they run only as last trusted.
project_code_hash() {
  project_code_files "$1" | while IFS= read -r file; do
    printf '%s\n' "$file"
    cat "$1/.kapelos/$file"
  done | sha256_stdin
}

project_has_code() {
  [[ -f $1/.kapelos/compose.yaml || -n $(find "$1/.kapelos/commands" -type f 2>/dev/null | head -n 1) ]]
}

project_trust_file() {
  printf '%s/var/trust/%s' "$KAPELOS_HOME" "$(printf '%s' "$1" | sha256_stdin)"
}

project_is_trusted() {
  local store="$1" file
  project_has_code "$store" || return 0
  file="$(project_trust_file "$store")"
  [[ -f $file && $(cat "$file") == "$(project_code_hash "$store")" ]]
}

trust_project() {
  mkdir -p "$KAPELOS_HOME/var/trust"
  project_code_hash "$1" >"$(project_trust_file "$1")"
}

require_trusted() {
  project_is_trusted "$1" ||
    die "$1/.kapelos brings a compose file or commands that are new or changed since you last trusted them. They run with your permissions, so read them, then: kapelos trust $1"
}

cmd_trust() {
  local store="${1:-}"
  if [[ -z $store ]]; then
    load_env
    store="${MAGENTO_SRC:-}"
  fi
  [[ -d $store ]] || die "name the store's folder: kapelos trust PATH"
  store="$(cd "$store" && pwd -P)"
  project_has_code "$store" || die "$store has no .kapelos/compose.yaml or .kapelos/commands, so there's nothing to trust"
  echo "From now on these run with your permissions, until one of them changes:"
  project_code_files "$store" | sed 's/^/  .kapelos\//'
  trust_project "$store"
  echo "Trusted."
}

env_value() {
  local file="$1" key="$2"
  sed -n "s/^$key=//p" "$file" | tail -n 1
}

set_env_value() {
  local file key="$2" value="$3" tmp
  file="$(follow_link "$1")"
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v k="$key" -v v="$value" '
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Magento's admin password needs at least one letter and one digit, so draw until it has both.
random_secret() {
  local secret=""
  until [[ $secret =~ [a-f] && $secret =~ [0-9] ]]; do
    secret="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  done
  printf '%s' "$secret"
}

write_env() {
  local out="$1" line pair
  shift
  [[ ! -e $out && ! -L $out ]] || die "$out already exists. Move it aside first if you want a fresh one."
  (
    umask 077
    while IFS= read -r line || [[ -n $line ]]; do
      case "$line" in
        *_PASSWORD=) printf '%s%s\n' "$line" "$(random_secret)" ;;
        HOST_UID=) printf '%s%s\n' "$line" "$(id -u)" ;;
        HOST_GID=) printf '%s%s\n' "$line" "$(id -g)" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <.env.example >"$out"
  )
  for pair in "$@"; do
    set_env_value "$out" "${pair%%=*}" "${pair#*=}"
  done
}

valid_site_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "a site name uses lowercase letters, digits and dashes, and starts with a letter or digit: $1"
}

# Settings are read on every call, so a store's own settings and compose file always apply.
compose() {
  load_env
  local files="${COMPOSE_FILE:-compose.yaml}"
  if [[ -n ${MAGENTO_SRC:-} && -f $MAGENTO_SRC/.kapelos/compose.yaml ]]; then
    require_trusted "$MAGENTO_SRC"
    files="$files:$MAGENTO_SRC/.kapelos/compose.yaml"
  fi
  local profiles="${COMPOSE_PROFILES:-}"
  [[ ${CRON:-no} != yes ]] || profiles="${profiles:+$profiles,}cron"
  # Down skips a service whose profile was switched off after it started, so down runs with every profile on.
  [[ ${1:-} != down ]] || profiles='*'
  COMPOSE_PROFILES="$profiles" COMPOSE_FILE="$files" docker compose --env-file "$ENV_FILE" "$@"
}

project_name() {
  env_value "$ENV_FILE" COMPOSE_PROJECT_NAME
}

# Every Kapelos project with a running container, from this folder only.
running_projects() {
  docker ps --filter "label=com.docker.compose.project.working_dir=$KAPELOS_HOME" \
    --format '{{.Label "com.docker.compose.project"}}' | sort -u
}

require_running() {
  local running service
  running="$(compose ps --status running --services 2>/dev/null)"
  for service in "$@"; do
    grep -qx "$service" <<<"$running" || die "$service isn't running. Start the stack with: kapelos up"
  done
}

# Pipes and scripts have no terminal, and docker compose exec refuses to allocate one for them.
compose_exec() {
  require_running "$1"
  if [[ -t 0 ]]; then
    compose exec "$@"
  else
    compose exec -T "$@"
  fi
}

exec_php() {
  compose_exec php "$@"
}

# For output that is read rather than shown: a terminal would end every line with a carriage return.
exec_quiet() {
  require_running "$1"
  compose exec -T "$@"
}

magento() {
  exec_php php bin/magento "$@"
}

# Compiling reads every class in the store, encoded ones included, and SourceGuardian
# refuses to decode while Xdebug is loaded. The image carries a scan directory that is
# every setting except Xdebug's, so the frontend containers keep their debugger.
exec_php_no_xdebug() {
  require_running php
  local tty=(-T)
  [[ -t 0 ]] && tty=()
  compose exec "${tty[@]}" -e PHP_INI_SCAN_DIR=/usr/local/etc/php/conf.d php "$@"
}

magento_no_xdebug() {
  exec_php_no_xdebug php bin/magento "$@"
}

# Magento empties generated/ whenever the module list changes, and a deployed store's
# optimised class map names the classes that were in there. Composer trusts a class map
# without checking, so the next command includes a file that is gone and the store dies
# on a warning about a Proxy class, which says nothing about the cause.
autoload_is_stale() {
  local root="${MAGENTO_SRC:-}" map
  map="$root/vendor/composer/autoload_classmap.php"
  [[ -n $root && -f $map ]] || return 1
  compgen -G "$root/generated/code/*" >/dev/null && return 1
  grep -q "generated/code" "$map"
}

# Rebuilds the class map without the generated classes, which is what makes the store
# boot again. Production mode cannot generate a class on demand, so it also needs a
# compile, and saying so is the difference between a fix and a half fix.
autoload_repair() {
  autoload_is_stale || return 0
  compose ps --status running --services 2>/dev/null | grep -qx php || return 0

  step "The class map names generated classes that are gone. Rebuilding it plain"
  exec_php composer dump-autoload --no-interaction >/dev/null || return 0

  if [[ "$(magento_mode 2>/dev/null)" == production ]]; then
    echo "    The store is in production mode, so it also needs: kapelos setup:di:compile"
  fi
}

# Said once, after the command rather than before it, because whether generated code is
# missing is only worth reporting when something has just emptied it.
warn_if_uncompiled() {
  compgen -G "${MAGENTO_SRC:-}/generated/code/*" >/dev/null && return 0
  [[ "$(magento_mode 2>/dev/null)" == production ]] || return 0
  step "Generated code is empty and the store is in production mode. Compile it: kapelos setup:di:compile"
}

magento_mode() {
  exec_quiet php php bin/magento deploy:mode:show 2>/dev/null |
    sed -n 's/.*Current application mode: \([a-z]*\).*/\1/p'
}

# Magento clears generated/ partway through each of these and then carries on in the
# same process, so the class map has to stop naming generated classes before they run.
CLEARS_GENERATED_CODE="module:enable module:disable module:uninstall setup:upgrade deploy:mode:set"

# The dangerous state: an optimised class map naming generated classes that are still
# there. Nothing is broken yet, and the next command to empty generated/ breaks it.
autoload_is_optimised() {
  local root="${MAGENTO_SRC:-}" map
  map="$root/vendor/composer/autoload_classmap.php"
  [[ -n $root && -f $map ]] || return 1
  compgen -G "$root/generated/code/*" >/dev/null || return 1
  grep -q "generated/code" "$map"
}

# Clearing generated code from outside the command, and rebuilding the map without it,
# leaves the command nothing to delete and nothing to race. Emptying it mid-run does not
# work: the class map is plain by then, so Magento generates classes into the very
# directories it is deleting, and the command stops on "Directory not empty".
clear_generated_for_module_change() {
  autoload_is_optimised || return 0
  compose ps --status running --services 2>/dev/null | grep -qx php || return 0

  step "This command clears generated code, so clearing it first and rebuilding the class map plain"
  exec_php sh -c 'rm -rf generated/code generated/metadata' || true
  exec_php composer dump-autoload --no-interaction >/dev/null || true
}

# Every Magento command a person types goes through here, so a command that clears
# generated code finishes its work and leaves a store that still boots.
run_magento_command() {
  local status=0
  load_env
  autoload_repair
  case " $CLEARS_GENERATED_CODE " in
    *" ${1:-} "*) clear_generated_for_module_change ;;
  esac
  if [[ ${1:-} == setup:di:compile ]]; then
    magento_no_xdebug "$@" || status=$?
  else
    magento "$@" || status=$?
  fi
  autoload_repair
  case " $CLEARS_GENERATED_CODE " in
    *" ${1:-} "*) warn_if_uncompiled ;;
  esac
  return "$status"
}

installed() {
  exec_quiet php test -f app/etc/env.php
}

db_root() {
  exec_quiet db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot "$@"' sh "$@"
}

db_table_count() {
  db_root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${DB_NAME:-magento}'"
}

require_empty_database() {
  local tables
  tables="$(db_table_count)"
  [[ $tables -eq 0 ]] || die "the database already has $tables tables, so this looks like a store that exists. To start again from empty, docker compose down -v deletes this site's database and search index"
}

ask() {
  local prompt="$1" default="${2:-}"
  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " REPLY
  else
    read -r -p "$prompt: " REPLY
  fi
  REPLY="${REPLY:-$default}"
}

ask_yes() {
  ask "$1 (y/n)" "$2"
  case "$REPLY" in y | Y | yes | Yes) return 0 ;; *) return 1 ;; esac
}

absolute_path() {
  (cd "$1" && pwd)
}

confirm() {
  local question="$1" yes="$2"
  [[ $yes == yes ]] && return 0
  [[ -t 0 ]] || die "$question Run it again with -y to go ahead without a terminal to ask on."
  ask_yes "$question" n
}

disposable() {
  [[ ${DISPOSABLE:-no} == yes ]]
}

require_site_running() {
  running_projects | grep -qx "${COMPOSE_PROJECT_NAME:-kapelos}" || die "the site isn't running. Start it with: kapelos up"
}
