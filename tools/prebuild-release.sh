#!/usr/bin/env bash
#
# Materialize the fork's `prebuild` branch for an upstream release tag.
#
#   tools/prebuild-release.sh v0.2.37
#
# Given an upstream tag, this:
#   1. fetches refs/tags/<tag> from upstream (lovablelabs/oj),
#   2. resets the `prebuild` branch to that release commit,
#   3. overlays the fork's CI-only files from the `ci` branch,
#   4. commits, creates the same tag locally, and pushes both to origin.
#
# The `ci` branch is an orphan branch: it holds only the fork's CI changes
# (the prebuild workflow and this script) and none of the upstream tree, so
# the overlay is a straight copy with nothing to merge as upstream moves.
#
# Pushing `prebuild` starts the prebuild workflow. Upstream's release.yml is
# dropped from the generated commit by default so a tag push on the fork
# cannot attempt a crates.io publish; set KEEP_RELEASE_WORKFLOW=1 to keep it.
#
# Overridable env:
#   UPSTREAM_URL=https://github.com/lovablelabs/oj.git
#   CI_BRANCH=ci
#   TARGET_BRANCH=prebuild
#   ORIGIN=origin
#   KEEP_RELEASE_WORKFLOW=0
#   DRY_RUN=0
set -euo pipefail

# The overlay replaces files in the working tree (and this script is not in
# the upstream tree), while bash reads a script lazily. Run from a temp copy
# so the file changing underneath cannot truncate the run.
if [ -z "${PREBUILD_REEXEC:-}" ]; then
  _prebuild_tmp="$(mktemp "${TMPDIR:-/tmp}/prebuild-release.XXXXXX")"
  cp "$0" "$_prebuild_tmp"
  chmod +x "$_prebuild_tmp"
  PREBUILD_REEXEC=1 PREBUILD_REEXEC_TMP="$_prebuild_tmp" \
    exec "$_prebuild_tmp" "$@"
fi
trap 'rm -f "${PREBUILD_REEXEC_TMP:-}"' EXIT

die() { printf 'prebuild-release: %s\n' "$*" >&2; exit 1; }

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/lovablelabs/oj.git}"
CI_BRANCH="${CI_BRANCH:-ci}"
TARGET_BRANCH="${TARGET_BRANCH:-prebuild}"
ORIGIN="${ORIGIN:-origin}"

tag="${1:-}"
[ -n "$tag" ] || die "usage: $0 <upstream-tag>  (e.g. v0.2.37)"
case "$tag" in
  v[0-9]*) ;;
  *) die "tag '$tag' does not look like v<version>" ;;
esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$root"

[ -z "$(git status --porcelain)" ] || die "working tree is not clean; commit or stash first"
git rev-parse --verify --quiet "$CI_BRANCH^{commit}" >/dev/null \
  || die "CI branch '$CI_BRANCH' not found locally"

echo "prebuild-release: fetching $tag from $UPSTREAM_URL"
tmp_ref="refs/prebuild-sync/upstream-$tag"
git fetch --force --no-tags "$UPSTREAM_URL" "+refs/tags/$tag:$tmp_ref"
commit="$(git rev-parse --verify "$tmp_ref^{commit}")"
git update-ref -d "$tmp_ref"

# The workspace version must match the tag, same invariant release.yml checks.
want="${tag#v}"
have="$(git show "$commit:Cargo.toml" | sed -n 's/^version = "\(.*\)"$/\1/p' | head -1)"
[ "$have" = "$want" ] || die "tag $tag expects version $want but $commit has $have"

echo "prebuild-release: $tag -> $commit (version $have)"
git checkout -B "$TARGET_BRANCH" "$commit" >/dev/null

# Overlay every path the CI branch carries. Paths only in the upstream tree
# are untouched; paths in both are replaced by the CI branch's copy, so the
# CI branch stays the single source of truth for fork-only changes.
git checkout "$CI_BRANCH" -- .

if [ "${KEEP_RELEASE_WORKFLOW:-0}" != "1" ] \
   && git cat-file -e "HEAD:.github/workflows/release.yml" 2>/dev/null; then
  git rm -q -f .github/workflows/release.yml
  echo "prebuild-release: dropped upstream release.yml (KEEP_RELEASE_WORKFLOW=1 to keep)"
fi

if git diff --cached --quiet; then
  echo "prebuild-release: no overlay changes to commit"
else
  git commit -q -m "ci: overlay fork CI on $tag"
fi

git tag -f "$tag" HEAD >/dev/null
echo "prebuild-release: $TARGET_BRANCH at $(git rev-parse --short HEAD), tagged $tag"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "prebuild-release: DRY_RUN=1, not pushing"
  exit 0
fi

git push --force-with-lease "$ORIGIN" \
  "refs/heads/$TARGET_BRANCH:refs/heads/$TARGET_BRANCH"
git push --force "$ORIGIN" "refs/tags/$tag:refs/tags/$tag"
echo "prebuild-release: pushed $TARGET_BRANCH and $tag to $ORIGIN"
echo "prebuild-release: the $TARGET_BRANCH push starts the prebuild workflow"
