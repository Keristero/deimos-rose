#!/usr/bin/env bash
# Runs one of another commit's own mise tasks, in a worktree of it under
# $DR_BUILD/refs/, so a change can be measured against its base with the
# base's own code and tools: `REF=site-and-workflow TASK=bench mise run ref`.
# Prints the worktree's src/ last, for tasks that take a ROOT
# (menu-shots:all). The worktree is kept and reused; remove it with
# `git worktree remove`.
set -euo pipefail
# KEY=value arguments (`mise run <task> A=x`) set KEY, as the environment does.
for a in "$@"; do case "$a" in [A-Z]*=*) export "$a" ;; esac; done
: "${REF:?REF=<branch or commit> is required}"
TASK="${TASK:-build}"
commit=$(git -C "$DR_SRC" rev-parse --verify "$REF^{commit}")
slug=$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '-')
wt="$DR_BUILD/refs/$slug"
if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
  git -C "$wt" checkout -q --detach "$commit"
else
  mkdir -p "$DR_BUILD/refs"
  git -C "$DR_SRC" worktree add -q --detach "$wt" "$commit"
fi
# The third-party libraries are not in git; share this tree's.
[ -e "$wt/src/.deps" ] || ln -s "$DR_SRC/.deps" "$wt/src/.deps"
echo "ref: $REF at $(git -C "$wt" log -1 --format='%h %s')" >&2
# This tree's DR_* values would win over the worktree's (DR_PLUGINS and
# DR_WINE keep a value already in the environment), so drop them all.
unset_dr=()
while IFS='=' read -r k _; do
  case "$k" in DR_*) unset_dr+=(-u "$k") ;; esac
done < <(env)
cd "$wt/src"
env "${unset_dr[@]}" MISE_TRUSTED_CONFIG_PATHS="$wt/src" mise run "$TASK"
echo "$wt/src"
