#!/usr/bin/env bash
# Prints the Markdown release notes for HEAD: every "Changelog:" block in
# the commits since the previous release tag, oldest first. The commit
# message format is documented in AGENTS.md ("Commits and patch notes"):
#
#   Changelog:
#   - One player-facing change per bullet.
#     An indented line continues the bullet above it.
#
# The block ends at the first line that is neither. The previous release is
# the nearest v* (or older build-*) tag behind HEAD, so a re-run of the
# same commit, whose own tag already exists, still finds the one before it.
set -euo pipefail
cd "$(dirname "$0")/../.."
prev=$(git describe --tags --abbrev=0 --match 'v*' --match 'build-*' HEAD^ 2>/dev/null || true)
range=${prev:+$prev..}HEAD

# A plain-text boundary line: mawk (Ubuntu's awk, which CI runs) does not
# take \x escapes in a regex.
notes=$(git log --reverse --format='@@deimos-commit@@%n%B' "$range" | awk '
	/^@@deimos-commit@@$/ { inblock = 0; next }
	/^Changelog:[ \t]*$/ { inblock = 1; next }
	inblock && /^- /  { print; next }
	inblock && /^  [^ ]/ && NF { sub(/^ +/, "  "); print; next }
	                  { inblock = 0 }
')

echo "## Changes"
echo
if [ -n "$notes" ]; then
	echo "$notes"
else
	echo "No player-facing changes in this release."
fi
if [ -n "$prev" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
	echo
	echo "All commits: https://github.com/$GITHUB_REPOSITORY/compare/$prev...$(git rev-parse --short HEAD)"
fi
