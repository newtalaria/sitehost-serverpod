#!/usr/bin/env bash
# Path checks shared by the remote scripts.
# ssh-payload.sh prepends this file onto the encoded script, so the container
# receives the functions in the same bash process. A script run as a file
# sources this file when SITEHOST_LIB_LOADED is unset.

# Remote scripts skip their own source when this is already set.
export SITEHOST_LIB_LOADED=1

# Reject a path that is relative, contains "..", or is the filesystem root.
assert_absolute_path() {
  local label="$1"
  local value="$2"
  case "$value" in
    /*) ;;
    *)
      echo "${label} must be an absolute path" >&2
      exit 1
      ;;
  esac
  case "$value" in
    *..*|*\;*|*[[:space:]]*)
      echo "${label} must not contain .., whitespace, or a semicolon" >&2
      exit 1
      ;;
  esac
  if [[ "$value" == "/" ]]; then
    echo "Refusing to use / as ${label}" >&2
    exit 1
  fi
}
