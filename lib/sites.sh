# Sites: which project is active, what each one is called, and removing one.
# shellcheck shell=bash

cmd_env() {
  local name="" slot=0 pairs=() key
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot)
        [[ $# -ge 2 ]] || die "--slot takes a number, for example: kapelos env acme --slot 1"
        slot="$2"
        shift 2
        ;;
      --slot=*)
        slot="${1#--slot=}"
        shift
        ;;
      -*) die "env doesn't know $1. See: kapelos help" ;;
      *)
        [[ -z $name ]] || die "env takes one site name, and got a second: $1"
        name="$1"
        shift
        ;;
    esac
  done
  require_port_slot "$slot"
  for key in $PORT_KEYS; do
    pairs+=("$key=$(slot_port "$key" "$slot")")
  done
  if [[ -z $name ]]; then
    write_env .env "${pairs[@]}" "MAGENTO_BASE_URL=http://magento.test:$(slot_port HTTP_PORT "$slot")/"
    echo "Wrote .env. Set MAGENTO_SRC in it to your Magento tree, then run: kapelos up"
    return
  fi
  valid_site_name "$name"
  require_name_free_on_daemon "$name"
  mkdir -p "$SITES_DIR"
  write_env "$SITES_DIR/$name.env" \
    "COMPOSE_PROJECT_NAME=kapelos-$name" \
    "APP_HOST=$name.test" \
    "${pairs[@]}" \
    "MAGENTO_BASE_URL=http://$name.test:$(slot_port HTTP_PORT "$slot")/"
  echo "Wrote $SITES_DIR/$name.env. Set MAGENTO_SRC in it, then: kapelos use $name && kapelos up"
}

# A slot's port for KEY: the default in .env.example, moved up by one stride per slot.
slot_port() {
  local base
  base="$(env_value .env.example "$1")"
  [[ $base =~ ^[0-9]+$ ]] || die ".env.example has no port for $1"
  printf '%s' "$((base + $2 * PORT_SLOT_STRIDE))"
}

# The ports a slot publishes, as KEY PORT lines. HTTP_PORT brings the four above it that kapelos scale's servers take.
slot_block() {
  local key port n
  for key in $PORT_KEYS; do
    port="$(slot_port "$key" "$1")"
    echo "$key $port"
    if [[ $key == HTTP_PORT ]]; then
      for n in 1 2 3 4; do echo "$key+$n $((port + n))"; done
    fi
  done
}

# A slot is refused when a port would pass 65535, or would be a port another slot, or this one, already publishes.
require_port_slot() {
  local slot="$1" key port other_key other_port gap block zero
  [[ $slot =~ ^(0|[1-9][0-9]{0,4})$ ]] || die "--slot takes a whole number, 0 for the default ports, and got: $slot"
  block="$(slot_block "$slot")"
  zero="$(slot_block 0)"
  while read -r key port; do
    [[ $port -le 65535 ]] || die "slot $slot would put ${key%%+*} at $port, past the last port, 65535. Pick a lower slot"
    while read -r other_key other_port; do
      gap=$((port - other_port))
      [[ $gap -ge 0 && $((gap % PORT_SLOT_STRIDE)) -eq 0 ]] || continue
      [[ $((gap / PORT_SLOT_STRIDE)) -ne $slot || $other_key != "$key" ]] || continue
      die "slot $slot would put ${key%%+*} on $port, which slot $((gap / PORT_SLOT_STRIDE)) uses for ${other_key%%+*}"
    done <<<"$zero"
  done <<<"$block"
}

# Compose names containers and volumes kapelos-NAME on the whole Docker daemon, so a name another checkout
# uses would share its containers and its database. Volumes carry no folder, so ones no container here claims are refused.
require_name_free_on_daemon() {
  local project="kapelos-$1" folders elsewhere volumes
  command -v docker >/dev/null || return 0
  if ! folders="$(docker ps -a --filter "label=com.docker.compose.project=$project" \
    --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null)"; then
    echo "kapelos: Docker isn't answering, so no check was made that another Kapelos folder doesn't already use the name $1" >&2
    return 0
  fi
  elsewhere="$(grep -vxF "$KAPELOS_HOME" <<<"$folders" | grep -v '^$' | sort -u | tr '\n' ' ' || true)"
  [[ -z $elsewhere ]] || die "$project already has containers from another Kapelos folder: $elsewhere
One name in two folders shares one set of containers and one database. Pick another name"
  grep -qxF "$KAPELOS_HOME" <<<"$folders" && return 0
  volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=$project"; docker volume ls -q --filter "label=kapelos.snapshot.project=$project")"
  volumes="$(grep -v '^$' <<<"$volumes" | tr '\n' ' ' || true)"
  [[ -z $volumes ]] || die "Docker already has volumes for $project, and no container in this folder says they are this folder's: $volumes
Another Kapelos folder may have a site called $1 parked. Pick another name, or, if they are left from a site of this folder, remove them with: docker volume rm $volumes"
}

