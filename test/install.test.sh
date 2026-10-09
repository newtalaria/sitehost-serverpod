#!/usr/bin/env bash
# The hosting install is idempotent, and a failed reload restores the previous files.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
install="${root}/actions/ssh/remote-install.sh"
site="${root}/nginx/serverpod.conf"
program="${root}/supervisor/serverpod.conf"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "${tmp}/supervisorctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SUPERVISOR_LOG:?}"
if [[ "${FAIL_REREAD:-0}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
chmod 755 "${tmp}/supervisorctl"

prepare_tree() {
  local dir="$1"
  mkdir -p "${dir}/nginx/sites-available" "${dir}/nginx/sites-enabled" "${dir}/application"
  printf '%s\n' '[supervisord]' > "${dir}/supervisord.conf"
  printf '%s\n' 'nodaemon=true' >> "${dir}/supervisord.conf"
  printf '%s\n' '[program:nginx]' >> "${dir}/supervisord.conf"
  printf '%s\n' 'command=/usr/sbin/nginx' >> "${dir}/supervisord.conf"
}

run_install() {
  local dir="$1"
  local reload="$2"
  SITEHOST_APP_PATH="${dir}/application" \
    NGINX_SITE_FILE="${dir}/nginx/sites-available/default" \
    NGINX_SITE_ENABLED="${dir}/nginx/sites-enabled/default" \
    SUPERVISORD_CONF="${dir}/supervisord.conf" \
    SUPERVISOR_PROGRAM_FILE="${dir}/serverpod.conf" \
    SUPERVISOR_LOG_DIR="${dir}/logs" \
    SERVERPOD_NGINX_SITE_FILE="$site" \
    SERVERPOD_SUPERVISOR_FILE="$program" \
    SUPERVISORCTL_BIN="${tmp}/supervisorctl" \
    SUPERVISOR_LOG="${dir}/supervisor.log" \
    NGINX_RELOAD_COMMAND="$reload" \
    APPLY_MIGRATIONS="${APPLY_MIGRATIONS:-true}" \
    WEB_PATH="${WEB_PATH:-}" \
    bash "$install"
}

prepare_tree "$tmp"
: > "${tmp}/supervisor.log"
run_install "$tmp" "touch ${tmp}/reloaded"
if [[ ! -f "${tmp}/reloaded" ]]; then
  echo "install did not reload nginx" >&2
  exit 1
fi
installed="${tmp}/nginx/sites-available/default"
if ! grep -q '127.0.0.1:8080' "$installed"; then
  echo "site file is missing the API upstream" >&2
  exit 1
fi
if ! grep -q 'proxy_set_header Upgrade' "$installed"; then
  echo "site file is missing the WebSocket upgrade header" >&2
  exit 1
fi
if ! grep -q 'talaria-serverpod' "$installed"; then
  echo "site file is missing its marker" >&2
  exit 1
fi
if grep -q '__WEB_LOCATION__' "$installed"; then
  echo "site file still contains the web location placeholder" >&2
  exit 1
fi
if grep -q 'proxy_pass http://127.0.0.1:8082' "$installed"; then
  echo "default install proxied a web path" >&2
  exit 1
fi
if [[ ! -L "${tmp}/nginx/sites-enabled/default" ]]; then
  echo "sites-enabled/default was not linked" >&2
  exit 1
fi
if ! grep -q -- '--apply-migrations' "${tmp}/serverpod.conf"; then
  echo "supervisor program did not apply migrations" >&2
  exit 1
fi
if ! grep -q "${tmp}/application/current/bin/server" "${tmp}/serverpod.conf"; then
  echo "supervisor program does not start the current release" >&2
  exit 1
fi
if ! grep -q "${tmp}/serverpod.conf" "${tmp}/supervisord.conf"; then
  echo "supervisord config does not include the program file" >&2
  exit 1
fi
if ! grep -q 'reread' "${tmp}/supervisor.log"; then
  echo "install did not reread supervisord" >&2
  exit 1
fi

rm -f "${tmp}/reloaded"
: > "${tmp}/supervisor.log"
second="$(run_install "$tmp" "touch ${tmp}/reloaded")"
if [[ -f "${tmp}/reloaded" ]]; then
  echo "second install reloaded nginx" >&2
  exit 1
fi
if [[ -s "${tmp}/supervisor.log" ]]; then
  echo "second install reread supervisord" >&2
  exit 1
fi
if [[ "$second" != *"Serverpod hosting unchanged"* ]]; then
  echo "second install did not report an unchanged config" >&2
  echo "$second" >&2
  exit 1
fi

web_dir="${tmp}/web"
prepare_tree "$web_dir"
WEB_PATH=/app run_install "$web_dir" "true"
if [[ "$(grep -c 'location /app' "${web_dir}/nginx/sites-available/default")" -ne 1 ]]; then
  echo "web_path did not add exactly one location" >&2
  exit 1
fi
if ! grep -q '127.0.0.1:8082' "${web_dir}/nginx/sites-available/default"; then
  echo "web_path did not proxy to the web server" >&2
  exit 1
fi

quiet_dir="${tmp}/quiet"
prepare_tree "$quiet_dir"
APPLY_MIGRATIONS=false run_install "$quiet_dir" "true"
if grep -q -- '--apply-migrations' "${quiet_dir}/serverpod.conf"; then
  echo "apply_migrations false still passed the flag" >&2
  exit 1
fi

fail_dir="${tmp}/fail"
prepare_tree "$fail_dir"
set +e
SITEHOST_APP_PATH="${fail_dir}/application" \
  NGINX_SITE_FILE="${fail_dir}/nginx/sites-available/default" \
  NGINX_SITE_ENABLED="${fail_dir}/nginx/sites-enabled/default" \
  SUPERVISORD_CONF="${fail_dir}/supervisord.conf" \
  SUPERVISOR_PROGRAM_FILE="${fail_dir}/serverpod.conf" \
  SUPERVISOR_LOG_DIR="${fail_dir}/logs" \
  SERVERPOD_NGINX_SITE_FILE="$site" \
  SERVERPOD_SUPERVISOR_FILE="$program" \
  SUPERVISORCTL_BIN="${tmp}/supervisorctl" \
  SUPERVISOR_LOG="${fail_dir}/supervisor.log" \
  NGINX_RELOAD_COMMAND="false" \
  bash "$install" >"${tmp}/fail.out" 2>"${tmp}/fail.err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "failed reload was treated as success" >&2
  exit 1
fi
if [[ -e "${fail_dir}/nginx/sites-available/default" ]]; then
  echo "failed reload left the new site file in place" >&2
  exit 1
fi
if [[ -e "${fail_dir}/nginx/sites-enabled/default" ]]; then
  echo "failed reload left the sites-enabled link in place" >&2
  exit 1
fi
if [[ -e "${fail_dir}/serverpod.conf" ]]; then
  echo "failed reload left the supervisor program in place" >&2
  exit 1
fi
if grep -q 'talaria-serverpod' "${fail_dir}/supervisord.conf"; then
  echo "failed reload left the supervisor include in place" >&2
  exit 1
fi

echo "install test passed"
