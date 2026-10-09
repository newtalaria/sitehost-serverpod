#!/usr/bin/env bash
# build-server.sh refuses passwords.yaml and assembles bin/server from the bundle.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${root}/actions/build/build-server.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "${tmp}/bin" "${tmp}/pkg/bin" "${tmp}/pkg/config" "${tmp}/pkg/lib/src/generated" "${tmp}/pkg/web" "${tmp}/pkg/migrations"
cat > "${tmp}/bin/dart" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DART_ARGS_FILE:?}"
if [[ "$1" == "pub" ]]; then
  exit 0
fi
if [[ "$1" == "build" ]]; then
  mkdir -p build/bundle/bin
  printf '%s\n' '#!/bin/sh' > build/bundle/bin/main
  chmod 755 build/bundle/bin/main
  exit 0
fi
echo "unexpected dart invocation: $*" >&2
exit 1
EOF
chmod 755 "${tmp}/bin/dart"

printf '%s\n' 'name: sample' > "${tmp}/pkg/pubspec.yaml"
printf '%s\n' 'void main() {}' > "${tmp}/pkg/bin/main.dart"
printf '%s\n' 'apiServer:' > "${tmp}/pkg/config/production.yaml"
printf '%s\n' 'passwords: example' > "${tmp}/pkg/config/passwords.yaml.example"
printf '%s\n' 'protocol: sample' > "${tmp}/pkg/lib/src/generated/protocol.yaml"
printf '%s\n' 'index' > "${tmp}/pkg/web/index.html"
mkdir -p "${tmp}/pkg/migrations/00000000000000"
printf '%s\n' 'migration' > "${tmp}/pkg/migrations/00000000000000/definition.sql"

printf '%s\n' 'database: secret' > "${tmp}/pkg/config/passwords.yaml"
set +e
PATH="${tmp}/bin:${PATH}" \
  SERVER_DIR="${tmp}/pkg" \
  DART_ARGS_FILE="${tmp}/args" \
  bash "$build" >"${tmp}/secret.out" 2>"${tmp}/secret.err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "passwords.yaml was published" >&2
  exit 1
fi
if ! grep -q 'Refusing to publish config/passwords.yaml' "${tmp}/secret.err"; then
  echo "passwords refusal did not explain why" >&2
  cat "${tmp}/secret.err" >&2
  exit 1
fi
if [[ -e "${tmp}/args" ]]; then
  echo "dart ran even though passwords.yaml was present" >&2
  exit 1
fi
rm -f "${tmp}/pkg/config/passwords.yaml"

: > "${tmp}/args"
PATH="${tmp}/bin:${PATH}" \
  SERVER_DIR="${tmp}/pkg" \
  DART_ARGS_FILE="${tmp}/args" \
  bash "$build"
if ! grep -q 'pub get' "${tmp}/args"; then
  echo "build did not run dart pub get" >&2
  cat "${tmp}/args" >&2
  exit 1
fi
if ! grep -q 'build cli --target bin/main.dart --output build' "${tmp}/args"; then
  echo "build did not run dart build cli" >&2
  cat "${tmp}/args" >&2
  exit 1
fi
release="${tmp}/pkg/build/sitehost"
if [[ ! -x "${release}/bin/server" ]]; then
  echo "release is missing bin/server" >&2
  exit 1
fi
if [[ -e "${release}/bin/main" ]]; then
  echo "release still contains bin/main" >&2
  exit 1
fi
if [[ ! -f "${release}/config/production.yaml" ]]; then
  echo "release is missing production.yaml" >&2
  exit 1
fi
if [[ ! -f "${release}/config/passwords.yaml.example" ]]; then
  echo "release dropped passwords.yaml.example" >&2
  exit 1
fi
if [[ -e "${release}/config/passwords.yaml" ]]; then
  echo "release contains passwords.yaml" >&2
  exit 1
fi
if [[ "$(cat "${release}/lib/src/generated/protocol.yaml")" != "protocol: sample" ]]; then
  echo "release is missing protocol.yaml" >&2
  exit 1
fi
if [[ ! -f "${release}/web/index.html" || ! -f "${release}/migrations/00000000000000/definition.sql" ]]; then
  echo "release dropped web or migrations" >&2
  exit 1
fi

rm -f "${tmp}/pkg/lib/src/generated/protocol.yaml"
set +e
PATH="${tmp}/bin:${PATH}" \
  SERVER_DIR="${tmp}/pkg" \
  DART_ARGS_FILE="${tmp}/args-missing" \
  bash "$build" >"${tmp}/missing.out" 2>"${tmp}/missing.err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "missing protocol.yaml was accepted" >&2
  exit 1
fi
if ! grep -q 'protocol.yaml' "${tmp}/missing.err"; then
  echo "missing protocol.yaml did not explain why" >&2
  cat "${tmp}/missing.err" >&2
  exit 1
fi

echo "build test passed"