site_of_project() {
  local file
  for file in "$SITES_DIR"/*.env; do
    [[ -f $file ]] || continue
    if [[ $(env_value "$file" COMPOSE_PROJECT_NAME) == "$1" ]]; then
      printf '%s' "$file"
      return
    fi
  done
}

# Every profile is on, so a service whose profile was switched off after it started is stopped too.
stop_project() {
  local project="$1" file
  file="$(site_of_project "$project")"
  step "Stopping $project, keeping its data"
  if [[ -n $file ]]; then
    COMPOSE_PROFILES='*' docker compose --progress quiet --env-file "$file" down --remove-orphans
  elif [[ -f .env && ! -L .env && $(env_value .env COMPOSE_PROJECT_NAME) == "$project" ]]; then
    COMPOSE_PROFILES='*' docker compose --progress quiet --env-file .env down --remove-orphans
  else
    COMPOSE_PROFILES='*' docker compose --progress quiet -p "$project" down --remove-orphans
  fi
}

# A plain .env becomes a named site the first time sites are used, so nothing in it is lost.
adopt_plain_env() {
  [[ -f .env && ! -L .env ]] || return 0
  local project name
  project="$(env_value .env COMPOSE_PROJECT_NAME)"
  case "$project" in
    '' | kapelos) name=default ;;
    kapelos-*) name="${project#kapelos-}" ;;
    *) name="$project" ;;
  esac
  mkdir -p "$SITES_DIR"
  [[ ! -e $SITES_DIR/$name.env ]] || die ".env would become the site $name, and $SITES_DIR/$name.env already exists. Move one of them aside first."
  mv .env "$SITES_DIR/$name.env"
  ln -s "$SITES_DIR/$name.env" .env
  echo "Your .env is now the site $name, in $SITES_DIR/$name.env."
}

cmd_sites() {
  local active="" file name project state marker found=0 running
  [[ -L .env ]] && active="$(readlink .env)"
  running="$(running_projects)"
  for file in "$SITES_DIR"/*.env; do
    [[ -f $file ]] || continue
    found=1
    name="$(basename "$file" .env)"
    project="$(env_value "$file" COMPOSE_PROJECT_NAME)"
    state=stopped
    grep -qx "$project" <<<"$running" && state=running
    marker=" "
    [[ $active == "$file" ]] && marker="*"
    printf '%s %-20s %-8s %s\n' "$marker" "$name" "$state" "$(env_value "$file" MAGENTO_SRC)"
  done
  if [[ -f .env && ! -L .env ]]; then
    echo "  .env is a single site of its own. The first kapelos use turns it into a named site."
  elif [[ $found -eq 0 ]]; then
    echo "No sites yet. kapelos demo, kapelos interactive or kapelos env SITE makes one."
  fi
}

# Setting a store up never stops a site that's running; only kapelos use switches away from one.
require_free_to_switch() {
  local command="$1" project="$2" other
  other="$(running_projects | grep -vx "$project" | head -n 1 || true)"
  [[ -z $other ]] || die "$other is running, and $command would have to stop it. Stop it with kapelos down, or switch with kapelos use"
}

cmd_use() {
  local name="${1:-}"
  if [[ -z $name ]]; then
    cmd_sites
    return
  fi
  [[ -z ${KAPELOS_ENV:-} ]] || die "kapelos use switches .env, and KAPELOS_ENV points somewhere else"
  valid_site_name "$name"
  local target="$SITES_DIR/$name.env" project running
  [[ -f $target ]] || die "there's no site called $name. kapelos sites lists them, and kapelos env $name makes one"
  adopt_plain_env
  project="$(env_value "$target" COMPOSE_PROJECT_NAME)"
  for running in $(running_projects); do
    [[ $running == "$project" ]] || stop_project "$running"
  done
  ln -sfn "$target" .env
  [[ ${2:-} == quiet ]] || echo "Now on $name. Start it with: kapelos up"
}

store_codes() {
  db_root -N "${DB_NAME:-magento}" -e "SELECT code FROM \`$(table_prefix)store\` WHERE store_id > 0" </dev/null | tr '\n' ' '
}

cmd_stores() {
  load_env
  if [[ -z ${STORES:-} ]]; then
    echo "No STORES setting, so every hostname runs the store's default. Set it in the site's settings or the store's .kapelos/settings.env:"
    echo '  STORES="second.test=second_store third.test=third_store"'
    return
  fi
  local pair code address known="" missing=""
  if compose ps --status running --services 2>/dev/null | grep -qx db && installed; then
    known="$(store_codes)"
  fi
  for pair in $(store_urls); do
    code="${pair%%=*}"
    address="${pair#*=}"
    if [[ -n $known && " $known " != *" $code "* ]]; then
      printf '  %-30s %s, which this database does not have\n' "$address" "$code"
      missing="$missing $code"
    else
      printf '  %-30s %s\n' "$address" "$code"
    fi
  done
  [[ ${1:-} == apply ]] || return 0
  require_running php db
  [[ -z $missing ]] || die "the database has no store called$missing. Its stores: $known"
  if [[ -n ${KAPELOS_ENV_PHP:-} ]]; then
    step "Pinning each store's address in Kapelos's env.php"
    write_adopted_env_php
  else
    for pair in $(store_urls); do
      step "Setting ${pair%%=*}'s address to ${pair#*=}"
      magento config:set --scope=stores --scope-code="${pair%%=*}" web/unsecure/base_url "${pair#*=}"
      magento config:set --scope=stores --scope-code="${pair%%=*}" web/secure/base_url "${pair#*=}"
    done
  fi
  # nginx reads the hostname map when it starts.
  compose up -d
  # shellcheck disable=SC2046 # one word per service
  compose restart web web-debug $(scale_extra_services | tr ' ' '\n' | grep '^web-')
  cmd_cache_reset
}

# Removes a site: its containers, database, search index, snapshots and generated files. A store's code stays, unless Kapelos downloaded it.
site_remove() {
  local name="" yes=no file project code volumes reply volume
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y) yes=yes ;;
      *) name="$1" ;;
    esac
    shift
  done
  [[ -n $name ]] || die "name the site to remove: kapelos site remove SITE"
  valid_site_name "$name"
  file="$SITES_DIR/$name.env"
  [[ -f $file ]] || die "there's no site called $name. kapelos sites lists them"
  project="$(env_value "$file" COMPOSE_PROJECT_NAME)"
  code="$(env_value "$file" MAGENTO_SRC)"
  volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=$project"; docker volume ls -q --filter "label=kapelos.snapshot.project=$project")"
  echo "Removing $name deletes, with no way back:"
  echo "  its containers, and these volumes: $(tr '\n' ' ' <<<"$volumes")"
  echo "  $file, $(site_state_dir_of "$project") and var/tools/$project"
  if [[ $code == "$KAPELOS_HOME/$STORES_DIR/"* ]]; then
    echo "  $code, the code Kapelos downloaded for it"
  else
    echo "Its code in $code stays where it is."
  fi
  if [[ $yes != yes ]]; then
    [[ -t 0 ]] || die "run it again with -y to remove $name without a terminal to confirm on"
    read -r -p "Type the site's name to remove it: " reply
    [[ $reply == "$name" ]] || die "nothing removed"
  fi
  # Every profile is on, so a service whose profile was switched off after it started is removed too.
  COMPOSE_PROFILES='*' docker compose --progress quiet --env-file "$file" down -v --remove-orphans
  # Snapshots aren't part of the compose project, and a scaled site's copies and replica aren't in compose.yaml, so down -v leaves them.
  { docker volume ls -q --filter "label=kapelos.snapshot.project=$project"; docker volume ls -q --filter "label=com.docker.compose.project=$project"; } | while IFS= read -r volume; do
    docker volume rm "$volume" >/dev/null
  done
  rm -rf "$(site_state_dir_of "$project")" "var/tools/$project"
  if [[ $code == "$KAPELOS_HOME/$STORES_DIR/"* ]]; then
    rm -f "$(project_trust_file "$code")"
    rm -rf "$code"
  fi
  # An adopt that stopped part way leaves .env as a plain file for the site it was
  # building, so it has to go by what it names as well as by what it points at. Left
  # behind, it makes the next adopt of the same name collide with itself.
  if [[ $(readlink .env 2>/dev/null) == "$file" ]] ||
    { [[ -f .env && ! -L .env ]] && [[ $(env_value .env COMPOSE_PROJECT_NAME) == "$project" ]]; }; then
    rm -f .env
    echo "Your .env was this site, so it is gone too. kapelos sites lists the rest."
  fi
  rm -f "$file"
  echo "Removed $name."
}

site_state_dir_of() {
  printf 'var/sites/%s' "${1#kapelos-}"
}

cmd_site() {
  local action="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$action" in
    audit) ;;
    remove)
      site_remove "$@"
      return
      ;;
    *) die "kapelos site audit [SITE] or kapelos site remove SITE" ;;
  esac
  if [[ -n ${1:-} ]]; then
    valid_site_name "$1"
    [[ -f $SITES_DIR/$1.env ]] || die "there's no site called $1. kapelos sites lists them"
    ENV_FILE="$SITES_DIR/$1.env"
  fi
  load_env
  [[ -d ${MAGENTO_SRC:-} ]] || die "MAGENTO_SRC isn't a folder: ${MAGENTO_SRC:-not set}"
  mkdir -p var/intel
  compose --progress quiet build audit >/dev/null

  echo "Site audit: ${COMPOSE_PROJECT_NAME:-kapelos}, $MAGENTO_SRC"
  audit_dependencies
  audit_credentials
  audit_settings
  audit_public_files
  audit_headers
  echo
  echo "$REPORT_FAILS failed, $REPORT_WARNS to look at."
  [[ $REPORT_FAILS -eq 0 ]]
}
