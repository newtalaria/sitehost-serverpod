#!/usr/bin/env bash
# Publishing flips a relative symlink, restarts Serverpod, and prune drops old shas.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
publish="${root}/actions/ssh/remote-publish.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

app="${tmp}/app"
sha1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
sha2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
sha3="cccccccccccccccccccccccccccccccccccccccc"
sha4="dddddddddddddddddddddddddddddddddddddddd"

cat > "${tmp}/supervisorctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SUPERVISOR_LOG:?}"
if [[ "${FAIL_RESTART:-0}" == "1" ]]; then
  case "$*" in
    *restart*) exit 1 ;;
  esac
fi
exit 0
EOF
chmod 755 "${tmp}/supervisorctl"
printf '%s\n' '[supervisord]' > "${tmp}/supervisord.conf"

seed() {
  local sha="$1"
  local body="$2"
  mkdir -p "${app}/releases/${sha}/bin" "${app}/releases/${sha}/config"
  printf '%s\n' "$body" > "${app}/releases/${sha}/bin/server"
  chmod 755 "${app}/releases/${sha}/bin/server"
}

run_publish() {
  SITEHOST_APP_PATH="$app" \
    SUPERVISORCTL_BIN="${tmp}/supervisorctl" \
    SUPERVISOR_LOG="${tmp}/supervisor.log" \
    SUPERVISORD_CONF="${tmp}/supervisord.conf" \
    SERVERPOD_PASSWORDS_FILE="${SERVERPOD_PASSWORDS_FILE:-${tmp}/missing-passwords.yaml}" \
    FAIL_RESTART="${FAIL_RESTART:-0}" \
    bash "$publish" "$@"
}

mkdir -p "${app}/current/bin"
printf '%s\n' 'legacy' > "${app}/current/bin/server"
seed "$sha1" "one"
: > "${tmp}/supervisor.log"

DEPLOY_SHA="$sha1" PUBLISH_ACTION=publish run_publish
if [[ "$(readlink "${app}/current")" != "releases/${sha1}" ]]; then
  echo "current did not point at the first release" >&2
  exit 1
fi
if [[ "$(cat "${app}/current/bin/server")" != "one" ]]; then
  echo "current did not serve the first release" >&2
  exit 1
fi
if [[ ! -f "${app}/releases/previous/bin/server" ]]; then
  echo "legacy current directory was not moved aside" >&2
  exit 1
fi
if ! grep -q 'restart serverpod' "${tmp}/supervisor.log"; then
  echo "publish did not restart serverpod" >&2
  exit 1
fi

printf '%s\n' 'database: secret' > "${tmp}/passwords.yaml"
seed "$sha2" "two"
: > "${tmp}/supervisor.log"
DEPLOY_SHA="$sha2" PUBLISH_ACTION=publish \
  SERVERPOD_PASSWORDS_FILE="${tmp}/passwords.yaml" \
  run_publish
if [[ "$(cat "${app}/current/bin/server")" != "two" ]]; then
  echo "current did not serve the second release" >&2
  exit 1
fi
if [[ "$(readlink "${app}/releases/${sha2}/config/passwords.yaml")" != "${tmp}/passwords.yaml" ]]; then
  echo "publish did not link passwords.yaml into the release" >&2
  exit 1
fi

: > "${tmp}/supervisor.log"
PUBLISH_ACTION=rollback \
  SERVERPOD_PASSWORDS_FILE="${tmp}/passwords.yaml" \
  run_publish
if [[ "$(readlink "${app}/current")" != "releases/${sha1}" ]]; then
  echo "rollback did not restore the first release" >&2
  exit 1
fi
if [[ "$(cat "${app}/current/bin/server")" != "one" ]]; then
  echo "rollback did not serve the first release" >&2
  exit 1
fi
if ! grep -q 'restart serverpod' "${tmp}/supervisor.log"; then
  echo "rollback did not restart serverpod" >&2
  exit 1
fi
if [[ "$(readlink "${app}/releases/${sha1}/config/passwords.yaml")" != "${tmp}/passwords.yaml" ]]; then
  echo "rollback did not link passwords.yaml into the restored release" >&2
  exit 1
fi

old1="1111111111111111111111111111111111111111"
old2="2222222222222222222222222222222222222222"
seed "$old1" "old"
seed "$old2" "older"
touch -t 202001010000 "${app}/releases/${old1}" "${app}/releases/${old2}"
seed "$sha3" "three"
seed "$sha4" "four"
KEEP_RELEASES=2 PUBLISH_ACTION=prune run_publish
if [[ ! -d "${app}/releases/${sha1}" || ! -d "${app}/releases/${sha2}" ]]; then
  echo "prune deleted the current or previous release" >&2
  exit 1
fi
if [[ -d "${app}/releases/${old1}" || -d "${app}/releases/${old2}" ]]; then
  echo "prune left an old release in place" >&2
  exit 1
fi

fail_app="${tmp}/fail-app"
mkdir -p "${fail_app}/releases/${sha1}/bin"
printf '%s\n' 'one' > "${fail_app}/releases/${sha1}/bin/server"
chmod 755 "${fail_app}/releases/${sha1}/bin/server"
mkdir -p "${fail_app}/releases/${sha2}/bin"
printf '%s\n' 'two' > "${fail_app}/releases/${sha2}/bin/server"
chmod 755 "${fail_app}/releases/${sha2}/bin/server"
: > "${tmp}/supervisor.log"
SITEHOST_APP_PATH="$fail_app" \
  SUPERVISORCTL_BIN="${tmp}/supervisorctl" \
  SUPERVISOR_LOG="${tmp}/supervisor.log" \
  SUPERVISORD_CONF="${tmp}/supervisord.conf" \
  SERVERPOD_PASSWORDS_FILE="${tmp}/missing-passwords.yaml" \
  DEPLOY_SHA="$sha1" PUBLISH_ACTION=publish \
  bash "$publish"
: > "${tmp}/supervisor.log"
set +e
SITEHOST_APP_PATH="$fail_app" \
  SUPERVISORCTL_BIN="${tmp}/supervisorctl" \
  SUPERVISOR_LOG="${tmp}/supervisor.log" \
  SUPERVISORD_CONF="${tmp}/supervisord.conf" \
  SERVERPOD_PASSWORDS_FILE="${tmp}/missing-passwords.yaml" \
  FAIL_RESTART=1 \
  DEPLOY_SHA="$sha2" PUBLISH_ACTION=publish \
  bash "$publish" >"${tmp}/fail.out" 2>"${tmp}/fail.err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "failed restart was treated as success" >&2
  exit 1
fi
if [[ "$(readlink "${fail_app}/current")" != "releases/${sha1}" ]]; then
  echo "failed restart did not restore the previous release" >&2
  exit 1
fi

echo "publish test passed"
