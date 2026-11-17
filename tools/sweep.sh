#!/bin/sh
# Free disk taken by builds: in this checkout and every git worktree of it,
# clear what no build has used for DAYS days (default 14), and with
# --worktrees also remove worktrees under .claude/worktrees whose branch is
# merged into main and that have no uncommitted changes.
#
#   nix develop -c tools/sweep.sh            # artifacts older than 14 days
#   nix develop -c tools/sweep.sh 3 --worktrees
set -eu
days=14
prune=
for a in "$@"; do
  case "$a" in
    --worktrees) prune=1 ;;
    *) days="$a" ;;
  esac
done
root=$(git rev-parse --show-toplevel)
cd "$root"

if [ -n "$prune" ]; then
  git worktree list --porcelain | awk '/^worktree /{w=$2} /^branch /{print w, $2}' |
  while read -r tree branch; do
    case "$tree" in "$root"/.claude/worktrees/*) ;; *) continue ;; esac
    git merge-base --is-ancestor "$branch" main 2>/dev/null || continue
    [ -z "$(git -C "$tree" status --porcelain 2>/dev/null)" ] || continue
    # A tree an agent is still working in is locked; leave it.
    [ -e "$(git -C "$tree" rev-parse --git-dir)/locked" ] && continue
    echo "removing merged worktree $tree"
    git worktree remove --force "$tree"
  done
  git worktree prune
fi

git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r tree; do
  [ -d "$tree/target" ] || continue
  echo "sweeping $tree"
  (cd "$tree" && cargo sweep -t "$days" >/dev/null)
done
command -v sccache >/dev/null && sccache --show-stats | grep -E "Cache size|Max cache" || true
