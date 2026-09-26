#!/usr/bin/env bash
# Prints the branch a CI build is of, made safe for a tag and a file name
# (anything but letters, digits, dots and dashes becomes a dash), or
# nothing for main and for builds outside CI. version.sh labels branch
# builds with it, and the release job decides from it whether a release is
# main's or a branch's.
set -euo pipefail
ref=${GITHUB_REF_NAME:-}
[ -n "${CI:-}" ] && [ -n "$ref" ] && [ "$ref" != main ] || exit 0
printf '%s' "$ref" | tr -c 'A-Za-z0-9.-' '-'
echo
