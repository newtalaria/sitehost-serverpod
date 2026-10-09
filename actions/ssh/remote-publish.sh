#!/usr/bin/env bash
# Point the container's current symlink at a published Serverpod release.
# publish records the previous target, links passwords.yaml, and restarts
# the process. rollback flips back and restarts. prune drops old shas.
set -euo pipefail

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"

action="${PUBLISH_ACTION:-publish}"
releases="${SITEHOST_APP_PATH}/releases"
live="${SITEHOST_APP_PATH}/current"
state="${releases}/.state"
passwords_file="${SERVERPOD_PASSWORDS_FILE:-/container/config/serverpod/passwords.yaml}"
supervisord_conf="${SUPERVISORD_CONF:-/container/config/supervisord.conf}"

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"

case "$action" in
  publish|rollback|prune) ;;
  *)
    echo "PUBLISH_ACTION must be publish, rollback, or prune" >&2
    exit 1
    ;;
esac

state_get() {
  local key="$1"
  local line
  [[ -f "$state" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        printf '%s' "${line#"${key}"=}"
        return 0
        ;;
    esac
  done < "$state"
}

state_put() {
  local previous="$1"
  local current="$2"
  local tmp
  tmp="$(mktemp)"
  printf 'previous=%s\ncurrent=%s\n' "$previous" "$current" > "$tmp"
  mv "$tmp" "$state"
}

assert_release_rel() {
  local label="$1"
  local value="$2"
  case "$value" in
    releases/[A-Za-z0-9._-]*) ;;
    *)
      echo "${label} must be a releases/<name> path" >&2
      exit 1
      ;;
  esac
  case "$value" in
    *..*|releases/*/*|releases/)
      echo "${label} must be a single path segment under releases" >&2
      exit 1
      ;;
  esac
}

flip_current() {
  local rel="$1"
  local next="${SITEHOST_APP_PATH}/current.next"
  ln -sfn "$rel" "$next"
  if mv -T "$next" "$live" 2>/dev/null; then
    return 0
  fi
  rm -f "$next"
  ln -sfn "$rel" "$live"
}

require_server() {
  local rel="$1"
  if [[ ! -f "${SITEHOST_APP_PATH}/${rel}/bin/server" ]]; then
    echo "Release is missing bin/server: ${SITEHOST_APP_PATH}/${rel}" >&2
    exit 1
  fi
}

link_passwords() {
  local rel="$1"
  local dest="${SITEHOST_APP_PATH}/${rel}/config/passwords.yaml"
  [[ -f "$passwords_file" ]] || return 0
  assert_absolute_path "SERVERPOD_PASSWORDS_FILE" "$passwords_file"
  mkdir -p "$(dirname "$dest")"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$passwords_file" ]]; then
    return 0
  fi
  rm -f "$dest"
  ln -s "$passwords_file" "$dest"
  echo "Linked ${passwords_file} into ${rel}"
}

prepare_release_tree() {
  local rel="$1"
  local root="${SITEHOST_APP_PATH}/${rel}"
  chmod -R a+rX "$root"
  if [[ -f "${root}/bin/server" ]]; then
    chmod 755 "${root}/bin/server"
  fi
  link_passwords "$rel"
}

supervisor_apply() {
  local ctl="${SUPERVISORCTL_BIN:-}"
  if [[ -z "$ctl" ]]; then
    ctl="$(command -v supervisorctl || true)"
  fi
  if [[ -z "$ctl" ]]; then
    echo "supervisorctl is not on PATH" >&2
    return 1
  fi
  local -a args=()
  if [[ -f "$supervisord_conf" ]]; then
    args+=(-c "$supervisord_conf")
  fi
  "$ctl" "${args[@]}" reread
  "$ctl" "${args[@]}" update
  "$ctl" "${args[@]}" restart serverpod
}

restart_or_restore() {
  local previous="$1"
  local failed_rel="$2"
  if supervisor_apply; then
    return 0
  fi
  echo "Serverpod did not restart on ${failed_rel}" >&2
  if [[ -n "$previous" ]]; then
    flip_current "$previous"
    state_put "$failed_rel" "$previous"
    supervisor_apply || true
  fi
  return 1
}

publish_release() {
  local sha previous="" rel current_link
  sha="${DEPLOY_SHA:?DEPLOY_SHA is required}"
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "DEPLOY_SHA must be a 40 character git commit" >&2
    exit 1
  fi
  rel="releases/${sha}"
  require_server "$rel"
  mkdir -p "$releases"
  prepare_release_tree "$rel"

  if [[ -e "$live" && ! -L "$live" ]]; then
    if [[ ! -d "$live" ]]; then
      echo "current exists and is not a directory or a symlink: ${live}" >&2
      exit 1
    fi
    if [[ -e "${releases}/previous" ]]; then
      echo "Refusing to replace ${releases}/previous while migrating the live directory" >&2
      exit 1
    fi
    mv "$live" "${releases}/previous"
    previous="releases/previous"
    echo "Moved the existing current directory to ${releases}/previous"
  elif [[ -L "$live" ]]; then
    current_link="$(readlink "$live")"
    case "$current_link" in
      releases/*)
        previous="$current_link"
        ;;
      *)
        echo "current symlink must be relative (releases/<name>), found ${current_link}" >&2
        exit 1
        ;;
    esac
  fi

  if [[ -n "$previous" ]]; then
    assert_release_rel "previous" "$previous"
  fi
  flip_current "$rel"
  state_put "$previous" "$rel"
  if ! restart_or_restore "$previous" "$rel"; then
    exit 1
  fi
  echo "Published ${rel}"
}

rollback_release() {
  local previous current
  previous="$(state_get previous)"
  current="$(state_get current)"
  if [[ -z "$previous" ]]; then
    echo "No previous release to restore" >&2
    exit 1
  fi
  assert_release_rel "previous" "$previous"
  require_server "$previous"
  prepare_release_tree "$previous"
  flip_current "$previous"
  state_put "$current" "$previous"
  if ! restart_or_restore "$current" "$previous"; then
    exit 1
  fi
  echo "Restored ${previous}"
}

prune_releases() {
  local keep previous current name mtime
  local -a ranked=()
  keep="${KEEP_RELEASES:-5}"
  if [[ ! "$keep" =~ ^[0-9]+$ || "$keep" -lt 1 ]]; then
    echo "KEEP_RELEASES must be a positive whole number" >&2
    exit 1
  fi
  previous="$(state_get previous)"
  current="$(state_get current)"
  [[ -d "$releases" ]] || return 0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    ranked+=("$name")
  done < <(
    for dir in "$releases"/*; do
      [[ -d "$dir" ]] || continue
      name="$(basename "$dir")"
      [[ "$name" =~ ^[0-9a-fA-F]{40}$ ]] || continue
      if mtime="$(stat -f %m "$dir" 2>/dev/null)"; then
        :
      else
        mtime="$(stat -c %Y "$dir")"
      fi
      printf '%s %s\n' "$mtime" "$name"
    done | sort -nr | awk '{print $2}'
  )
  if [[ "${#ranked[@]}" -eq 0 ]]; then
    return 0
  fi
  local index=0
  for name in "${ranked[@]}"; do
    local rel="releases/${name}"
    index=$((index + 1))
    if [[ "$index" -le "$keep" || "$rel" == "$current" || "$rel" == "$previous" ]]; then
      continue
    fi
    if [[ ! "$name" =~ ^[0-9a-fA-F]{40}$ || -z "$releases" || "$releases" == "/" ]]; then
      echo "Refusing to prune ${name}" >&2
      exit 1
    fi
    rm -rf -- "${releases:?}/${name:?}"
    echo "Pruned ${rel}"
  done
}

case "$action" in
  publish) publish_release ;;
  rollback) rollback_release ;;
  prune) prune_releases ;;
esac
