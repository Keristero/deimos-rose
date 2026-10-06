#!/usr/bin/env bash
# CI only: pins mise's Odin to mise.toml's DR_ODIN, in the gitignored
# mise.local.toml, before mise itself is installed (so the value is read
# from the file, not mise's environment).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ver=$(sed -n 's/^DR_ODIN *= *"\(.*\)".*/\1/p' mise.toml)
[ -n "$ver" ] || { echo "ci-pin-odin: no DR_ODIN in mise.toml" >&2; exit 1; }
printf '[tools]\nodin = "%s"\n' "$ver" > mise.local.toml
cat mise.local.toml
