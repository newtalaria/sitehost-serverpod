#!/usr/bin/env bash
# Compile a Serverpod server on the runner and assemble a release tree.
# The container does not get a Dart SDK.
set -euo pipefail

run_pub_get="${RUN_PUB_GET:-1}"
workspace="${GITHUB_WORKSPACE:-$(pwd)}"

if [[ -n "${SERVER_DIR:-}" ]]; then
  server="$SERVER_DIR"
elif [[ "${SERVER_PATH:-server}" == /* ]]; then
  server="$SERVER_PATH"
else
  server="${workspace}/${SERVER_PATH:-server}"
fi

if [[ ! -d "$server" ]]; then
  echo "Serverpod package not found: ${server}" >&2
  exit 1
fi
if [[ ! -f "${server}/pubspec.yaml" ]]; then
  echo "Missing ${server}/pubspec.yaml" >&2
  exit 1
fi
if [[ ! -f "${server}/bin/main.dart" ]]; then
  echo "Missing ${server}/bin/main.dart" >&2
  exit 1
fi
if [[ ! -f "${server}/config/production.yaml" ]]; then
  echo "Missing ${server}/config/production.yaml" >&2
  exit 1
fi
proto="${server}/lib/src/generated/protocol.yaml"
if [[ ! -f "$proto" ]]; then
  echo "Missing ${proto}" >&2
  exit 1
fi
if [[ -e "${server}/config/passwords.yaml" ]]; then
  echo "Refusing to publish config/passwords.yaml. Put secrets in the SiteHost panel or in /container/config/serverpod/passwords.yaml on the container." >&2
  exit 1
fi

if [[ "$run_pub_get" != "0" ]]; then
  (cd "$server" && dart pub get)
fi
(cd "$server" && dart build cli --target bin/main.dart --output build)

bundle="${server}/build/bundle"
dest="${server}/build/sitehost"
if [[ ! -f "${bundle}/bin/main" ]]; then
  echo "dart build cli did not write ${bundle}/bin/main" >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
cp -a "${bundle}/." "$dest/"
mv "${dest}/bin/main" "${dest}/bin/server"
chmod 755 "${dest}/bin/server"

mkdir -p "${dest}/config"
shopt -s nullglob
for file in "${server}/config/"*.yaml "${server}/config/"*.example; do
  base="$(basename "$file")"
  if [[ "$base" == "passwords.yaml" ]]; then
    echo "Refusing to publish config/passwords.yaml" >&2
    exit 1
  fi
  cp "$file" "${dest}/config/${base}"
done
shopt -u nullglob

if [[ -d "${server}/web" ]]; then
  mkdir -p "${dest}/web"
  cp -a "${server}/web/." "${dest}/web/"
fi
if [[ -d "${server}/migrations" ]]; then
  mkdir -p "${dest}/migrations"
  cp -a "${server}/migrations/." "${dest}/migrations/"
fi
mkdir -p "${dest}/lib/src/generated"
cp "$proto" "${dest}/lib/src/generated/protocol.yaml"

if [[ ! -f "${dest}/config/production.yaml" || ! -x "${dest}/bin/server" ]]; then
  echo "Release tree is incomplete: ${dest}" >&2
  exit 1
fi

echo "Assembled ${dest}"
