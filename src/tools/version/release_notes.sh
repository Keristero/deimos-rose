#!/usr/bin/env bash
# Prints the Markdown release notes for HEAD: every "Changelog:" block in
# the commits since the previous release tag, oldest first. The commit
# message format is documented in AGENTS.md ("Commits and patch notes"):
#
#   Changelog:
#   - One player-facing change per bullet.
#     An indented line continues the bullet above it.
#
# The block ends at the first line that is neither. On main the previous
# release is the nearest main tag -- v* without a branch suffix, or an
# older build-* -- behind HEAD, so a re-run of the same commit, whose own
# tag already exists, still finds the one before it.
#
# A branch build (tools/version/branch.sh) lists the blocks of the
# branch's own commits, those not on main, and links the latest main
# release, which is what the branch's changes are on top of.
set -euo pipefail
cd "$(dirname "$0")/../.."
branch=$(bash tools/version/branch.sh)
main_tag() {
	git describe --tags --abbrev=0 --match 'v*' --match 'build-*' --exclude 'v*-*' "$1" 2>/dev/null || true
}
if [ -n "$branch" ]; then
	main_ref=$(git rev-parse -q --verify origin/main || git rev-parse -q --verify main || true)
	base=${main_ref:+$(git merge-base "$main_ref" HEAD)}
	range=${base:+$base..}HEAD
	latest=${main_ref:+$(main_tag "$main_ref")}
else
	prev=$(main_tag HEAD^)
	range=${prev:+$prev..}HEAD
fi

# A plain-text boundary line: mawk (Ubuntu's awk, which CI runs) does not
# take \x escapes in a regex.
notes=$(git log --reverse --format='@@deimos-commit@@%n%B' "$range" | awk '
	/^@@deimos-commit@@$/ { inblock = 0; next }
	/^Changelog:[ \t]*$/ { inblock = 1; next }
	inblock && /^- /  { print; next }
	inblock && /^  [^ ]/ && NF { sub(/^ +/, "  "); print; next }
	                  { inblock = 0 }
')

if [ -n "$branch" ]; then
	echo "**Branch build of \`${GITHUB_REF_NAME:-$branch}\`**, not a release of main."
	if [ -n "$latest" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
		echo "The latest release of main is [$latest](https://github.com/$GITHUB_REPOSITORY/releases/tag/$latest)."
	fi
	echo
	echo "## Changes on this branch"
else
	echo "## Changes"
fi
echo
if [ -n "$notes" ]; then
	echo "$notes"
else
	echo "No player-facing changes in this release."
fi
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
	if [ -n "$branch" ] && [ -n "$latest" ]; then
		echo
		echo "All commits since $latest: https://github.com/$GITHUB_REPOSITORY/compare/$latest...$(git rev-parse --short HEAD)"
	elif [ -z "$branch" ] && [ -n "$prev" ]; then
		echo
		echo "All commits: https://github.com/$GITHUB_REPOSITORY/compare/$prev...$(git rev-parse --short HEAD)"
	fi
fi
