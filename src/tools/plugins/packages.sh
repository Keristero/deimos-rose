#!/usr/bin/env bash
# Prints each code plugin and the packages that make it, one per line:
#
#   chaingun plugins/chaingun plugins/chaingun/view
#
# plugins/<name> and its view/ where they hold Odin source; a plugin's
# tests/ are its own program. A data plugin, content only (D52), prints
# nothing. Every plugin, or those named.
set -euo pipefail
cd "$(dirname "$0")/../.."
names=("$@")
if [ ${#names[@]} -eq 0 ]; then
	for dir in plugins/*/; do names+=("$(basename "$dir")"); done
fi
for name in "${names[@]}"; do
	[ -d "plugins/$name" ] || { echo "packages: no plugins/$name" >&2; exit 1; }
	line=$name
	for p in "plugins/$name" "plugins/$name/view"; do
		ls "$p"/*.odin >/dev/null 2>&1 && line="$line $p"
	done
	[ "$line" = "$name" ] || echo "$line"
done
