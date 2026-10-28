# A store as a deploy target: releases under DEPLOY_ROOT, a web node and a build host a deployment tool reaches by SSH.
# shellcheck shell=bash

# The release symlink, named as the deployment tools this was built for name it.
DEPLOY_LINK=magento_current

deploy_target() {
  [[ -n ${DEPLOY_ROOT:-} ]]
}

# DEPLOY_ROOT replaces MAGENTO_SRC with the live release, so everything that reads the store's files reads that.
derive_deploy_target() {
  unset KAPELOS_DEPLOY_FILE KAPELOS_DEPLOY_STATE
  deploy_target || return 0
  [[ $DEPLOY_ROOT =~ ^/[A-Za-z0-9._/-]+$ && $DEPLOY_ROOT != *..* && $DEPLOY_ROOT != */ ]] ||
    die "DEPLOY_ROOT is $DEPLOY_ROOT, and it must be an absolute path of letters, digits, dots, dashes and underscores, with no trailing slash"
  [[ -n ${DEPLOY_ORIGIN:-} ]] || die "a deploy target needs DEPLOY_ORIGIN, the bare repository its builder clones"
  [[ ${DEPLOY_SSH_PORT:=2222} =~ ^[0-9]+$ ]] || die "DEPLOY_SSH_PORT is $DEPLOY_SSH_PORT, which isn't a port"
  [[ ${WEB_SERVERS:-1} == 1 && ${DB_REPLICAS:-0} == 0 ]] ||
    die "a deploy target runs one web server and no replica for now. Set WEB_SERVERS=1 and DB_REPLICAS=0, or take DEPLOY_ROOT out"
  [[ ${MAGENTO_SRC:-} == "$DEPLOY_ROOT/$DEPLOY_LINK" ]] ||
    die "MAGENTO_SRC is ${MAGENTO_SRC:-unset}, and with DEPLOY_ROOT set it must be $DEPLOY_ROOT/$DEPLOY_LINK, the live release"
  export DEPLOY_SSH_PORT
  KAPELOS_DEPLOY_STATE="$KAPELOS_HOME/$(site_state_dir)/deploy"
  export KAPELOS_DEPLOY_STATE
  export KAPELOS_DEPLOY_FILE="$KAPELOS_HOME/compose.deploy-target.yaml"
  deploy_target_keys
}

# A key pair for the deployment, a host key for each node, and the known_hosts that names both, so nothing that
# connects ever skips the host check. Kept in the site's state folder, readable only by you. Also the builder's own
# shared/env.php, made on every run so a target made before it existed gets one too.
deploy_target_keys() {
  local dir="$KAPELOS_DEPLOY_STATE" known
  if [[ ! -f $dir/keys/id_deploy || ! -f $dir/host_key_web || ! -f $dir/host_key_builder ]]; then
    require_tools ssh-keygen
    mkdir -p "$dir/keys" "$dir/builder-tree"
    chmod 700 "$dir" "$dir/keys"
    [[ -f $dir/keys/id_deploy ]] || ssh-keygen -q -t ed25519 -N '' -C "deploy@${COMPOSE_PROJECT_NAME:-kapelos}" -f "$dir/keys/id_deploy"
    [[ -f $dir/host_key_web ]] || ssh-keygen -q -t ed25519 -N '' -C web -f "$dir/host_key_web"
    [[ -f $dir/host_key_builder ]] || ssh-keygen -q -t ed25519 -N '' -C builder -f "$dir/host_key_builder"
  fi
  write_if_changed "$dir/authorized_keys" "$(cat "$dir/keys/id_deploy.pub")"
  # The builder by the address the deploying machine reaches it on; the web node by its name on the store's network.
  known="[127.0.0.1]:$DEPLOY_SSH_PORT $(cut -d' ' -f1,2 "$dir/host_key_builder.pub")
[php]:2222 $(cut -d' ' -f1,2 "$dir/host_key_web.pub")"
  write_if_changed "$dir/keys/known_hosts" "$known"
  # A deployment links the build's app/etc/env.php at shared/env.php before any bin/magento call, and
  # setup:di:compile writes into it. The builder mounts its own tree, never the host's shared/, so it gets a
  # scratch env.php of its own: empty when made, never overwritten, and never the live one.
  mkdir -p "$dir/builder-tree/shared"
  [[ -e $dir/builder-tree/shared/env.php || -L $dir/builder-tree/shared/env.php ]] ||
    : >"$dir/builder-tree/shared/env.php"
}

