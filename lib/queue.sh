# The queue for heavy work: starting a store, installing one, composer, setup:upgrade and a reindex.
# shellcheck shell=bash
# A store sitting up costs little; these are what fill every core, so they take turns across every Kapelos
# folder on the machine. bash 3.2 and macOS have no flock, so a turn is a directory, which mkdir makes or
# refuses in one step. It is a queue for load, not a guard for data: the worst a race can do is let two
# run at once, and the one race left is two waiters clearing the same dead holder's turn in the same moment.

# Where every Kapelos folder of this user on this machine takes its turns.
heavy_queue_dir() {
  printf '%s' "${KAPELOS_QUEUE_DIR:-${TMPDIR:-/tmp}/kapelos-queue-$(id -u)}"
}

# Whether a command is heavy work: yes for starting, installing, composer changing the tree, saving or
# restoring a snapshot, copying a site, and the Magento commands that rebuild the database, the code or
# the indexes. A command with a colon is Magento's.
heavy_command() {
  local command="${1:-}" first="${2:-}"
  case "$command" in
    up | demo | interactive | magento-install | adopt | import | deploy | develop | sample-data | self-test) return 0 ;;
    modules) [[ $first == add || $first == remove ]] ;;
    snapshot) [[ $first == save || $first == restore ]] ;;
    site) [[ $first == copy ]] ;;
    composer)
      case "$first" in install | require | update | remove | reinstall | upgrade | create-project) return 0 ;; esac
      return 1
      ;;
    magento) heavy_magento_command "$first" ;;
    *:*) heavy_magento_command "$command" ;;
    *) return 1 ;;
  esac
}

heavy_magento_command() {
  case "${1:-}" in
    setup:upgrade | setup:install | setup:di:compile | setup:static-content:deploy | indexer:reindex | deploy:mode:set | sampledata:deploy) return 0 ;;
  esac
  return 1
}

# The start time ps reports for a process, which with its pid tells it apart from a later process given the same pid.
process_started() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/  */ /g; s/^ //; s/ $//' | grep .
}

# A turn's holder is alive while a process with its pid and its start time runs. A turn whose owner file
# isn't written yet is its holder's first instant, so it counts as held unless it is a minute old.
turn_is_held() {
  local turn="$1" pid started
  [[ -d $turn ]] || return 1
  if [[ ! -f $turn/owner ]]; then
    [[ -z $(find "$turn" -maxdepth 0 -mmin +1 2>/dev/null) ]]
    return
  fi
  { read -r pid && read -r started; } <"$turn/owner" || return 1
  [[ $(process_started "$pid" || true) == "$started" ]]
}

# What a turn's holder said it was doing, or DEFAULT while its owner file isn't written.
turn_holder() {
  local holder
  holder="$(sed -n 3p "$1/owner" 2>/dev/null || true)"
  printf '%s' "${holder:-$2}"
}

# Waits for a turn at heavy work, then holds it until this process exits. WHAT names the work in the
# line another waiter sees. A command run inside one that holds a turn already goes straight on.
heavy_turn_take() {
  local what="$1" dir at_once limit n turn busy announced="" waited=0
  [[ -z ${KAPELOS_HEAVY_TURN:-} ]] || return 0
  at_once="${KAPELOS_HEAVY_AT_ONCE:-1}"
  limit="${KAPELOS_HEAVY_WAIT:-3600}"
  [[ $at_once =~ ^[1-9][0-9]?$ ]] || die "KAPELOS_HEAVY_AT_ONCE is $at_once, and it takes how many heavy jobs may run at once, 1 or more"
  [[ $limit =~ ^[0-9]+$ ]] || die "KAPELOS_HEAVY_WAIT is $limit, and it takes the seconds to wait for a turn, 0 for no wait"
  dir="$(heavy_queue_dir)"
  mkdir -p "$dir" || die "can't make $dir for the queue of heavy work. Set KAPELOS_QUEUE_DIR to a folder you can write"
  while :; do
    busy=""
    for ((n = 1; n <= at_once; n++)); do
      turn="$dir/turn-$n"
      if mkdir "$turn" 2>/dev/null; then
        printf '%s\n%s\n%s\n' "$$" "$(process_started "$$")" "$what" >"$turn/owner"
        KAPELOS_HEAVY_TURN="$turn"
        HEAVY_TURN_MINE="$turn"
        export KAPELOS_HEAVY_TURN
        trap heavy_turn_release EXIT
        return 0
      fi
      if ! turn_is_held "$turn"; then
        echo "kapelos: $(turn_holder "$turn" "a heavy job") left its turn behind when it stopped; taking it" >&2
        rm -rf "$turn"
        n=$((n - 1))
        continue
      fi
      busy="${busy:+$busy; }$(turn_holder "$turn" "a job just starting")"
    done
    if [[ $busy != "$announced" ]]; then
      echo "kapelos: waiting for a turn at heavy work, $what: busy with $busy" >&2
      announced="$busy"
    fi
    [[ $waited -lt $limit ]] || die "waited ${limit}s for a turn at heavy work and it is still busy with $busy. Set KAPELOS_HEAVY_WAIT to wait longer"
    sleep 2
    waited=$((waited + 2))
  done
}

# Gives the turn back. Only the process that took it does, so a command run inside it never frees its caller's.
heavy_turn_release() {
  [[ -n ${HEAVY_TURN_MINE:-} ]] || return 0
  rm -rf "$HEAVY_TURN_MINE"
  HEAVY_TURN_MINE=""
}
