# Sites: which project is active, what each one is called, copying one and removing one.
# shellcheck shell=bash

cmd_env() {
  local name="" slot="" slot_given=no pairs=() key
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot)
        [[ $# -ge 2 ]] || die "--slot takes a number, for example: kapelos env acme --slot 1"
        slot="$2"
        slot_given=yes
        shift 2
        ;;
      --slot=*)
        slot="${1#--slot=}"
        slot_given=yes
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
  # A named site with no --slot takes the first block no other site here uses, so the first is still slot 0.
  if [[ $slot_given == no ]]; then
    slot=0
    [[ -z $name ]] || slot="$(first_free_slot "$SITES_DIR/$name.env")"
    [[ $slot == 0 ]] || echo "Slot 0's ports are taken by another site here, so $name gets slot $slot."
  fi
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
  folders="$(while IFS= read -r folder; do [[ -z $folder ]] || physical_dir "$folder"; done <<<"$folders")"
  elsewhere="$(grep -vxF "$KAPELOS_HOME" <<<"$folders" | grep -v '^$' | sort -u | tr '\n' ' ' || true)"
  [[ -z $elsewhere ]] || die "$project already has containers from another Kapelos folder: $elsewhere
One name in two folders shares one set of containers and one database. Pick another name"
  grep -qxF "$KAPELOS_HOME" <<<"$folders" && return 0
  volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=$project"; docker volume ls -q --filter "label=kapelos.snapshot.project=$project")"
  volumes="$(grep -v '^$' <<<"$volumes" | tr '\n' ' ' || true)"
  [[ -z $volumes ]] || die "Docker already has volumes for $project, and no container in this folder says they are this folder's: $volumes
Another Kapelos folder may have a site called $1 parked. Pick another name, or, if they are left from a site of this folder, remove them with: docker volume rm $volumes"
}

# The slot a site file's ports are in, from its HTTP_PORT; nothing for ports set by hand off the grid.
slot_of_site() {
  local port base
  port="$(env_value "$1" HTTP_PORT)"
  base="$(env_value .env.example HTTP_PORT)"
  [[ -n $port ]] || port="$base"
  [[ $port =~ ^[0-9]+$ && $port -ge $base && $(((port - base) % PORT_SLOT_STRIDE)) -eq 0 ]] || return 1
  printf '%s' "$(((port - base) / PORT_SLOT_STRIDE))"
}

