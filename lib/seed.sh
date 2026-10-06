# Production-sized data from a profile: Magento's own generator, a reindex, a record of what it cost and a snapshot.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

# Where, from the store's root, a profile Kapelos ships is put for the generator to read. The profiles in
# share/seed name Magento's own files by a path from here, two folders below the root.
SEED_PROFILE_DIR=var/kapelos-seed
# The generator's stand-ins for mail. A profile names this file, and the generator skips a missing one without
# a word and sends through the store's own transport, so seed asks for both before it generates.
SEED_MAIL_STAND_INS=setup/performance-toolkit/config/di.xml
SEED_RECORD_HEADER='when	profile	generate_s	reindex_s	simples	configurables	bundles	categories	customers	orders	db_mib	search_mib	queue_mib	media_mib	php_peak_mib	db_peak_mib	search_peak_mib'

# The file that holds one line for every seed of this site, on this machine only.
seed_record_file() {
  printf '%s/var/seed/%s.tsv' "$KAPELOS_HOME" "$COMPOSE_PROJECT_NAME"
}

# A seed's snapshots are a series named for its profile; a snapshot's name takes dashes, not underscores.
seed_series() {
  printf 'seed-%s' "${1//_/-}"
}

# The profiles Magento ships in this store, one name a line, or nothing when the store has none.
magento_seed_profiles() {
  exec_quiet php sh -c 'for f in setup/performance-toolkit/profiles/*/*.xml; do [ -f "$f" ] && basename "$f" .xml; done; true' </dev/null |
    LC_ALL=C sort -u
}

# Whether a profile is one Kapelos ships.
seed_profile_is_ours() {
  [[ -f $KAPELOS_HOME/share/seed/$1.xml ]]
}

# Prints where Magento keeps a profile of its own in this store, as a path from the store's root.
magento_seed_profile_path() {
  local edition
  for edition in ee ce; do
    if exec_quiet php test -f "setup/performance-toolkit/profiles/$edition/$1.xml" </dev/null; then
      printf 'setup/performance-toolkit/profiles/%s/%s.xml' "$edition" "$1"
      return 0
    fi
  done
  return 1
}

# Copies a profile Kapelos ships into the store, since the generator runs in the container.
seed_profile_put() {
  exec_quiet php sh -c 'mkdir -p "$1" && cat >"$1/$2.xml"' sh "$SEED_PROFILE_DIR" "$1" <"$KAPELOS_HOME/share/seed/$1.xml"
}

