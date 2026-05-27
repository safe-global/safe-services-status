#!/usr/bin/env bash
#
# prune-graphs-history.sh — periodic repo-size cleanup for this Upptime repo.
#
# WHY THIS EXISTS
#   Upptime's Graphs CI commits ~250 regenerated PNGs every run. PNGs are binary and
#   change every time, so git cannot delta-compress them: graphs/ history grows ~1 GB/yr
#   and dominates repo size (measured: 4.48 GB of 4.5 GB). This script strips graphs/
#   from ALL history while PRESERVING history/*.yml (the uptime time-series Upptime reads
#   to compute graphs and uptime %). The next Graphs CI run regenerates current graphs.
#
# WHAT IT DOES
#   1. Fresh `git clone --mirror` from origin (all branches: master, gh-pages, features).
#   2. `git filter-repo --path graphs --invert-paths`  (removes only graphs/).
#   3. Aggressive gc; prints before/after size (expect ~4.5 GB -> ~85 MB).
#   4. STOPS and requires you to type CONFIRM before any force-push.
#
# WHAT IT DOES NOT / CANNOT DO (you must do these around it)
#   - Freeze CI first (this repo auto-commits every ~5 min, force-push would drop them).
#   - Temporarily lift branch protection on master.
#   - File a GitHub Support ticket afterward to actually reclaim server-side storage.
#   - Make teammates re-clone (old clones reintroduce the blobs if merged back).
#
# SAFETY
#   - gh-pages is an orphan branch with no graphs/ path; its CONTENT tree is unchanged
#     (only its commit hash shifts). The Pages site renders identically. It is NOT deleted.
#   - A full backup mirror is written before anything is pushed.
#
# USAGE
#   ./scripts/prune-graphs-history.sh            # rewrite + verify, prompt before push
#   ./scripts/prune-graphs-history.sh --dry-run  # rewrite + verify, never offer to push
#
set -euo pipefail

REMOTE="git@github.com:safe-global/safe-services-status.git"
WORK="$(mktemp -d -t ssr-prune.XXXXXX)"
MIRROR="$WORK/ssr-rewrite.git"
BACKUP="$WORK/ssr-backup.git"
DRY_RUN="${1:-}"

command -v git-filter-repo >/dev/null 2>&1 || git filter-repo --version >/dev/null 2>&1 || {
  echo "ERROR: git-filter-repo not installed.  brew install git-filter-repo" >&2; exit 1; }

echo ">> Working dir: $WORK"
echo ">> Cloning fresh mirror from $REMOTE ..."
git clone --mirror "$REMOTE" "$MIRROR"
cp -r "$MIRROR" "$BACKUP"
echo ">> Backup mirror kept at: $BACKUP"

before=$(du -sh "$MIRROR" | cut -f1)
ghp_tree_before=$(git -C "$MIRROR" rev-parse gh-pages^{tree} 2>/dev/null || echo "none")

echo ">> Rewriting history (removing graphs/) ..."
git -C "$MIRROR" filter-repo --path graphs --invert-paths --force

echo ">> Repacking ..."
git -C "$MIRROR" reflog expire --all --expire=now
git -C "$MIRROR" gc --prune=now --aggressive

after=$(du -sh "$MIRROR" | cut -f1)
ghp_tree_after=$(git -C "$MIRROR" rev-parse gh-pages^{tree} 2>/dev/null || echo "none")
remaining=$(git -C "$MIRROR" rev-list --all --count -- graphs/)

echo
echo "================ RESULT ================"
echo " size before : $before"
echo " size after  : $after"
echo " graphs/ objects remaining in history : $remaining   (must be 0)"
echo " gh-pages content tree before : $ghp_tree_before"
echo " gh-pages content tree after  : $ghp_tree_after"
if [ "$ghp_tree_before" = "$ghp_tree_after" ]; then
  echo " gh-pages content : UNCHANGED (Pages site unaffected)"
else
  echo " gh-pages content : CHANGED -- STOP and investigate before pushing!" ; exit 1
fi
[ "$remaining" = "0" ] || { echo " graphs/ not fully removed -- STOP."; exit 1; }
echo "========================================"
echo

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo ">> --dry-run: not pushing. Rewritten mirror left at $MIRROR"
  exit 0
fi

cat <<EOF
About to FORCE-PUSH the rewritten history to:
    $REMOTE
This is IRREVERSIBLE and rewrites every branch (gh-pages content unchanged).
Confirm you have:
  [ ] disabled the scheduled workflows (Uptime/Response Time/Graphs/Summary/Static Site)
  [ ] lifted branch protection on master
  [ ] told the team not to push
EOF
read -r -p 'Type CONFIRM to force-push, anything else to abort: ' ans
[ "$ans" = "CONFIRM" ] || { echo "Aborted. Mirror left at $MIRROR"; exit 0; }

git -C "$MIRROR" push --mirror --force
echo
echo ">> Force-push done. NOW:"
echo "   - Re-enable the workflows and restore branch protection."
echo "   - Open a GitHub Support request to GC/repack server-side storage."
echo "   - Tell everyone to delete and re-clone (do NOT merge old clones)."
echo "   - Backup mirror (pre-rewrite) is at: $BACKUP"
