# Your own commands, and the ones Kapelos ships in share/commands.
# shellcheck shell=bash

user_commands_dir() {
  printf '%s/kapelos/commands' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

shipped_commands() {
  local file
  for file in "$SHARE_COMMANDS"/*; do
    if [[ -f $file ]]; then
      basename "$file"
    fi
  done
}

# The comment on the line under the shebang, which is what kapelos help lists.
command_summary() {
  sed -n '2s/^# \{0,1\}//p' "$1"
}

# Which lib files a command needs is read out of the command itself, so there's no second list to fall behind.
command_lib_files() {
  local file name
  for file in "$SHARE_COMMANDS"/lib/*; do
    [[ -f $file ]] || continue
    name="$(basename "$file")"
    if grep -qF "$name" "$1"; then
      printf '%s\n' "$name"
    fi
  done
}

# same when it's the file Kapelos ships, changed when you've edited it, - when it isn't there.
command_state() {
  if [[ ! -f $1/$2 ]]; then
    printf -- '-'
  elif cmp -s "$SHARE_COMMANDS/$2" "$1/$2"; then
    printf 'same'
  else
    printf 'changed'
  fi
}

# The store's folder unless you say --user, and yours when there's no store yet.
commands_destination() {
  local where="$1"
  if [[ $where == user ]]; then
    user_commands_dir
    return
  fi
  [[ ! -f $ENV_FILE ]] || load_env
  if [[ -n ${MAGENTO_SRC:-} ]]; then
    printf '%s/.kapelos/commands' "$MAGENTO_SRC"
  elif [[ $where == store ]]; then
    die "there's no store to add them to yet: $ENV_FILE names no MAGENTO_SRC. Put them where every store sees them instead: kapelos commands add --user"
  else
    user_commands_dir
  fi
}

# True when .kapelos holds nothing but the files Kapelos ships, so there's nothing in it you haven't read.
commands_only_ours() {
  local store="$1" file name
  [[ ! -f $store/.kapelos/compose.yaml ]] || return 1
  for file in "$store"/.kapelos/commands/*; do
    [[ -e $file ]] || continue
    name="$(basename "$file")"
    if [[ -d $file ]]; then
      [[ $name == lib ]] || return 1
    else
      cmp -s "$SHARE_COMMANDS/$name" "$file" || return 1
    fi
  done
  for file in "$store"/.kapelos/commands/lib/*; do
    [[ -e $file ]] || continue
    cmp -s "$SHARE_COMMANDS/lib/$(basename "$file")" "$file" || return 1
  done
}

# A store's commands run with your permissions, so they're trusted here only when nothing in .kapelos is unread.
commands_retrust() {
  local destination="$1" trusted_before="$2" store
  [[ $destination == */.kapelos/commands ]] || return 0
  store="${destination%/.kapelos/commands}"
  if [[ $trusted_before == yes ]] || commands_only_ours "$store"; then
    if project_has_code "$store"; then
      trust_project "$store"
      echo "  Trusted them for you: there's nothing in .kapelos you haven't read."
    fi
  else
    echo "  Not trusted: something else in $store/.kapelos is new or changed since you last read it."
    echo "  Read it, then: kapelos trust $store"
  fi
}

commands_status() {
  local user_dir store_dir="" name store="" you
  user_dir="$(user_commands_dir)"
  [[ ! -f $ENV_FILE ]] || load_env
  [[ -z ${MAGENTO_SRC:-} ]] || store_dir="$MAGENTO_SRC/.kapelos/commands"

  printf '  %-14s %-9s %-9s %s\n' Command Store You 'What it does'
  while IFS= read -r name; do
    store='-'
    [[ -z $store_dir ]] || store="$(command_state "$store_dir" "$name")"
    you="$(command_state "$user_dir" "$name")"
    printf '  %-14s %-9s %-9s %s\n' "$name" "$store" "$you" "$(command_summary "$SHARE_COMMANDS/$name")"
  done < <(shipped_commands)

  echo
  if [[ -n $store_dir ]]; then
    echo "  Store is this store's .kapelos/commands, shared with everyone working on it."
  fi
  echo "  You is ${user_dir/#$HOME/\~}, which follows you into every store."
  if [[ -n $store_dir ]]; then
    echo "  Add all of them to this store: kapelos commands add        Or just yours: kapelos commands add --user"
  else
    echo "  There's no store here yet. Add all of them for yourself: kapelos commands add --user"
  fi
}

commands_add() {
  local destination="$1" force="$2" trusted_before=no name lib store=""
  shift 2
  [[ $destination != */.kapelos/commands ]] || store="${destination%/.kapelos/commands}"
  if [[ -n $store && -d $store ]] && project_is_trusted "$store"; then
    trusted_before=yes
  fi

  step "Adding ${#@} command(s) to $destination"
  mkdir -p "$destination"
  for name in "$@"; do
    if [[ $(command_state "$destination" "$name") == changed && $force == no ]]; then
      echo "  kept     $name, because the copy there isn't the one Kapelos ships. Replace it with: kapelos commands add $name -f"
      continue
    fi
    cp "$SHARE_COMMANDS/$name" "$destination/$name"
    chmod 0755 "$destination/$name"
    while IFS= read -r lib; do
      mkdir -p "$destination/lib"
      if [[ -f $destination/lib/$lib ]] && ! cmp -s "$SHARE_COMMANDS/lib/$lib" "$destination/lib/$lib" && [[ $force == no ]]; then
        echo "  kept     lib/$lib, which has been changed since it was added"
      else
        cp "$SHARE_COMMANDS/lib/$lib" "$destination/lib/$lib"
      fi
    done < <(command_lib_files "$SHARE_COMMANDS/$name")
    echo "  added    $name"
  done

  commands_retrust "$destination" "$trusted_before"
  echo "  kapelos help lists them, and each one takes -h."
}

