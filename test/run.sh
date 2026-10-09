#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
bash "${dir}/payload.test.sh"
bash "${dir}/install.test.sh"
bash "${dir}/publish.test.sh"
bash "${dir}/build.test.sh"
