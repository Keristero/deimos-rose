#!/usr/bin/env bash
# Prints the ABI stamp the game and every plugin library are built with
# (-define:DR_ABI=..., dr:blocks's ABI): a digest of every Odin source a
# library can carry a copy of -- the core's packages, the plugins', and
# the libraries they use. The game loads a plugin only when the two agree,
# so a plugin is always run with the very sources it was built against
# (decisions.md D85). Carriage returns are dropped, so a checkout with
# Windows line endings stamps as a Unix one does.
set -euo pipefail
cd "$(dirname "$0")/../.."
find blocks data game plugin_entry plugins prefs render sim third_party ui \
	-name '*.odin' -not -path '*/tests/*' -print0 2>/dev/null |
	LC_ALL=C sort -z |
	xargs -0 cat |
	tr -d '\r' |
	sha256sum | cut -c1-16