refuse_on_deploy_target() {
  deploy_target || return 0
  die "this site is a deploy target, so its code changes only through a deployment. $1"
}

cmd_deploy_target() {
  load_env
  case "${1:-}" in
    '') deploy_target_status ;;
    init)
      shift
      deploy_target_init "$@"
      ;;
    *) die "deploy-target doesn't know $1. See: kapelos help" ;;
  esac
}

deploy_target_status() {
  if ! deploy_target; then
    echo "This site isn't a deploy target. kapelos deploy-target init ROOT --origin REPO makes it one."
    return
  fi
  local live releases host
  live="$(readlink "$DEPLOY_ROOT/$DEPLOY_LINK" 2>/dev/null || echo "none")"
  releases="$(find "$DEPLOY_ROOT/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  host="$(hostname)"
  cat <<EOF
Deploy root      $DEPLOY_ROOT
Live release     $live, one of $releases
Builds from      $DEPLOY_ORIGIN
Keys             $KAPELOS_DEPLOY_STATE/keys (id_deploy and known_hosts)

From the machine you deploy from, with the keys folder copied to the same path there:
  builder  127.0.0.1 port $DEPLOY_SSH_PORT, through $host
  web      php port 2222, through $host and then the builder
EOF
}

# Copies the site's tree into ROOT as its first release. The tree itself isn't changed, so taking DEPLOY_ROOT out and
# putting MAGENTO_SRC back is the way back.
deploy_target_init() {
  local root="" origin="" label yes=no tree="${MAGENTO_SRC:-}" release
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --origin)
        [[ $# -ge 2 ]] || die "--origin takes the bare repository the builder clones"
        origin="$2"
        shift
        ;;
      -y) yes=yes ;;
      -*) die "deploy-target init doesn't know $1. See: kapelos help" ;;
      *) root="$1" ;;
    esac
    shift
  done
  ! deploy_target || die "this site is already a deploy target, at $DEPLOY_ROOT"
  [[ -n $root && -n $origin ]] || die "kapelos deploy-target init ROOT --origin REPO"
  [[ $root =~ ^/[A-Za-z0-9._/-]+$ && $root != *..* && $root != */ ]] || die "ROOT must be an absolute path with no trailing slash: $root"
  [[ ! -e $root || -z $(ls -A "$root") ]] || die "$root isn't empty"
  [[ $(git -C "$origin" rev-parse --is-bare-repository 2>/dev/null) == true ]] || die "$origin isn't a bare git repository"
  [[ -f $tree/app/etc/env.php ]] || die "MAGENTO_SRC, $tree, isn't an installed store"
  label="$(date +%Y%m%d)_$(date +%s)_initial"
  release="$root/releases/$label"
  confirm "Copy $tree ($(du -sh "$tree" | cut -f1)) into $release and make it the live release?" "$yes" || return 0

  step "Copying the store into $release"
  mkdir -p "$root/releases" "$root/shared" "$root/archives"
  cp -a "$tree/." "$release"
  # Media and env.php are the release's links into shared/, as a deployment makes them.
  mv "$release/pub/media" "$root/shared/media"
  ln -s "$root/shared/media" "$release/pub/media"
  mv "$release/app/etc/env.php" "$root/shared/env.php"
  ln -s "$root/shared/env.php" "$release/app/etc/env.php"
  ln -s "releases/$label" "$root/$DEPLOY_LINK"

  printf '# Before it was a deploy target: MAGENTO_SRC=%s\n' "$tree" >>"$(follow_link "$ENV_FILE")"
  set_env_value "$ENV_FILE" MAGENTO_SRC "$root/$DEPLOY_LINK"
  set_env_value "$ENV_FILE" DEPLOY_ROOT "$root"
  set_env_value "$ENV_FILE" DEPLOY_ORIGIN "$origin"
  load_env
  echo
  echo "Made. $tree is as it was. Next: kapelos build, then kapelos up."
  deploy_target_status
}
