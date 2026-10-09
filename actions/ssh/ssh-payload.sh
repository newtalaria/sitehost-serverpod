#!/usr/bin/env bash
# Write a one-line remote command that runs a bash script on the container.
# The SSH action would otherwise run only the first line, and "bash -s" exits
# before the install script starts.
# When lib.sh sits next to SOURCE, it is prepended so the remote bash process
# has the shared functions without a second file on the container.
set -euo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "Usage: ssh-payload.sh SOURCE DEST ENV_NAME..." >&2
  exit 1
fi

src="$1"
dest="$2"
shift 2

for name in "$@"; do
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Refusing to export ${name}" >&2
    exit 1
  fi
done

src_dir="$(cd "$(dirname "$src")" && pwd)"
body="$(mktemp)"
cleanup() {
  rm -f "$body"
}
trap cleanup EXIT

parts=()
base="$(basename "$src")"
if [[ -f "${src_dir}/lib.sh" && "$base" != "lib.sh" ]]; then
  parts+=("${src_dir}/lib.sh")
fi
if [[ "${#parts[@]}" -gt 0 ]]; then
  cat "${parts[@]}" "$src" > "$body"
else
  cat "$src" > "$body"
fi

# The remote bash process has no checkout of this action. Embed the site
# and supervisor files when the install script is the payload.
payload_root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$base" == "remote-install.sh" ]]; then
  site="${payload_root}/nginx/serverpod.conf"
  program="${payload_root}/supervisor/serverpod.conf"
  if [[ ! -f "$site" || ! -f "$program" ]]; then
    echo "Missing the Nginx site or the supervisor program file" >&2
    exit 1
  fi
  site_b64="$(base64 < "$site" | tr -d '\n')"
  program_b64="$(base64 < "$program" | tr -d '\n')"
  {
    printf "SERVERPOD_NGINX_SITE_B64='%s'\n" "$site_b64"
    printf "SERVERPOD_SUPERVISOR_B64='%s'\n" "$program_b64"
    cat "$body"
  } > "${body}.with-templates"
  mv "${body}.with-templates" "$body"
fi

encoded="$(base64 < "$body" | tr -d '\n')"
exports=""
for name in "$@"; do
  value="${!name-}"
  escaped="${value//\'/\'\\\'\'}"
  exports+="export ${name}='${escaped}'; "
done

printf "/bin/bash -c 'set -o pipefail; %secho %s | base64 -d | /bin/bash'\n" "$exports" "$encoded" > "$dest"
