#!/usr/bin/env bash
# Copy an assembled Serverpod release to releases/<sha>/ on the container.
set -euo pipefail

: "${BUILD_DIR:?BUILD_DIR is required}"
: "${DEPLOY_SHA:?DEPLOY_SHA is required}"
: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"

if [[ ! "$DEPLOY_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "DEPLOY_SHA must be a 40 character git commit" >&2
  exit 1
fi
if [[ ! -f "${BUILD_DIR}/bin/server" ]]; then
  echo "Missing ${BUILD_DIR}/bin/server" >&2
  exit 1
fi
case "$SITEHOST_APP_PATH" in
  /*) ;;
  *)
    echo "SITEHOST_APP_PATH must be an absolute path" >&2
    exit 1
    ;;
esac
case "$SITEHOST_APP_PATH" in
  *\ *|*$'\n'*|*'"'*)
    echo "SITEHOST_APP_PATH must not contain spaces, quotes, or newlines" >&2
    exit 1
    ;;
esac

remote="${SITEHOST_APP_PATH}/releases/${DEPLOY_SHA}"
key_file=""
known=""
scanned=""

cleanup() {
  rm -f "$key_file" "$known" "$scanned"
}
trap cleanup EXIT

if [[ -n "${SSH_CONFIG_HOST:-}" ]]; then
  echo "Uploading ${BUILD_DIR}/ to ${SSH_CONFIG_HOST}:${remote}/"
  # remote is validated above. The path is expanded locally on purpose.
  # shellcheck disable=SC2029
  ssh "$SSH_CONFIG_HOST" "mkdir -p ${remote}"
  rsync -az --delete \
    --exclude '.DS_Store' \
    -e ssh \
    "${BUILD_DIR}/" \
    "${SSH_CONFIG_HOST}:${remote}/"
  exit 0
fi

: "${SITEHOST_SSH_HOST:?SITEHOST_SSH_HOST is required}"
: "${SITEHOST_SSH_USER:?SITEHOST_SSH_USER is required}"
: "${SITEHOST_SSH_PRIVATE_KEY:?SITEHOST_SSH_PRIVATE_KEY is required}"
: "${SITEHOST_SSH_HOST_FINGERPRINT:?SITEHOST_SSH_HOST_FINGERPRINT is required}"
port="${SITEHOST_SSH_PORT:-22}"

key_file="$(mktemp)"
known="$(mktemp)"
scanned="$(mktemp)"
chmod 600 "$key_file"
printf '%s\n' "$SITEHOST_SSH_PRIVATE_KEY" > "$key_file"

ssh-keyscan -T 10 -p "$port" -t ecdsa,ed25519,rsa "$SITEHOST_SSH_HOST" > "$scanned" 2>/dev/null || true
found=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  fp="$(printf '%s\n' "$line" | ssh-keygen -lf - | awk '{print $2}')"
  if [[ "$fp" == "$SITEHOST_SSH_HOST_FINGERPRINT" ]]; then
    printf '%s\n' "$line" > "$known"
    found=1
    break
  fi
done < "$scanned"
if [[ "$found" -ne 1 ]]; then
  echo "SSH host fingerprint did not match SITEHOST_SSH_HOST_FINGERPRINT" >&2
  exit 1
fi

ssh_cmd="ssh -i ${key_file} -p ${port} -o UserKnownHostsFile=${known} -o IdentitiesOnly=yes -o BatchMode=yes"
echo "Uploading ${BUILD_DIR}/ to ${SITEHOST_SSH_USER}@${SITEHOST_SSH_HOST}:${remote}/"
# shellcheck disable=SC2029
ssh -i "$key_file" -p "$port" \
  -o "UserKnownHostsFile=${known}" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "${SITEHOST_SSH_USER}@${SITEHOST_SSH_HOST}" \
  "mkdir -p ${remote}"
rsync -az --delete \
  --exclude '.DS_Store' \
  -e "$ssh_cmd" \
  "${BUILD_DIR}/" \
  "${SITEHOST_SSH_USER}@${SITEHOST_SSH_HOST}:${remote}/"
