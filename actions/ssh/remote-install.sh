#!/usr/bin/env bash
# Install Serverpod hosting on a stock Nginx + PHP container.
# Idempotent: a second run that finds the same files does not reload Nginx
# or reread supervisord.
set -euo pipefail

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"

echo "Remote Serverpod hosting install started"

site_file="${NGINX_SITE_FILE:-/container/config/nginx/sites-available/default}"
enabled_file="${NGINX_SITE_ENABLED:-/container/config/nginx/sites-enabled/default}"
supervisord_conf="${SUPERVISORD_CONF:-/container/config/supervisord.conf}"
program_file="${SUPERVISOR_PROGRAM_FILE:-/container/config/serverpod/serverpod.conf}"
current="${SITEHOST_APP_PATH}/current"
web_path="${WEB_PATH:-}"
apply_migrations="${APPLY_MIGRATIONS:-true}"
nginx_changed=0
supervisor_changed=0
site_bak=""
enabled_bak=""
supervisor_bak=""
program_bak=""
had_site=0
had_enabled=0
enabled_existed=0
enabled_was_link=0
enabled_link_target=""
had_program=0
rendered_site=""
rendered_program=""
rendered_conf=""

cleanup() {
  rm -f "$site_bak" "$enabled_bak" "$supervisor_bak" "$program_bak" \
    "$rendered_site" "$rendered_program" "$rendered_conf"
}
trap cleanup EXIT

restore_config() {
  if [[ "$had_site" -eq 1 && -n "$site_bak" && -f "$site_bak" ]]; then
    cp "$site_bak" "$site_file"
  elif [[ "$had_site" -eq 0 ]]; then
    rm -f "$site_file"
  fi
  if [[ "$enabled_was_link" -eq 1 ]]; then
    ln -sfn "$enabled_link_target" "$enabled_file"
  elif [[ "$had_enabled" -eq 1 && -n "$enabled_bak" && -f "$enabled_bak" ]]; then
    cp "$enabled_bak" "$enabled_file"
  elif [[ "$enabled_existed" -eq 0 ]]; then
    rm -f "$enabled_file"
  fi
  if [[ -n "$supervisor_bak" && -f "$supervisor_bak" ]]; then
    cp "$supervisor_bak" "$supervisord_conf"
  fi
  if [[ "$had_program" -eq 1 && -n "$program_bak" && -f "$program_bak" ]]; then
    cp "$program_bak" "$program_file"
  elif [[ "$had_program" -eq 0 ]]; then
    rm -f "$program_file"
  fi
}

