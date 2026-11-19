#!/usr/bin/env bash
#
# Install (or remove) the daily upstream-sync crontab entry.
#
#   tools/install-sync-cron.sh            # install / update (idempotent)
#   tools/install-sync-cron.sh --remove   # remove the entry
#
# Env overrides:
#   CRON_SCHEDULE  default "17 4 * * *" (daily at 04:17 UTC/server time)
#   SYNC_LOG       default "$HOME/.oj-upstream-sync.log"
#
# The entry bakes in the PATH seen here so cron (whose default PATH is bare)
# still finds git/gh. Make sure origin is reachable non-interactively, e.g.
# an https origin plus `gh auth setup-git`, or an ssh key cron can read.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repository" >&2; exit 1; }
job="$root/tools/upstream-sync.sh"
schedule="${CRON_SCHEDULE:-17 4 * * *}"
log_file="${SYNC_LOG:-$HOME/.oj-upstream-sync.log}"

command -v crontab >/dev/null 2>&1 || { echo "crontab not found" >&2; exit 1; }
[ -x "$job" ] || { echo "$job is not executable" >&2; exit 1; }

current="$(crontab -l 2>/dev/null || true)"
# Drop any earlier entry for this job so re-running replaces it.
cleaned="$(printf '%s\n' "$current" | grep -vF -- "$job" || true)"

if [ "${1:-}" = "--remove" ]; then
  printf '%s\n' "$cleaned" | sed '/^$/d' | crontab -
  echo "removed the upstream-sync crontab entry"
  exit 0
fi

mkdir -p "$(dirname "$log_file")"
# Bake the dirs cron needs (cron's own PATH is bare), not a huge login PATH.
git_dir="$(dirname "$(command -v git)")"
gh_dir=""
if gh_bin="$(command -v gh 2>/dev/null)"; then gh_dir="$(dirname "$gh_bin")"; fi
path="$git_dir${gh_dir:+:$gh_dir}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
entry="$schedule export PATH=$path; cd \"$root\" && \"$job\" >> \"$log_file\" 2>&1"
printf '%s\n%s\n' "$cleaned" "$entry" | sed '/^$/d' | crontab -

echo "installed crontab entry:"
echo "  $entry"
echo "log: $log_file"
