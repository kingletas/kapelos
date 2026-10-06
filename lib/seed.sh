# Production-sized data from a profile: Magento's own generator, a reindex, a record of what it cost and a snapshot.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

# Where, from the store's root, a profile Kapelos ships is put for the generator to read.
SEED_PROFILE_DIR=var/kapelos-seed
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

# Prints where the generator finds a profile, as a path from the store's root. One of Kapelos's is copied into
# the store first, since the generator runs in the container; one of Magento's is read where Magento keeps it.
seed_profile_path() {
  local name="$1" file="$KAPELOS_HOME/share/seed/$1.xml" edition
  if [[ -f $file ]]; then
    exec_quiet php sh -c 'mkdir -p "$1" && cat >"$1/$2.xml"' sh "$SEED_PROFILE_DIR" "$name" <"$file"
    printf '%s/%s.xml' "$SEED_PROFILE_DIR" "$name"
    return 0
  fi
  for edition in ee ce; do
    if exec_quiet php test -f "setup/performance-toolkit/profiles/$edition/$name.xml" </dev/null; then
      printf 'setup/performance-toolkit/profiles/%s/%s.xml' "$edition" "$name"
      return 0
    fi
  done
  return 1
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
  path="$(seed_profile_path "$profile")" || die "there's no profile called $profile. kapelos seed lists them"
  if [[ $snapshot == yes ]]; then
    # Both asked before the hours of generating, not after them.
    require_helper_starts
    require_disk_room_for_snapshot
    # A store with no snapshot at all has no way back from a seed, so it gets one first.
    [[ -n $(snapshot_names) ]] || cmd_snapshot save before-seed
  fi

  step "Generating $profile with Magento's own generator. A large profile takes hours"
  SECONDS=0
  exec_php_no_xdebug php -d memory_limit=-1 bin/magento setup:performance:generate-fixtures --skip-reindex "$path"
  generate_s=$SECONDS
  step "Reindexing"
  SECONDS=0
  exec_php_no_xdebug php -d memory_limit=-1 bin/magento indexer:reindex
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
