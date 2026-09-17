# What kapelos doctor and kapelos site audit decide.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted code runs in a container's shell, which expands it

report_line() {
  case "$1" in
    FAIL) REPORT_FAILS=$((REPORT_FAILS + 1)) ;;
    WARN) REPORT_WARNS=$((REPORT_WARNS + 1)) ;;
  esac
  printf '  %-4s  %s\n' "$1" "$2"
}

audit_run() {
  compose run --rm --no-deps -T audit "$@"
}

# The verdict comes from dep-intel's JSON report, which exists only when a scan finished, never from its exit status.
# The first line counts serious, exploited and lesser findings, or says unreadable; each line after it names a feed the store needs that the database doesn't hold.
intel_report() {
  { audit_run dep-intel scan /site --format json --no-fail 2>/dev/null </dev/null || true; } | python3 -c '
import json, sys
try:
    report = json.load(sys.stdin)
    by = report["summary"]["by_severity"]
    have = set(report["store"]["feeds"])
except Exception:
    print("unreadable")
    sys.exit()
print(by.get("critical", 0) + by.get("high", 0), report["summary"].get("kev", 0), sum(by.get(k, 0) for k in ("medium", "low", "unknown")))
for feed in sys.argv[1:]:
    if feed not in have:
        print(feed)' "$@"
}

audit_dependencies() {
  echo
  echo "Dependencies, checked by dep-intel"
  local db=var/intel/dep-intel.db out report counts serious kev lesser missing ecosystems feeds
  # Magento is NVD's record of Magento's own advisories, which a Mage-OS store is matched against too.
  ecosystems=(--ecosystem Packagist --ecosystem Magento)
  feeds=(osv:Packagist nvd:Magento)
  if [[ -f $MAGENTO_SRC/package-lock.json ]]; then
    ecosystems+=(--ecosystem npm)
    feeds+=(osv:npm)
  fi
  if [[ -d $MAGENTO_SRC/.github/workflows ]]; then
    ecosystems+=(--ecosystem "GitHub Actions")
    feeds+=("osv:GitHub Actions")
  fi
  [[ -f $db ]] && report="$(intel_report "${feeds[@]}")" || report=unreadable
  if [[ $report != [0-9]* || $report == *$'\n'* || -n $(find "$db" -mmin +1440 2>/dev/null) ]]; then
    if ! audit_run dep-intel sync -y "${ecosystems[@]}" >/dev/null 2>&1 </dev/null; then
      if [[ -f $db ]]; then
        report_line WARN "the advisories couldn't be refreshed, so this uses the last download"
      else
        report_line FAIL "the advisories couldn't be downloaded, so no dependency was checked"
        return
      fi
    fi
  fi

  out="$(audit_run dep-intel scan /site --no-fail 2>&1 </dev/null || true)"
  printf '%s\n' "$out" | sed -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*/        /'
  report="$(intel_report "${feeds[@]}")"
  counts="${report%%$'\n'*}"
  if [[ $counts == unreadable ]]; then
    report_line FAIL "dep-intel couldn't finish the scan, so no dependency was checked"
    return
  fi
  read -r serious kev lesser <<<"$counts"
  missing="$(printf '%s\n' "$report" | sed 1d | paste -sd, - | sed 's/,/, /g')"
  [[ -z $missing ]] || report_line FAIL "dep-intel has no advisories from $missing, so the packages those cover weren't checked"
  if [[ $serious -gt 0 || $kev -gt 0 ]]; then
    report_line FAIL "a dependency has a known vulnerability at high severity or above, or on CISA's exploited list, shown above"
  elif [[ -z $missing ]]; then
    report_line pass "nothing at or above high severity, and nothing on CISA's exploited list"
  fi
  [[ $lesser -eq 0 ]] || report_line WARN "$lesser finding(s) below high severity, shown above"
}