seed_list() {
  local file names
  echo "Kapelos's own, each a step toward the last:"
  for file in "$KAPELOS_HOME"/share/seed/*.xml; do
    [[ -f $file ]] || continue
    printf '  %-14s %s\n' "$(basename "$file" .xml)" "$(sed -n 's/^.*<!-- kapelos: \(.*\) -->.*$/\1/p' "$file" | sed -n 1p)"
  done
  load_env
  if compose ps --status running --services 2>/dev/null | holds -qx php; then
    names="$(magento_seed_profiles | tr '\n' ' ')"
    echo "Magento's own, in this store: ${names:-none: the store has no setup/performance-toolkit folder}"
  else
    echo "Magento's own are listed once the store is up: kapelos up"
  fi
}

# The most memory a service's container has held since it started, in MiB, or - where the kernel doesn't say.
service_peak_mib() {
  local bytes
  bytes="$(exec_quiet "$1" cat /sys/fs/cgroup/memory.peak 2>/dev/null </dev/null || true)"
  if [[ $bytes =~ ^[0-9]+$ ]]; then
    printf '%s' $((bytes / 1048576))
  else
    printf -- '-'
  fi
}

# What a volume of this site holds, in MiB, or - when it can't be measured.
seed_volume_mib() {
  local bytes
  bytes="$(volume_bytes "${COMPOSE_PROJECT_NAME}_$1" || true)"
  if [[ $bytes =~ ^[0-9]+$ ]]; then
    printf '%s' $((bytes / 1048576))
  else
    printf -- '-'
  fi
}

# Simple, configurable and bundle products, categories, customers and orders, tab-separated, as the database counts them.
seed_counts() {
  local db="${DB_NAME:-magento}" prefix
  prefix="$(table_prefix)"
  db_root -N -e "SELECT
    (SELECT COUNT(*) FROM \`$db\`.\`${prefix}catalog_product_entity\` WHERE type_id = 'simple'),
    (SELECT COUNT(*) FROM \`$db\`.\`${prefix}catalog_product_entity\` WHERE type_id = 'configurable'),
    (SELECT COUNT(*) FROM \`$db\`.\`${prefix}catalog_product_entity\` WHERE type_id = 'bundle'),
    (SELECT COUNT(*) FROM \`$db\`.\`${prefix}catalog_category_entity\`),
    (SELECT COUNT(*) FROM \`$db\`.\`${prefix}customer_entity\`),
    (SELECT COUNT(*) FROM \`$db\`.\`${prefix}sales_order\`)" </dev/null
}

# Adds this seed's line to the site's record: what the store holds now, what it takes on disk, how long the two
# slow steps took, and the most memory each of the three busiest containers has held since it started.
seed_record() {
  local profile="$1" generate_s="$2" reindex_s="$3" file counts media
  file="$(seed_record_file)"
  mkdir -p "$(dirname "$file")"
  [[ -s $file ]] || printf '%s\n' "$SEED_RECORD_HEADER" >"$file"
  counts="$(seed_counts)" || counts="-	-	-	-	-	-"
  media="$(exec_quiet php du -sk pub/media </dev/null | cut -f 1 || true)"
  if [[ $media =~ ^[0-9]+$ ]]; then
    media=$((media / 1024))
  else
    media="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$profile" "$generate_s" "$reindex_s" \
    "$counts" "$(seed_volume_mib db-data)" "$(seed_volume_mib opensearch-data)" "$(seed_volume_mib rabbitmq-data)" "$media" \
    "$(service_peak_mib php)" "$(service_peak_mib db)" "$(service_peak_mib opensearch)" >>"$file"
}

seed_steps() {
  local file
  load_env
  file="$(seed_record_file)"
  [[ -s $file ]] || {
    echo "No seed of this site is on record yet. kapelos seed PROFILE makes the first."
    return 0
  }
  if command -v column >/dev/null 2>&1; then
    column -t -s '	' "$file"
  else
    cat "$file"
  fi
}

seed_reset() {
  local profile="" yes=no name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y) yes=yes ;;
      -*) die "seed reset doesn't know $1. See: kapelos help" ;;
      *) profile="$1" ;;
    esac
    shift
  done
  [[ -n $profile ]] || die "name the profile to go back to: kapelos seed reset PROFILE"
  load_env
  name="$(snapshot_series "$(seed_series "$profile")" | tail -n 1)"
  [[ -n $name ]] || die "this site has no snapshot of $profile to go back to. kapelos seed $profile makes one"
  if [[ $yes == yes ]]; then
    cmd_snapshot restore "$name" -y
  else
    cmd_snapshot restore "$name"
  fi
}

# Says which snapshot a seed can be undone with and when it was saved, since one that is weeks old is a way
# back to a store weeks old.
seed_way_back() {
  local name
  name="$(snapshot_latest)"
  if [[ -n $name ]]; then
    echo "The way back from this seed is the snapshot $name, saved $(snapshot_created "$COMPOSE_PROJECT_NAME" "$name"): kapelos snapshot restore $name"
  else
    echo "This site has no snapshot, so there is no way back from this seed short of installing the store again."
  fi
}

# Takes the profile kapelos put in the store out again; one of Magento's own is left where Magento keeps it.
seed_profile_remove() {
  [[ $1 == "$SEED_PROFILE_DIR"/* ]] || return 0
  exec_quiet php sh -c 'rm -f "$1" && rmdir "$2" 2>/dev/null; true' sh "$1" "$SEED_PROFILE_DIR" </dev/null || true
}

seed_failed() {
  seed_profile_remove "$2"
  echo "kapelos: $1 failed, so nothing was recorded and no snapshot of the half-seeded store was saved." >&2
  seed_way_back >&2
  exit 1
}

# Generates, reindexes, records and snapshots. The generator adds only what the store lacks to reach the
# profile's numbers, so a store grows by seeding a larger profile over a smaller one.
seed_run() {
  local profile="$1" snapshot=yes keep path generate_s reindex_s
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-snapshot) snapshot=no ;;
      *) die "seed doesn't know $1. See: kapelos help" ;;
    esac
    shift
  done
  [[ $profile =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "a profile's name uses lowercase letters, digits, dashes and underscores: $profile. kapelos seed lists them"
  load_env
  require_running php db opensearch
  installed || die "the store isn't installed yet. Run: kapelos magento-install"
  keep="${SEED_SNAPSHOT_KEEP:-1}"
  [[ $keep =~ ^[1-9][0-9]?$ ]] || die "SEED_SNAPSHOT_KEEP is $keep, and it takes how many snapshots of one profile to keep, 1 to 99"
  exec_quiet php test -f "$SEED_MAIL_STAND_INS" </dev/null ||
    die "this store has no $SEED_MAIL_STAND_INS, which holds the generator's stand-ins for mail. Without it the generator sends its mail through the store's own transport, so nothing is generated"
  if seed_profile_is_ours "$profile"; then
    grep -qF "<di>../../$SEED_MAIL_STAND_INS</di>" "$KAPELOS_HOME/share/seed/$profile.xml" ||
      die "share/seed/$profile.xml doesn't name the generator's stand-ins for mail, so its mail would go out through the store's own transport. It needs this line in its profile: <di>../../$SEED_MAIL_STAND_INS</di>"
    path="$SEED_PROFILE_DIR/$profile.xml"
  else
    path="$(magento_seed_profile_path "$profile")" || die "there's no profile called $profile. kapelos seed lists them"
  fi
  if [[ $snapshot == yes ]]; then
    # Both asked before the hours of generating, not after them.
    require_helper_starts
    require_disk_room_for_snapshot
    # A store with no snapshot at all has no way back from a seed, so it gets one first.
    [[ -n $(snapshot_names) ]] || cmd_snapshot save before-seed
  fi
  seed_way_back
  # Put there last, so a refusal above leaves nothing of the seed in the store.
  ! seed_profile_is_ours "$profile" || seed_profile_put "$profile"

  step "Generating $profile with Magento's own generator. A large profile takes hours"
  SECONDS=0
  exec_php_no_xdebug php -d memory_limit=-1 bin/magento setup:performance:generate-fixtures --skip-reindex "$path" ||
    seed_failed "generating $profile" "$path"
  generate_s=$SECONDS
  seed_profile_remove "$path"
  step "Reindexing"
  SECONDS=0
  exec_php_no_xdebug php -d memory_limit=-1 bin/magento indexer:reindex || seed_failed "the reindex after generating $profile" "$path"
  reindex_s=$SECONDS
  cmd_cache_reset
  step "Recording what the store holds and what it cost"
  seed_record "$profile" "$generate_s" "$reindex_s"
  if [[ $snapshot == yes ]]; then
    cmd_snapshot save --series "$(seed_series "$profile")" --keep "$keep"
    echo "Seeded $profile. kapelos seed reset $profile puts the store back to this, in the time a restore takes."
  else
    echo "Seeded $profile, with no snapshot: kapelos snapshot save NAME takes one."
  fi
  echo "kapelos seed steps shows what every seed of this site cost."
}

cmd_seed() {
  local action="${1:-list}"
  [[ $# -gt 0 ]] && shift
  case "$action" in
    list) seed_list ;;
    steps) seed_steps ;;
    reset) seed_reset "$@" ;;
    -*) die "seed takes a profile's name first: kapelos seed PROFILE. kapelos seed lists them" ;;
    *) seed_run "$action" "$@" ;;
  esac
}
