#!/usr/bin/env bash
# Prints the version this commit builds as: v<major.minor>.<commits>, where
# major.minor is src/VERSION (bumped by hand) and <commits> is the number of
# commits reachable from HEAD -- so every commit on main gets its own,
# increasing number, and any job that builds the same commit computes the
# same version with no coordination. CI tags releases with it and bakes it
# into the binary (mise.toml's build tasks, -define:DR_VERSION); the main
# menu shows it.
#
# A CI build of any branch but main ends in -<branch>, so it can never take
# main's tag for the same count, and says where it came from wherever the
# version shows. Outside CI the result ends in -local, so a build from
# someone's working tree is never mistaken for the release of the same
# number. Without git (a source zip) it prints "dev".
set -euo pipefail
cd "$(dirname "$0")/../.."
base=$(tr -d ' \r\n' < VERSION)
if ! git rev-parse --git-dir >/dev/null 2>&1; then
	echo dev
	exit 0
fi
# A shallow clone (actions/checkout's default) would count 1 commit and
# silently mint a duplicate version; refuse instead.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
	echo "version.sh: shallow clone -- fetch full history (fetch-depth: 0)" >&2
	exit 1
fi
v="v$base.$(git rev-list --count HEAD)"
if [ -z "${CI:-}" ]; then
	v="$v-local"
elif [ -n "$(bash tools/version/branch.sh)" ]; then
	v="$v-$(bash tools/version/branch.sh)"
fi
echo "$v"