# The lowest slot no site of this folder other than SKIP uses.
first_free_slot() {
  local skip="${1:-}" used="" file slot
  for file in "$SITES_DIR"/*.env; do
    [[ -f $file && $file != "$skip" ]] || continue
    slot="$(slot_of_site "$file")" && used="$used $slot "
  done
  slot=0
  while [[ $used == *" $slot "* ]]; do slot=$((slot + 1)); done
  printf '%s' "$slot"
}

# The site of this folder whose ports are in a slot, leaving out the site file SKIP; nothing when it is free.
slot_owner() {
  local slot="$1" skip="${2:-}" other
  for other in "$SITES_DIR"/*.env; do
    [[ -f $other && $other != "$skip" ]] || continue
    if [[ $(slot_of_site "$other" || true) == "$slot" ]]; then
      basename "$other" .env
      return 0
    fi
  done
}

# Moves a site to a block of ports of its own: the slot named, or the first one no other site of this folder
# uses. The store's own addresses in its database still carry the old port, so it prints what changes those.
site_ports() {
  local name="" slot="" file project owner old_url new_url old_http new_http key
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot)
        [[ $# -ge 2 ]] || die "--slot takes a number, for example: kapelos site ports acme --slot 1"
        slot="$2"
        shift 2
        ;;
      --slot=*)
        slot="${1#--slot=}"
        shift
        ;;
      -*) die "site ports doesn't know $1" ;;
      *)
        [[ -z $name ]] || die "site ports takes one site name, and got a second: $1"
        name="$1"
        shift
        ;;
    esac
  done
  [[ -n $name ]] || die "name the site, for example: kapelos site ports acme, or kapelos site ports acme --slot 2"
  valid_site_name "$name"
  file="$SITES_DIR/$name.env"
  [[ -f $file ]] || die "there's no site called $name. kapelos sites lists them"
  project="$(env_value "$file" COMPOSE_PROJECT_NAME)"
  ! running_projects | grep -qx "$project" || die "$name is running, and its ports can't change under it. Stop it first: kapelos down $name"
  [[ -n $slot ]] || slot="$(first_free_slot "$file")"
  require_port_slot "$slot"
  owner="$(slot_owner "$slot" "$file")"
  [[ -z $owner ]] || die "slot $slot is $owner's. Leave out --slot and $name gets the first free one"
  old_url="$(env_value "$file" MAGENTO_BASE_URL)"
  old_http="$(env_value "$file" HTTP_PORT)"
  [[ -n $old_http ]] || old_http="$(env_value .env.example HTTP_PORT)"
  for key in $PORT_KEYS; do
    set_env_value "$file" "$key" "$(slot_port "$key" "$slot")"
  done
  new_http="$(slot_port HTTP_PORT "$slot")"
  new_url="${old_url/:$old_http\//:$new_http/}"
  set_env_value "$file" MAGENTO_BASE_URL "$new_url"
  echo "$name is on slot $slot now: $(slot_block "$slot" | awk '$1 !~ /\+/ { printf "%s%s %s", sep, $1, $2; sep = ", " }')."
  [[ $new_url != "$old_url" ]] || return 0
  echo "Its store still has $old_url in its database. Once it is up, change that with:"
  echo "  kapelos use $name && kapelos up"
  echo "  kapelos magento config:set web/unsecure/base_url $new_url"
  echo "  kapelos magento config:set web/secure/base_url $new_url"
  echo "  kapelos magento cache:flush"
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

# Each site, whether it runs, the memory it uses now or used when it last ran, and its storefront port.
cmd_sites() {
  local active="" file name project state marker found=0 running memory bytes port
  [[ -L .env ]] && active="$(readlink .env)"
  running="$(running_projects)"
  for file in "$SITES_DIR"/*.env; do
    [[ -f $file ]] || continue
    found=1
    name="$(basename "$file" .env)"
    project="$(env_value "$file" COMPOSE_PROJECT_NAME)"
    state=stopped
    memory="-"
    if grep -qx "$project" <<<"$running"; then
      state=running
      record_footprint "$project"
    fi
    if bytes="$(recorded_footprint "$project")"; then
      memory="$(gib "$bytes") GiB"
      [[ $state == running ]] || memory="($memory)"
    fi
    port="$(env_value "$file" HTTP_PORT)"
    marker=" "
    [[ $active == "$file" ]] && marker="*"
    printf '%s %-20s %-8s %-11s %-6s %s\n' "$marker" "$name" "$state" "$memory" "${port:-8080}" "$(env_value "$file" MAGENTO_SRC)"
  done
  if [[ -f .env && ! -L .env ]]; then
    echo "  .env is a single site of its own. The first kapelos use turns it into a named site."
  elif [[ $found -eq 0 ]]; then
    echo "No sites yet. kapelos demo, kapelos interactive or kapelos env SITE makes one."
  fi
}

# Setting a store up stops nothing, so it goes ahead only where kapelos up would let the new store start.
require_room_to_set_up() {
  require_room_for_another "$1"
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
  ln -sfn "$target" .env
  [[ ${2:-} == quiet ]] && return 0
  echo "Now on $name. Start it with: kapelos up"
  running="$(running_projects | grep -vx "$project" | sed 's/^kapelos-//' | tr '\n' ' ' || true)"
  [[ -z $running ]] || echo "Still running: ${running% }. kapelos down SITE stops one."
}

# Stops one site, or the active one, keeping its data. What it used goes on record first, for the next start.
cmd_down() {
  local name="${1:-}" file project
  if [[ -z $name ]]; then
    load_env
    record_footprint "${COMPOSE_PROJECT_NAME:-kapelos}"
    compose down
    return
  fi
  valid_site_name "$name"
  file="$SITES_DIR/$name.env"
  [[ -f $file ]] || die "there's no site called $name. kapelos sites lists them"
  project="$(env_value "$file" COMPOSE_PROJECT_NAME)"
  record_footprint "$project"
  stop_project "$project"
}

# Stops every running site of this folder but the active one.
cmd_stop_others() {
  local current project stopped=0
  load_env
  current="${COMPOSE_PROJECT_NAME:-kapelos}"
  for project in $(running_projects); do
    [[ $project != "$current" ]] || continue
    record_footprint "$project"
    stop_project "$project"
    stopped=1
  done
  [[ $stopped -eq 1 ]] || echo "Nothing else is running."
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
  if compose ps --status running --services 2>/dev/null | holds -qx db && installed; then
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

# Removes a site: its containers, database, search index, snapshots and generated files. A store's code stays, unless Kapelos downloaded or copied it.
site_remove() {
  local name="" yes=no file project code volumes reply volume kept remaining
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
    echo "  $code, the code Kapelos downloaded or copied for it"
  else
    echo "Its code in $code stays where it is."
  fi
  if [[ $yes != yes ]]; then
    [[ -t 0 ]] || die "run it again with -y to remove $name without a terminal to confirm on"
    read -r -p "Type the site's name to remove it: " reply
    [[ $reply == "$name" ]] || die "nothing removed"
  fi
  # Every profile is on, so a service whose profile was switched off after it started is removed too.
  # Docker can refuse to let go of a network nothing is attached to, and only a restart of Docker clears that,
  # so a refusal here doesn't end the removal: whatever Docker kept is named at the end.
  COMPOSE_PROFILES='*' docker compose --progress quiet --env-file "$file" down -v --remove-orphans || true
  # A container that is still there may be running from this code, so nothing more is taken from under it.
  # Asked on a line of its own: a docker that can't answer ends the command here, and is not read as no containers.
  remaining="$(docker ps -a -q --filter "label=com.docker.compose.project=$project")"
  [[ -z $remaining ]] ||
    die "Docker wouldn't remove $name's containers, so its volumes, code and settings are where they were. docker ps -a --filter label=com.docker.compose.project=$project lists them, and this command finishes once they are gone"
  # Snapshots aren't part of the compose project, and a scaled site's copies and replica aren't in compose.yaml, so down -v leaves them.
  { docker volume ls -q --filter "label=kapelos.snapshot.project=$project"; docker volume ls -q --filter "label=com.docker.compose.project=$project"; } | while IFS= read -r volume; do
    docker volume rm "$volume" >/dev/null || true
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
  kept="$(site_left_in_docker "$project")"
  if [[ -n $kept ]]; then
    echo "Removed $name, all but what Docker kept:"
    while IFS= read -r volume; do
      echo "  $volume"
    done <<<"$kept"
    echo "A network Docker says has active endpoints, with nothing attached, goes when Docker restarts; until then docker network rm NAME is refused. docker volume rm NAME removes a volume once nothing uses it."
    exit 1
  fi
  echo "Removed $name."
}

# What Docker still holds under a site's project name, one a line as "network NAME" or "volume NAME".
site_left_in_docker() {
  docker network ls --filter "label=com.docker.compose.project=$1" --format 'network {{.Name}}'
  { docker volume ls -q --filter "label=com.docker.compose.project=$1"; docker volume ls -q --filter "label=kapelos.snapshot.project=$1"; } |
    sed 's/^/volume /'
}

# Points a setting that names a file inside SOURCE's code, such as a store's own VCL, at the same file in the
# copy's. Kapelos writes such a path whole or from its own folder, so both are followed; a folder whose name
# only starts the same is left alone.
site_copy_paths() {
  local source_file="$1" file="$2" code="$3" target="$4" line key value new quote body rel_code rel_target
  rel_code="${code#"$KAPELOS_HOME"/}"
  rel_target="${target#"$KAPELOS_HOME"/}"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *=* ]] || continue
    key="${line%%=*}"
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $key != MAGENTO_SRC ]] || continue
    value="${line#*=}"
    new="${value//"$code/"/"$target/"}"
    if [[ $rel_code != "$code" ]]; then
      quote=""
      case "$new" in \"* | \'*) quote="${new:0:1}" ;; esac
      body="${new#"$quote"}"
      case "$body" in
        "./$rel_code/"*) new="$quote./$rel_target/${body#"./$rel_code/"}" ;;
        "$rel_code/"*) new="$quote$rel_target/${body#"$rel_code/"}" ;;
      esac
    fi
    [[ $new == "$value" ]] || set_env_value "$file" "$key" "$new"
  done <"$source_file"
}

# NAME's settings: SOURCE's, passwords included, since the copied database and env.php already hold them, with
# its own name, hostname, ports and code, on one web server with no replica, and with its scheduled jobs off.
site_copy_settings() {
  local source_file="$1" file="$2" name="$3" slot="$4" target="$5" key old_url scheme=http port=""
  (umask 077 && cp "$source_file" "$file")
  site_copy_paths "$source_file" "$file" "$(env_value "$source_file" MAGENTO_SRC)" "$target"
  set_env_value "$file" COMPOSE_PROJECT_NAME "kapelos-$name"
  set_env_value "$file" APP_HOST "$name.test"
  set_env_value "$file" MAGENTO_SRC "$target"
  for key in $PORT_KEYS; do
    set_env_value "$file" "$key" "$(slot_port "$key" "$slot")"
  done
  set_env_value "$file" WEB_SERVERS 1
  set_env_value "$file" DB_REPLICAS 0
  # A copy would run SOURCE's scheduled jobs beside it, with the same settings and the same outside servers.
  # kapelos cron on turns them on, and asks first for a store that isn't disposable.
  set_env_value "$file" CRON no
  # The hostnames of SOURCE's other storefronts are SOURCE's, so the copy serves its default store on its own.
  for key in STORES PROXY_HOSTS; do
    [[ -z $(env_value "$file" "$key") ]] || set_env_value "$file" "$key" ""
  done
  old_url="$(env_value "$source_file" MAGENTO_BASE_URL)"
  [[ $old_url != https://* ]] || scheme=https
  # A store reached through the reverse proxy has no port in its address, and its copy has none either.
  if [[ $old_url =~ ^https?://[^/:]+:[0-9]+ ]]; then
    if [[ $scheme == https ]]; then port=":$(slot_port HTTPS_PORT "$slot")"; else port=":$(slot_port HTTP_PORT "$slot")"; fi
  fi
  set_env_value "$file" MAGENTO_BASE_URL "$scheme://$name.test$port/"
}

# Said when a copy ends before it is whole, whatever ended it.
site_copy_stopped() {
  [[ -z ${SITE_COPY_UNFINISHED:-} ]] ||
    echo "kapelos: the copy stopped part way. kapelos site remove $SITE_COPY_UNFINISHED -y removes what was made of it" >&2
}

# Makes NAME a second store from SOURCE: a copy of SOURCE's code as it is now, and the database, search index
# and queue of one of SOURCE's snapshots, the newest unless one is named. SOURCE is read and never changed, and
# keeps running, so NAME is where a test that may break a store runs. kapelos site remove NAME deletes all of it.
site_copy() {
  local source="" name="" snapshot="" slot="" source_file file source_project code target owner bytes need free volume table
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot | --slot)
        [[ $# -ge 2 ]] || die "$1 takes a value. See: kapelos help"
        if [[ $1 == --snapshot ]]; then snapshot="$2"; else slot="$2"; fi
        shift 2
        ;;
      --snapshot=*)
        snapshot="${1#--snapshot=}"
        shift
        ;;
      --slot=*)
        slot="${1#--slot=}"
        shift
        ;;
      -*) die "site copy doesn't know $1" ;;
      *)
        if [[ -z $source ]]; then
          source="$1"
        elif [[ -z $name ]]; then
          name="$1"
        else
          die "site copy takes the site to copy and the new site's name, and got a third: $1"
        fi
        shift
        ;;
    esac
  done
  [[ -n $source && -n $name ]] || die "name the site to copy and the new one, for example: kapelos site copy acme acme-scratch"
  valid_site_name "$source"
  valid_site_name "$name"
  source_file="$SITES_DIR/$source.env"
  file="$SITES_DIR/$name.env"
  [[ -f $source_file ]] || die "there's no site called $source. kapelos sites lists them"
  [[ ! -e $file ]] || die "there's already a site called $name. kapelos site remove $name deletes it"
  [[ -z $(env_value "$source_file" KAPELOS_ENV_PHP) ]] ||
    die "$source was adopted: its code stays where you keep it, with Kapelos's env.php laid over it, and site copy doesn't copy that arrangement yet. Adopt the store again under another name instead"
  source_project="$(env_value "$source_file" COMPOSE_PROJECT_NAME)"
  code="$(env_value "$source_file" MAGENTO_SRC)"
  [[ -n $code && -d $code ]] || die "$source's code isn't a folder: ${code:-MAGENTO_SRC is not set in $source_file}"
  project_is_trusted "$code" ||
    die "$code/.kapelos brings a compose file or commands that are new or changed since you last trusted them, and a copy would run them too. Read them, then: kapelos trust $code"
  target="$KAPELOS_HOME/$STORES_DIR/$name"
  [[ ! -e $target ]] || die "$target is already there. Move it aside first"
  require_name_free_on_daemon "$name"
  require_helper_starts
  if [[ -n $snapshot ]]; then
    valid_snapshot_name "$snapshot"
    snapshot_names "$source_project" | holds -qx "$snapshot" ||
      die "$source has no snapshot called $snapshot. kapelos use $source && kapelos snapshot lists them"
  else
    snapshot="$(snapshot_latest "$source_project")"
    [[ -n $snapshot ]] || die "$source has no snapshot to copy from. Take one first: kapelos use $source && kapelos snapshot save NAME"
  fi
  [[ -n $slot ]] || slot="$(first_free_slot)"
  require_port_slot "$slot"
  owner="$(slot_owner "$slot")"
  [[ -z $owner ]] || die "slot $slot is $owner's. Leave out --slot and $name gets the first free one"

  echo "Copying $source into a new site, $name: its code as it is now, and its snapshot $snapshot, saved $(snapshot_created "$source_project" "$snapshot"). $source isn't changed or stopped."
  SITE_COPY_UNFINISHED="$name"
  trap 'site_copy_stopped; heavy_turn_release' EXIT
  mkdir -p "$SITES_DIR" "$KAPELOS_HOME/$STORES_DIR"
  site_copy_settings "$source_file" "$file" "$name" "$slot" "$target"
  # From here every command acts on the new site.
  # shellcheck disable=SC2034 # load_env and the commands read it; a check of this file alone can't see them
  ENV_FILE="$file"
  load_env

  # It is admitted the way kapelos up admits any store, before anything large is copied, counting as what
  # the store it is a copy of used when it last ran.
  step "Checking there is room for another store"
  if bytes="$(recorded_footprint "$source_project")"; then
    mkdir -p "$(site_state_dir)"
    printf '%s\n' "$bytes" >"$(footprint_file "$COMPOSE_PROJECT_NAME")"
  fi
  require_ports_free "$COMPOSE_PROJECT_NAME"
  require_room_for_another "$COMPOSE_PROJECT_NAME"
  require_disk_room_for_copy "a copy of $source's snapshot $snapshot" "this copy" "${source_project}_snapshot-$snapshot-"
  need="$(du -sk "$code" | awk '{ printf "%.0f\n", $1 * 1024 }')"
  if free="$(free_bytes_in "$KAPELOS_HOME/$STORES_DIR")"; then
    [[ $need -le $free ]] ||
      die "$source's code is $(gib "$need") GiB, more than the $(gib "$free") GiB free in $KAPELOS_HOME/$STORES_DIR, where its copy goes"
  fi

  step "Copying $source's code, $(gib "$need") GiB, into $target"
  mkdir "$target"
  cp -a "$code/." "$target/"
  # The copy's .kapelos files are byte for byte the ones trusted in the store it was copied from.
  ! project_has_code "$target" || trust_project "$target"
  # Read again now the code is there: a store's own settings, such as its service versions, come with it.
  load_env

  step "Making $name's database, search index and queue"
  compose --progress quiet create db opensearch rabbitmq
  for volume in $SNAPSHOT_VOLUMES; do
    step "Copying $volume from the snapshot"
    copy_volume "${source_project}_snapshot-$snapshot-$volume" "${COMPOSE_PROJECT_NAME}_$volume"
  done
  cmd_up

  table="$(config_table)"
  step "Setting the copy's address to $MAGENTO_BASE_URL"
  db_root "${DB_NAME:-magento}" -e "
    UPDATE \`$table\` SET value = '$MAGENTO_BASE_URL'
      WHERE path IN ('web/unsecure/base_url', 'web/secure/base_url');
    DELETE FROM \`$table\` WHERE path = 'web/cookie/cookie_domain';"
  # A snapshot taken before a deploy is older than the code the deploy left, and Magento refuses to serve until they agree.
  if ! magento setup:db:status >/dev/null 2>&1; then
    step "Upgrading the copy's database to match its code"
    magento setup:upgrade --keep-generated
  fi
  cmd_cache_reset

  SITE_COPY_UNFINISHED=""
  echo "$name is up at $MAGENTO_BASE_URL, with $source's logins, and with its scheduled jobs off whatever $source's are."
  echo "It is not the active site:"
  echo "  kapelos use $name                      makes it the one plain commands act on"
  echo "  KAPELOS_ENV=$file kapelos ...   runs one command on it and switches nothing"
  echo "  kapelos site remove $name              deletes it, its copy of the code included, and stops nothing else"
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
    ports)
      site_ports "$@"
      return
      ;;
    copy)
      site_copy "$@"
      return
      ;;
    *) die "kapelos site audit [SITE], kapelos site copy SOURCE NEW, kapelos site ports SITE [--slot N] or kapelos site remove SITE" ;;
  esac
  if [[ -n ${1:-} ]]; then
    valid_site_name "$1"
    [[ -f $SITES_DIR/$1.env ]] || die "there's no site called $1. kapelos sites lists them"
    # shellcheck disable=SC2034 # load_env and the commands read it; a check of this file alone can't see them
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