commands_remove() {
  local destination="$1" force="$2" trusted_before=no name lib store="" wanted
  shift 2
  [[ $destination != */.kapelos/commands ]] || store="${destination%/.kapelos/commands}"
  if [[ -n $store && -d $store ]] && project_is_trusted "$store"; then
    trusted_before=yes
  fi
  [[ -d $destination ]] || die "there's nothing in $destination to remove"

  step "Removing command(s) from $destination"
  for name in "$@"; do
    if [[ ! -f $destination/$name ]]; then
      echo "  not there  $name"
      continue
    fi
    if [[ $(command_state "$destination" "$name") == changed && $force == no ]]; then
      echo "  kept     $name, because it has been changed since it was added. Remove it anyway with: kapelos commands remove $name -f"
      continue
    fi
    rm -f "$destination/$name"
    echo "  removed  $name"
  done

  # A lib file goes when no command left in the folder names it, and only while it's still ours.
  for lib in "$destination"/lib/*; do
    [[ -f $lib ]] || continue
    name="$(basename "$lib")"
    wanted=no
    for file in "$destination"/*; do
      if [[ -f $file ]] && grep -qF "$name" "$file"; then
        wanted=yes
      fi
    done
    if [[ $wanted == no ]] && { [[ $force == yes ]] || cmp -s "$SHARE_COMMANDS/lib/$name" "$lib"; }; then
      rm -f "$lib"
      echo "  removed  lib/$name"
    fi
  done
  rmdir "$destination/lib" 2>/dev/null || true
  rmdir "$destination" 2>/dev/null || true

  commands_retrust "$destination" "$trusted_before"
}

cmd_commands() {
  local action=status
  case "${1:-}" in
    add | remove | status)
      action="$1"
      shift
      ;;
    '' | -*) ;;
    *) die "kapelos commands shows them; kapelos commands add [NAME...] and kapelos commands remove [NAME...] change them" ;;
  esac

  local where="" force=no argument name
  local names=() selected=()
  while [[ $# -gt 0 ]]; do
    argument="$1"
    shift
    case "$argument" in
      --user) where=user ;;
      --store) where=store ;;
      -f | --force) force=yes ;;
      -*) die "kapelos commands takes --user, --store and -f, not $argument" ;;
      *) names+=("$argument") ;;
    esac
  done

  if [[ $action == status ]]; then
    commands_status
    return
  fi

  local destination
  destination="$(commands_destination "$where")"

  if [[ ${#names[@]} -gt 0 ]]; then
    selected=("${names[@]}")
    for name in "${selected[@]}"; do
      [[ -f $SHARE_COMMANDS/$name ]] || die "Kapelos doesn't ship a command called $name. kapelos commands lists the ones it does."
    done
  else
    # With no names, add means all of them and remove means the ones that are actually there.
    while IFS= read -r name; do
      if [[ $action == add || -f $destination/$name ]]; then
        selected+=("$name")
      fi
    done < <(shipped_commands)
  fi

  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "None of the commands Kapelos ships are in $destination."
    return
  fi

  "commands_$action" "$destination" "$force" "${selected[@]}"
}

# A command Kapelos doesn't have is looked for in the store's .kapelos/commands, then in your own.
custom_command_file() {
  local name="$1" store="" file
  [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [[ -f $ENV_FILE ]] && store="$(env_value "$ENV_FILE" MAGENTO_SRC)"
  for file in "$store/.kapelos/commands/$name" "${XDG_CONFIG_HOME:-$HOME/.config}/kapelos/commands/$name"; do
    [[ -n $store || $file != /.kapelos/* ]] || continue
    if [[ -f $file ]]; then
      printf '%s' "$file"
      return 0
    fi
  done
  return 1
}

run_custom_command() {
  local file="$1"
  shift
  load_env
  [[ $file != "${MAGENTO_SRC:-}/.kapelos/"* ]] || require_trusted "$MAGENTO_SRC"
  [[ -x $file ]] || die "$file isn't executable. Make it so with: chmod +x $file"
  export KAPELOS="$KAPELOS_HOME/bin/kapelos" KAPELOS_HOME
  cd "${MAGENTO_SRC:-$KAPELOS_HOME}"
  exec "$file" "$@"
}

# Each custom command with the first comment line under its shebang.
list_custom_commands() {
  local store="" dir file
  [[ -f $ENV_FILE ]] && store="$(env_value "$ENV_FILE" MAGENTO_SRC)"
  for dir in ${store:+"$store/.kapelos/commands"} "${XDG_CONFIG_HOME:-$HOME/.config}/kapelos/commands"; do
    for file in "$dir"/*; do
      [[ -f $file ]] || continue
      printf '  %-22s %s\n' "$(basename "$file")" "$(sed -n '2s/^# \{0,1\}//p' "$file")"
    done
  done
}