assert_web_path() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  case "$value" in
    /*) ;;
    *)
      echo "WEB_PATH must start with /" >&2
      exit 1
      ;;
  esac
  case "$value" in
    /|*//*|*..*|*\;*|*[[:space:]]*|*\**|*'$'*)
      echo "WEB_PATH must be one location such as /app" >&2
      exit 1
      ;;
  esac
  if [[ ! "$value" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "WEB_PATH contains characters the Nginx config cannot quote" >&2
    exit 1
  fi
}

load_template() {
  local dest="$1"
  local file_var="$2"
  local b64_var="$3"
  local label="$4"
  local file_value="${!file_var:-}"
  local b64_value="${!b64_var:-}"
  if [[ -n "$file_value" ]]; then
    if [[ ! -f "$file_value" ]]; then
      echo "${label} does not exist" >&2
      exit 1
    fi
    cp "$file_value" "$dest"
    return 0
  fi
  if [[ -z "$b64_value" ]]; then
    echo "${label} is required" >&2
    exit 1
  fi
  printf '%s' "$b64_value" | base64 -d > "$dest"
}

# Add the program file to the existing include list, or append one include.
ensure_include() {
  local dest="$1"
  local extra="$2"
  local tmp line done=0
  if grep -F -q -- "$extra" "$dest"; then
    return 0
  fi
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$done" -eq 0 && "$line" =~ ^[[:space:]]*files[[:space:]]*= ]]; then
      printf '%s %s\n' "$line" "$extra" >> "$tmp"
      done=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$dest"
  if [[ "$done" -eq 0 ]]; then
    printf '\n; talaria-serverpod-include\n[include]\nfiles = %s\n' "$extra" >> "$tmp"
  fi
  mv "$tmp" "$dest"
}

write_if_different() {
  local dest="$1"
  local src="$2"
  local flag_name="$3"
  if [[ -f "$dest" ]] && cmp -s "$dest" "$src"; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  printf -v "$flag_name" '%s' 1
}

reload_nginx() {
  if [[ -n "${NGINX_RELOAD_COMMAND:-}" ]]; then
    bash --noprofile --norc -c "$NGINX_RELOAD_COMMAND"
    return
  fi
  local bin="${NGINX_BIN:-}"
  if [[ -z "$bin" ]]; then
    bin="$(command -v nginx || true)"
  fi
  if [[ -z "$bin" && -x /usr/sbin/nginx ]]; then
    bin=/usr/sbin/nginx
  fi
  if [[ -z "$bin" ]]; then
    echo "nginx is not on PATH, so the new config was not reloaded." >&2
    return 1
  fi
  if ! "$bin" -t; then
    echo "nginx -t failed. The previous config was restored." >&2
    return 1
  fi
  if "$bin" -s reload; then
    return 0
  fi
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl signal HUP nginx && return 0
    supervisorctl restart nginx && return 0
  fi
  echo "Could not reload nginx." >&2
  return 1
}

reread_supervisor() {
  local ctl="${SUPERVISORCTL_BIN:-}"
  if [[ -z "$ctl" ]]; then
    ctl="$(command -v supervisorctl || true)"
  fi
  if [[ -z "$ctl" ]]; then
    echo "supervisorctl is not on PATH, so the program was not loaded." >&2
    return 1
  fi
  local -a args=()
  if [[ -f "$supervisord_conf" ]]; then
    args+=(-c "$supervisord_conf")
  fi
  if ! "$ctl" "${args[@]}" reread; then
    echo "supervisorctl reread failed. The previous config was restored." >&2
    return 1
  fi
  return 0
}

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"
assert_absolute_path "NGINX_SITE_FILE" "$site_file"
assert_absolute_path "SUPERVISORD_CONF" "$supervisord_conf"
assert_absolute_path "SUPERVISOR_PROGRAM_FILE" "$program_file"
assert_web_path "$web_path"

case "$apply_migrations" in
  true|1) migrations=" --apply-migrations" ;;
  false|0) migrations="" ;;
  *)
    echo "APPLY_MIGRATIONS must be true or false" >&2
    exit 1
    ;;
esac

if [[ ! -d "$(dirname "$site_file")" ]]; then
  echo "Nginx site directory not found: $(dirname "$site_file")" >&2
  exit 1
fi
if [[ ! -f "$supervisord_conf" ]]; then
  echo "supervisord config not found at ${supervisord_conf}" >&2
  exit 1
fi

if [[ "$supervisord_conf" == "/container/config/supervisord.conf" ]]; then
  log_dir="${SUPERVISOR_LOG_DIR:-/container/logs/supervisor}"
else
  log_dir="${SUPERVISOR_LOG_DIR:-$(dirname "$supervisord_conf")/logs}"
fi
assert_absolute_path "SUPERVISOR_LOG_DIR" "$log_dir"
mkdir -p "$log_dir"

rendered_site="$(mktemp)"
rendered_program="$(mktemp)"
load_template "$rendered_site" SERVERPOD_NGINX_SITE_FILE SERVERPOD_NGINX_SITE_B64 "Nginx site file"
load_template "$rendered_program" SERVERPOD_SUPERVISOR_FILE SERVERPOD_SUPERVISOR_B64 "Supervisor program file"

if ! grep -q 'talaria-serverpod' "$rendered_site"; then
  echo "Refusing to install a site file that is not the Serverpod proxy" >&2
  exit 1
fi
web_location_count="$(grep -c '__WEB_LOCATION__' "$rendered_site" || true)"
if [[ "$web_location_count" -ne 1 ]]; then
  echo "The Nginx site file must contain the web location placeholder once" >&2
  exit 1
fi
if ! grep -q 'talaria-serverpod' "$rendered_program"; then
  echo "Refusing to install a supervisor program that is not the Serverpod program" >&2
  exit 1
fi
if ! grep -q '__CURRENT__' "$rendered_program"; then
  echo "The supervisor program is missing __CURRENT__" >&2
  exit 1
fi

web_location=""
if [[ -n "$web_path" ]]; then
  web_location="$(cat <<EOF
    location ${web_path} {
        proxy_pass http://127.0.0.1:8082;
        proxy_http_version 1.1;
        proxy_connect_timeout 3s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

EOF
)"
fi

site_body="$(cat "$rendered_site")"
site_body="${site_body//__WEB_LOCATION__/$web_location}"
printf '%s\n' "$site_body" > "$rendered_site"
if grep -q '__WEB_LOCATION__' "$rendered_site"; then
  echo "Failed to set the Nginx web location" >&2
  exit 1
fi

program_body="$(cat "$rendered_program")"
program_body="${program_body//__CURRENT__/$current}"
program_body="${program_body//__LOG_DIR__/$log_dir}"
program_body="${program_body//__MIGRATIONS__/$migrations}"
printf '%s\n' "$program_body" > "$rendered_program"
if grep -Eq '__CURRENT__|__LOG_DIR__|__MIGRATIONS__' "$rendered_program"; then
  echo "Failed to render the supervisor program" >&2
  exit 1
fi

rendered_conf="$(mktemp)"
cp "$supervisord_conf" "$rendered_conf"
ensure_include "$rendered_conf" "$program_file"

if [[ -f "$site_file" ]]; then
  had_site=1
  site_bak="$(mktemp)"
  cp "$site_file" "$site_bak"
fi
if [[ -L "$enabled_file" ]]; then
  enabled_existed=1
  enabled_was_link=1
  enabled_link_target="$(readlink "$enabled_file")"
elif [[ -e "$enabled_file" ]]; then
  enabled_existed=1
  had_enabled=1
  enabled_bak="$(mktemp)"
  cp "$enabled_file" "$enabled_bak"
fi
supervisor_bak="$(mktemp)"
cp "$supervisord_conf" "$supervisor_bak"
if [[ -f "$program_file" ]]; then
  had_program=1
  program_bak="$(mktemp)"
  cp "$program_file" "$program_bak"
fi

write_if_different "$site_file" "$rendered_site" nginx_changed
if [[ -d "$(dirname "$enabled_file")" ]]; then
  if [[ -L "$enabled_file" ]]; then
    if [[ ! -f "$enabled_file" ]] || ! cmp -s "$enabled_file" "$rendered_site"; then
      ln -sfn "$site_file" "$enabled_file"
      nginx_changed=1
    fi
  elif [[ ! -e "$enabled_file" ]]; then
    ln -sfn "$site_file" "$enabled_file"
    nginx_changed=1
  else
    write_if_different "$enabled_file" "$rendered_site" nginx_changed
  fi
fi

write_if_different "$program_file" "$rendered_program" supervisor_changed
if ! cmp -s "$supervisord_conf" "$rendered_conf"; then
  cp "$rendered_conf" "$supervisord_conf"
  supervisor_changed=1
fi

if [[ "$nginx_changed" -eq 0 && "$supervisor_changed" -eq 0 ]]; then
  echo "Serverpod hosting unchanged"
  exit 0
fi

if [[ "$supervisor_changed" -eq 1 ]]; then
  if ! reread_supervisor; then
    restore_config
    exit 1
  fi
fi
if [[ "$nginx_changed" -eq 1 ]]; then
  if ! reload_nginx; then
    restore_config
    if [[ "$supervisor_changed" -eq 1 ]]; then
      reread_supervisor || true
    fi
    exit 1
  fi
fi

echo "Installed Serverpod hosting"
