#!/usr/bin/env bash
#
# Daily upstream sync for the prebuild fork. Intended to be run from cron;
# tools/install-sync-cron.sh installs that entry.
#
#   1. fast-forward `main` to lovablelabs/oj main and push it to origin
#   2. for every upstream vX.Y.Z tag not already on origin (i.e. newer than
#      our newest release), run tools/prebuild-release.sh <tag>, which moves
#      `prebuild` to upstream + CI, pushes it, and pushes the tag; that tag
#      triggers the prebuild workflow and its GitHub release
#   3. leave the working tree back on the `ci` branch
#
# The server needs git and a gh-configured credential helper for origin
# (`gh auth setup-git`); upstream is read anonymously over https.
#
# Env overrides:
#   UPSTREAM_URL  default https://github.com/lovablelabs/oj.git
#   ORIGIN        default origin
#   HOME_BRANCH   default ci
#   MAIN_BRANCH   default main
set -euo pipefail

log() { printf '%s upstream-sync: %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "error: $*"; exit 1; }

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/lovablelabs/oj.git}"
ORIGIN="${ORIGIN:-origin}"
HOME_BRANCH="${HOME_BRANCH:-ci}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
export UPSTREAM_URL ORIGIN

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$root"

# One run at a time: a slow previous run must not interleave branch moves.
if command -v flock >/dev/null 2>&1; then
  exec 9>"${TMPDIR:-/tmp}/oj-upstream-sync.lock"
  flock -n 9 || die "another upstream-sync is already running"
fi

[ -z "$(git status --porcelain)" ] || die "working tree is not clean; refusing to sync"
[ -x tools/prebuild-release.sh ] || die "tools/prebuild-release.sh missing; run this from the ci checkout"

# Always end back on the ci branch, even if a step fails midway.
trap 'git checkout -q "$HOME_BRANCH" 2>/dev/null || true' EXIT

git checkout -q "$HOME_BRANCH"

log "fetching $ORIGIN and $UPSTREAM_URL"
git fetch --prune --no-tags "$ORIGIN"
git fetch --force --no-tags "$UPSTREAM_URL" \
  "+refs/heads/$MAIN_BRANCH:refs/upstream/$MAIN_BRANCH"

# 1. main mirrors upstream.
git checkout -q "$MAIN_BRANCH"
git reset --hard -q "refs/upstream/$MAIN_BRANCH"
git push --force-with-lease "$ORIGIN" \
  "refs/heads/$MAIN_BRANCH:refs/heads/$MAIN_BRANCH"
log "synced $MAIN_BRANCH to $(git rev-parse --short HEAD)"

# 2. every upstream tag newer than our newest, oldest first.
remote_tags() {
  git ls-remote --tags --refs "$1" 'refs/tags/v[0-9]*' | sed -n 's#.*refs/tags/##p'
}
upstream_tags="$(remote_tags "$UPSTREAM_URL" | sed '/^$/d' | sort -V)"
# Our newest release. The fork only carries the tags we made ourselves, so
# this is NOT a set difference against upstream's history: anything upstream
# has that is older than our newest is already accounted for.
our_newest="$(remote_tags "$ORIGIN" | sed '/^$/d' | sort -V | tail -1)"
if [ -z "$upstream_tags" ]; then
  new_tags=""
elif [ -z "$our_newest" ]; then
  # Nothing released yet: start from the newest upstream tag only.
  new_tags="$(printf '%s\n' "$upstream_tags" | tail -1)"
else
  # Merge our newest into the upstream list by version and take everything
  # strictly after it (uniq drops the duplicate when we are also upstream's).
  new_tags="$(printf '%s\n%s\n' "$upstream_tags" "$our_newest" \
    | sed '/^$/d' | sort -V | uniq \
    | awk -v m="$our_newest" 'f{print} $0==m{f=1}')"
fi

if [ -z "$new_tags" ]; then
  log "no new upstream tags (newest upstream: $(printf '%s\n' "$upstream_tags" | tail -1))"
else
  log "new upstream tags: $(printf '%s' "$new_tags" | tr '\n' ' ')"
  for tag in $new_tags; do
    log "releasing $tag"
    ./tools/prebuild-release.sh "$tag"
  done
fi

log "done"
