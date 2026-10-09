#!/usr/bin/env bash
# ssh-payload.sh writes one line, and the install payload includes both templates.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
payload_sh="${root}/actions/ssh/ssh-payload.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "${tmp}/hello.sh" <<'EOF'
#!/usr/bin/env bash
echo hello-from-payload
EOF

SAMPLE_VALUE="quote's here"
export SAMPLE_VALUE
bash "$payload_sh" "${tmp}/hello.sh" "${tmp}/payload.sh" SAMPLE_VALUE

lines="$(wc -l < "${tmp}/payload.sh" | tr -d ' ')"
if [[ "$lines" != "1" ]]; then
  echo "expected one payload line, got ${lines}" >&2
  exit 1
fi

payload="$(cat "${tmp}/payload.sh")"
encoded="$(printf '%s\n' "$payload" | sed -n 's/.*echo \([^ ]*\) | base64 -d.*/\1/p')"
if [[ -z "$encoded" ]]; then
  echo "could not find the base64 body" >&2
  exit 1
fi
decoded="$(printf '%s' "$encoded" | base64 -d)"
expected="$(cat "${tmp}/hello.sh")"
if [[ "$decoded" != "$expected" ]]; then
  echo "round trip did not match the source script" >&2
  exit 1
fi
if [[ "$payload" != *"export SAMPLE_VALUE="* ]]; then
  echo "payload did not export SAMPLE_VALUE" >&2
  exit 1
fi
if [[ "$payload" != *"quote"* || "$payload" != *"here"* ]]; then
  echo "payload dropped the sample value" >&2
  exit 1
fi

bash "$payload_sh" "${root}/actions/ssh/remote-install.sh" "${tmp}/install-payload.sh" SITEHOST_APP_PATH
install_payload="$(cat "${tmp}/install-payload.sh")"
install_encoded="$(printf '%s\n' "$install_payload" | sed -n 's/.*echo \([^ ]*\) | base64 -d.*/\1/p')"
install_decoded="$(printf '%s' "$install_encoded" | base64 -d)"
if [[ "$install_decoded" != *"SITEHOST_LIB_LOADED=1"* || "$install_decoded" != *"Remote Serverpod hosting install started"* ]]; then
  echo "install payload did not include lib.sh and the script" >&2
  exit 1
fi
site_b64="$(printf '%s\n' "$install_decoded" | sed -n "s/^SERVERPOD_NGINX_SITE_B64='\\(.*\\)'$/\\1/p")"
program_b64="$(printf '%s\n' "$install_decoded" | sed -n "s/^SERVERPOD_SUPERVISOR_B64='\\(.*\\)'$/\\1/p")"
if [[ -z "$site_b64" || -z "$program_b64" ]]; then
  echo "install payload did not embed the Nginx site and the supervisor program" >&2
  exit 1
fi
printf '%s' "$site_b64" | base64 -d > "${tmp}/site.conf"
printf '%s' "$program_b64" | base64 -d > "${tmp}/program.conf"
if ! grep -q '127.0.0.1:8080' "${tmp}/site.conf"; then
  echo "embedded site file is missing the API upstream" >&2
  exit 1
fi
if ! grep -q 'proxy_set_header Upgrade' "${tmp}/site.conf"; then
  echo "embedded site file is missing the WebSocket upgrade header" >&2
  exit 1
fi
if ! grep -q 'talaria-serverpod' "${tmp}/program.conf"; then
  echo "embedded supervisor program is missing its marker" >&2
  exit 1
fi
lib_count="$(printf '%s\n' "$install_decoded" | grep -c 'SITEHOST_LIB_LOADED=1' || true)"
if [[ "$lib_count" != "1" ]]; then
  echo "expected lib.sh once in the payload, found ${lib_count}" >&2
  exit 1
fi

printf '%s' "$install_encoded" | base64 -d | /bin/bash >"${tmp}/install.out" 2>"${tmp}/install.err" || true
if grep -q 'BASH_SOURCE' "${tmp}/install.err"; then
  echo "piped install still evaluates BASH_SOURCE" >&2
  cat "${tmp}/install.err" >&2
  exit 1
fi
if ! grep -q 'SITEHOST_APP_PATH is required' "${tmp}/install.err"; then
  echo "piped install did not reach the argument check" >&2
  cat "${tmp}/install.err" >&2
  exit 1
fi

echo "payload test passed"