audit_credentials() {
  echo
  echo "Credentials, checked by credential-guard"
  local out status paths=() path count top
  # Only a repository of the store's own counts; a store sitting inside another repository, like the demo, doesn't.
  top="$(git -C "$MAGENTO_SRC" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n $top && $(cd "$top" && pwd -P) == $(cd "$MAGENTO_SRC" && pwd -P) ]]; then
    echo "        the files git tracks"
    set +e
    out="$(audit_run credential-guard scan /site 2>&1)"
    status=$?
    set -e
  else
    read -r -a paths <<<"${AUDIT_PATHS:-app/code app/design app/i18n app/etc/config.php}"
    local present=() files=() part rc
    for path in ${paths[@]+"${paths[@]}"}; do
      [[ -n $(find "$MAGENTO_SRC/$path" -type f -print -quit 2>/dev/null) ]] && present+=("$path")
    done
    count=0
    [[ ${#present[@]} -eq 0 ]] || count="$(cd "$MAGENTO_SRC" && find "${present[@]}" -type f | wc -l | tr -d ' ')"
    if [[ $count -eq 0 ]]; then
      report_line note "the store has no code of its own in ${AUDIT_PATHS:-app/code app/design app/i18n app/etc/config.php}, so there was nothing to scan"
      return
    fi
    echo "        $count file(s) in ${present[*]}"
    # credential-guard walks one directory per call, and reads several arguments as a list of files.
    out="" status=0
    for path in "${present[@]}"; do
      if [[ -d $MAGENTO_SRC/$path ]]; then
        set +e
        part="$(audit_run sh -c 'cd /site && credential-guard scan "$1"' sh "$path" 2>&1 </dev/null)"
        rc=$?
        set -e
        out+="$part"$'\n'
        [[ $rc -le $status ]] || status=$rc
      else
        files+=("$path")
      fi
    done
    if [[ ${#files[@]} -gt 0 ]]; then
      set +e
      part="$(audit_run sh -c 'cd /site && credential-guard scan "$@"' sh "${files[@]}" 2>&1 </dev/null)"
      rc=$?
      set -e
      out+="$part"
      [[ $rc -le $status ]] || status=$rc
    fi
  fi
  printf '%s\n' "$out" | grep -vE '^credential-guard: scanning|^[[:space:]]*$' | sed 's/^/        /' || true
  case "$status" in
    0) report_line pass "nothing that looks like a credential" ;;
    1) report_line FAIL "credential-guard found something that looks like a credential, or couldn't read a file; its output is above. A line meant to stay can carry: pragma: allowlist secret" ;;
    *) report_line FAIL "credential-guard couldn't run the scan; its output is above" ;;
  esac
}

audit_value_fails() {
  local value="$1" condition="$2"
  case "$condition" in
    "= "*) [[ $value == "${condition#= }" ]] ;;
    "> "*) [[ $value =~ ^[0-9]+$ && $value -gt ${condition#> } ]] ;;
    *) return 1 ;;
  esac
}

audit_settings() {
  echo
  echo "Security settings that ship with the store"
  local kind subject condition severity why value found=0 config="$MAGENTO_SRC/app/etc/config.php" db_up=0
  running_projects | grep -qx "${COMPOSE_PROJECT_NAME:-kapelos}" && installed 2>/dev/null && db_up=1
  while IFS=$'\t' read -r kind subject condition severity why; do
    if [[ $kind == module ]]; then
      value="$(sed -n "s/.*'$subject' => \([01]\).*/\1/p" "$config" 2>/dev/null | head -n 1)"
      [[ -n $value ]] || continue
      if audit_value_fails "$value" "$condition"; then
        report_line "$severity" "$subject is off: $why"
        found=1
      fi
    elif [[ $db_up -eq 1 ]]; then
      value="$(db_root -N "${DB_NAME:-magento}" -e "SELECT value FROM core_config_data WHERE path = '$subject' ORDER BY scope = 'default' DESC LIMIT 1" </dev/null)"
      [[ -n $value ]] || continue
      if audit_value_fails "$value" "$condition"; then
        report_line "$severity" "$subject is $value: $why"
        found=1
      fi
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$AUDIT_CHECKS")
  if [[ $db_up -eq 0 ]]; then
    [[ $found -eq 1 ]] || report_line pass "every security module is on"
    report_line note "the site isn't running, so settings held in its database weren't read"
  elif [[ $found -eq 0 ]]; then
    report_line pass "every security module is on, and no setting in $AUDIT_CHECKS is unsafe"
  fi
}

# A web server hands out whatever sits in pub/, so these are findings whichever server serves the store.
audit_public_files() {
  echo
  echo "Files in pub/ that any web server would hand out"
  local found=0 file
  while IFS= read -r file; do
    report_line FAIL "pub/${file#./}"
    found=1
  done < <(cd "$MAGENTO_SRC/pub" 2>/dev/null && find . -maxdepth 1 \( -iname '*.sql' -o -iname '*.sql.gz' -o -iname '*.zip' -o -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.bak' -o -iname '*.old' -o -iname '*.log' -o -iname 'phpinfo.php' -o -iname 'info.php' -o -iname 'adminer*.php' -o -name '.env' -o -name '.git' \) | sort)
  while IFS= read -r file; do
    report_line FAIL "pub/media/${file#./} is a script in the upload folder, the usual sign of a compromised store"
    found=1
  done < <(cd "$MAGENTO_SRC/pub/media" 2>/dev/null && find . -type f \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.phar' -o -iname '*.pht' \) | sort)
  [[ $found -eq 1 ]] || report_line pass "no dumps, archives, logs, info pages or scripts where they don't belong"
}

audit_headers() {
  echo
  echo "Security headers Magento sends"
  if ! running_projects | grep -qx "${COMPOSE_PROJECT_NAME:-kapelos}"; then
    report_line note "the site isn't running, so its headers weren't checked"
    return
  fi
  local url="${MAGENTO_BASE_URL:-http://localhost:8080/}" host port headers
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^:/]+).*#\1#')"
  port="$(printf '%s' "$url" | sed -nE 's#^https?://[^:/]+:([0-9]+).*#\1#p')"
  if [[ -z $port ]]; then
    port=80
    [[ $url != https://* ]] || port=443
  fi
  headers="$(curl -sk -o /dev/null -D - --resolve "$host:$port:127.0.0.1" "$url" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  if [[ -z $headers ]]; then
    report_line WARN "the storefront didn't answer, so its headers weren't checked"
    return
  fi
  if grep -q '^x-frame-options:' <<<"$headers"; then
    report_line pass "X-Frame-Options is sent, so other sites can't frame the store"
  else
    report_line FAIL "no X-Frame-Options, so another site can load the store in a frame and trick clicks"
  fi
  if grep -q '^x-content-type-options: nosniff' <<<"$headers"; then
    report_line pass "X-Content-Type-Options: nosniff is sent"
  else
    report_line WARN "no X-Content-Type-Options: nosniff, so browsers may guess a file's type"
  fi
  if grep -q '^content-security-policy:' <<<"$headers"; then
    report_line pass "a content security policy is enforced"
  elif grep -q '^content-security-policy-report-only:' <<<"$headers"; then
    report_line note "the content security policy only reports on the storefront, which is Magento's default"
  else
    report_line WARN "no content security policy is sent"
  fi
}

# A scaled site's other servers and its replica. Silent for a site on one server and no replica.
doctor_scale() {
  local n state
  for n in $(scale_extra_servers); do
    if scale_copy_stale "$n"; then
      report_line WARN "web-$n runs a copy of the code older than the store's folder. Copy it again with: kapelos scale refresh"
    fi
  done
  [[ $(scale_replicas) -gt 0 ]] || return 0
  state="$(scale_replica_state)"
  report_either "$(yes_if test "${state%%,*}" = running -o "$state" = "connecting to the primary")" "db-replica is replicating" FAIL "db-replica isn't replicating: $state. kapelos scale reseed copies the database to it again"
}

# The release a store is: Magento's version, or for Mage-OS the Magento version it's built on.
magento_release() {
  python3 - "$1/composer.lock" <<'PY' 2>/dev/null || true
import json, re, sys
for package in json.load(open(sys.argv[1]))["packages"]:
    if re.fullmatch(r"(magento|mage-os)/product-[a-z]+-edition", package["name"]):
        print(package.get("extra", {}).get("magento_version") or package["version"])
        break
PY
}

# A release's row from etc/magento-versions.tsv, tab-separated: mariadb opensearch valkey rabbitmq varnish nginx, each a list.
release_versions() {
  local line="$1"
  line="$(sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/' <<<"$line")"
  awk -F '\t' -v release="$line" '$1 == release { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }' etc/magento-versions.tsv
}

# Whether a version is one of those listed: equal to one, or under it, so 3 accepts 3.6.0 and 4.3 accepts 4.3-management-alpine.
version_listed() {
  local version="$1" listed
  for listed in $2; do
    [[ $version == "$listed" || $version == "$listed".* || $version == "$listed"-* ]] && return 0
  done
  return 1
}

# Prints a pass line when the first argument is yes, and otherwise a line at the level the third names.
report_either() {
  if [[ $1 == yes ]]; then
    report_line pass "$2"
  else
    report_line "$3" "$4"
  fi
}

# Its own subshell, so a check that exits, like one that calls die, only answers no.
yes_if() {
  if ("$@") >/dev/null 2>&1; then echo yes; else echo no; fi
}

# Whether this machine and this site can run: tools, memory, disk, ports, names, certificates and the store itself.
cmd_doctor() {
  REPORT_FAILS=0
  REPORT_WARNS=0
  local version major minor memory free root port running=no release row actual tool rc busy i n
  echo "This machine"
  if ! command -v docker >/dev/null; then
    report_line FAIL "Docker isn't installed"
  elif ! version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"; then
    report_line FAIL "Docker is installed, but its daemon isn't answering"
  else
    major="${version%%.*}"
    report_either "$(yes_if test "$major" -ge 25)" "Docker $version" FAIL "Docker $version; Kapelos needs 25 or newer for its health checks"
    version="$(docker compose version --short 2>/dev/null || true)"
    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"
    if [[ -z $version ]]; then
      report_line FAIL "Docker Compose v2 isn't installed"
    else
      report_either "$(yes_if test "$major" -gt 2 -o "$major" -eq 2 -a "$minor" -ge 20)" "Docker Compose $version" FAIL "Docker Compose $version; Kapelos needs 2.20 or newer"
    fi
    memory="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    memory=$((memory / 1073741824))
    report_either "$(yes_if test "$memory" -ge 8)" "$memory GiB of memory for containers" WARN "$memory GiB of memory for containers; a store with its search and database wants 8"
    root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    if [[ -d $root ]]; then
      free="$(df -Pk "$root" | awk 'NR == 2 { print int($4 / 1048576) }')"
      report_either "$(yes_if test "$free" -ge 20)" "$free GiB free for Docker's data" WARN "$free GiB free for Docker's data; a database copy or snapshot needs room"
    fi
  fi
  for tool in curl python3 gzip; do
    report_either "$(yes_if command -v "$tool")" "$tool" FAIL "$tool isn't installed, and Kapelos uses it"
  done
  report_either "$(yes_if command -v mkcert)" "mkcert, for kapelos cert" note "mkcert isn't installed, so kapelos cert can't issue a trusted certificate"
  if [[ -r /proc/meminfo ]]; then
    free="$(awk '/^MemAvailable:/ { print int($2 / 1048576) }' /proc/meminfo)"
    report_either "$(yes_if test "$free" -ge 6)" "$free GiB of memory available now" WARN "$free GiB of memory available now; a working store uses about 6"
  fi

  echo
  echo "This site"
  if [[ ! -f $ENV_FILE ]]; then
    report_line note "no site yet. kapelos demo or kapelos interactive makes one"
  elif ! (load_env) 2>"${TMPDIR:-/tmp}/kapelos-doctor.$$"; then
    report_line FAIL "its settings don't load: $(sed 's/^kapelos: //' "${TMPDIR:-/tmp}/kapelos-doctor.$$")"
  else
    load_env
    report_either "$(yes_if test -f "${MAGENTO_SRC:-}/bin/magento")" "the store is at $MAGENTO_SRC" FAIL "MAGENTO_SRC doesn't hold a Magento store: ${MAGENTO_SRC:-not set}"
    if project_has_code "${MAGENTO_SRC:-/nonexistent}"; then
      report_either "$(yes_if require_trusted "$MAGENTO_SRC")" "the store's .kapelos compose file and commands are trusted" \
        WARN "the store's .kapelos compose file or commands changed since you last trusted them. Read them, then: kapelos trust"
    fi
    running_projects | grep -qx "${COMPOSE_PROJECT_NAME:-kapelos}" && running=yes
    if [[ $running == yes ]]; then
      report_line pass "running"
      doctor_scale
    else
      local taken=0
      for port in "${HTTP_PORT:-8080}" "${HTTPS_PORT:-8443}" $(scaled && scale_port 1) $(for n in $(scale_extra_servers); do scale_port "$n"; done) "${DB_PORT:-13306}" "${MAIL_UI_PORT:-8025}" "${OPENSEARCH_PORT:-9200}" "${RABBITMQ_UI_PORT:-15672}"; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
          report_line FAIL "port $port is taken by something else, so the site can't start"
          taken=1
        fi
      done
      [[ $taken -eq 1 ]] || report_line pass "stopped, and its ports are free"
    fi
    if autoload_is_stale; then
      report_line WARN "the class map names generated classes that are gone, so the store won't boot. Fix it with: kapelos composer dump-autoload"
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/${LIVERELOAD_PORT:-35729}") 2>/dev/null; then
      report_line note "port ${LIVERELOAD_PORT:-35729} is taken, so kapelos grunt watch can't publish LiveReload there. Set LIVERELOAD_PORT to another"
    fi
    if [[ ${APP_HOST:-localhost} != localhost && ${APP_HOST:-} != 127.0.0.1 ]]; then
      rc=0
      curl -s -o /dev/null --max-time 3 "http://$APP_HOST:9/" 2>/dev/null || rc=$?
      # curl's exit status 6 means the name didn't resolve; anything else means it did.
      report_either "$(yes_if test "$rc" -ne 6)" "$APP_HOST resolves" WARN "$APP_HOST doesn't resolve on this machine. Add to /etc/hosts: 127.0.0.1 $APP_HOST"
    fi
    if [[ -f etc/tls/cert.pem ]] && command -v openssl >/dev/null; then
      report_either "$(yes_if openssl x509 -checkend 2592000 -noout -in etc/tls/cert.pem)" "the certificate from kapelos cert is good for 30 days or more" \
        WARN "the certificate from kapelos cert expires within 30 days. Run: kapelos cert"
    fi
    if [[ -d ${MAGENTO_SRC:-} ]]; then
      busy="$(adopt_path_in_use "$(cd "$MAGENTO_SRC" && pwd -P)")"
      [[ -z $busy ]] || report_line WARN "$(tr '\n' ' ' <<<"$busy")also uses this store; two stacks serving one store fight over it"
      release="$(magento_release "$MAGENTO_SRC")"
      row="$(release_versions "$release")"
      if [[ -n $row ]]; then
        local labels=(MariaDB OpenSearch Valkey RabbitMQ Varnish nginx) keys=(MARIADB_VERSION OPENSEARCH_VERSION VALKEY_VERSION RABBITMQ_VERSION VARNISH_VERSION NGINX_VERSION) wanted=()
        IFS=$'\t' read -r -a wanted <<<"$row"
        for i in 0 1 2 3 4 5; do
          actual="$(printenv "${keys[$i]}" || true)"
          version_listed "$actual" "${wanted[$i]}" ||
            report_line WARN "runs ${labels[$i]} ${actual:-by default}, which Magento $release doesn't list; it lists ${wanted[$i]// /, }. Set ${keys[$i]}=${wanted[$i]%% *} to match"
        done
        report_line pass "Magento $release"
      elif [[ -n $release ]]; then
        report_line note "Magento $release isn't in etc/magento-versions.tsv, so its service versions weren't checked"
      fi
    fi
  fi
  rm -f "${TMPDIR:-/tmp}/kapelos-doctor.$$"
  echo
  echo "$REPORT_FAILS failed, $REPORT_WARNS to look at."
  [[ $REPORT_FAILS -eq 0 ]]
}
